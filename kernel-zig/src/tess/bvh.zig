const std = @import("std");
const Allocator = std.mem.Allocator;
const c_abi = @import("../c_abi.zig");
const CadTessellatedSolidSlice = c_abi.CadTessellatedSolidSlice;

// ---------------------------------------------------------------------------
// 3D Vector Math Helpers for BVH
// ---------------------------------------------------------------------------

fn add3(a: [3]f32, b: [3]f32) [3]f32 {
    return .{ a[0] + b[0], a[1] + b[1], a[2] + b[2] };
}

fn sub3(a: [3]f32, b: [3]f32) [3]f32 {
    return .{ a[0] - b[0], a[1] - b[1], a[2] - b[2] };
}

fn scale3(a: [3]f32, s: f32) [3]f32 {
    return .{ a[0] * s, a[1] * s, a[2] * s };
}

fn dot3(a: [3]f32, b: [3]f32) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

fn cross3(a: [3]f32, b: [3]f32) [3]f32 {
    return .{
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    };
}

fn length3(a: [3]f32) f32 {
    return @sqrt(dot3(a, a));
}

fn normalize3(a: [3]f32) [3]f32 {
    const len = length3(a);
    if (len < 1e-8) return .{ 0, 0, 0 };
    return scale3(a, 1.0 / len);
}

// ---------------------------------------------------------------------------
// Axis-Aligned Bounding Box (AABB)
// ---------------------------------------------------------------------------

pub const AABB = struct {
    min: [3]f32,
    max: [3]f32,

    pub fn empty() AABB {
        return .{
            .min = .{ std.math.inf(f32), std.math.inf(f32), std.math.inf(f32) },
            .max = .{ -std.math.inf(f32), -std.math.inf(f32), -std.math.inf(f32) },
        };
    }

    pub fn fromPoint(p: [3]f32) AABB {
        return .{ .min = p, .max = p };
    }

    pub fn encapsulate(self: *AABB, p: [3]f32) void {
        inline for (0..3) |i| {
            if (p[i] < self.min[i]) self.min[i] = p[i];
            if (p[i] > self.max[i]) self.max[i] = p[i];
        }
    }

    pub fn unionWith(self: *AABB, other: AABB) void {
        inline for (0..3) |i| {
            if (other.min[i] < self.min[i]) self.min[i] = other.min[i];
            if (other.max[i] > self.max[i]) self.max[i] = other.max[i];
        }
    }

    pub fn center(self: AABB) [3]f32 {
        return .{
            (self.min[0] + self.max[0]) * 0.5,
            (self.min[1] + self.max[1]) * 0.5,
            (self.min[2] + self.max[2]) * 0.5,
        };
    }

    pub fn extent(self: AABB) [3]f32 {
        return .{
            self.max[0] - self.min[0],
            self.max[1] - self.min[1],
            self.max[2] - self.min[2],
        };
    }

    pub fn longestAxis(self: AABB) usize {
        const ext = self.extent();
        if (ext[0] >= ext[1] and ext[0] >= ext[2]) return 0;
        if (ext[1] >= ext[0] and ext[1] >= ext[2]) return 1;
        return 2;
    }

    pub fn intersectsBox(self: AABB, other: AABB) bool {
        inline for (0..3) |i| {
            if (self.max[i] < other.min[i] or self.min[i] > other.max[i]) return false;
        }
        return true;
    }

    pub fn intersectsRay(self: AABB, ray_orig: [3]f32, inv_dir: [3]f32, t_min: f32, t_max: f32) ?f32 {
        var t0 = t_min;
        var t1 = t_max;
        inline for (0..3) |i| {
            const near = (self.min[i] - ray_orig[i]) * inv_dir[i];
            const far = (self.max[i] - ray_orig[i]) * inv_dir[i];
            const t_near = @min(near, far);
            const t_far = @max(near, far);
            t0 = @max(t0, t_near);
            t1 = @min(t1, t_far);
            if (t0 > t1) return null;
        }
        return t0;
    }
};

// ---------------------------------------------------------------------------
// Ray & Intersection Structures
// ---------------------------------------------------------------------------

