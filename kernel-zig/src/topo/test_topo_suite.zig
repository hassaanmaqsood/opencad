const std = @import("std");
const testing = std.testing;
const Vec3 = @import("../math/vec3.zig").Vec3;
const c_abi = @import("../c_abi.zig");
const topo = @import("mod.zig");
const ops = @import("../ops/mod.zig");

const SoASolid = topo.SoASolid;
const CadTopoId = topo.CadTopoId;
const topo_naming = topo.topo_naming;
const dag = topo.dag;
const extrude = ops.extrude;
const revolve = ops.revolve;
const boolean = ops.boolean;

test "SoASolid validateManifold detects corrupted twin invariants" {
    const allocator = testing.allocator;
    var solid = SoASolid.init();
    defer solid.deinit(allocator);

    const dummy_topo = CadTopoId.INVALID;
    const solid_id = try solid.addSolid(allocator, dummy_topo);
    const shell_id = try solid.addShell(allocator, solid_id, true, dummy_topo);

    const v0 = try solid.addVertex(allocator, Vec3.init(0, 0, 0), dummy_topo);
    const v1 = try solid.addVertex(allocator, Vec3.init(1, 0, 0), dummy_topo);
    const v2 = try solid.addVertex(allocator, Vec3.init(0, 1, 0), dummy_topo);

    const f0 = try solid.addFace(allocator, shell_id, Vec3.init(0, 0, 1), .Plane, dummy_topo);
    const l0 = try solid.addLoop(allocator, f0, true, dummy_topo);
    solid.faces.slice().items(.outer_loop)[f0] = l0;

    const he0 = try solid.addHalfEdge(allocator, v0, l0, dummy_topo);
    const he1 = try solid.addHalfEdge(allocator, v1, l0, dummy_topo);
    const he2 = try solid.addHalfEdge(allocator, v2, l0, dummy_topo);
    solid.setNextPrev(he0, he1);
    solid.setNextPrev(he1, he2);
    solid.setNextPrev(he2, he0);
    solid.loops.slice().items(.half_edge)[l0] = he0;

    // First: edges unlinked => InvalidEdgeRef
    try testing.expectError(error.InvalidEdgeRef, solid.validateManifold());

    // Link valid edges
    const e0 = try solid.addEdge(allocator, he0, dummy_topo);
    const e1 = try solid.addEdge(allocator, he1, dummy_topo);
    const e2 = try solid.addEdge(allocator, he2, dummy_topo);
    solid.half_edges.slice().items(.edge)[he0] = e0;
    solid.half_edges.slice().items(.edge)[he1] = e1;
    solid.half_edges.slice().items(.edge)[he2] = e2;

    // Twins unlinked => InvalidTwinRef
    try testing.expectError(error.InvalidTwinRef, solid.validateManifold());
}


test "SoASolid validateManifold detects NaN/Inf coordinates" {
    const allocator = testing.allocator;
    var solid = SoASolid.init();
    defer solid.deinit(allocator);

    const dummy_topo = CadTopoId.INVALID;
    _ = try solid.addSolid(allocator, dummy_topo);
    const nan_val = std.math.nan(f32);
    _ = try solid.addVertex(allocator, Vec3.init(nan_val, 0, 0), dummy_topo);
    const f0 = try solid.addFace(allocator, 0, Vec3.init(0, 0, 1), .Plane, dummy_topo);
    _ = try solid.addHalfEdge(allocator, 0, 0, dummy_topo);
    solid.faces.slice().items(.outer_loop)[f0] = 0;

    try testing.expectError(error.InvalidCoordinates, solid.validateManifold());
}

