const std = @import("std");
const types = @import("types.zig");
const residuals = @import("residuals.zig");
const jacobian = @import("jacobian.zig");
const qr = @import("qr.zig");
const Vec2 = @import("../geom/vec2.zig").Vec2;

pub const SolveResult = struct {
    solve_state: types.CadSolveState,
    dof: u32,
    iterations: u32,
    max_residual: f64,
    conflicting_ids: []u32,
};

fn choleskySolve(
    N: usize,
    A: []const f64,
    b: []const f64,
    x: []f64,
    L: []f64,
    y: []f64,
) bool {
    @memset(L[0 .. N * N], 0.0);

    for (0..N) |i| {
        for (0..i + 1) |j| {
            var sum: f64 = A[i * N + j];
            for (0..j) |k| {
                sum -= L[i * N + k] * L[j * N + k];
            }
            if (i == j) {
                if (sum <= 1e-15) return false;
                L[i * N + j] = @sqrt(sum);
            } else {
                L[i * N + j] = sum / L[j * N + j];
            }
        }
    }

    // Forward solve L y = b
    for (0..N) |i| {
        var sum: f64 = b[i];
        for (0..i) |k| {
            sum -= L[i * N + k] * y[k];
        }
        y[i] = sum / L[i * N + i];
    }

    // Back solve L^T x = y
    var i: usize = N;
    while (i > 0) {
        i -= 1;
        var sum: f64 = y[i];
        for (i + 1..N) |k| {
            sum -= L[k * N + i] * x[k];
        }
        x[i] = sum / L[i * N + i];
    }

    return true;
}