pub const Ray = struct {
    origin: [3]f32,
    direction: [3]f32,
    inv_direction: [3]f32,

    pub fn init(origin: [3]f32, direction: [3]f32) Ray {
        const dir = normalize3(direction);
        const inv = [3]f32{
            if (@abs(dir[0]) > 1e-12) 1.0 / dir[0] else if (dir[0] >= 0) 1e12 else -1e12,
            if (@abs(dir[1]) > 1e-12) 1.0 / dir[1] else if (dir[1] >= 0) 1e12 else -1e12,
            if (@abs(dir[2]) > 1e-12) 1.0 / dir[2] else if (dir[2] >= 0) 1e12 else -1e12,
        };
        return .{
            .origin = origin,
            .direction = dir,
            .inv_direction = inv,
        };
    }
};

pub const RayHit = struct {
    t: f32,
    point: [3]f32,
    normal: [3]f32,
    triangle_index: u32,
    face_topo_id: u64,
    u: f32,
    v: f32,
};

pub const EdgeRayHit = struct {
    t: f32,
    point: [3]f32,
    segment_index: u32,
    edge_topo_id: u64,
    distance_to_ray: f32,
};

// ---------------------------------------------------------------------------
// Möller–Trumbore Ray-Triangle & Closest Line-Ray Tests
// ---------------------------------------------------------------------------

pub fn intersectRayTriangle(
    ray: Ray,
    v0: [3]f32,
    v1: [3]f32,
    v2: [3]f32,
) ?struct { t: f32, u: f32, v: f32 } {
    const eps: f32 = 1e-7;
    const edge1 = sub3(v1, v0);
    const edge2 = sub3(v2, v0);
    const h = cross3(ray.direction, edge2);
    const a = dot3(edge1, h);

    if (@abs(a) < eps) return null; // Parallel to triangle plane

    const f = 1.0 / a;
    const s = sub3(ray.origin, v0);
    const u = f * dot3(s, h);
    if (u < 0.0 or u > 1.0) return null;

    const q = cross3(s, edge1);
    const v = f * dot3(ray.direction, q);
    if (v < 0.0 or u + v > 1.0) return null;

    const t = f * dot3(edge2, q);
    if (t > eps) {
        return .{ .t = t, .u = u, .v = v };
    }
    return null;
}

pub fn distanceRaySegment(
    ray: Ray,
    p0: [3]f32,
    p1: [3]f32,
) ?struct { t_ray: f32, s_seg: f32, point: [3]f32, distance: f32 } {
    const u = ray.direction;
    const v = sub3(p1, p0);
    const w0 = sub3(ray.origin, p0);

    const a = dot3(u, u);
    const b = dot3(u, v);
    const c = dot3(v, v);
    const d = dot3(u, w0);
    const e = dot3(v, w0);

    const denom = a * c - b * b;
    if (denom < 1e-8) {
        // Parallel lines
        const s_clamped: f32 = std.math.clamp(e / @max(c, 1e-8), 0.0, 1.0);
        const pt = add3(p0, scale3(v, s_clamped));
        const diff = sub3(pt, ray.origin);
        const t_proj = dot3(diff, u);
        if (t_proj < 0.0) return null;
        const pt_on_ray = add3(ray.origin, scale3(u, t_proj));
        const dist = length3(sub3(pt, pt_on_ray));
        return .{ .t_ray = t_proj, .s_seg = s_clamped, .point = pt, .distance = dist };
    }

    var s = (a * e - b * d) / denom;
    s = std.math.clamp(s, 0.0, 1.0);

    const t = (b * s - d) / a;
    if (t < 0.0) return null;

    const pt_seg = add3(p0, scale3(v, s));
    const pt_ray = add3(ray.origin, scale3(u, t));
    const dist = length3(sub3(pt_seg, pt_ray));

    return .{ .t_ray = t, .s_seg = s, .point = pt_seg, .distance = dist };
}

// ---------------------------------------------------------------------------
// BVH Node & Tree
// ---------------------------------------------------------------------------

pub const BVHNode = struct {
    bbox: AABB,
    left_first: u32, // If is_leaf: start in prim_indices; If inner: left child node index
    prim_count: u32, // If is_leaf: count (> 0); If inner: 0

    pub fn isLeaf(self: BVHNode) bool {
        return self.prim_count > 0;
    }
};

