const std = @import("std");

pub const ElementType = enum(u8) {
    Tet4 = 4,   // Linear 4-node tetrahedron
    Tet10 = 10, // Quadratic 10-node isoparametric tetrahedron
};

pub const TetMesh = struct {
    allocator: std.mem.Allocator,
    element_type: ElementType = .Tet4,
    node_positions: std.ArrayListUnmanaged(f64) = .empty, // flat [x0, y0, z0, x1, y1, z1, ...]
    element_indices: std.ArrayListUnmanaged(u32) = .empty, // 4 or 10 node indices per element

    pub fn init(allocator: std.mem.Allocator, el_type: ElementType) TetMesh {
        return .{
            .allocator = allocator,
            .element_type = el_type,
        };
    }

    pub fn deinit(self: *TetMesh) void {
        self.node_positions.deinit(self.allocator);
        self.element_indices.deinit(self.allocator);
    }

    pub fn nodeCount(self: TetMesh) usize {
        return self.node_positions.items.len / 3;
    }

    pub fn elementCount(self: TetMesh) usize {
        const stride: usize = @intFromEnum(self.element_type);
        return self.element_indices.items.len / stride;
    }

    /// Generates a structured tetrahedral block mesh (box) for benchmarking FEA solver and compliance tests.
    pub fn generateBoxTetMesh(
        self: *TetMesh,
        dx: f64,
        dy: f64,
        dz: f64,
        nx: usize,
        ny: usize,
        nz: usize,
    ) !void {
        self.node_positions.clearRetainingCapacity();
        self.element_indices.clearRetainingCapacity();

        // 1. Generate grid nodes
        for (0..nz + 1) |k| {
            const z = (@as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(nz))) * dz;
            for (0..ny + 1) |j| {
                const y = (@as(f64, @floatFromInt(j)) / @as(f64, @floatFromInt(ny))) * dy;
                for (0..nx + 1) |i| {
                    const x = (@as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(nx))) * dx;
                    try self.node_positions.appendSlice(self.allocator, &.{ x, y, z });
                }
            }
        }

        const stride_y = nx + 1;
        const stride_z = (nx + 1) * (ny + 1);

        const nodeIdx = struct {
            fn get(i: usize, j: usize, k: usize, sy: usize, sz: usize) u32 {
                return @intCast(i + j * sy + k * sz);
            }
        }.get;

        // 2. Subdivide each hexahedral cell into 5 tetrahedra
        for (0..nz) |k| {
            for (0..ny) |j| {
                for (0..nx) |i| {
                    const v0 = nodeIdx(i, j, k, stride_y, stride_z);
                    const v1 = nodeIdx(i + 1, j, k, stride_y, stride_z);
                    const v2 = nodeIdx(i + 1, j + 1, k, stride_y, stride_z);
                    const v3 = nodeIdx(i, j + 1, k, stride_y, stride_z);
                    const v4 = nodeIdx(i, j, k + 1, stride_y, stride_z);
                    const v5 = nodeIdx(i + 1, j, k + 1, stride_y, stride_z);
                    const v6 = nodeIdx(i + 1, j + 1, k + 1, stride_y, stride_z);
                    const v7 = nodeIdx(i, j + 1, k + 1, stride_y, stride_z);

                    // 5 tets decomposition
                    try self.element_indices.appendSlice(self.allocator, &.{ v0, v1, v3, v4 });
                    try self.element_indices.appendSlice(self.allocator, &.{ v1, v2, v3, v6 });
                    try self.element_indices.appendSlice(self.allocator, &.{ v1, v4, v5, v6 });
                    try self.element_indices.appendSlice(self.allocator, &.{ v3, v4, v6, v7 });
                    try self.element_indices.appendSlice(self.allocator, &.{ v1, v3, v4, v6 });
                }
            }
        }
    }
};

test "TetMesh box generator" {
    var mesh = TetMesh.init(std.testing.allocator, .Tet4);
    defer mesh.deinit();

    try mesh.generateBoxTetMesh(10.0, 5.0, 2.0, 2, 2, 2);
    try std.testing.expectEqual(@as(usize, 27), mesh.nodeCount());
    try std.testing.expectEqual(@as(usize, 40), mesh.elementCount()); // 2*2*2 * 5 = 40 tets
}
