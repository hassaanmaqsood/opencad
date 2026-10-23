const std = @import("std");
const testing = std.testing;
const cad = @import("cad_kernel");

test "Wave 13: 2D Sketch Modifiers & Region Extraction" {
    _ = cad.cad_kernel_init();
    defer _ = cad.cad_kernel_deinit();

    // Test 2D Fillet
    var pts = [_]cad.c_abi.CadSketchPoint2D{
        .{ .id = 1, .x = 0, .y = 10, .is_fixed = 0, .is_construction = 0 },
        .{ .id = 2, .x = 0, .y = 0, .is_fixed = 0, .is_construction = 0 },
        .{ .id = 3, .x = 10, .y = 0, .is_fixed = 0, .is_construction = 0 },
    };
    var pt_count: u32 = 3;
    var lines = [_]cad.c_abi.CadSketchLine2D{
        .{ .id = 1, .start_point_id = 1, .end_point_id = 2, .is_construction = 0 },
        .{ .id = 2, .start_point_id = 2, .end_point_id = 3, .is_construction = 0 },
    };
    var out_arcs: [1]cad.c_abi.CadSketchArc2D = undefined;
    var arc_count: u32 = 0;

    const f_st = cad.cad_sketch_fillet_2d(
        &pts,
        &pt_count,
        &lines,
        2,
        &out_arcs,
        &arc_count,
        1,
        2,
        2.0,
    );
    try testing.expectEqual(cad.CadStatus.Ok, f_st);
    try testing.expectEqual(@as(u32, 1), arc_count);
    try testing.expectApproxEqAbs(@as(f64, 2.0), out_arcs[0].radius, 1e-4);

    // Test 2D Chamfer
    var chamfer_lines = [_]cad.c_abi.CadSketchLine2D{
        .{ .id = 1, .start_point_id = 1, .end_point_id = 2, .is_construction = 0 },
        .{ .id = 2, .start_point_id = 2, .end_point_id = 3, .is_construction = 0 },
    };
    var line_count: u32 = 2;
    const c_st = cad.cad_sketch_chamfer_2d(
        &pts,
        &pt_count,
        &chamfer_lines,
        &line_count,
        1,
        2,
        3.0,
    );
    try testing.expectEqual(cad.CadStatus.Ok, c_st);

    // Test 2D Region Extraction (Shoelace formula)
    var box_lines = [_]cad.c_abi.CadSketchLine2D{
        .{ .id = 1, .start_point_id = 1, .end_point_id = 2, .is_construction = 0 },
        .{ .id = 2, .start_point_id = 2, .end_point_id = 3, .is_construction = 0 },
        .{ .id = 3, .start_point_id = 3, .end_point_id = 4, .is_construction = 0 },
        .{ .id = 4, .start_point_id = 4, .end_point_id = 1, .is_construction = 0 },
    };
    var out_regions: ?[*]cad.c_abi.CadSketchRegion = null;
    var out_reg_count: u32 = 0;
    const reg_st = cad.cad_sketch_extract_regions(
        &box_lines,
        4,
        null,
        0,
        &out_regions,
        &out_reg_count,
    );
    try testing.expectEqual(cad.CadStatus.Ok, reg_st);
    try testing.expectEqual(@as(u32, 1), out_reg_count);
    if (out_regions) |r| {
        try testing.expectApproxEqAbs(@as(f64, 100.0), r[0].area, 1e-4);
        cad.cad_sketch_regions_free(out_regions);
    }
}

test "Wave 13: 3D Sketch Solver" {
    _ = cad.cad_kernel_init();
    defer _ = cad.cad_kernel_deinit();

    var pts = [_]cad.c_abi.CadSketchPoint3D{
        .{ .id = 1, .x = 0, .y = 0, .z = 0, .is_fixed = 1, .is_construction = 0 },
        .{ .id = 2, .x = 5, .y = 3, .z = 2, .is_fixed = 0, .is_construction = 0 },
    };
    const cns = [_]cad.c_abi.CadSketchConstraint3D{
        .{
            .id = 10,
            .type = .AlongX,
            .entity1_id = 1,
            .entity2_id = 2,
            .parameter_value = 0,
            .plane_normal = [_]f64{ 0, 0, 0 },
            .is_driving = 1,
        },
        .{
            .id = 11,
            .type = .Distance,
            .entity1_id = 1,
            .entity2_id = 2,
            .parameter_value = 10.0,
            .plane_normal = [_]f64{ 0, 0, 0 },
            .is_driving = 1,
        },
    };

    var status: cad.c_abi.CadSolverStatus = undefined;
    const st = cad.cad_sketch3d_solve(
        &pts,
        2,
        null,
        0,
        null,
        0,
        null,
        0,
        &cns,
        2,
        50,
        1e-6,
        &status,
    );
    try testing.expectEqual(cad.CadStatus.Ok, st);
    try testing.expectEqual(cad.c_abi.CadSolveState.UnderConstrained, status.solve_state);
    try testing.expectApproxEqAbs(@as(f64, 10.0), pts[1].x, 1e-4);
    try testing.expectApproxEqAbs(@as(f64, 0.0), pts[1].y, 1e-4);
    try testing.expectApproxEqAbs(@as(f64, 0.0), pts[1].z, 1e-4);

    var dof: u32 = 0;
    const dof_st = cad.cad_sketch3d_get_dof(2, null, 0, null, 0, null, 0, &cns, 2, &dof);
    try testing.expectEqual(cad.CadStatus.Ok, dof_st);
    try testing.expectEqual(@as(u32, 4), dof); // 6 vars - 2 constraints = 4 DOF
}