pub const BVHTree = struct {
    // Triangle BVH
    tri_nodes: []BVHNode,
    tri_indices: []u32,

    // Edge BVH
    edge_nodes: []BVHNode,
    edge_indices: []u32,

    // References to underlying flat slice buffers
    positions: []const f32,
    normals: []const f32,
    indices: []const u32,
    triangle_to_face_id: []const u64,
    edge_polylines: []const f32,
    edge_to_topo_id: []const u64,

    pub fn build(allocator: Allocator, slice: *const CadTessellatedSolidSlice) !BVHTree {
        const tri_count = slice.triangle_count;
        const edge_count = slice.edge_segment_count;

        const pos_slice = if (slice.positions) |p| p[0 .. slice.vertex_count * 3] else &[_]f32{};
        const nrm_slice = if (slice.normals) |n| n[0 .. slice.vertex_count * 3] else &[_]f32{};
        const idx_slice = if (slice.indices) |i| i[0 .. slice.triangle_count * 3] else &[_]u32{};
        const tri_face_slice = if (slice.triangle_to_face_id) |tf| tf[0..slice.triangle_count] else &[_]u64{};
        const edge_poly_slice = if (slice.edge_polylines) |ep| ep[0 .. slice.edge_segment_count * 6] else &[_]f32{};
        const edge_topo_slice = if (slice.edge_to_topo_id) |et| et[0..slice.edge_segment_count] else &[_]u64{};

        // 1. Build Triangle BVH
        var tri_indices = try allocator.alloc(u32, tri_count);
        errdefer allocator.free(tri_indices);
        for (0..tri_count) |i| {
            tri_indices[i] = @intCast(i);
        }

        var tri_nodes_list = std.ArrayList(BVHNode).empty;
        errdefer tri_nodes_list.deinit(allocator);

        if (tri_count > 0) {
            // Allocate initial root node
            _ = try tri_nodes_list.append(allocator, std.mem.zeroes(BVHNode));
            try buildTriRecursive(allocator, &tri_nodes_list, tri_indices, pos_slice, idx_slice, 0, 0, tri_count, 0);
        }

        // 2. Build Edge BVH
        var edge_indices = try allocator.alloc(u32, edge_count);
        errdefer allocator.free(edge_indices);
        for (0..edge_count) |i| {
            edge_indices[i] = @intCast(i);
        }

        var edge_nodes_list = std.ArrayList(BVHNode).empty;
        errdefer edge_nodes_list.deinit(allocator);

        if (edge_count > 0) {
            _ = try edge_nodes_list.append(allocator, std.mem.zeroes(BVHNode));
            try buildEdgeRecursive(allocator, &edge_nodes_list, edge_indices, edge_poly_slice, 0, 0, edge_count, 0);
        }

        const final_tri_nodes = try tri_nodes_list.toOwnedSlice(allocator);
        errdefer allocator.free(final_tri_nodes);
        const final_edge_nodes = try edge_nodes_list.toOwnedSlice(allocator);

        return BVHTree{
            .tri_nodes = final_tri_nodes,
            .tri_indices = tri_indices,
            .edge_nodes = final_edge_nodes,
            .edge_indices = edge_indices,
            .positions = pos_slice,
            .normals = nrm_slice,
            .indices = idx_slice,
            .triangle_to_face_id = tri_face_slice,
            .edge_polylines = edge_poly_slice,
            .edge_to_topo_id = edge_topo_slice,
        };
    }

    pub fn deinit(self: *BVHTree, allocator: Allocator) void {
        allocator.free(self.tri_nodes);
        allocator.free(self.tri_indices);
        allocator.free(self.edge_nodes);
        allocator.free(self.edge_indices);
        self.* = undefined;
    }

    // -----------------------------------------------------------------------
    // Triangle Raycast
    // -----------------------------------------------------------------------

    pub fn raycastTriangles(self: *const BVHTree, ray: Ray) ?RayHit {
        if (self.tri_nodes.len == 0) return null;

        var stack: [64]u32 = undefined;
        var stack_ptr: usize = 0;
        stack[stack_ptr] = 0; // Root node
        stack_ptr += 1;

        var best_hit: ?RayHit = null;
        var max_t: f32 = std.math.inf(f32);

        while (stack_ptr > 0) {
            stack_ptr -= 1;
            const node_idx = stack[stack_ptr];
            const node = self.tri_nodes[node_idx];

            if (node.bbox.intersectsRay(ray.origin, ray.inv_direction, 0.0, max_t) == null) {
                continue;
            }

            if (node.isLeaf()) {
                const start = node.left_first;
                const end = start + node.prim_count;

                for (start..end) |p| {
                    const tri_idx = self.tri_indices[p];
                    const idx0 = self.indices[tri_idx * 3 + 0];
                    const idx1 = self.indices[tri_idx * 3 + 1];
                    const idx2 = self.indices[tri_idx * 3 + 2];

                    const v0 = [3]f32{ self.positions[idx0 * 3], self.positions[idx0 * 3 + 1], self.positions[idx0 * 3 + 2] };
                    const v1 = [3]f32{ self.positions[idx1 * 3], self.positions[idx1 * 3 + 1], self.positions[idx1 * 3 + 2] };
                    const v2 = [3]f32{ self.positions[idx2 * 3], self.positions[idx2 * 3 + 1], self.positions[idx2 * 3 + 2] };

                    if (intersectRayTriangle(ray, v0, v1, v2)) |hit| {
                        if (hit.t < max_t) {
                            max_t = hit.t;
                            const hit_point = add3(ray.origin, scale3(ray.direction, hit.t));
                            const face_id = if (tri_idx < self.triangle_to_face_id.len) self.triangle_to_face_id[tri_idx] else 0;

                            // Interpolated or face normal
                            var nrm: [3]f32 = .{ 0, 0, 1 };
                            if (self.normals.len > idx0 * 3 + 2) {
                                const n0 = [3]f32{ self.normals[idx0 * 3], self.normals[idx0 * 3 + 1], self.normals[idx0 * 3 + 2] };
                                const n1 = [3]f32{ self.normals[idx1 * 3], self.normals[idx1 * 3 + 1], self.normals[idx1 * 3 + 2] };
                                const n2 = [3]f32{ self.normals[idx2 * 3], self.normals[idx2 * 3 + 1], self.normals[idx2 * 3 + 2] };
                                const w = 1.0 - hit.u - hit.v;
                                nrm = normalize3(add3(add3(scale3(n0, w), scale3(n1, hit.u)), scale3(n2, hit.v)));
                            } else {
                                nrm = normalize3(cross3(sub3(v1, v0), sub3(v2, v0)));
                            }

                            best_hit = RayHit{
                                .t = hit.t,
                                .point = hit_point,
                                .normal = nrm,
                                .triangle_index = tri_idx,
                                .face_topo_id = face_id,
                                .u = hit.u,
                                .v = hit.v,
                            };
                        }
                    }
                }
            } else {
                // Inner node: push children
                const left = node.left_first;
                const right = node.left_first + 1;
                if (stack_ptr + 2 < stack.len) {
                    stack[stack_ptr] = right;
                    stack_ptr += 1;
                    stack[stack_ptr] = left;
                    stack_ptr += 1;
                }
            }
        }

        return best_hit;
    }

    // -----------------------------------------------------------------------
    // Feature Edge Raycast
    // -----------------------------------------------------------------------

    pub fn raycastEdges(self: *const BVHTree, ray: Ray, threshold: f32) ?EdgeRayHit {
        if (self.edge_nodes.len == 0) return null;

        var stack: [64]u32 = undefined;
        var stack_ptr: usize = 0;
        stack[stack_ptr] = 0;
        stack_ptr += 1;

        var best_hit: ?EdgeRayHit = null;
        var min_dist: f32 = threshold;
        var best_t: f32 = std.math.inf(f32);

        while (stack_ptr > 0) {
            stack_ptr -= 1;
            const node_idx = stack[stack_ptr];
            const node = self.edge_nodes[node_idx];

            var expanded_box = node.bbox;
            expanded_box.min[0] -= threshold; expanded_box.min[1] -= threshold; expanded_box.min[2] -= threshold;
            expanded_box.max[0] += threshold; expanded_box.max[1] += threshold; expanded_box.max[2] += threshold;

            if (expanded_box.intersectsRay(ray.origin, ray.inv_direction, 0.0, best_t) == null) {
                continue;
            }

            if (node.isLeaf()) {
                const start = node.left_first;
                const end = start + node.prim_count;

                for (start..end) |p| {
                    const seg_idx = self.edge_indices[p];
                    const offset = seg_idx * 6;
                    const p0 = [3]f32{ self.edge_polylines[offset], self.edge_polylines[offset + 1], self.edge_polylines[offset + 2] };
                    const p1 = [3]f32{ self.edge_polylines[offset + 3], self.edge_polylines[offset + 4], self.edge_polylines[offset + 5] };

                    if (distanceRaySegment(ray, p0, p1)) |res| {
                        if (res.distance <= min_dist or (res.distance <= threshold and res.t_ray < best_t)) {
                            min_dist = res.distance;
                            best_t = res.t_ray;
                            const edge_id = if (seg_idx < self.edge_to_topo_id.len) self.edge_to_topo_id[seg_idx] else 0;

                            best_hit = EdgeRayHit{
                                .t = res.t_ray,
                                .point = res.point,
                                .segment_index = seg_idx,
                                .edge_topo_id = edge_id,
                                .distance_to_ray = res.distance,
                            };
                        }
                    }
                }
            } else {
                const left = node.left_first;
                const right = node.left_first + 1;
                if (stack_ptr + 2 < stack.len) {
                    stack[stack_ptr] = right;
                    stack_ptr += 1;
                    stack[stack_ptr] = left;
                    stack_ptr += 1;
                }
            }
        }

        return best_hit;
    }

    // -----------------------------------------------------------------------
    // AABB Query (Sub-Shape Culling & Spatial Overlap)
    // -----------------------------------------------------------------------

    pub fn queryAABB(self: *const BVHTree, query_box: AABB, out_triangles: *std.ArrayList(u32), allocator: Allocator) !void {
        if (self.tri_nodes.len == 0) return;

        var stack: [64]u32 = undefined;
        var stack_ptr: usize = 0;
        stack[stack_ptr] = 0;
        stack_ptr += 1;

        while (stack_ptr > 0) {
            stack_ptr -= 1;
            const node_idx = stack[stack_ptr];
            const node = self.tri_nodes[node_idx];

            if (!node.bbox.intersectsBox(query_box)) continue;

            if (node.isLeaf()) {
                const start = node.left_first;
                const end = start + node.prim_count;
                for (start..end) |p| {
                    const tri_idx = self.tri_indices[p];
                    try out_triangles.append(allocator, tri_idx);
                }
            } else {
                const left = node.left_first;
                const right = node.left_first + 1;
                if (stack_ptr + 2 < stack.len) {
                    stack[stack_ptr] = right;
                    stack_ptr += 1;
                    stack[stack_ptr] = left;
                    stack_ptr += 1;
                }
            }
        }
    }
};

