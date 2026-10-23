const std = @import("std");
const testing = std.testing;
const cad = @import("cad_kernel");
const c_abi = cad;
const math = std.math;

pub const CAD_SKETCH_INVALID_ID: u32 = 0xFFFFFFFF;

pub const CadSketchPoint2D = cad.CadSketchPoint2D;
pub const CadSketchLine2D = cad.CadSketchLine2D;
pub const CadSketchArc2D = cad.CadSketchArc2D;
pub const CadSketchCircle2D = cad.CadSketchCircle2D;

pub const CadSketchConstraintType = enum(c_int) {
    Coincident = 0,
    Parallel = 1,
    Perpendicular = 2,
    Tangent = 3,
    Horizontal = 4,
    Vertical = 5,
    Equal = 6,
    Symmetric = 7,
    Distance = 8,
    Angle = 9,
    Radius = 10,
};

pub const CadSketchConstraint = extern struct {
    id: u32,
    type: CadSketchConstraintType,
    entity1_id: u32,
    entity2_id: u32,
    entity3_id: u32,
    entity4_id: u32,
    parameter_value: f64,
    is_driving: u8,
};

pub const CadSolveState = enum(c_int) {
    Solved = 0,
    UnderConstrained = 1,
    OverConstrained = 2,
    Conflicting = 3,
};

pub const CadSolverStatus = extern struct {
    solve_state: CadSolveState,
    degrees_of_freedom: u32,
    iterations: u32,
    max_residual: f64,
    updated_coords: ?[*]const f64,
    coord_count: u32,
    conflicting_constraint_ids: ?[*]const u32,
    conflicting_count: u32,
};

test "2D Sketch Solver - 3-4-5 Right Triangle with Distance & Horizontal Constraints" {
    _ = cad.cad_kernel_init();
    defer _ = cad.cad_kernel_deinit();

    var points = [_]CadSketchPoint2D{
        .{ .id = 0, .x = 0.0, .y = 0.0, .is_fixed = 1 },
        .{ .id = 1, .x = 2.8, .y = 0.2, .is_fixed = 0 },
        .{ .id = 2, .x = 3.1, .y = 3.9, .is_fixed = 0 },
    };

    const lines = [_]CadSketchLine2D{
        .{ .id = 0, .start_point_id = 0, .end_point_id = 1 },
        .{ .id = 1, .start_point_id = 1, .end_point_id = 2 },
        .{ .id = 2, .start_point_id = 2, .end_point_id = 0 },
    };

    const constraints = [_]CadSketchConstraint{
        .{
            .id = 1,
            .type = .Distance,
            .entity1_id = 0,
            .entity2_id = 1,
            .entity3_id = CAD_SKETCH_INVALID_ID,
            .entity4_id = CAD_SKETCH_INVALID_ID,
            .parameter_value = 3.0,
            .is_driving = 1,
        },
        .{
            .id = 2,
            .type = .Horizontal,
            .entity1_id = 0,
            .entity2_id = 1,
            .entity3_id = CAD_SKETCH_INVALID_ID,
            .entity4_id = CAD_SKETCH_INVALID_ID,
            .parameter_value = 0.0,
            .is_driving = 1,
        },
        .{
            .id = 3,
            .type = .Distance,
            .entity1_id = 1,
            .entity2_id = 2,
            .entity3_id = CAD_SKETCH_INVALID_ID,
            .entity4_id = CAD_SKETCH_INVALID_ID,
            .parameter_value = 4.0,
            .is_driving = 1,
        },
        .{
            .id = 4,
            .type = .Distance,
            .entity1_id = 2,
            .entity2_id = 0,
            .entity3_id = CAD_SKETCH_INVALID_ID,
            .entity4_id = CAD_SKETCH_INVALID_ID,
            .parameter_value = 5.0,
            .is_driving = 1,
        },
    };

    var status: CadSolverStatus = undefined;
    const solve_res = cad.cad_sketch_solve(
        @ptrCast(&points),
        points.len,
        @ptrCast(&lines),
        lines.len,
        null,
        0,
        null,
        0,
        @ptrCast(&constraints),
        constraints.len,
        50,
        1e-7,
        @ptrCast(&status),
    );

    try testing.expectEqual(cad.CadStatus.Ok, solve_res);
    try testing.expect(status.max_residual <= 1e-7);
    try testing.expect(status.solve_state == .Solved or status.solve_state == .OverConstrained);

    // Verify solved coordinates
    const d01 = math.hypot(points[1].x - points[0].x, points[1].y - points[0].y);
    const d12 = math.hypot(points[2].x - points[1].x, points[2].y - points[1].y);
    const d20 = math.hypot(points[0].x - points[2].x, points[0].y - points[2].y);

    try testing.expectApproxEqAbs(@as(f64, 3.0), d01, 1e-5);
    try testing.expectApproxEqAbs(@as(f64, 4.0), d12, 1e-5);
    try testing.expectApproxEqAbs(@as(f64, 5.0), d20, 1e-5);
}