test "Wave 13: Assembly Kinematics & Exploded Views" {
    _ = cad.cad_kernel_init();
    defer _ = cad.cad_kernel_deinit();

    var instances = [_]cad.c_abi.CadAssemblyInstance{
        .{
            .instance_id = 1,
            .solid_handle = 10,
            .is_grounded = 1,
            .initial_transform = [_]f32{
                1, 0, 0, 0,
                0, 1, 0, 0,
                0, 0, 1, 0,
                0, 0, 0, 1,
            },
            .name = std.mem.zeroes([32]u8),
        },
        .{
            .instance_id = 2,
            .solid_handle = 11,
            .is_grounded = 0,
            .initial_transform = [_]f32{
                1, 0, 0, 0,
                0, 1, 0, 0,
                0, 0, 1, 0,
                10, 0, 0, 1,
            },
            .name = std.mem.zeroes([32]u8),
        },
    };

    const mates = [_]cad.c_abi.CadAssemblyMate{
        .{
            .mate_id = 1,
            .type = .RackPinion,
            .instance1_id = 1,
            .entity1_topo_id = .{ .raw = 0 },
            .instance2_id = 2,
            .entity2_topo_id = .{ .raw = 0 },
            .is_anti_aligned = 0,
            .parameter_value = 5.0,
            .limits_min = -100.0,
            .limits_max = 100.0,
        },
    };

    var xforms: [32]f32 = undefined;
    var status: cad.c_abi.CadAssemblySolveStatus = undefined;

    const step_st = cad.cad_assembly_step_motion(
        &instances,
        2,
        &mates,
        1,
        0.1,
        &xforms,
        &status,
    );
    try testing.expectEqual(cad.CadStatus.Ok, step_st);
    try testing.expectEqual(cad.c_abi.CadSolveState.Solved, status.solve_state);

    var trails: [2]cad.c_abi.CadExplodeTrailLine = undefined;
    var trail_count: u32 = 0;
    const exp_st = cad.cad_assembly_exploded_view(
        &instances,
        2,
        1.5,
        &xforms,
        &trails,
        &trail_count,
    );
    try testing.expectEqual(cad.CadStatus.Ok, exp_st);
    try testing.expectEqual(@as(u32, 1), trail_count);
}

test "Wave 13: Datums, Hole Wizard, Threads, and Split Body" {
    _ = cad.cad_kernel_init();
    defer _ = cad.cad_kernel_deinit();

    var dplane: cad.c_abi.CadDatumPlane = undefined;
    const dp_st = cad.cad_datum_plane(
        .Offset,
        &[_]f64{ 0, 0, 0 },
        &[_]f64{ 0, 0, 1 },
        25.0,
        0.0,
        &dplane,
    );
    try testing.expectEqual(cad.CadStatus.Ok, dp_st);
    try testing.expectApproxEqAbs(@as(f64, 25.0), dplane.offset_distance, 1e-4);

    var daxis: cad.c_abi.CadDatumAxis = undefined;
    const da_st = cad.cad_datum_axis(
        .Cylinder,
        &[_]f64{ 0, 0, 0 },
        &[_]f64{ 0, 1, 0 },
        &daxis,
    );
    try testing.expectEqual(cad.CadStatus.Ok, da_st);
    try testing.expectApproxEqAbs(@as(f64, 1.0), daxis.direction.y, 1e-4);

    var solid_pos: cad.c_abi.CadSolidHandle = 0;
    var solid_neg: cad.c_abi.CadSolidHandle = 0;
    const sb_st = cad.cad_op_split_body(
        1,
        &[_]f64{ 0, 0, 5 },
        &[_]f64{ 0, 0, 1 },
        &solid_pos,
        &solid_neg,
    );
    try testing.expectEqual(cad.CadStatus.Ok, sb_st);
    try testing.expectEqual(@as(cad.c_abi.CadSolidHandle, 1), solid_pos);
    try testing.expectEqual(@as(cad.c_abi.CadSolidHandle, 1), solid_neg);
}