test "TNP Lineage: Face resolution across parametric depth modification" {
    const allocator = testing.allocator;

    const base_sq = [_][2]f32{
        .{ 0, 0 },
        .{ 10, 0 },
        .{ 10, 10 },
        .{ 0, 10 },
    };

    // 1. Initial solid with extrusion depth = 10
    var solid1 = try extrude.extrudePolygon(allocator, 101, &base_sq, 10.0, Vec3.init(0, 0, 1), false);
    defer solid1.deinit(allocator);

    // Get CadTopoId of the top cap face
    const top_face_idx1 = topo_naming.resolveFace(&solid1, CadTopoId.init(101, 0, 3, .Face, topo_naming.FLAG_CAP_TOP, 0));
    try testing.expect(top_face_idx1 != null);
    const original_top_topo = solid1.faces.slice().items(.topo_id)[top_face_idx1.?];

    // 2. Upstream parameter changed: extrusion depth modified from 10 to 50
    var solid2 = try extrude.extrudePolygon(allocator, 101, &base_sq, 50.0, Vec3.init(0, 0, 1), false);
    defer solid2.deinit(allocator);

    // Resolve historical top cap CadTopoId on the new solid
    const resolved_idx2 = topo_naming.resolveFace(&solid2, original_top_topo);
    try testing.expect(resolved_idx2 != null);

    // Verify it correctly resolved the top cap face on solid2
    const resolved_face_norm = solid2.faces.slice().items(.normal)[resolved_idx2.?];
    try testing.expectApproxEqAbs(@as(f32, 1.0), resolved_face_norm.z, 1e-4);
    try testing.expectEqual(topo_naming.FLAG_CAP_TOP, solid2.faces.slice().items(.topo_id)[resolved_idx2.?].fields.flags);
}

test "Extrude Hexagon (6-gon) to watertight manifold" {
    const allocator = testing.allocator;

    // Regular hexagon with radius 5
    var hex_pts: [6][2]f32 = undefined;
    for (0..6) |i| {
        const theta = @as(f32, @floatFromInt(i)) * (std.math.pi / 3.0);
        hex_pts[i] = .{ 5.0 * @cos(theta), 5.0 * @sin(theta) };
    }

    var hex_solid = try extrude.extrudePolygon(
        allocator,
        42,
        &hex_pts,
        15.0,
        Vec3.init(0, 0, 1),
        true, // Symmetric extrusion
    );
    defer hex_solid.deinit(allocator);

    // V = 2 * 6 = 12
    // E = 3 * 6 = 18
    // F = 6 + 2 = 8
    try testing.expectEqual(@as(usize, 12), hex_solid.vertices.len);
    try testing.expectEqual(@as(usize, 18), hex_solid.edges.len);
    try testing.expectEqual(@as(usize, 8), hex_solid.faces.len);
    try testing.expectEqual(@as(usize, 36), hex_solid.half_edges.len);

    try testing.expectEqual(@as(i32, 0), hex_solid.calcEulerPoincare(0));
    try hex_solid.validateManifold();

    // Hexagon area = (3 * sqrt(3) / 2) * R^2 = 2.598076 * 25 = 64.9519
    // Volume = Area * 15 = 974.278
    try testing.expectApproxEqAbs(@as(f32, 974.28), hex_solid.volume, 1.0);

    // Verify bounding box for symmetric extrusion [-7.5, +7.5]
    const bbox = hex_solid.calcBoundingBox();
    try testing.expectApproxEqAbs(@as(f32, -7.5), bbox.min.z, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 7.5), bbox.max.z, 1e-3);
}

test "Extrude Triangle (3-gon) to watertight manifold" {
    const allocator = testing.allocator;

    const tri_pts = [_][2]f32{
        .{ 0.0, 0.0 },
        .{ 4.0, 0.0 },
        .{ 0.0, 3.0 },
    };

    var tri_solid = try extrude.extrudePolygon(
        allocator,
        7,
        &tri_pts,
        10.0,
        Vec3.init(0, 0, 1),
        false,
    );
    defer tri_solid.deinit(allocator);

    // V = 6, E = 9, F = 5
    try testing.expectEqual(@as(usize, 6), tri_solid.vertices.len);
    try testing.expectEqual(@as(usize, 9), tri_solid.edges.len);
    try testing.expectEqual(@as(usize, 5), tri_solid.faces.len);
    try testing.expectEqual(@as(i32, 0), tri_solid.calcEulerPoincare(0));
    try tri_solid.validateManifold();

    // Area = 0.5 * 4 * 3 = 6. Volume = 6 * 10 = 60
    try testing.expectApproxEqAbs(@as(f32, 60.0), tri_solid.volume, 1e-3);
}