// ---------------------------------------------------------------------------
// Internal BVH Build Recursion
// ---------------------------------------------------------------------------

fn getTriangleAABB(tri_idx: u32, pos: []const f32, idx: []const u32) AABB {
    const idx0 = idx[tri_idx * 3 + 0];
    const idx1 = idx[tri_idx * 3 + 1];
    const idx2 = idx[tri_idx * 3 + 2];

    const v0 = [3]f32{ pos[idx0 * 3], pos[idx0 * 3 + 1], pos[idx0 * 3 + 2] };
    const v1 = [3]f32{ pos[idx1 * 3], pos[idx1 * 3 + 1], pos[idx1 * 3 + 2] };
    const v2 = [3]f32{ pos[idx2 * 3], pos[idx2 * 3 + 1], pos[idx2 * 3 + 2] };

    var box = AABB.fromPoint(v0);
    box.encapsulate(v1);
    box.encapsulate(v2);
    return box;
}

fn buildTriRecursive(
    allocator: Allocator,
    nodes: *std.ArrayList(BVHNode),
    tri_indices: []u32,
    pos: []const f32,
    idx: []const u32,
    node_idx: usize,
    start: usize,
    count: usize,
    depth: usize,
) !void {
    var node_bbox = AABB.empty();
    var centroid_bbox = AABB.empty();

    for (start..start + count) |i| {
        const tri_idx = tri_indices[i];
        const tri_box = getTriangleAABB(tri_idx, pos, idx);
        node_bbox.unionWith(tri_box);
        centroid_bbox.encapsulate(tri_box.center());
    }

    nodes.items[node_idx].bbox = node_bbox;

    const max_leaf_prims: usize = 4;
    const max_depth: usize = 32;

    if (count <= max_leaf_prims or depth >= max_depth) {
        // Leaf node
        nodes.items[node_idx].left_first = @intCast(start);
        nodes.items[node_idx].prim_count = @intCast(count);
        return;
    }

    // Split along longest axis of centroid bounding box
    const axis = centroid_bbox.longestAxis();
    const split_coord = centroid_bbox.center()[axis];

    // Partition primitives in-place
    var i: usize = start;
    var j: usize = start + count - 1;

    while (i <= j) {
        const tri_box = getTriangleAABB(tri_indices[i], pos, idx);
        if (tri_box.center()[axis] < split_coord) {
            i += 1;
        } else {
            const tmp = tri_indices[i];
            tri_indices[i] = tri_indices[j];
            tri_indices[j] = tmp;
            if (j == 0) break;
            j -= 1;
        }
    }

    var left_count = i - start;
    if (left_count == 0 or left_count == count) {
        // Median fallback if partitioning failed
        left_count = count / 2;
    }
    const right_count = count - left_count;

    // Allocate two child nodes in list
    const left_child_idx = nodes.items.len;
    _ = try nodes.append(allocator, std.mem.zeroes(BVHNode));
    _ = try nodes.append(allocator, std.mem.zeroes(BVHNode));

    nodes.items[node_idx].left_first = @intCast(left_child_idx);
    nodes.items[node_idx].prim_count = 0; // Inner node

    try buildTriRecursive(allocator, nodes, tri_indices, pos, idx, left_child_idx, start, left_count, depth + 1);
    try buildTriRecursive(allocator, nodes, tri_indices, pos, idx, left_child_idx + 1, start + left_count, right_count, depth + 1);
}

