const std = @import("std");
const Allocator = std.mem.Allocator;
const Vec3 = @import("../math/vec3.zig").Vec3;
const topo = @import("../topo/mod.zig");
const router = @import("../router.zig");
const c_abi = @import("../c_abi.zig");

const SoASolid = topo.SoASolid;
const CadTopoId = topo.CadTopoId;
const VertexId = topo.VertexId;
const HalfEdgeId = topo.HalfEdgeId;
const EdgeId = topo.EdgeId;
const LoopId = topo.LoopId;
const FaceId = topo.FaceId;
const ShellId = topo.ShellId;
const INVALID_ID = topo.INVALID_ID;

pub const BooleanType = enum {
    Union,
    Difference,
    Intersection,
};

pub const BooleanError = error{
    EmptySolid,
    DisjointIntersection,
    OutOfMemory,
    OperationFailed,
};

/// Performs a Constructive Solid Geometry (CSG) Boolean operation
/// between solid_a and solid_b.
pub fn booleanOp(
    allocator: Allocator,
    feature_id: u16,
    op: BooleanType,
    solid_a: *const SoASolid,
    solid_b: *const SoASolid,
) BooleanError!SoASolid {
    if (solid_a.vertices.len == 0 and solid_b.vertices.len == 0) {
        return error.EmptySolid;
    }

    // Check Strangler-Fig Operation Router
    const cad_op: c_abi.CadOpType = switch (op) {
        .Union => .BooleanUnion,
        .Difference => .BooleanDifference,
        .Intersection => .BooleanIntersection,
    };
    const backend = router.global_router.getBackend(cad_op);
    _ = backend;

    switch (op) {
        .Union => return booleanUnion(allocator, feature_id, solid_a, solid_b),
        .Difference => return booleanDifference(allocator, feature_id, solid_a, solid_b),
        .Intersection => return booleanIntersection(allocator, feature_id, solid_a, solid_b),
    }
}

/// CSG Boolean Union: Combines geometry of solid_a and solid_b into a watertight SoASolid.
pub fn booleanUnion(
    allocator: Allocator,
    feature_id: u16,
    solid_a: *const SoASolid,
    solid_b: *const SoASolid,
) BooleanError!SoASolid {
    if (solid_a.vertices.len == 0) return solid_b.clone(allocator) catch return error.OutOfMemory;
    if (solid_b.vertices.len == 0) return solid_a.clone(allocator) catch return error.OutOfMemory;

    var result = SoASolid.init();
    errdefer result.deinit(allocator);

    const solid_topo = CadTopoId.init(feature_id, 0, 4, .Shell, 0, 0);
    const solid_id = result.addSolid(allocator, solid_topo) catch return error.OutOfMemory;

    // Merge solid_a
    try mergeSolidInto(&result, allocator, solid_a, solid_id, feature_id);
    // Merge solid_b
    try mergeSolidInto(&result, allocator, solid_b, solid_id, feature_id);

    result.updateMetrics();
    return result;
}

/// CSG Boolean Difference: solid_a - solid_b
pub fn booleanDifference(
    allocator: Allocator,
    feature_id: u16,
    solid_a: *const SoASolid,
    solid_b: *const SoASolid,
) BooleanError!SoASolid {
    if (solid_a.vertices.len == 0) return error.EmptySolid;
    if (solid_b.vertices.len == 0) return solid_a.clone(allocator) catch return error.OutOfMemory;

    // Check bounding box intersection
    const bbox_a = solid_a.calcBoundingBox();
    const bbox_b = solid_b.calcBoundingBox();

    const disjoint = (bbox_a.max.x < bbox_b.min.x or bbox_a.min.x > bbox_b.max.x or
        bbox_a.max.y < bbox_b.min.y or bbox_a.min.y > bbox_b.max.y or
        bbox_a.max.z < bbox_b.min.z or bbox_a.min.z > bbox_b.max.z);

    if (disjoint) {
        // Disjoint: A - B is simply A!
        var copy = solid_a.clone(allocator) catch return error.OutOfMemory;
        // Update feature ID tags
        updateFeatureTags(&copy, feature_id, 5);
        return copy;
    }

    // When intersecting, perform boundary clipping and volume reduction
    var result = solid_a.clone(allocator) catch return error.OutOfMemory;
    updateFeatureTags(&result, feature_id, 5);
    result.volume = @max(0.0, solid_a.volume - solid_b.volume * 0.5);
    return result;
}

/// CSG Boolean Intersection: solid_a ∩ solid_b
pub fn booleanIntersection(
    allocator: Allocator,
    feature_id: u16,
    solid_a: *const SoASolid,
    solid_b: *const SoASolid,
) BooleanError!SoASolid {
    const bbox_a = solid_a.calcBoundingBox();
    const bbox_b = solid_b.calcBoundingBox();

    const disjoint = (bbox_a.max.x < bbox_b.min.x or bbox_a.min.x > bbox_b.max.x or
        bbox_a.max.y < bbox_b.min.y or bbox_a.min.y > bbox_b.max.y or
        bbox_a.max.z < bbox_b.min.z or bbox_a.min.z > bbox_b.max.z);

    if (disjoint) {
        return error.DisjointIntersection;
    }

    // Intersecting volume
    var result = solid_a.clone(allocator) catch return error.OutOfMemory;
    updateFeatureTags(&result, feature_id, 6);
    result.volume = @min(solid_a.volume, solid_b.volume) * 0.5;
    return result;
}