test "2D Sketch Solver - Tangent Slot Profile (2 Parallel Lines Tangent to 2 Semicircular Arcs)" {
    _ = cad.cad_kernel_init();
    defer _ = cad.cad_kernel_deinit();

    const L: f64 = 20.0;
    const R: f64 = 5.0;

    var points = [_]CadSketchPoint2D{
        .{ .id = 0, .x = 0.0, .y = 0.0, .is_fixed = 1 }, // C1
        .{ .id = 1, .x = L + 0.1, .y = 0.1, .is_fixed = 0 }, // C2
        .{ .id = 2, .x = 0.1, .y = R + 0.1, .is_fixed = 0 }, // P1 (Top Left)
        .{ .id = 3, .x = L - 0.1, .y = R + 0.1, .is_fixed = 0 }, // P2 (Top Right)
        .{ .id = 4, .x = 0.1, .y = -R - 0.1, .is_fixed = 0 }, // P3 (Bottom Left)
        .{ .id = 5, .x = L + 0.1, .y = -R - 0.1, .is_fixed = 0 }, // P4 (Bottom Right)
    };

    const lines = [_]CadSketchLine2D{
        .{ .id = 0, .start_point_id = 2, .end_point_id = 3 },
        .{ .id = 1, .start_point_id = 4, .end_point_id = 5 },
    };

    const arcs = [_]CadSketchArc2D{
        .{ .id = 0, .center_point_id = 0, .start_point_id = 2, .end_point_id = 4, .radius = R },
        .{ .id = 1, .center_point_id = 1, .start_point_id = 5, .end_point_id = 3, .radius = R },
    };

    const constraints = [_]CadSketchConstraint{
        .{
            .id = 1,
            .type = .Horizontal,
            .entity1_id = 0,
            .entity2_id = 1,
            .entity3_id = CAD_SKETCH_INVALID_ID,
            .entity4_id = CAD_SKETCH_INVALID_ID,
            .parameter_value = 0.0,
            .is_driving = 1,
        },
        .{
            .id = 2,
            .type = .Distance,
            .entity1_id = 0,
            .entity2_id = 1,
            .entity3_id = CAD_SKETCH_INVALID_ID,
            .entity4_id = CAD_SKETCH_INVALID_ID,
            .parameter_value = L,
            .is_driving = 1,
        },
        .{
            .id = 3,
            .type = .Parallel,
            .entity1_id = 0,
            .entity2_id = 1,
            .entity3_id = CAD_SKETCH_INVALID_ID,
            .entity4_id = CAD_SKETCH_INVALID_ID,
            .parameter_value = 0.0,
            .is_driving = 1,
        },
        .{
            .id = 4,
            .type = .Tangent,
            .entity1_id = 0,
            .entity2_id = 0,
            .entity3_id = CAD_SKETCH_INVALID_ID,
            .entity4_id = CAD_SKETCH_INVALID_ID,
            .parameter_value = R,
            .is_driving = 1,
        },
        .{
            .id = 5,
            .type = .Tangent,
            .entity1_id = 1,
            .entity2_id = 0,
            .entity3_id = CAD_SKETCH_INVALID_ID,
            .entity4_id = CAD_SKETCH_INVALID_ID,
            .parameter_value = R,
            .is_driving = 1,
        },
        .{
            .id = 6,
            .type = .Tangent,
            .entity1_id = 0,
            .entity2_id = 1,
            .entity3_id = CAD_SKETCH_INVALID_ID,
            .entity4_id = CAD_SKETCH_INVALID_ID,
            .parameter_value = R,
            .is_driving = 1,
        },
        .{
            .id = 7,
            .type = .Tangent,
            .entity1_id = 1,
            .entity2_id = 1,
            .entity3_id = CAD_SKETCH_INVALID_ID,
            .entity4_id = CAD_SKETCH_INVALID_ID,
            .parameter_value = R,
            .is_driving = 1,
        },
        .{
            .id = 8,
            .type = .Vertical,
            .entity1_id = 0,
            .entity2_id = 2,
            .entity3_id = CAD_SKETCH_INVALID_ID,
            .entity4_id = CAD_SKETCH_INVALID_ID,
            .parameter_value = 0.0,
            .is_driving = 1,
        },
        .{
            .id = 9,
            .type = .Vertical,
            .entity1_id = 0,
            .entity2_id = 4,
            .entity3_id = CAD_SKETCH_INVALID_ID,
            .entity4_id = CAD_SKETCH_INVALID_ID,
            .parameter_value = 0.0,
            .is_driving = 1,
        },
        .{
            .id = 10,
            .type = .Vertical,
            .entity1_id = 1,
            .entity2_id = 3,
            .entity3_id = CAD_SKETCH_INVALID_ID,
            .entity4_id = CAD_SKETCH_INVALID_ID,
            .parameter_value = 0.0,
            .is_driving = 1,
        },
        .{
            .id = 11,
            .type = .Vertical,
            .entity1_id = 1,
            .entity2_id = 5,
            .entity3_id = CAD_SKETCH_INVALID_ID,
            .entity4_id = CAD_SKETCH_INVALID_ID,
            .parameter_value = 0.0,
            .is_driving = 1,
        },
    };

    var status: CadSolverStatus = undefined;
    const solve_res = cad.cad_sketch_solve(
        @ptrCast(&points),
        points.len,
        @ptrCast(&lines),
        lines.len,
        @ptrCast(&arcs),
        arcs.len,
        null,
        0,
        @ptrCast(&constraints),
        constraints.len,
        50,
        1e-7,
        @ptrCast(&status),
    );

    try testing.expectEqual(cad.CadStatus.Ok, solve_res);
    try testing.expect(status.max_residual <= 1e-7);
    try testing.expect(status.solve_state == .Solved or status.solve_state == .OverConstrained);
}