fn getEdgeAABB(seg_idx: u32, edge_poly: []const f32) AABB {
    const off = seg_idx * 6;
    const p0 = [3]f32{ edge_poly[off], edge_poly[off + 1], edge_poly[off + 2] };
    const p1 = [3]f32{ edge_poly[off + 3], edge_poly[off + 4], edge_poly[off + 5] };

    var box = AABB.fromPoint(p0);
    box.encapsulate(p1);
    return box;
}

fn buildEdgeRecursive(
    allocator: Allocator,
    nodes: *std.ArrayList(BVHNode),
    edge_indices: []u32,
    edge_poly: []const f32,
    node_idx: usize,
    start: usize,
    count: usize,
    depth: usize,
) !void {
    var node_bbox = AABB.empty();
    var centroid_bbox = AABB.empty();

    for (start..start + count) |i| {
        const seg_idx = edge_indices[i];
        const e_box = getEdgeAABB(seg_idx, edge_poly);
        node_bbox.unionWith(e_box);
        centroid_bbox.encapsulate(e_box.center());
    }

    nodes.items[node_idx].bbox = node_bbox;

    const max_leaf_prims: usize = 4;
    const max_depth: usize = 32;

    if (count <= max_leaf_prims or depth >= max_depth) {
        nodes.items[node_idx].left_first = @intCast(start);
        nodes.items[node_idx].prim_count = @intCast(count);
        return;
    }

    const axis = centroid_bbox.longestAxis();
    const split_coord = centroid_bbox.center()[axis];

    var i: usize = start;
    var j: usize = start + count - 1;

    while (i <= j) {
        const e_box = getEdgeAABB(edge_indices[i], edge_poly);
        if (e_box.center()[axis] < split_coord) {
            i += 1;
        } else {
            const tmp = edge_indices[i];
            edge_indices[i] = edge_indices[j];
            edge_indices[j] = tmp;
            if (j == 0) break;
            j -= 1;
        }
    }

    var left_count = i - start;
    if (left_count == 0 or left_count == count) {
        left_count = count / 2;
    }
    const right_count = count - left_count;

    const left_child_idx = nodes.items.len;
    _ = try nodes.append(allocator, std.mem.zeroes(BVHNode));
    _ = try nodes.append(allocator, std.mem.zeroes(BVHNode));

    nodes.items[node_idx].left_first = @intCast(left_child_idx);
    nodes.items[node_idx].prim_count = 0;

    try buildEdgeRecursive(allocator, nodes, edge_indices, edge_poly, left_child_idx, start, left_count, depth + 1);
    try buildEdgeRecursive(allocator, nodes, edge_indices, edge_poly, left_child_idx + 1, start + left_count, right_count, depth + 1);
}

