const std = @import("std");
const autodiff = @import("cad_kernel").autodiff;
const constraint_sys = @import("cad_kernel").constraint_sys;

test "Test A: Orthonormal 3D Chart Frame Solver" {
    // Orthonormal frame: Phi(u, v) = p0 + u*e1 + v*e2
    // Parameters: e1 = (e1x, e1y, e1z), e2 = (e2x, e2y, e2z) -> 6 parameters
    // Residuals:
    // 1. ||e1||^2 - 1 = 0  => e1x^2 + e1y^2 + e1z^2 - 1.0 = 0
    // 2. ||e2||^2 - 1 = 0  => e2x^2 + e2y^2 + e2z^2 - 1.0 = 0
    // 3. e1 . e2 = 0       => e1x*e2x + e1y*e2y + e1z*e2z = 0
    // Chart alignment:
    // 4. e1y = 0
    // 5. e1z = 0
    // 6. e2z = 0
    // Exact solution: e1 = (1, 0, 0), e2 = (0, 1, 0)
    var sys = constraint_sys.ConstraintSystem.init(std.testing.allocator);
    defer sys.deinit();

    // Initial perturbed guess
    const init_params = [_]f64{ 0.85, 0.1, 0.05, 0.1, 0.92, -0.05 };
    _ = try sys.allocParams(&init_params);

    // Compile residuals
    const r1 = autodiff.expr_compile("x0^2 + x1^2 + x2^2 - 1.0", 23);
    defer autodiff.expr_free(r1);
    const r2 = autodiff.expr_compile("x0^2 + x1^2 + x2^2 - 1.0", 23);
    defer autodiff.expr_free(r2);
    const r3 = autodiff.expr_compile("x0*x3 + x1*x4 + x2*x5", 21);
    defer autodiff.expr_free(r3);
    const r4 = autodiff.expr_compile("x0", 2);
    defer autodiff.expr_free(r4);
    const r5 = autodiff.expr_compile("x0", 2);
    defer autodiff.expr_free(r5);
    const r6 = autodiff.expr_compile("x0", 2);
    defer autodiff.expr_free(r6);

    _ = try sys.addResidual(r1, &[_]u32{ 0, 1, 2 });
    _ = try sys.addResidual(r2, &[_]u32{ 3, 4, 5 });
    _ = try sys.addResidual(r3, &[_]u32{ 0, 1, 2, 3, 4, 5 });
    _ = try sys.addResidual(r4, &[_]u32{1});
    _ = try sys.addResidual(r5, &[_]u32{2});
    _ = try sys.addResidual(r6, &[_]u32{5});

    // Check DOF before solve: 6 equations for 6 variables => DOF should be 0
    const dof = sys.getDof();
    try std.testing.expectEqual(@as(i32, 0), dof);

    // Solve with tolerance 1e-13
    const status = sys.solve(1e-13, 20);
    try std.testing.expectEqual(@as(u32, 0), status);

    const q = sys.params.items;
    // Verify exact analytical convergence: e1 = (1, 0, 0), e2 = (0, 1, 0)
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), q[0], 1e-13);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), q[1], 1e-13);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), q[2], 1e-13);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), q[3], 1e-13);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), q[4], 1e-13);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), q[5], 1e-13);
}