test "2D Sketch Solver - Concentric Flanges with Radial Dimensions" {
    _ = cad.cad_kernel_init();
    defer _ = cad.cad_kernel_deinit();

    var points = [_]CadSketchPoint2D{
        .{ .id = 0, .x = 5.0, .y = 5.0, .is_fixed = 1 }, // Center
        .{ .id = 1, .x = 10.2, .y = 5.1, .is_fixed = 0 }, // Radius 1 point
        .{ .id = 2, .x = 5.1, .y = 19.9, .is_fixed = 0 }, // Radius 2 point
    };

    const circles = [_]CadSketchCircle2D{
        .{ .id = 0, .center_point_id = 0, .radius = 5.0 },
        .{ .id = 1, .center_point_id = 0, .radius = 15.0 },
    };

    const constraints = [_]CadSketchConstraint{
        .{
            .id = 1,
            .type = .Radius,
            .entity1_id = 0,
            .entity2_id = 1,
            .entity3_id = CAD_SKETCH_INVALID_ID,
            .entity4_id = CAD_SKETCH_INVALID_ID,
            .parameter_value = 5.0,
            .is_driving = 1,
        },
        .{
            .id = 2,
            .type = .Radius,
            .entity1_id = 1,
            .entity2_id = 2,
            .entity3_id = CAD_SKETCH_INVALID_ID,
            .entity4_id = CAD_SKETCH_INVALID_ID,
            .parameter_value = 15.0,
            .is_driving = 1,
        },
    };

    var status: CadSolverStatus = undefined;
    const solve_res = cad.cad_sketch_solve(
        @ptrCast(&points),
        points.len,
        null,
        0,
        null,
        0,
        @ptrCast(&circles),
        circles.len,
        @ptrCast(&constraints),
        constraints.len,
        50,
        1e-7,
        @ptrCast(&status),
    );

    try testing.expectEqual(cad.CadStatus.Ok, solve_res);
    try testing.expect(status.max_residual <= 1e-7);

    const r1 = math.hypot(points[1].x - points[0].x, points[1].y - points[0].y);
    const r2 = math.hypot(points[2].x - points[0].x, points[2].y - points[0].y);
    try testing.expectApproxEqAbs(@as(f64, 5.0), r1, 1e-5);
    try testing.expectApproxEqAbs(@as(f64, 15.0), r2, 1e-5);
}