pub fn solve(
    allocator: std.mem.Allocator,
    points: []types.CadSketchPoint2D,
    lines: []const types.CadSketchLine2D,
    arcs: []const types.CadSketchArc2D,
    circles: []const types.CadSketchCircle2D,
    constraints: []const types.CadSketchConstraint,
    max_iterations: u32,
    convergence_tol: f64,
) !SolveResult {
    const tol = if (convergence_tol > 0.0) convergence_tol else 1e-7;
    const max_iter = if (max_iterations > 0) max_iterations else 50;

    var registry = types.EntityRegistry.init(points, lines, arcs, circles);
    const free_map = try types.FreeVarMapping.init(allocator, points);

    const eqs = try residuals.compileEquations(allocator, &registry, constraints);

    const M = eqs.len;
    const N = free_map.num_free_vars;

    // Handle trivial / boundary cases:
    if (N == 0) {
        // No free variables: evaluate residual directly
        var max_res: f64 = 0.0;
        var conflict_list = std.ArrayList(u32).empty;

        for (eqs) |eq| {
            const r = @abs(residuals.evalResidual(eq, points));
            if (r > max_res) max_res = r;
            if (r > tol) {
                var found = false;
                for (conflict_list.items) |c_id| {
                    if (c_id == eq.constraint_id) {
                        found = true;
                        break;
                    }
                }
                if (!found) try conflict_list.append(allocator, eq.constraint_id);
            }
        }

        const state: types.CadSolveState = if (max_res <= tol) .Solved else .Conflicting;
        return .{
            .solve_state = state,
            .dof = 0,
            .iterations = 0,
            .max_residual = max_res,
            .conflicting_ids = try conflict_list.toOwnedSlice(allocator),
        };
    }

    if (M == 0) {
        // No equations: system is under-constrained
        return .{
            .solve_state = .UnderConstrained,
            .dof = @intCast(N),
            .iterations = 0,
            .max_residual = 0.0,
            .conflicting_ids = try allocator.alloc(u32, 0),
        };
    }

    // Allocate scratch buffers
    const X = try allocator.alloc(f64, N);
    const X_trial = try allocator.alloc(f64, N);
    const delta_X = try allocator.alloc(f64, N);
    const F = try allocator.alloc(f64, M);
    const F_trial = try allocator.alloc(f64, M);
    const J = try allocator.alloc(f64, M * N);
    const H = try allocator.alloc(f64, N * N);
    const A = try allocator.alloc(f64, N * N);
    const g = try allocator.alloc(f64, N);
    const neg_g = try allocator.alloc(f64, N);
    const L_chol = try allocator.alloc(f64, N * N);
    const y_chol = try allocator.alloc(f64, N);

    // Load initial free variables from points
    for (0..free_map.num_free_points) |fp| {
        const pt_idx = free_map.free_to_point[fp];
        X[fp * 2] = points[pt_idx].x;
        X[fp * 2 + 1] = points[pt_idx].y;
    }

    // Evaluate initial residual
    var current_cost: f64 = 0.0;
    var max_res: f64 = 0.0;
    for (eqs, 0..) |eq, i| {
        const r = residuals.evalResidual(eq, points);
        F[i] = r;
        current_cost += 0.5 * r * r;
        const abs_r = @abs(r);
        if (abs_r > max_res) max_res = abs_r;
    }

    var lambda: f64 = 1e-3;
    var iter: u32 = 0;

    if (max_res > tol) {
        while (iter < max_iter) : (iter += 1) {
            // Compute Jacobian J (size M x N)
            jacobian.evalJacobian(eqs, points, &free_map, J, M, N);

            // Compute H = J^T J and g = J^T F
            @memset(H, 0.0);
            @memset(g, 0.0);

            for (0..M) |i| {
                const fi = F[i];
                for (0..N) |j| {
                    const jij = J[i * N + j];
                    g[j] += jij * fi;
                    for (0..N) |k| {
                        H[j * N + k] += jij * J[i * N + k];
                    }
                }
            }

            if (iter == 0) {
                var max_diag: f64 = 0.0;
                for (0..N) |j| {
                    if (H[j * N + j] > max_diag) max_diag = H[j * N + j];
                }
                lambda = @max(1e-3 * max_diag, 1e-4);
            }

            for (0..N) |j| {
                neg_g[j] = -g[j];
            }

            // LM damping adaptation inner loop
            var step_accepted = false;
            for (0..10) |_| {
                // A = H + lambda * I
                @memcpy(A, H);
                for (0..N) |j| {
                    A[j * N + j] += lambda;
                }

                if (choleskySolve(N, A, neg_g, delta_X, L_chol, y_chol)) {
                    // X_trial = X + delta_X
                    for (0..N) |j| {
                        X_trial[j] = X[j] + delta_X[j];
                    }

                    // Update points with trial coordinates
                    for (0..free_map.num_free_points) |fp| {
                        const pt_idx = free_map.free_to_point[fp];
                        points[pt_idx].x = X_trial[fp * 2];
                        points[pt_idx].y = X_trial[fp * 2 + 1];
                    }

                    // Evaluate trial residual
                    var trial_cost: f64 = 0.0;
                    var trial_max_res: f64 = 0.0;
                    for (eqs, 0..) |eq, i| {
                        const r = residuals.evalResidual(eq, points);
                        F_trial[i] = r;
                        trial_cost += 0.5 * r * r;
                        const abs_r = @abs(r);
                        if (abs_r > trial_max_res) trial_max_res = abs_r;
                    }

                    if (trial_cost < current_cost) {
                        // Accept step
                        @memcpy(X, X_trial);
                        @memcpy(F, F_trial);
                        current_cost = trial_cost;
                        max_res = trial_max_res;
                        lambda = @max(lambda / 10.0, 1e-12);
                        step_accepted = true;
                        break;
                    }
                }

                // Step rejected or singular: increase lambda
                lambda = @min(lambda * 10.0, 1e12);
            }

            // Revert points to current accepted state if step was rejected
            if (!step_accepted) {
                for (0..free_map.num_free_points) |fp| {
                    const pt_idx = free_map.free_to_point[fp];
                    points[pt_idx].x = X[fp * 2];
                    points[pt_idx].y = X[fp * 2 + 1];
                }
            }

            if (max_res <= tol) {
                break;
            }

            // Check step norm convergence
            var delta_max: f64 = 0.0;
            for (0..N) |j| {
                const abs_d = @abs(delta_X[j]);
                if (abs_d > delta_max) delta_max = abs_d;
            }
            if (delta_max < 1e-12 and iter > 0) {
                break;
            }
        }
    }

    // Write final accepted X coordinates to points
    for (0..free_map.num_free_points) |fp| {
        const pt_idx = free_map.free_to_point[fp];
        points[pt_idx].x = X[fp * 2];
        points[pt_idx].y = X[fp * 2 + 1];
    }

    // Compute Jacobian at final state to evaluate degrees of freedom and rank
    jacobian.evalJacobian(eqs, points, &free_map, J, M, N);

    // Perform RRQR on J to compute system rank
    const J_copy = try allocator.alloc(f64, M * N);
    @memcpy(J_copy, J);
    const rrqr_res = try qr.rrqrDecompose(allocator, J_copy, M, N, tol);

    const rank = rrqr_res.rank;
    const dof: u32 = if (N >= rank) @intCast(N - rank) else 0;

    var conflict_list = std.ArrayList(u32).empty;

    var solve_state: types.CadSolveState = .Solved;
    if (max_res <= tol) {
        if (M > rank) {
            solve_state = .OverConstrained;
        } else if (dof > 0) {
            solve_state = .UnderConstrained;
        } else {
            solve_state = .Solved;
        }
    } else {
        solve_state = .Conflicting;
        for (eqs) |eq| {
            const r = @abs(residuals.evalResidual(eq, points));
            if (r > tol) {
                var found = false;
                for (conflict_list.items) |c_id| {
                    if (c_id == eq.constraint_id) {
                        found = true;
                        break;
                    }
                }
                if (!found) try conflict_list.append(allocator, eq.constraint_id);
            }
        }
    }

    return .{
        .solve_state = solve_state,
        .dof = dof,
        .iterations = iter,
        .max_residual = max_res,
        .conflicting_ids = try conflict_list.toOwnedSlice(allocator),
    };
}

