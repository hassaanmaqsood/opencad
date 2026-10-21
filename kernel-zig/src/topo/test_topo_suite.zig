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

test "Milestone 4.2: Analytical Primitives Integration & Invariants" {
    const allocator = testing.allocator;
    const prim = @import("../primitives/mod.zig");

    // 1. Sphere
    const r_sphere: f32 = 4.0;
    var sphere = try prim.sphere.createSphere(allocator, 10, r_sphere, 8, 16);
    defer sphere.deinit(allocator);

    try testing.expectEqual(@as(i32, 0), sphere.calcEulerPoincare(0));
    try sphere.validateManifold();
    const exp_sph_vol = (4.0 / 3.0) * std.math.pi * r_sphere * r_sphere * r_sphere;
    const exp_sph_area = 4.0 * std.math.pi * r_sphere * r_sphere;
    try testing.expectApproxEqAbs(exp_sph_vol, sphere.volume, 1e-2);
    try testing.expectApproxEqAbs(exp_sph_area, sphere.surface_area, 1e-2);

    // 2. Cone (sharp apex)
    var cone = try prim.cone.createCone(allocator, 20, 5.0, 0.0, 12.0, 16);
    defer cone.deinit(allocator);

    try testing.expectEqual(@as(i32, 0), cone.calcEulerPoincare(0));
    try cone.validateManifold();
    const exp_cone_vol = (1.0 / 3.0) * std.math.pi * 12.0 * 25.0;
    try testing.expectApproxEqAbs(exp_cone_vol, cone.volume, 1e-2);

    // 3. Torus (genus 1)
    const R: f32 = 12.0;
    const r: f32 = 4.0;
    var torus = try prim.torus.createTorus(allocator, 30, R, r, 16, 16);
    defer torus.deinit(allocator);

    // V - E + F = 0 for torus
    try testing.expectEqual(@as(i32, 0), torus.calcEulerPoincare(1));
    try torus.validateManifoldGenus(1);
    const exp_torus_vol = 2.0 * std.math.pi * std.math.pi * R * r * r;
    const exp_torus_area = 4.0 * std.math.pi * std.math.pi * R * r;
    try testing.expectApproxEqAbs(exp_torus_vol, torus.volume, 1e-2);
    try testing.expectApproxEqAbs(exp_torus_area, torus.surface_area, 1e-2);
}

test "Milestone 4.2: Exact B-Rep Sweep and Loft Operations" {
    const allocator = testing.allocator;

    // Sweep: equilateral triangle profile along S-curved 3D polyline
    const tri = [_][2]f32{
        .{ 0.0, 1.0 },
        .{ 0.866, -0.5 },
        .{ -0.866, -0.5 },
    };
    const s_curve = [_]Vec3{
        Vec3.init(0, 0, 0),
        Vec3.init(2, 5, 2),
        Vec3.init(6, 10, 4),
        Vec3.init(12, 12, 8),
    };

    var swept = try ops.sweep.sweepProfile(allocator, 40, &tri, &s_curve);
    defer swept.deinit(allocator);

    try testing.expectEqual(@as(i32, 0), swept.calcEulerPoincare(0));
    try swept.validateManifold();
    try testing.expect(swept.volume > 10.0);

    // Loft: 3 circular profiles approximating a vase / nozzle
    var p0: [8]Vec3 = undefined;
    var p1: [8]Vec3 = undefined;
    var p2: [8]Vec3 = undefined;
    for (0..8) |i| {
        const theta = @as(f32, @floatFromInt(i)) * (std.math.pi / 4.0);
        p0[i] = Vec3.init(6.0 * @cos(theta), 6.0 * @sin(theta), 0.0);
        p1[i] = Vec3.init(3.0 * @cos(theta), 3.0 * @sin(theta), 10.0);
        p2[i] = Vec3.init(5.0 * @cos(theta), 5.0 * @sin(theta), 20.0);
    }

    const profiles = [_][]const Vec3{ &p0, &p1, &p2 };
    var lofted = try ops.loft.loftProfiles(allocator, 50, &profiles);
    defer lofted.deinit(allocator);

    try testing.expectEqual(@as(i32, 0), lofted.calcEulerPoincare(0));
    try lofted.validateManifold();
    try testing.expect(lofted.volume > 100.0);
}

test "Milestone 4.3: Full B-Rep CSG Booleans (Union, Cut, Intersect) & Manifold Closure" {
    const allocator = testing.allocator;

    // Box A: [0, 10] x [0, 10] x [0, 10], Vol = 1000
    const sq_a = [_][2]f32{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 }, .{ 0, 10 } };
    var box_a = try extrude.extrudePolygon(allocator, 101, &sq_a, 10.0, Vec3.init(0, 0, 1), false);
    defer box_a.deinit(allocator);

    // Box B: [5, 15] x [5, 15] x [5, 15], Vol = 1000
    const sq_b = [_][2]f32{ .{ 5, 5 }, .{ 15, 5 }, .{ 15, 15 }, .{ 5, 15 } };
    var box_b = try extrude.extrudePolygon(allocator, 102, &sq_b, 10.0, Vec3.init(0, 0, 1), false);
    for (box_b.vertices.slice().items(.point)) |*pt| {
        pt.z += 5.0;
    }
    defer box_b.deinit(allocator);

    // 1. CSG Union: Vol = 1875.0, watertight 2-manifold
    var u_solid = try boolean.booleanOp(allocator, 103, .Union, &box_a, &box_b);
    defer u_solid.deinit(allocator);
    try u_solid.validateManifold();
    try testing.expectEqual(@as(i32, 0), u_solid.calcEulerPoincare(0));
    try testing.expectApproxEqAbs(@as(f32, 1875.0), u_solid.volume, 1e-1);

    // 2. CSG Difference (Cut): Vol = 875.0, watertight 2-manifold
    var cut_solid = try boolean.booleanOp(allocator, 104, .Difference, &box_a, &box_b);
    defer cut_solid.deinit(allocator);
    try cut_solid.validateManifold();
    try testing.expectEqual(@as(i32, 0), cut_solid.calcEulerPoincare(0));
    try testing.expectApproxEqAbs(@as(f32, 875.0), cut_solid.volume, 1e-1);

    // 3. CSG Intersection: Vol = 125.0, watertight 2-manifold
    var inter_solid = try boolean.booleanOp(allocator, 105, .Intersection, &box_a, &box_b);
    defer inter_solid.deinit(allocator);
    try inter_solid.validateManifold();
    try testing.expectEqual(@as(i32, 0), inter_solid.calcEulerPoincare(0));
    try testing.expectApproxEqAbs(@as(f32, 125.0), inter_solid.volume, 1e-1);

    // 4. Disjoint Difference: A \ Disjoint_B = A
    const sq_disjoint = [_][2]f32{ .{ 50, 0 }, .{ 60, 0 }, .{ 60, 10 }, .{ 50, 10 } };
    var box_disjoint = try extrude.extrudePolygon(allocator, 106, &sq_disjoint, 10.0, Vec3.init(0, 0, 1), false);
    defer box_disjoint.deinit(allocator);

    var diff_disjoint = try boolean.booleanOp(allocator, 107, .Difference, &box_a, &box_disjoint);
    defer diff_disjoint.deinit(allocator);
    try diff_disjoint.validateManifold();
    try testing.expectApproxEqAbs(box_a.volume, diff_disjoint.volume, 1e-3);

    // 5. Disjoint Intersection: returns error.DisjointIntersection
    const err_inter = boolean.booleanOp(allocator, 108, .Intersection, &box_a, &box_disjoint);
    try testing.expectError(error.DisjointIntersection, err_inter);
}