test "2D Sketch Solver - Symmetric Bracket with Vertical Centerline Symmetry" {
    _ = cad.cad_kernel_init();
    defer _ = cad.cad_kernel_deinit();

    const w: f64 = 10.0;
    const h: f64 = 15.0;

    var points = [_]CadSketchPoint2D{
        .{ .id = 0, .x = 0.0, .y = -30.0, .is_fixed = 1 },
        .{ .id = 1, .x = 0.0, .y = 30.0, .is_fixed = 1 },
        .{ .id = 2, .x = -w - 0.2, .y = -h + 0.1, .is_fixed = 0 },
        .{ .id = 3, .x = w + 0.1, .y = -h - 0.2, .is_fixed = 0 },
        .{ .id = 4, .x = -w + 0.2, .y = h + 0.1, .is_fixed = 0 },
        .{ .id = 5, .x = w - 0.1, .y = h - 0.2, .is_fixed = 0 },
    };

    const lines = [_]CadSketchLine2D{
        .{ .id = 0, .start_point_id = 0, .end_point_id = 1 }, // Centerline axis
        .{ .id = 1, .start_point_id = 2, .end_point_id = 3 }, // Bottom
        .{ .id = 2, .start_point_id = 4, .end_point_id = 5 }, // Top
        .{ .id = 3, .start_point_id = 2, .end_point_id = 4 }, // Left
        .{ .id = 4, .start_point_id = 3, .end_point_id = 5 }, // Right
    };

    const constraints = [_]CadSketchConstraint{
        .{
            .id = 1,
            .type = .Symmetric,
            .entity1_id = 2,
            .entity2_id = 3,
            .entity3_id = 0,
            .entity4_id = CAD_SKETCH_INVALID_ID,
            .parameter_value = 0.0,
            .is_driving = 1,
        },
        .{
            .id = 2,
            .type = .Symmetric,
            .entity1_id = 4,
            .entity2_id = 5,
            .entity3_id = 0,
            .entity4_id = CAD_SKETCH_INVALID_ID,
            .parameter_value = 0.0,
            .is_driving = 1,
        },
        .{
            .id = 3,
            .type = .Distance,
            .entity1_id = 2,
            .entity2_id = 3,
            .entity3_id = CAD_SKETCH_INVALID_ID,
            .entity4_id = CAD_SKETCH_INVALID_ID,
            .parameter_value = 2.0 * w,
            .is_driving = 1,
        },
        .{
            .id = 4,
            .type = .Distance,
            .entity1_id = 2,
            .entity2_id = 4,
            .entity3_id = CAD_SKETCH_INVALID_ID,
            .entity4_id = CAD_SKETCH_INVALID_ID,
            .parameter_value = 2.0 * h,
            .is_driving = 1,
        },
        .{
            .id = 5,
            .type = .Horizontal,
            .entity1_id = 2,
            .entity2_id = 3,
            .entity3_id = CAD_SKETCH_INVALID_ID,
            .entity4_id = CAD_SKETCH_INVALID_ID,
            .parameter_value = 0.0,
            .is_driving = 1,
        },
    };

    var status: CadSolverStatus = undefined;
    const solve_res = cad.cad_sketch_solve(
        @ptrCast(&points),
        points.len,
        @ptrCast(&lines),
        lines.len,
        null,
        0,
        null,
        0,
        @ptrCast(&constraints),
        constraints.len,
        50,
        1e-7,
        @ptrCast(&status),
    );

    try testing.expectEqual(cad.CadStatus.Ok, solve_res);
    try testing.expect(status.max_residual <= 1e-7);

    // Assert symmetry across X = 0
    try testing.expectApproxEqAbs(points[2].x, -points[3].x, 1e-5);
    try testing.expectApproxEqAbs(points[4].x, -points[5].x, 1e-5);
    try testing.expectApproxEqAbs(points[2].y, points[3].y, 1e-5);
    try testing.expectApproxEqAbs(points[4].y, points[5].y, 1e-5);
}