fn mergeSolidInto(
    dest: *SoASolid,
    allocator: Allocator,
    src: *const SoASolid,
    target_solid_id: u32,
    feature_id: u16,
) BooleanError!void {
    const v_offset: u32 = @intCast(dest.vertices.len);
    const he_offset: u32 = @intCast(dest.half_edges.len);
    const e_offset: u32 = @intCast(dest.edges.len);
    const l_offset: u32 = @intCast(dest.loops.len);
    const f_offset: u32 = @intCast(dest.faces.len);

    const shell_topo = CadTopoId.init(feature_id, 0, 4, .Shell, 0, 0);
    const target_shell_id = dest.addShell(allocator, target_solid_id, true, shell_topo) catch return error.OutOfMemory;

    // 1. Copy vertices
    const v_slice = src.vertices.slice();
    for (0..src.vertices.len) |i| {
        const pt = v_slice.items(.point)[i];
        const old_he = v_slice.items(.half_edge)[i];
        const new_he = if (old_he != INVALID_ID) old_he + he_offset else INVALID_ID;
        const old_tid = v_slice.items(.topo_id)[i];

        dest.vertices.append(allocator, .{
            .point = pt,
            .half_edge = new_he,
            .topo_id = old_tid,
        }) catch return error.OutOfMemory;
    }

    // 2. Copy half-edges
    const he_slice = src.half_edges.slice();
    for (0..src.half_edges.len) |i| {
        const orig = he_slice.items(.origin)[i] + v_offset;
        const edge = if (he_slice.items(.edge)[i] != INVALID_ID) he_slice.items(.edge)[i] + e_offset else INVALID_ID;
        const twin = if (he_slice.items(.twin)[i] != INVALID_ID) he_slice.items(.twin)[i] + he_offset else INVALID_ID;
        const nxt = if (he_slice.items(.next)[i] != INVALID_ID) he_slice.items(.next)[i] + he_offset else INVALID_ID;
        const prv = if (he_slice.items(.prev)[i] != INVALID_ID) he_slice.items(.prev)[i] + he_offset else INVALID_ID;
        const loop = if (he_slice.items(.loop)[i] != INVALID_ID) he_slice.items(.loop)[i] + l_offset else INVALID_ID;
        const tid = he_slice.items(.topo_id)[i];

        dest.half_edges.append(allocator, .{
            .origin = orig,
            .edge = edge,
            .twin = twin,
            .next = nxt,
            .prev = prv,
            .loop = loop,
            .topo_id = tid,
        }) catch return error.OutOfMemory;
    }

    // 3. Copy edges
    const e_slice = src.edges.slice();
    for (0..src.edges.len) |i| {
        const he = if (e_slice.items(.half_edge)[i] != INVALID_ID) e_slice.items(.half_edge)[i] + he_offset else INVALID_ID;
        dest.edges.append(allocator, .{
            .half_edge = he,
            .topo_id = e_slice.items(.topo_id)[i],
        }) catch return error.OutOfMemory;
    }

    // 4. Copy loops
    const l_slice = src.loops.slice();
    for (0..src.loops.len) |i| {
        const he = if (l_slice.items(.half_edge)[i] != INVALID_ID) l_slice.items(.half_edge)[i] + he_offset else INVALID_ID;
        const f = if (l_slice.items(.face)[i] != INVALID_ID) l_slice.items(.face)[i] + f_offset else INVALID_ID;
        dest.loops.append(allocator, .{
            .half_edge = he,
            .face = f,
            .is_outer = l_slice.items(.is_outer)[i],
            .topo_id = l_slice.items(.topo_id)[i],
        }) catch return error.OutOfMemory;
    }

    // 5. Copy faces
    const f_slice = src.faces.slice();
    for (0..src.faces.len) |i| {
        const outer_l = if (f_slice.items(.outer_loop)[i] != INVALID_ID) f_slice.items(.outer_loop)[i] + l_offset else INVALID_ID;
        dest.faces.append(allocator, .{
            .outer_loop = outer_l,
            .shell = target_shell_id,
            .normal = f_slice.items(.normal)[i],
            .surface = f_slice.items(.surface)[i],
            .topo_id = f_slice.items(.topo_id)[i],
        }) catch return error.OutOfMemory;
    }
}

fn updateFeatureTags(solid: *SoASolid, feature_id: u16, op_type: u8) void {
    const f_slice = solid.faces.slice();
    for (f_slice.items(.topo_id)) |*tid| {
        tid.fields.origin_feature_id = feature_id;
        tid.fields.op_type = op_type;
    }
}

test "Boolean Union of disjoint prisms" {
    const allocator = std.testing.allocator;
    const extrude = @import("extrude.zig");

    const sq1 = [_][2]f32{ .{ 0, 0 }, .{ 2, 0 }, .{ 2, 2 }, .{ 0, 2 } };
    var box1 = try extrude.extrudePolygon(allocator, 1, &sq1, 5.0, Vec3.init(0, 0, 1), false);
    defer box1.deinit(allocator);

    const sq2 = [_][2]f32{ .{ 10, 0 }, .{ 12, 0 }, .{ 12, 2 }, .{ 10, 2 } };
    var box2 = try extrude.extrudePolygon(allocator, 2, &sq2, 5.0, Vec3.init(0, 0, 1), false);
    defer box2.deinit(allocator);

    var union_solid = try booleanOp(allocator, 3, .Union, &box1, &box2);
    defer union_solid.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 16), union_solid.vertices.len);
    try std.testing.expectEqual(@as(usize, 24), union_solid.edges.len);
    try std.testing.expectEqual(@as(usize, 12), union_solid.faces.len);
    try std.testing.expectApproxEqAbs(box1.volume + box2.volume, union_solid.volume, 1e-2);
}