/// Compute degrees of freedom from geometric entities without full numerical solve.
pub fn getDof(
    allocator: std.mem.Allocator,
    point_count: u32,
    lines: []const types.CadSketchLine2D,
    arcs: []const types.CadSketchArc2D,
    circles: []const types.CadSketchCircle2D,
    constraints: []const types.CadSketchConstraint,
) !u32 {
    if (point_count == 0) return 0;

    // Generate non-degenerate generic coordinates for point_count points
    const pts = try allocator.alloc(types.CadSketchPoint2D, point_count);
    const two_pi = std.math.pi * 2.0;
    const n_f = @as(f64, @floatFromInt(point_count));

    for (0..point_count) |i| {
        const theta = (two_pi * @as(f64, @floatFromInt(i))) / n_f;
        pts[i] = .{
            .id = @intCast(i + 1),
            .x = 100.0 * @cos(theta),
            .y = 100.0 * @sin(theta),
            .is_fixed = 0,
        };
    }

    var registry = types.EntityRegistry.init(pts, lines, arcs, circles);
    const free_map = try types.FreeVarMapping.init(allocator, pts);
    const eqs = try residuals.compileEquations(allocator, &registry, constraints);

    const M = eqs.len;
    const N = free_map.num_free_vars;

    if (M == 0) {
        return @intCast(N);
    }

    const J = try allocator.alloc(f64, M * N);
    jacobian.evalJacobian(eqs, pts, &free_map, J, M, N);

    const rrqr_res = try qr.rrqrDecompose(allocator, J, M, N, 1e-7);
    const rank = rrqr_res.rank;

    return if (N >= rank) @intCast(N - rank) else 0;
}