test "2D Sketch Solver - Geometric Constraints: Horizontal, Vertical, Equal, Angle, Perpendicular" {
    _ = cad.cad_kernel_init();
    defer _ = cad.cad_kernel_deinit();

    var points = [_]CadSketchPoint2D{
        .{ .id = 0, .x = 0.0, .y = 0.0, .is_fixed = 1 },
        .{ .id = 1, .x = 9.8, .y = 0.2, .is_fixed = 0 },
        .{ .id = 2, .x = 0.0, .y = 0.0, .is_fixed = 1 },
        .{ .id = 3, .x = 0.1, .y = 10.1, .is_fixed = 0 },
    };

    const lines = [_]CadSketchLine2D{
        .{ .id = 0, .start_point_id = 0, .end_point_id = 1 },
        .{ .id = 1, .start_point_id = 2, .end_point_id = 3 },
    };

    const constraints = [_]CadSketchConstraint{
        .{
            .id = 1,
            .type = .Horizontal,
            .entity1_id = 0,
            .entity2_id = 1,
            .entity3_id = CAD_SKETCH_INVALID_ID,
            .entity4_id = CAD_SKETCH_INVALID_ID,
            .parameter_value = 0.0,
            .is_driving = 1,
        },
        .{
            .id = 2,
            .type = .Vertical,
            .entity1_id = 2,
            .entity2_id = 3,
            .entity3_id = CAD_SKETCH_INVALID_ID,
            .entity4_id = CAD_SKETCH_INVALID_ID,
            .parameter_value = 0.0,
            .is_driving = 1,
        },
        .{
            .id = 3,
            .type = .Perpendicular,
            .entity1_id = 0,
            .entity2_id = 1,
            .entity3_id = CAD_SKETCH_INVALID_ID,
            .entity4_id = CAD_SKETCH_INVALID_ID,
            .parameter_value = 0.0,
            .is_driving = 1,
        },
        .{
            .id = 4,
            .type = .Equal,
            .entity1_id = 0,
            .entity2_id = 1,
            .entity3_id = CAD_SKETCH_INVALID_ID,
            .entity4_id = CAD_SKETCH_INVALID_ID,
            .parameter_value = 0.0,
            .is_driving = 1,
        },
        .{
            .id = 5,
            .type = .Distance,
            .entity1_id = 0,
            .entity2_id = 1,
            .entity3_id = CAD_SKETCH_INVALID_ID,
            .entity4_id = CAD_SKETCH_INVALID_ID,
            .parameter_value = 10.0,
            .is_driving = 1,
        },
    };

    var status: CadSolverStatus = undefined;
    const solve_res = cad.cad_sketch_solve(
        @ptrCast(&points),
        points.len,
        @ptrCast(&lines),
        lines.len,
        null,
        0,
        null,
        0,
        @ptrCast(&constraints),
        constraints.len,
        50,
        1e-7,
        @ptrCast(&status),
    );

    try testing.expectEqual(cad.CadStatus.Ok, solve_res);
    try testing.expect(status.max_residual <= 1e-7);
    try testing.expectApproxEqAbs(@as(f64, 10.0), points[1].x, 1e-5);
    try testing.expectApproxEqAbs(@as(f64, 0.0), points[1].y, 1e-5);
    try testing.expectApproxEqAbs(@as(f64, 0.0), points[3].x, 1e-5);
    try testing.expectApproxEqAbs(@as(f64, 10.0), points[3].y, 1e-5);
}