// ---------------------------------------------------------------------------
// Unit Tests for BVH Spatial Accelerator
// ---------------------------------------------------------------------------

test "BVH: Ray-triangle Möller-Trumbore intersection" {
    const v0 = [3]f32{ 0, 0, 0 };
    const v1 = [3]f32{ 2, 0, 0 };
    const v2 = [3]f32{ 0, 2, 0 };

    const ray_hit = Ray.init(.{ 0.5, 0.5, 5 }, .{ 0, 0, -1 });
    const hit = intersectRayTriangle(ray_hit, v0, v1, v2);
    try std.testing.expect(hit != null);
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), hit.?.t, 1e-4);

    const ray_miss = Ray.init(.{ 3, 3, 5 }, .{ 0, 0, -1 });
    const miss = intersectRayTriangle(ray_miss, v0, v1, v2);
    try std.testing.expect(miss == null);
}

test "BVH: AABB ray intersection" {
    var box = AABB.empty();
    box.encapsulate(.{ -1, -1, -1 });
    box.encapsulate(.{ 1, 1, 1 });

    const ray = Ray.init(.{ 0, 0, -5 }, .{ 0, 0, 1 });
    const hit_t = box.intersectsRay(ray.origin, ray.inv_direction, 0, 100);
    try std.testing.expect(hit_t != null);
    try std.testing.expectApproxEqAbs(@as(f32, 4.0), hit_t.?, 1e-4);
}