test "Test B: Closed 2D Polygon Wire Solver (Orthogonality & Distance Residuals)" {
    // 4 points P0, P1, P2, P3 forming a rectangle 10x5 mm
    // Coordinates: (x0, y0, x1, y1, x2, y2, x3, y3) -> 8 parameters
    // P0 fixed at (0, 0):
    // 1. x0 = 0
    // 2. y0 = 0
    // P0 -> P1 along X axis of length 10:
    // 3. y1 = 0
    // 4. (x1 - x0)^2 + (y1 - y0)^2 - 100 = 0
    // P1 -> P2 perpendicular (dot product = 0), length 5:
    // 5. (x1 - x0)*(x2 - x1) + (y1 - y0)*(y2 - y1) = 0
    // 6. (x2 - x1)^2 + (y2 - y1)^2 - 25 = 0
    // P2 -> P3 top edge length 10 and perpendicular:
    // 7. (x2 - x1)*(x3 - x2) + (y2 - y1)*(y3 - y2) = 0
    // 8. (x3 - x2)^2 + (y3 - y2)^2 - 100 = 0
    var sys = constraint_sys.ConstraintSystem.init(std.testing.allocator);
    defer sys.deinit();

    // Perturbed initial guesses
    const init_q = [_]f64{
        0.05, -0.05, // P0 near (0, 0)
        9.8, 0.2,    // P1 near (10, 0)
        10.1, 5.2,   // P2 near (10, 5)
        0.15, 4.85,  // P3 near (0, 5)
    };
    _ = try sys.allocParams(&init_q);

    // Expressions
    const r_fix = autodiff.expr_compile("x0", 2);
    defer autodiff.expr_free(r_fix);
    const r_dist10 = autodiff.expr_compile("(x0 - x2)^2 + (x1 - x3)^2 - 100.0", 33);
    defer autodiff.expr_free(r_dist10);
    const r_dist5 = autodiff.expr_compile("(x0 - x2)^2 + (x1 - x3)^2 - 25.0", 32);
    defer autodiff.expr_free(r_dist5);
    const r_ortho = autodiff.expr_compile("(x0 - x2)*(x4 - x0) + (x1 - x3)*(x5 - x1)", 41);
    defer autodiff.expr_free(r_ortho);

    // 1 & 2: P0 at origin
    _ = try sys.addResidual(r_fix, &[_]u32{0}); // x0 = 0
    _ = try sys.addResidual(r_fix, &[_]u32{1}); // y0 = 0

    // 3 & 4: P1 on X axis, dist = 10
    _ = try sys.addResidual(r_fix, &[_]u32{3}); // y1 = 0
    _ = try sys.addResidual(r_dist10, &[_]u32{ 2, 3, 0, 1 }); // dist(P1, P0) = 10

    // 5 & 6: P2 orthogonal to P0-P1, dist = 5
    _ = try sys.addResidual(r_ortho, &[_]u32{ 2, 3, 0, 1, 4, 5 }); // (P1-P0) . (P2-P1) = 0
    _ = try sys.addResidual(r_dist5, &[_]u32{ 4, 5, 2, 3 }); // dist(P2, P1) = 5

    // 7 & 8: P3 orthogonal to P1-P2, dist = 10
    _ = try sys.addResidual(r_ortho, &[_]u32{ 4, 5, 2, 3, 6, 7 }); // (P2-P1) . (P3-P2) = 0
    _ = try sys.addResidual(r_dist10, &[_]u32{ 6, 7, 4, 5 }); // dist(P3, P2) = 10

    const dof = sys.getDof();
    try std.testing.expectEqual(@as(i32, 0), dof);

    const status = sys.solve(1e-13, 30);
    try std.testing.expectEqual(@as(u32, 0), status);

    const q = sys.params.items;
    // P0 = (0, 0)
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), q[0], 1e-13);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), q[1], 1e-13);
    // P1 = (10, 0)
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), q[2], 1e-13);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), q[3], 1e-13);
    // P2 = (10, 5)
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), q[4], 1e-13);
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), q[5], 1e-13);
    // P3 = (0, 5)
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), q[6], 1e-13);
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), q[7], 1e-13);
}

test "Test C: Under-Constrained (DOF > 0) and Conflicting Systems" {
    // Part 1: Under-constrained system: 4 parameters, 2 independent constraints => DOF = 2
    {
        var sys = constraint_sys.ConstraintSystem.init(std.testing.allocator);
        defer sys.deinit();

        const init_q = [_]f64{ 3.1, 3.9, 4.0, 6.0 };
        _ = try sys.allocParams(&init_q);

        const r1 = autodiff.expr_compile("x0^2 + x1^2 - 25.0", 18);
        defer autodiff.expr_free(r1);
        const r2 = autodiff.expr_compile("x0 + x1 - 10.0", 14);
        defer autodiff.expr_free(r2);

        _ = try sys.addResidual(r1, &[_]u32{ 0, 1 });
        _ = try sys.addResidual(r2, &[_]u32{ 2, 3 });

        const dof = sys.getDof();
        try std.testing.expect(dof == 2);

        const status = sys.solve(1e-13, 20);
        try std.testing.expectEqual(@as(u32, 0), status);

        // Verify residuals are <= 1e-13
        const q = sys.params.items;
        const res1 = q[0] * q[0] + q[1] * q[1] - 25.0;
        const res2 = q[2] + q[3] - 10.0;
        try std.testing.expectApproxEqAbs(@as(f64, 0.0), res1, 1e-13);
        try std.testing.expectApproxEqAbs(@as(f64, 0.0), res2, 1e-13);
    }

    // Part 2: Over-constrained / Conflicting system: 1 parameter, 2 conflicting constraints
    // q0 = 1.0 and q0 = 2.0 (cannot be satisfied simultaneously)
    {
        var sys = constraint_sys.ConstraintSystem.init(std.testing.allocator);
        defer sys.deinit();

        const init_q = [_]f64{1.5};
        _ = try sys.allocParams(&init_q);

        const r1 = autodiff.expr_compile("x0 - 1.0", 8);
        defer autodiff.expr_free(r1);
        const r2 = autodiff.expr_compile("x0 - 2.0", 8);
        defer autodiff.expr_free(r2);

        _ = try sys.addResidual(r1, &[_]u32{0});
        _ = try sys.addResidual(r2, &[_]u32{0});

        const status = sys.solve(1e-13, 10);
        // Solver cannot satisfy both to 1e-13, status should be non-zero (1)
        try std.testing.expect(status != 0);
    }
}