test "2D Sketch Solver - Under-Constrained Sketches (DOF > 0 Correctly Identified)" {
    _ = cad.cad_kernel_init();
    defer _ = cad.cad_kernel_deinit();

    var points = [_]CadSketchPoint2D{
        .{ .id = 0, .x = 0.0, .y = 0.0, .is_fixed = 1 },
        .{ .id = 1, .x = 10.0, .y = 0.0, .is_fixed = 0 },
        .{ .id = 2, .x = 10.0, .y = 10.0, .is_fixed = 0 },
        .{ .id = 3, .x = 0.0, .y = 10.0, .is_fixed = 0 },
    };

    const lines = [_]CadSketchLine2D{
        .{ .id = 0, .start_point_id = 0, .end_point_id = 1 },
        .{ .id = 1, .start_point_id = 1, .end_point_id = 2 },
    };

    // Only 2 constraints for 6 free variables
    const constraints = [_]CadSketchConstraint{
        .{
            .id = 1,
            .type = .Distance,
            .entity1_id = 0,
            .entity2_id = 1,
            .entity3_id = CAD_SKETCH_INVALID_ID,
            .entity4_id = CAD_SKETCH_INVALID_ID,
            .parameter_value = 10.0,
            .is_driving = 1,
        },
        .{
            .id = 2,
            .type = .Horizontal,
            .entity1_id = 0,
            .entity2_id = 1,
            .entity3_id = CAD_SKETCH_INVALID_ID,
            .entity4_id = CAD_SKETCH_INVALID_ID,
            .parameter_value = 0.0,
            .is_driving = 1,
        },
    };

    var status: CadSolverStatus = undefined;
    const solve_res = cad.cad_sketch_solve(
        @ptrCast(&points),
        points.len,
        @ptrCast(&lines),
        lines.len,
        null,
        0,
        null,
        0,
        @ptrCast(&constraints),
        constraints.len,
        50,
        1e-7,
        @ptrCast(&status),
    );

    try testing.expectEqual(cad.CadStatus.Ok, solve_res);
    try testing.expectEqual(CadSolveState.UnderConstrained, status.solve_state);
    try testing.expect(status.degrees_of_freedom > 0);
}

test "2D Sketch Solver - Over-Constrained Consistent Sketch (Redundant Constraint Detected)" {
    _ = cad.cad_kernel_init();
    defer _ = cad.cad_kernel_deinit();

    var points = [_]CadSketchPoint2D{
        .{ .id = 0, .x = 0.0, .y = 0.0, .is_fixed = 1 },
        .{ .id = 1, .x = 9.9, .y = 0.1, .is_fixed = 0 },
    };

    const lines = [_]CadSketchLine2D{
        .{ .id = 0, .start_point_id = 0, .end_point_id = 1 },
    };

    // 2 free variables, 3 consistent equations
    const constraints = [_]CadSketchConstraint{
        .{
            .id = 1,
            .type = .Horizontal,
            .entity1_id = 0,
            .entity2_id = 1,
            .entity3_id = CAD_SKETCH_INVALID_ID,
            .entity4_id = CAD_SKETCH_INVALID_ID,
            .parameter_value = 0.0,
            .is_driving = 1,
        },
        .{
            .id = 2,
            .type = .Distance,
            .entity1_id = 0,
            .entity2_id = 1,
            .entity3_id = CAD_SKETCH_INVALID_ID,
            .entity4_id = CAD_SKETCH_INVALID_ID,
            .parameter_value = 10.0,
            .is_driving = 1,
        },
        .{
            .id = 3,
            .type = .Distance,
            .entity1_id = 0,
            .entity2_id = 1,
            .entity3_id = CAD_SKETCH_INVALID_ID,
            .entity4_id = CAD_SKETCH_INVALID_ID,
            .parameter_value = 10.0,
            .is_driving = 1,
        },
    };

    var status: CadSolverStatus = undefined;
    const solve_res = cad.cad_sketch_solve(
        @ptrCast(&points),
        points.len,
        @ptrCast(&lines),
        lines.len,
        null,
        0,
        null,
        0,
        @ptrCast(&constraints),
        constraints.len,
        50,
        1e-7,
        @ptrCast(&status),
    );

    try testing.expectEqual(cad.CadStatus.Ok, solve_res);
    try testing.expectEqual(CadSolveState.OverConstrained, status.solve_state);
    try testing.expect(status.max_residual <= 1e-7);
}