test "BVH: Full solid slice tree build, raycast, and sub-shape picking" {
    const box_mod = @import("../primitives/box.zig");
    const tess = @import("tessellator.zig");
    const allocator = std.testing.allocator;

    var b = try box_mod.createBox(allocator, 42, 2.0, 4.0, 6.0);
    defer b.deinit(allocator);

    var slice = try tess.tessellateSolidSlice(allocator, &b, 0.1, 0.2);
    defer tess.freeSlice(allocator, &slice);

    try std.testing.expectEqual(@as(u32, 12), slice.triangle_count);
    try std.testing.expectEqual(@as(u32, 12), slice.edge_segment_count);

    var bvh = try BVHTree.build(allocator, &slice);
    defer bvh.deinit(allocator);

    // Raycast towards top face (+Z, face index 2, z = 6)
    const ray_top = Ray.init(.{ 1.0, 2.0, 10.0 }, .{ 0, 0, -1 });
    const hit_top = bvh.raycastTriangles(ray_top);
    try std.testing.expect(hit_top != null);
    try std.testing.expectApproxEqAbs(@as(f32, 4.0), hit_top.?.t, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 6.0), hit_top.?.point[2], 1e-4);
    try std.testing.expect(hit_top.?.face_topo_id != 0);

    // Raycast towards right face (+X, x = 2)
    const ray_right = Ray.init(.{ 10.0, 2.0, 3.0 }, .{ -1, 0, 0 });
    const hit_right = bvh.raycastTriangles(ray_right);
    try std.testing.expect(hit_right != null);
    try std.testing.expectApproxEqAbs(@as(f32, 8.0), hit_right.?.t, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), hit_right.?.point[0], 1e-4);

    // Raycast missing the box
    const ray_miss = Ray.init(.{ 20.0, 20.0, 20.0 }, .{ 0, 0, -1 });
    try std.testing.expect(bvh.raycastTriangles(ray_miss) == null);

    // Edge raycast near top edge (x=1.0, y=0.0, z=6.0)
    const ray_edge = Ray.init(.{ 1.0, -0.05, 10.0 }, .{ 0, 0, -1 });
    const edge_hit = bvh.raycastEdges(ray_edge, 0.2);
    try std.testing.expect(edge_hit != null);
    try std.testing.expect(edge_hit.?.edge_topo_id != 0);

    // AABB query
    var query_box = AABB.empty();
    query_box.encapsulate(.{ 0, 0, 5 });
    query_box.encapsulate(.{ 2, 4, 7 });
    var found_triangles = std.ArrayList(u32).empty;
    defer found_triangles.deinit(allocator);

    try bvh.queryAABB(query_box, &found_triangles, allocator);
    try std.testing.expect(found_triangles.items.len > 0);
}