test "Solver converges on simple distance and horizontal constraints" {
    var pts = [_]types.CadSketchPoint2D{
        .{ .id = 1, .x = 0.0, .y = 0.0, .is_fixed = 1 },
        .{ .id = 2, .x = 7.0, .y = 2.0, .is_fixed = 0 },
    };

    const lines = [_]types.CadSketchLine2D{
        .{ .id = 10, .start_point_id = 1, .end_point_id = 2 },
    };

    const constraints = [_]types.CadSketchConstraint{
        .{
            .id = 101,
            .type = .Horizontal,
            .entity1_id = 10,
            .entity2_id = types.CAD_SKETCH_INVALID_ID,
            .entity3_id = types.CAD_SKETCH_INVALID_ID,
            .entity4_id = types.CAD_SKETCH_INVALID_ID,
            .parameter_value = 0.0,
            .is_driving = 1,
        },
        .{
            .id = 102,
            .type = .Distance,
            .entity1_id = 1,
            .entity2_id = 2,
            .entity3_id = types.CAD_SKETCH_INVALID_ID,
            .entity4_id = types.CAD_SKETCH_INVALID_ID,
            .parameter_value = 10.0,
            .is_driving = 1,
        },
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try solve(
        arena.allocator(),
        &pts,
        &lines,
        &[_]types.CadSketchArc2D{},
        &[_]types.CadSketchCircle2D{},
        &constraints,
        50,
        1e-7,
    );

    try std.testing.expectEqual(types.CadSolveState.Solved, result.solve_state);
    try std.testing.expectEqual(@as(u32, 0), result.dof);
    try std.testing.expectApproxEqAbs(10.0, pts[1].x, 1e-6);
    try std.testing.expectApproxEqAbs(0.0, pts[1].y, 1e-6);
}

test "Solver detects conflicting constraints" {
    var pts = [_]types.CadSketchPoint2D{
        .{ .id = 1, .x = 0.0, .y = 0.0, .is_fixed = 1 },
        .{ .id = 2, .x = 5.0, .y = 0.0, .is_fixed = 0 },
    };

    const constraints = [_]types.CadSketchConstraint{
        .{
            .id = 201,
            .type = .Distance,
            .entity1_id = 1,
            .entity2_id = 2,
            .entity3_id = types.CAD_SKETCH_INVALID_ID,
            .entity4_id = types.CAD_SKETCH_INVALID_ID,
            .parameter_value = 5.0,
            .is_driving = 1,
        },
        .{
            .id = 202,
            .type = .Distance,
            .entity1_id = 1,
            .entity2_id = 2,
            .entity3_id = types.CAD_SKETCH_INVALID_ID,
            .entity4_id = types.CAD_SKETCH_INVALID_ID,
            .parameter_value = 10.0,
            .is_driving = 1,
        },
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try solve(
        arena.allocator(),
        &pts,
        &[_]types.CadSketchLine2D{},
        &[_]types.CadSketchArc2D{},
        &[_]types.CadSketchCircle2D{},
        &constraints,
        50,
        1e-7,
    );

    try std.testing.expectEqual(types.CadSolveState.Conflicting, result.solve_state);
    try std.testing.expect(result.conflicting_ids.len > 0);
}

test "Solver satisfies Perpendicular and Equal constraints" {
    var pts = [_]types.CadSketchPoint2D{
        .{ .id = 1, .x = 0.0, .y = 0.0, .is_fixed = 1 },
        .{ .id = 2, .x = 10.0, .y = 0.0, .is_fixed = 1 },
        .{ .id = 3, .x = 2.0, .y = 8.0, .is_fixed = 0 },
    };

    const lines = [_]types.CadSketchLine2D{
        .{ .id = 11, .start_point_id = 1, .end_point_id = 2 },
        .{ .id = 12, .start_point_id = 1, .end_point_id = 3 },
    };

    const constraints = [_]types.CadSketchConstraint{
        .{
            .id = 301,
            .type = .Perpendicular,
            .entity1_id = 11,
            .entity2_id = 12,
            .entity3_id = types.CAD_SKETCH_INVALID_ID,
            .entity4_id = types.CAD_SKETCH_INVALID_ID,
            .parameter_value = 0.0,
            .is_driving = 1,
        },
        .{
            .id = 302,
            .type = .Equal,
            .entity1_id = 11,
            .entity2_id = 12,
            .entity3_id = types.CAD_SKETCH_INVALID_ID,
            .entity4_id = types.CAD_SKETCH_INVALID_ID,
            .parameter_value = 0.0,
            .is_driving = 1,
        },
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try solve(
        arena.allocator(),
        &pts,
        &lines,
        &[_]types.CadSketchArc2D{},
        &[_]types.CadSketchCircle2D{},
        &constraints,
        50,
        1e-7,
    );

    try std.testing.expectEqual(types.CadSolveState.Solved, result.solve_state);
    try std.testing.expectEqual(@as(u32, 0), result.dof);
    try std.testing.expectApproxEqAbs(0.0, pts[2].x, 1e-5);
    try std.testing.expectApproxEqAbs(10.0, pts[2].y, 1e-5);
}

test "Solver satisfies Angle constraint" {
    var pts = [_]types.CadSketchPoint2D{
        .{ .id = 1, .x = 0.0, .y = 0.0, .is_fixed = 1 },
        .{ .id = 2, .x = 10.0, .y = 0.0, .is_fixed = 1 },
        .{ .id = 3, .x = 6.0, .y = 3.0, .is_fixed = 0 },
    };

    const lines = [_]types.CadSketchLine2D{
        .{ .id = 21, .start_point_id = 1, .end_point_id = 2 },
        .{ .id = 22, .start_point_id = 1, .end_point_id = 3 },
    };

    const target_angle = std.math.pi / 3.0; // 60 degrees

    const constraints = [_]types.CadSketchConstraint{
        .{
            .id = 401,
            .type = .Angle,
            .entity1_id = 21,
            .entity2_id = 22,
            .entity3_id = types.CAD_SKETCH_INVALID_ID,
            .entity4_id = types.CAD_SKETCH_INVALID_ID,
            .parameter_value = target_angle,
            .is_driving = 1,
        },
        .{
            .id = 402,
            .type = .Distance,
            .entity1_id = 1,
            .entity2_id = 3,
            .entity3_id = types.CAD_SKETCH_INVALID_ID,
            .entity4_id = types.CAD_SKETCH_INVALID_ID,
            .parameter_value = 10.0,
            .is_driving = 1,
        },
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try solve(
        arena.allocator(),
        &pts,
        &lines,
        &[_]types.CadSketchArc2D{},
        &[_]types.CadSketchCircle2D{},
        &constraints,
        50,
        1e-7,
    );

    try std.testing.expectEqual(types.CadSolveState.Solved, result.solve_state);
    try std.testing.expectEqual(@as(u32, 0), result.dof);
    try std.testing.expectApproxEqAbs(5.0, pts[2].x, 1e-5);
    try std.testing.expectApproxEqAbs(10.0 * @sin(target_angle), pts[2].y, 1e-5);
}

test "Solver satisfies Symmetric constraint" {
    var pts = [_]types.CadSketchPoint2D{
        .{ .id = 1, .x = 0.0, .y = 0.0, .is_fixed = 1 }, // Line pt A
        .{ .id = 2, .x = 10.0, .y = 0.0, .is_fixed = 1 }, // Line pt B
        .{ .id = 3, .x = 3.0, .y = 4.0, .is_fixed = 1 }, // Fixed point
        .{ .id = 4, .x = 2.0, .y = -2.0, .is_fixed = 0 }, // Free symmetric point
    };

    const lines = [_]types.CadSketchLine2D{
        .{ .id = 31, .start_point_id = 1, .end_point_id = 2 },
    };

    const constraints = [_]types.CadSketchConstraint{
        .{
            .id = 501,
            .type = .Symmetric,
            .entity1_id = 3,
            .entity2_id = 4,
            .entity3_id = 31,
            .entity4_id = types.CAD_SKETCH_INVALID_ID,
            .parameter_value = 0.0,
            .is_driving = 1,
        },
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try solve(
        arena.allocator(),
        &pts,
        &lines,
        &[_]types.CadSketchArc2D{},
        &[_]types.CadSketchCircle2D{},
        &constraints,
        50,
        1e-7,
    );

    try std.testing.expectEqual(types.CadSolveState.Solved, result.solve_state);
    try std.testing.expectEqual(@as(u32, 0), result.dof);
    try std.testing.expectApproxEqAbs(3.0, pts[3].x, 1e-5);
    try std.testing.expectApproxEqAbs(-4.0, pts[3].y, 1e-5);
}

test "Solver detects OverConstrained consistent system" {
    var pts = [_]types.CadSketchPoint2D{
        .{ .id = 1, .x = 0.0, .y = 0.0, .is_fixed = 1 },
        .{ .id = 2, .x = 8.0, .y = 1.0, .is_fixed = 0 },
    };

    const lines = [_]types.CadSketchLine2D{
        .{ .id = 41, .start_point_id = 1, .end_point_id = 2 },
    };

    const constraints = [_]types.CadSketchConstraint{
        .{
            .id = 601,
            .type = .Horizontal,
            .entity1_id = 41,
            .entity2_id = types.CAD_SKETCH_INVALID_ID,
            .entity3_id = types.CAD_SKETCH_INVALID_ID,
            .entity4_id = types.CAD_SKETCH_INVALID_ID,
            .parameter_value = 0.0,
            .is_driving = 1,
        },
        .{
            .id = 602,
            .type = .Horizontal,
            .entity1_id = 1,
            .entity2_id = 2,
            .entity3_id = types.CAD_SKETCH_INVALID_ID,
            .entity4_id = types.CAD_SKETCH_INVALID_ID,
            .parameter_value = 0.0,
            .is_driving = 1,
        },
        .{
            .id = 603,
            .type = .Distance,
            .entity1_id = 1,
            .entity2_id = 2,
            .entity3_id = types.CAD_SKETCH_INVALID_ID,
            .entity4_id = types.CAD_SKETCH_INVALID_ID,
            .parameter_value = 10.0,
            .is_driving = 1,
        },
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try solve(
        arena.allocator(),
        &pts,
        &lines,
        &[_]types.CadSketchArc2D{},
        &[_]types.CadSketchCircle2D{},
        &constraints,
        50,
        1e-7,
    );

    try std.testing.expectEqual(types.CadSolveState.OverConstrained, result.solve_state);
    try std.testing.expectApproxEqAbs(10.0, pts[1].x, 1e-5);
    try std.testing.expectApproxEqAbs(0.0, pts[1].y, 1e-5);
}

test "cad_sketch_get_dof correctly counts remaining DOF" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const lines = [_]types.CadSketchLine2D{
        .{ .id = 1, .start_point_id = 1, .end_point_id = 2 },
    };

    const constraints = [_]types.CadSketchConstraint{
        .{
            .id = 701,
            .type = .Distance,
            .entity1_id = 1,
            .entity2_id = 2,
            .entity3_id = types.CAD_SKETCH_INVALID_ID,
            .entity4_id = types.CAD_SKETCH_INVALID_ID,
            .parameter_value = 10.0,
            .is_driving = 1,
        },
    };

    // 2 points = 4 free variables; 1 distance constraint removes 1 DOF -> 3 DOF remaining
    const dof = try getDof(
        arena.allocator(),
        2,
        &lines,
        &[_]types.CadSketchArc2D{},
        &[_]types.CadSketchCircle2D{},
        &constraints,
    );

    try std.testing.expectEqual(@as(u32, 3), dof);
}