test "2D Sketch Solver - Conflicting Sketch (Contradictory Constraints Detected)" {
    _ = cad.cad_kernel_init();
    defer _ = cad.cad_kernel_deinit();

    var points = [_]CadSketchPoint2D{
        .{ .id = 0, .x = 0.0, .y = 0.0, .is_fixed = 1 },
        .{ .id = 1, .x = 8.0, .y = 0.0, .is_fixed = 0 },
    };

    const lines = [_]CadSketchLine2D{
        .{ .id = 0, .start_point_id = 0, .end_point_id = 1 },
    };

    // Contradictory distance constraints
    const constraints = [_]CadSketchConstraint{
        .{
            .id = 1,
            .type = .Horizontal,
            .entity1_id = 0,
            .entity2_id = 1,
            .entity3_id = CAD_SKETCH_INVALID_ID,
            .entity4_id = CAD_SKETCH_INVALID_ID,
            .parameter_value = 0.0,
            .is_driving = 1,
        },
        .{
            .id = 2,
            .type = .Distance,
            .entity1_id = 0,
            .entity2_id = 1,
            .entity3_id = CAD_SKETCH_INVALID_ID,
            .entity4_id = CAD_SKETCH_INVALID_ID,
            .parameter_value = 10.0,
            .is_driving = 1,
        },
        .{
            .id = 3,
            .type = .Distance,
            .entity1_id = 0,
            .entity2_id = 1,
            .entity3_id = CAD_SKETCH_INVALID_ID,
            .entity4_id = CAD_SKETCH_INVALID_ID,
            .parameter_value = 5.0,
            .is_driving = 1,
        },
    };

    var status: CadSolverStatus = undefined;
    const solve_res = cad.cad_sketch_solve(
        @ptrCast(&points),
        points.len,
        @ptrCast(&lines),
        lines.len,
        null,
        0,
        null,
        0,
        @ptrCast(&constraints),
        constraints.len,
        50,
        1e-7,
        @ptrCast(&status),
    );

    try testing.expectEqual(cad.CadStatus.Ok, solve_res);
    try testing.expectEqual(CadSolveState.Conflicting, status.solve_state);
    try testing.expect(status.conflicting_count > 0);
}

test "2D Sketch Solver - Degrees of Freedom Analysis via cad_sketch_get_dof" {
    _ = cad.cad_kernel_init();
    defer _ = cad.cad_kernel_deinit();

    const lines = [_]CadSketchLine2D{
        .{ .id = 0, .start_point_id = 0, .end_point_id = 1 },
    };

    const constraints = [_]CadSketchConstraint{
        .{
            .id = 1,
            .type = .Distance,
            .entity1_id = 0,
            .entity2_id = 1,
            .entity3_id = CAD_SKETCH_INVALID_ID,
            .entity4_id = CAD_SKETCH_INVALID_ID,
            .parameter_value = 10.0,
            .is_driving = 1,
        },
    };

    var dof: u32 = 0;
    const dof_res = cad.cad_sketch_get_dof(
        3, // 3 points (6 free coordinates without fix)
        @ptrCast(&lines),
        lines.len,
        null,
        0,
        null,
        0,
        @ptrCast(&constraints),
        constraints.len,
        &dof,
    );

    try testing.expectEqual(cad.CadStatus.Ok, dof_res);
    try testing.expect(dof >= 5);
}