test "Feature DAG Rollback Bar: Multiple back-and-forth navigations with cache retention" {
    const allocator = testing.allocator;

    var f1 = std.mem.zeroes(c_abi.CadFeatureNode);
    f1.feature_id = 1;
    f1.type = .Extrude;
    f1.params.extrude = .{ .distance = 10.0, .direction = .{ .x = 0, .y = 0, .z = 1 }, .symmetric = 0 };

    var f2 = std.mem.zeroes(c_abi.CadFeatureNode);
    f2.feature_id = 2;
    f2.type = .Extrude;
    f2.params.extrude = .{ .distance = 20.0, .direction = .{ .x = 0, .y = 0, .z = 1 }, .symmetric = 0 };

    var f3 = std.mem.zeroes(c_abi.CadFeatureNode);
    f3.feature_id = 3;
    f3.type = .BooleanUnion;
    f3.parent_count = 1;
    f3.parent_ids[0] = 1;
    f3.params.boolean_op = .{ .tool_feature_id = 2 };

    const nodes = [_]c_abi.CadFeatureNode{ f1, f2, f3 };

    var dag_inst = dag.FeatureDag.init(allocator);
    defer dag_inst.deinit();

    // Evaluate step 2
    var s_step2 = try dag_inst.evaluateDag(&nodes, 2);
    s_step2.deinit(allocator);

    // Rollback to step 0
    var s_step0 = try dag_inst.evaluateDag(&nodes, 0);
    s_step0.deinit(allocator);

    // Advance back to step 2 (instant cache hit)
    var s_step2_hit = try dag_inst.evaluateDag(&nodes, 2);
    s_step2_hit.deinit(allocator);

    // Rollback to step 1
    var s_step1 = try dag_inst.evaluateDag(&nodes, 1);
    s_step1.deinit(allocator);

    // Ensure all 3 features exist in cache
    try testing.expect(dag_inst.cache.contains(1));
    try testing.expect(dag_inst.cache.contains(2));
    try testing.expect(dag_inst.cache.contains(3));
}

test "Feature DAG Suppressed Node Handling" {
    const allocator = testing.allocator;

    var f1 = std.mem.zeroes(c_abi.CadFeatureNode);
    f1.feature_id = 1;
    f1.type = .Extrude;
    f1.params.extrude = .{ .distance = 10.0, .direction = .{ .x = 0, .y = 0, .z = 1 }, .symmetric = 0 };

    var f2 = std.mem.zeroes(c_abi.CadFeatureNode);
    f2.feature_id = 2;
    f2.type = .Extrude;
    f2.is_suppressed = 1; // Suppressed!
    f2.params.extrude = .{ .distance = 20.0, .direction = .{ .x = 0, .y = 0, .z = 1 }, .symmetric = 0 };

    const nodes = [_]c_abi.CadFeatureNode{ f1, f2 };

    var dag_inst = dag.FeatureDag.init(allocator);
    defer dag_inst.deinit();

    var solid = try dag_inst.evaluateDag(&nodes, 1);
    defer solid.deinit(allocator);

    // Suppressed f2 is skipped, solid is from f1
    try testing.expectEqual(@as(usize, 8), solid.vertices.len);
    try testing.expect(!dag_inst.cache.contains(2));
}

test "SoASolid toLegacySolid conversion" {
    const allocator = testing.allocator;

    const rect = [_][2]f32{ .{ 0, 0 }, .{ 5, 0 }, .{ 5, 3 }, .{ 0, 3 } };
    var soa = try extrude.extrudePolygon(allocator, 1, &rect, 4.0, Vec3.init(0, 0, 1), false);
    defer soa.deinit(allocator);

    var legacy = try soa.toLegacySolid(allocator, 999);
    defer legacy.deinit(allocator);

    try testing.expectEqual(@as(u64, 999), legacy.id);
    try testing.expectEqual(@as(usize, 8), legacy.vertices.items.len);
    try testing.expectEqual(@as(usize, 12), legacy.edges.items.len);
    try testing.expectEqual(@as(usize, 6), legacy.shell.faces.items.len);

    const stats = legacy.getStats();
    try testing.expectEqual(@as(i32, 2), stats.euler_characteristic);
    try testing.expectApproxEqAbs(@as(f32, 60.0), stats.volume, 1e-2);
}
