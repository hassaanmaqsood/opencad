const std = @import("std");
const c_types = @import("c_types.zig");

pub const ElementType = enum(u8) {
    Tet4 = 4,
    Tet10 = 10,
};

pub const BoundaryTriangle = struct {
    indices: [3]u32,
    topo_id: c_types.CadTopoId,
    normal: [3]f64,
};

pub const TetMesh = struct {
    allocator: std.mem.Allocator,
    element_type: ElementType = .Tet4,
    /// Flat array of nodal coordinates [x0, y0, z0, x1, y1, z1, ...] in millimeters or meters
    node_positions: std.ArrayListUnmanaged(f64) = .empty,
    /// Flat array of element node indices. Stride is 4 for Tet4, 10 for Tet10.
    element_indices: std.ArrayListUnmanaged(u32) = .empty,
    /// Boundary surface triangles preserving topological CadTopoId tags
    boundary_triangles: std.ArrayListUnmanaged(BoundaryTriangle) = .empty,
    /// Node-to-TopoId tag set: maps node index to the CadTopoId of the face it belongs to
    node_topo_tags: std.AutoHashMapUnmanaged(u32, u64) = .empty,

    pub fn init(allocator: std.mem.Allocator, el_type: ElementType) TetMesh {
        return .{
            .allocator = allocator,
            .element_type = el_type,
        };
    }

    pub fn deinit(self: *TetMesh) void {
        self.node_positions.deinit(self.allocator);
        self.element_indices.deinit(self.allocator);
        self.boundary_triangles.deinit(self.allocator);
        self.node_topo_tags.deinit(self.allocator);
    }

    pub fn nodeCount(self: TetMesh) usize {
        return self.node_positions.items.len / 3;
    }

    pub fn elementCount(self: TetMesh) usize {
        const stride: usize = @intFromEnum(self.element_type);
        if (stride == 0) return 0;
        return self.element_indices.items.len / stride;
    }

    pub fn getNode(self: TetMesh, node_idx: usize) [3]f64 {
        const base = node_idx * 3;
        return .{
            self.node_positions.items[base],
            self.node_positions.items[base + 1],
            self.node_positions.items[base + 2],
        };
    }

    /// Generates a boundary-conforming tetrahedral mesh for a rectangular solid beam / block
    /// with tagged boundary faces (0: -X root, 1: +X tip, 2: -Y bottom, 3: +Y top, 4: -Z back, 5: +Z front).
    pub fn generateTaggedBoxMesh(
        self: *TetMesh,
        dx: f64,
        dy: f64,
        dz: f64,
        nx: usize,
        ny: usize,
        nz: usize,
        face_topo_ids: ?[6]c_types.CadTopoId,
    ) !void {
        self.node_positions.clearRetainingCapacity();
        self.element_indices.clearRetainingCapacity();
        self.boundary_triangles.clearRetainingCapacity();
        self.node_topo_tags.clearRetainingCapacity();

        const default_ids = [6]c_types.CadTopoId{
            .{ .raw = 100 }, // -X Left / Fixed Root
            .{ .raw = 101 }, // +X Right / Stage Tip
            .{ .raw = 102 }, // -Y Bottom
            .{ .raw = 103 }, // +Y Top
            .{ .raw = 104 }, // -Z Back
            .{ .raw = 105 }, // +Z Front
        };
        const actual_ids = face_topo_ids orelse default_ids;

        // 1. Generate regular 3D grid vertices
        for (0..nz + 1) |k| {
            const z = (@as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(nz))) * dz;
            for (0..ny + 1) |j| {
                const y = (@as(f64, @floatFromInt(j)) / @as(f64, @floatFromInt(ny))) * dy;
                for (0..nx + 1) |i| {
                    const x = (@as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(nx))) * dx;
                    const node_idx: u32 = @intCast(self.node_positions.items.len / 3);
                    try self.node_positions.appendSlice(self.allocator, &.{ x, y, z });

                    // Tag boundary vertices
                    if (i == 0) try self.node_topo_tags.put(self.allocator, node_idx, actual_ids[0].raw);
                    if (i == nx) try self.node_topo_tags.put(self.allocator, node_idx, actual_ids[1].raw);
                    if (j == 0) try self.node_topo_tags.put(self.allocator, node_idx, actual_ids[2].raw);
                    if (j == ny) try self.node_topo_tags.put(self.allocator, node_idx, actual_ids[3].raw);
                    if (k == 0) try self.node_topo_tags.put(self.allocator, node_idx, actual_ids[4].raw);
                    if (k == nz) try self.node_topo_tags.put(self.allocator, node_idx, actual_ids[5].raw);
                }
            }
        }

        const stride_y = nx + 1;
        const stride_z = (nx + 1) * (ny + 1);

        const nodeAt = struct {
            fn get(i: usize, j: usize, k: usize, sy: usize, sz: usize) u32 {
                return @intCast(i + j * sy + k * sz);
            }
        }.get;

        // 2. Subdivide each hexahedral grid cell into 5 Delaunay tetrahedra (or 6 symmetric)
        for (0..nz) |k| {
            for (0..ny) |j| {
                for (0..nx) |i| {
                    const v0 = nodeAt(i, j, k, stride_y, stride_z);
                    const v1 = nodeAt(i + 1, j, k, stride_y, stride_z);
                    const v2 = nodeAt(i + 1, j + 1, k, stride_y, stride_z);
                    const v3 = nodeAt(i, j + 1, k, stride_y, stride_z);
                    const v4 = nodeAt(i, j, k + 1, stride_y, stride_z);
                    const v5 = nodeAt(i + 1, j, k + 1, stride_y, stride_z);
                    const v6 = nodeAt(i + 1, j + 1, k + 1, stride_y, stride_z);
                    const v7 = nodeAt(i, j + 1, k + 1, stride_y, stride_z);

                    // Alternating 5-tet subdivision for optimal dihedral angles
                    const parity = (i + j + k) % 2;
                    if (parity == 0) {
                        try self.element_indices.appendSlice(self.allocator, &.{ v0, v1, v3, v4 });
                        try self.element_indices.appendSlice(self.allocator, &.{ v1, v2, v3, v6 });
                        try self.element_indices.appendSlice(self.allocator, &.{ v1, v4, v5, v6 });
                        try self.element_indices.appendSlice(self.allocator, &.{ v3, v4, v6, v7 });
                        try self.element_indices.appendSlice(self.allocator, &.{ v1, v3, v4, v6 });
                    } else {
                        try self.element_indices.appendSlice(self.allocator, &.{ v0, v1, v2, v5 });
                        try self.element_indices.appendSlice(self.allocator, &.{ v0, v2, v3, v7 });
                        try self.element_indices.appendSlice(self.allocator, &.{ v0, v4, v5, v7 });
                        try self.element_indices.appendSlice(self.allocator, &.{ v2, v5, v6, v7 });
                        try self.element_indices.appendSlice(self.allocator, &.{ v0, v2, v5, v7 });
                    }
                }
            }
        }

        // 3. Extract boundary triangles and assign CadTopoId tags
        // -X Face
        for (0..nz) |k| {
            for (0..ny) |j| {
                const p0 = nodeAt(0, j, k, stride_y, stride_z);
                const p1 = nodeAt(0, j + 1, k, stride_y, stride_z);
                const p2 = nodeAt(0, j + 1, k + 1, stride_y, stride_z);
                const p3 = nodeAt(0, j, k + 1, stride_y, stride_z);
                try self.boundary_triangles.append(self.allocator, .{ .indices = .{ p0, p2, p1 }, .topo_id = actual_ids[0], .normal = .{ -1.0, 0.0, 0.0 } });
                try self.boundary_triangles.append(self.allocator, .{ .indices = .{ p0, p3, p2 }, .topo_id = actual_ids[0], .normal = .{ -1.0, 0.0, 0.0 } });
            }
        }
        // +X Face
        for (0..nz) |k| {
            for (0..ny) |j| {
                const p0 = nodeAt(nx, j, k, stride_y, stride_z);
                const p1 = nodeAt(nx, j + 1, k, stride_y, stride_z);
                const p2 = nodeAt(nx, j + 1, k + 1, stride_y, stride_z);
                const p3 = nodeAt(nx, j, k + 1, stride_y, stride_z);
                try self.boundary_triangles.append(self.allocator, .{ .indices = .{ p0, p1, p2 }, .topo_id = actual_ids[1], .normal = .{ 1.0, 0.0, 0.0 } });
                try self.boundary_triangles.append(self.allocator, .{ .indices = .{ p0, p2, p3 }, .topo_id = actual_ids[1], .normal = .{ 1.0, 0.0, 0.0 } });
            }
        }

        // 4. Upgrade to quadratic Tet10 if requested
        if (self.element_type == .Tet10) {
            try self.upgradeToTet10();
        }
    }

    /// Upgrades the linear Tet4 mesh to quadratic 10-node isoparametric Tet10 elements
    /// by inserting midpoint nodes along every unique element edge.
    pub fn upgradeToTet10(self: *TetMesh) !void {
        const EdgeKey = struct {
            u: u32,
            v: u32,

            pub fn init(n0: u32, n1: u32) @This() {
                return if (n0 < n1) .{ .u = n0, .v = n1 } else .{ .u = n1, .v = n0 };
            }
        };

        var edge_to_midpoint = std.AutoHashMap(EdgeKey, u32).init(self.allocator);
        defer edge_to_midpoint.deinit();

        const tet4_count = self.element_indices.items.len / 4;
        var tet10_indices = try std.ArrayListUnmanaged(u32).initCapacity(self.allocator, tet4_count * 10);
        defer tet10_indices.deinit(self.allocator);

        // Standard edge local connectivity for Tet4:
        // Edge 0: (0, 1), Edge 1: (1, 2), Edge 2: (2, 0), Edge 3: (0, 3), Edge 4: (1, 3), Edge 5: (2, 3)
        const tet_edges = [6][2]usize{
            .{ 0, 1 },
            .{ 1, 2 },
            .{ 2, 0 },
            .{ 0, 3 },
            .{ 1, 3 },
            .{ 2, 3 },
        };

        for (0..tet4_count) |e| {
            const base = e * 4;
            const c0 = self.element_indices.items[base];
            const c1 = self.element_indices.items[base + 1];
            const c2 = self.element_indices.items[base + 2];
            const c3 = self.element_indices.items[base + 3];
            const corners = [4]u32{ c0, c1, c2, c3 };

            var midpoints: [6]u32 = undefined;
            for (tet_edges, 0..) |edge, edge_idx| {
                const u = corners[edge[0]];
                const v = corners[edge[1]];
                const key = EdgeKey.init(u, v);

                if (edge_to_midpoint.get(key)) |mid_idx| {
                    midpoints[edge_idx] = mid_idx;
                } else {
                    // Create midpoint coordinate
                    const pu = self.getNode(u);
                    const pv = self.getNode(v);
                    const mx = (pu[0] + pv[0]) * 0.5;
                    const my = (pu[1] + pv[1]) * 0.5;
                    const mz = (pu[2] + pv[2]) * 0.5;

                    const new_node_idx: u32 = @intCast(self.nodeCount());
                    try self.node_positions.appendSlice(self.allocator, &.{ mx, my, mz });
                    try edge_to_midpoint.put(key, new_node_idx);
                    midpoints[edge_idx] = new_node_idx;

                    // If both corner nodes share the same boundary TopoId, tag midpoint node
                    const tag_u = self.node_topo_tags.get(u);
                    const tag_v = self.node_topo_tags.get(v);
                    if (tag_u != null and tag_u == tag_v) {
                        try self.node_topo_tags.put(self.allocator, new_node_idx, tag_u.?);
                    }
                }
            }

            // Append 10 nodes for this Tet10 element:
            // 0..3: corners; 4..9: midpoints
            try tet10_indices.appendSlice(self.allocator, &.{
                corners[0], corners[1], corners[2], corners[3],
                midpoints[0], midpoints[1], midpoints[2], midpoints[3], midpoints[4], midpoints[5],
            });
        }

        self.element_indices.clearRetainingCapacity();
        try self.element_indices.appendSlice(self.allocator, tet10_indices.items);
        self.element_type = .Tet10;
    }

    /// Finds all node indices lying on the boundary face specified by `topo_id`.
    pub fn findNodesOnFace(self: TetMesh, allocator: std.mem.Allocator, topo_id: c_types.CadTopoId) ![]u32 {
        var result = std.ArrayList(u32).init(allocator);
        errdefer result.deinit();

        var it = self.node_topo_tags.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* == topo_id.raw) {
                try result.append(entry.key_ptr.*);
            }
        }

        return try result.toOwnedSlice();
    }
};

test "TetMesh basic Tet4 and Tet10 generation" {
    var m = TetMesh.init(std.testing.allocator, .Tet4);
    defer m.deinit();

    try m.generateTaggedBoxMesh(50.0, 10.0, 5.0, 5, 2, 1, null);
    try std.testing.expect(m.nodeCount() > 0);
    try std.testing.expect(m.elementCount() > 0);

    // Verify Tet10 conversion
    var m10 = TetMesh.init(std.testing.allocator, .Tet10);
    defer m10.deinit();

    try m10.generateTaggedBoxMesh(50.0, 10.0, 5.0, 5, 2, 1, null);
    try std.testing.expect(m10.nodeCount() > m.nodeCount());
    try std.testing.expectEqual(m.elementCount(), m10.elementCount());
}
