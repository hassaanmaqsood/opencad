const std = @import("std");
const types = @import("types.zig");
const residuals = @import("residuals.zig");
const Vec2 = @import("../geom/vec2.zig").Vec2;

const EPS: f64 = 1e-12;

fn addDeriv(
    J: []f64,
    row: usize,
    num_cols: usize,
    free_mapping: *const types.FreeVarMapping,
    pt_idx: usize,
    dx: f64,
    dy: f64,
) void {
    if (free_mapping.getVarIndex(pt_idx, false)) |col_x| {
        J[row * num_cols + col_x] += dx;
    }
    if (free_mapping.getVarIndex(pt_idx, true)) |col_y| {
        J[row * num_cols + col_y] += dy;
    }
}

pub fn evalJacobian(
    eqs: []const residuals.Equation,
    points: []const types.CadSketchPoint2D,
    free_mapping: *const types.FreeVarMapping,
    J: []f64,
    num_rows: usize,
    num_cols: usize,
) void {
    @memset(J[0 .. num_rows * num_cols], 0.0);

    for (eqs, 0..) |eq, row| {
        switch (eq.kind) {
            .coincident_x => {
                addDeriv(J, row, num_cols, free_mapping, eq.p1, 1.0, 0.0);
                addDeriv(J, row, num_cols, free_mapping, eq.p2, -1.0, 0.0);
            },
            .coincident_y => {
                addDeriv(J, row, num_cols, free_mapping, eq.p1, 0.0, 1.0);
                addDeriv(J, row, num_cols, free_mapping, eq.p2, 0.0, -1.0);
            },
            .point_on_line, .distance_pt_line => {
                const P = Vec2.init(points[eq.p1].x, points[eq.p1].y);
                const A = Vec2.init(points[eq.p2].x, points[eq.p2].y);
                const B = Vec2.init(points[eq.p3].x, points[eq.p3].y);
                const v = B.sub(A);
                const L = @max(v.norm(), EPS);
                const L2 = L * L;

                // N = (P.x - A.x)*v.y - (P.y - A.y)*v.x
                const N = (P.x - A.x) * v.y - (P.y - A.y) * v.x;

                // Deriv w.r.t P
                const dP_x = v.y / L;
                const dP_y = -v.x / L;
                addDeriv(J, row, num_cols, free_mapping, eq.p1, dP_x, dP_y);

                // Deriv w.r.t A
                const dN_Ax = P.y - B.y;
                const dN_Ay = B.x - P.x;
                const dL_Ax = -v.x / L;
                const dL_Ay = -v.y / L;
                const dA_x = (dN_Ax * L - N * dL_Ax) / L2;
                const dA_y = (dN_Ay * L - N * dL_Ay) / L2;
                addDeriv(J, row, num_cols, free_mapping, eq.p2, dA_x, dA_y);

                // Deriv w.r.t B
                const dN_Bx = -(P.y - A.y);
                const dN_By = P.x - A.x;
                const dL_Bx = v.x / L;
                const dL_By = v.y / L;
                const dB_x = (dN_Bx * L - N * dL_Bx) / L2;
                const dB_y = (dN_By * L - N * dL_By) / L2;
                addDeriv(J, row, num_cols, free_mapping, eq.p3, dB_x, dB_y);
            },
            .point_on_circle, .radius => {
                const P = Vec2.init(points[eq.p1].x, points[eq.p1].y);
                const C = Vec2.init(points[eq.p2].x, points[eq.p2].y);
                const d = @max(P.dist(C), EPS);
                const u = P.sub(C).scale(1.0 / d);

                addDeriv(J, row, num_cols, free_mapping, eq.p1, u.x, u.y);
                addDeriv(J, row, num_cols, free_mapping, eq.p2, -u.x, -u.y);
            },
            .horizontal => {
                addDeriv(J, row, num_cols, free_mapping, eq.p2, 0.0, 1.0);
                addDeriv(J, row, num_cols, free_mapping, eq.p1, 0.0, -1.0);
            },
            .vertical => {
                addDeriv(J, row, num_cols, free_mapping, eq.p2, 1.0, 0.0);
                addDeriv(J, row, num_cols, free_mapping, eq.p1, -1.0, 0.0);
            },
            .distance_pt_pt, .tangent_circle_circle => {
                const P1 = Vec2.init(points[eq.p1].x, points[eq.p1].y);
                const P2 = Vec2.init(points[eq.p2].x, points[eq.p2].y);
                const d = @max(P2.dist(P1), EPS);
                const u = P2.sub(P1).scale(1.0 / d);

                addDeriv(J, row, num_cols, free_mapping, eq.p2, u.x, u.y);
                addDeriv(J, row, num_cols, free_mapping, eq.p1, -u.x, -u.y);
            },
            .parallel => {
                const P1 = Vec2.init(points[eq.p1].x, points[eq.p1].y);
                const P2 = Vec2.init(points[eq.p2].x, points[eq.p2].y);
                const P3 = Vec2.init(points[eq.p3].x, points[eq.p3].y);
                const P4 = Vec2.init(points[eq.p4].x, points[eq.p4].y);

                const v1 = P2.sub(P1);
                const v2 = P4.sub(P3);
                const L1 = @max(v1.norm(), EPS);
                const L2 = @max(v2.norm(), EPS);
                const dir1 = v1.scale(1.0 / L1);
                const dir2 = v2.scale(1.0 / L2);

                const w = Vec2.init(dir2.y, -dir2.x);
                const w_dot_dir1 = w.dot(dir1);
                const grad_v1 = w.sub(dir1.scale(w_dot_dir1)).scale(1.0 / L1);

                addDeriv(J, row, num_cols, free_mapping, eq.p2, grad_v1.x, grad_v1.y);
                addDeriv(J, row, num_cols, free_mapping, eq.p1, -grad_v1.x, -grad_v1.y);

                const z = Vec2.init(-dir1.y, dir1.x);
                const z_dot_dir2 = z.dot(dir2);
                const grad_v2 = z.sub(dir2.scale(z_dot_dir2)).scale(1.0 / L2);

                addDeriv(J, row, num_cols, free_mapping, eq.p4, grad_v2.x, grad_v2.y);
                addDeriv(J, row, num_cols, free_mapping, eq.p3, -grad_v2.x, -grad_v2.y);
            },
            .perpendicular => {
                const P1 = Vec2.init(points[eq.p1].x, points[eq.p1].y);
                const P2 = Vec2.init(points[eq.p2].x, points[eq.p2].y);
                const P3 = Vec2.init(points[eq.p3].x, points[eq.p3].y);
                const P4 = Vec2.init(points[eq.p4].x, points[eq.p4].y);

                const v1 = P2.sub(P1);
                const v2 = P4.sub(P3);
                const L1 = @max(v1.norm(), EPS);
                const L2 = @max(v2.norm(), EPS);
                const dir1 = v1.scale(1.0 / L1);
                const dir2 = v2.scale(1.0 / L2);

                const dir1_dot_dir2 = dir1.dot(dir2);
                const grad_v1 = dir2.sub(dir1.scale(dir1_dot_dir2)).scale(1.0 / L1);
                addDeriv(J, row, num_cols, free_mapping, eq.p2, grad_v1.x, grad_v1.y);
                addDeriv(J, row, num_cols, free_mapping, eq.p1, -grad_v1.x, -grad_v1.y);

                const grad_v2 = dir1.sub(dir2.scale(dir1_dot_dir2)).scale(1.0 / L2);
                addDeriv(J, row, num_cols, free_mapping, eq.p4, grad_v2.x, grad_v2.y);
                addDeriv(J, row, num_cols, free_mapping, eq.p3, -grad_v2.x, -grad_v2.y);
            },
            .equal_length => {
                const P1 = Vec2.init(points[eq.p1].x, points[eq.p1].y);
                const P2 = Vec2.init(points[eq.p2].x, points[eq.p2].y);
                const P3 = Vec2.init(points[eq.p3].x, points[eq.p3].y);
                const P4 = Vec2.init(points[eq.p4].x, points[eq.p4].y);

                const d1 = @max(P2.dist(P1), EPS);
                const d2 = @max(P4.dist(P3), EPS);
                const dir1 = P2.sub(P1).scale(1.0 / d1);
                const dir2 = P4.sub(P3).scale(1.0 / d2);

                addDeriv(J, row, num_cols, free_mapping, eq.p2, dir1.x, dir1.y);
                addDeriv(J, row, num_cols, free_mapping, eq.p1, -dir1.x, -dir1.y);
                addDeriv(J, row, num_cols, free_mapping, eq.p4, -dir2.x, -dir2.y);
                addDeriv(J, row, num_cols, free_mapping, eq.p3, dir2.x, dir2.y);
            },
            .equal_radius => {
                const C1 = Vec2.init(points[eq.p1].x, points[eq.p1].y);
                const S1 = Vec2.init(points[eq.p2].x, points[eq.p2].y);
                const C2 = Vec2.init(points[eq.p3].x, points[eq.p3].y);
                const S2 = Vec2.init(points[eq.p4].x, points[eq.p4].y);

                const d1 = @max(S1.dist(C1), EPS);
                const d2 = @max(S2.dist(C2), EPS);
                const dir1 = S1.sub(C1).scale(1.0 / d1);
                const dir2 = S2.sub(C2).scale(1.0 / d2);

                addDeriv(J, row, num_cols, free_mapping, eq.p2, dir1.x, dir1.y);
                addDeriv(J, row, num_cols, free_mapping, eq.p1, -dir1.x, -dir1.y);
                addDeriv(J, row, num_cols, free_mapping, eq.p4, -dir2.x, -dir2.y);
                addDeriv(J, row, num_cols, free_mapping, eq.p3, dir2.x, dir2.y);
            },
            .angle => {
                const P1 = Vec2.init(points[eq.p1].x, points[eq.p1].y);
                const P2 = Vec2.init(points[eq.p2].x, points[eq.p2].y);
                const P3 = Vec2.init(points[eq.p3].x, points[eq.p3].y);
                const P4 = Vec2.init(points[eq.p4].x, points[eq.p4].y);

                const v1 = P2.sub(P1);
                const v2 = P4.sub(P3);
                const L1 = @max(v1.norm(), EPS);
                const L2 = @max(v2.norm(), EPS);
                const dir1 = v1.scale(1.0 / L1);
                const dir2 = v2.scale(1.0 / L2);

                const theta = eq.param;
                const cos_t = @cos(theta);
                const sin_t = @sin(theta);

                // dF/du1 = cos_t * (dir2.y, -dir2.x) - sin_t * (dir2.x, dir2.y)
                const grad_u1 = Vec2.init(
                    cos_t * dir2.y - sin_t * dir2.x,
                    -cos_t * dir2.x - sin_t * dir2.y,
                );
                const grad_v1 = grad_u1.sub(dir1.scale(grad_u1.dot(dir1))).scale(1.0 / L1);
                addDeriv(J, row, num_cols, free_mapping, eq.p2, grad_v1.x, grad_v1.y);
                addDeriv(J, row, num_cols, free_mapping, eq.p1, -grad_v1.x, -grad_v1.y);

                // dF/du2 = cos_t * (-dir1.y, dir1.x) - sin_t * (dir1.x, dir1.y)
                const grad_u2 = Vec2.init(
                    -cos_t * dir1.y - sin_t * dir1.x,
                    cos_t * dir1.x - sin_t * dir1.y,
                );
                const grad_v2 = grad_u2.sub(dir2.scale(grad_u2.dot(dir2))).scale(1.0 / L2);
                addDeriv(J, row, num_cols, free_mapping, eq.p4, grad_v2.x, grad_v2.y);
                addDeriv(J, row, num_cols, free_mapping, eq.p3, -grad_v2.x, -grad_v2.y);
            },
            .tangent_line_circle => {
                // Line is A (p1) to B (p2), circle center is C (p3)
                const A = Vec2.init(points[eq.p1].x, points[eq.p1].y);
                const B = Vec2.init(points[eq.p2].x, points[eq.p2].y);
                const C = Vec2.init(points[eq.p3].x, points[eq.p3].y);
                const v = B.sub(A);
                const L = @max(v.norm(), EPS);
                const L2 = L * L;
                const N = (C.x - A.x) * v.y - (C.y - A.y) * v.x;

                // Deriv w.r.t C (p3)
                const dC_x = v.y / L;
                const dC_y = -v.x / L;
                addDeriv(J, row, num_cols, free_mapping, eq.p3, dC_x, dC_y);

                // Deriv w.r.t A (p1)
                const dN_Ax = C.y - B.y;
                const dN_Ay = B.x - C.x;
                const dL_Ax = -v.x / L;
                const dL_Ay = -v.y / L;
                const dA_x = (dN_Ax * L - N * dL_Ax) / L2;
                const dA_y = (dN_Ay * L - N * dL_Ay) / L2;
                addDeriv(J, row, num_cols, free_mapping, eq.p1, dA_x, dA_y);

                // Deriv w.r.t B (p2)
                const dN_Bx = -(C.y - A.y);
                const dN_By = C.x - A.x;
                const dL_Bx = v.x / L;
                const dL_By = v.y / L;
                const dB_x = (dN_Bx * L - N * dL_Bx) / L2;
                const dB_y = (dN_By * L - N * dL_By) / L2;
                addDeriv(J, row, num_cols, free_mapping, eq.p2, dB_x, dB_y);
            },
            .symmetric_midpoint => {
                const P1 = Vec2.init(points[eq.p1].x, points[eq.p1].y);
                const P2 = Vec2.init(points[eq.p2].x, points[eq.p2].y);
                const A = Vec2.init(points[eq.p3].x, points[eq.p3].y);
                const B = Vec2.init(points[eq.p4].x, points[eq.p4].y);
                const M = P1.add(P2).scale(0.5);
                const v = B.sub(A);
                const L = @max(v.norm(), EPS);
                const L2 = L * L;
                const N = (M.x - A.x) * v.y - (M.y - A.y) * v.x;

                // Deriv w.r.t M: (v.y / L, -v.x / L)
                // Since M = 0.5 * P1 + 0.5 * P2:
                const dM_x = (v.y / L) * 0.5;
                const dM_y = (-v.x / L) * 0.5;
                addDeriv(J, row, num_cols, free_mapping, eq.p1, dM_x, dM_y);
                addDeriv(J, row, num_cols, free_mapping, eq.p2, dM_x, dM_y);

                // Deriv w.r.t A (p3)
                const dN_Ax = M.y - B.y;
                const dN_Ay = B.x - M.x;
                const dL_Ax = -v.x / L;
                const dL_Ay = -v.y / L;
                const dA_x = (dN_Ax * L - N * dL_Ax) / L2;
                const dA_y = (dN_Ay * L - N * dL_Ay) / L2;
                addDeriv(J, row, num_cols, free_mapping, eq.p3, dA_x, dA_y);

                // Deriv w.r.t B (p4)
                const dN_Bx = -(M.y - A.y);
                const dN_By = M.x - A.x;
                const dL_Bx = v.x / L;
                const dL_By = v.y / L;
                const dB_x = (dN_Bx * L - N * dL_Bx) / L2;
                const dB_y = (dN_By * L - N * dL_By) / L2;
                addDeriv(J, row, num_cols, free_mapping, eq.p4, dB_x, dB_y);
            },
            .symmetric_perp => {
                const P1 = Vec2.init(points[eq.p1].x, points[eq.p1].y);
                const P2 = Vec2.init(points[eq.p2].x, points[eq.p2].y);
                const A = Vec2.init(points[eq.p3].x, points[eq.p3].y);
                const B = Vec2.init(points[eq.p4].x, points[eq.p4].y);
                const seg = P2.sub(P1);
                const axis = B.sub(A);
                const L = @max(axis.norm(), EPS);
                const L2 = L * L;
                const N = seg.dot(axis);

                // Deriv w.r.t P2: axis / L
                addDeriv(J, row, num_cols, free_mapping, eq.p2, axis.x / L, axis.y / L);
                // Deriv w.r.t P1: -axis / L
                addDeriv(J, row, num_cols, free_mapping, eq.p1, -axis.x / L, -axis.y / L);

                // Deriv w.r.t B: (seg * L - N * (axis / L)) / L2
                const dB_x = (seg.x * L - N * (axis.x / L)) / L2;
                const dB_y = (seg.y * L - N * (axis.y / L)) / L2;
                addDeriv(J, row, num_cols, free_mapping, eq.p4, dB_x, dB_y);
                addDeriv(J, row, num_cols, free_mapping, eq.p3, -dB_x, -dB_y);
            },
        }
    }
}

test "Jacobian analytical vs numerical finite differences" {
    var pts = [_]types.CadSketchPoint2D{
        .{ .id = 1, .x = 1.0, .y = 2.0, .is_fixed = 0 },
        .{ .id = 2, .x = 5.0, .y = 8.0, .is_fixed = 0 },
        .{ .id = 3, .x = 3.0, .y = 10.0, .is_fixed = 0 },
        .{ .id = 4, .x = 7.0, .y = 4.0, .is_fixed = 0 },
    };

    var free_map = try types.FreeVarMapping.init(std.testing.allocator, &pts);
    defer std.testing.allocator.free(free_map.point_to_free);
    defer std.testing.allocator.free(free_map.free_to_point);

    const test_eqs = [_]residuals.Equation{
        .{ .constraint_id = 1, .kind = .distance_pt_pt, .p1 = 0, .p2 = 1, .param = 5.0 },
        .{ .constraint_id = 2, .kind = .horizontal, .p1 = 0, .p2 = 1 },
        .{ .constraint_id = 3, .kind = .vertical, .p1 = 2, .p2 = 3 },
        .{ .constraint_id = 4, .kind = .parallel, .p1 = 0, .p2 = 1, .p3 = 2, .p4 = 3 },
        .{ .constraint_id = 5, .kind = .perpendicular, .p1 = 0, .p2 = 1, .p3 = 2, .p4 = 3 },
        .{ .constraint_id = 6, .kind = .equal_length, .p1 = 0, .p2 = 1, .p3 = 2, .p4 = 3 },
        .{ .constraint_id = 7, .kind = .angle, .p1 = 0, .p2 = 1, .p3 = 2, .p4 = 3, .param = 0.785 },
        .{ .constraint_id = 8, .kind = .point_on_line, .p1 = 0, .p2 = 2, .p3 = 3 },
        .{ .constraint_id = 9, .kind = .tangent_line_circle, .p1 = 2, .p2 = 3, .p3 = 0, .param = 2.0, .aux = 1.0 },
        .{ .constraint_id = 10, .kind = .symmetric_midpoint, .p1 = 0, .p2 = 1, .p3 = 2, .p4 = 3 },
        .{ .constraint_id = 11, .kind = .symmetric_perp, .p1 = 0, .p2 = 1, .p3 = 2, .p4 = 3 },
    };

    const M = test_eqs.len;
    const N = free_map.num_free_vars;
    const J = try std.testing.allocator.alloc(f64, M * N);
    defer std.testing.allocator.free(J);

    evalJacobian(&test_eqs, &pts, &free_map, J, M, N);

    // Finite difference check
    const delta: f64 = 1e-7;
    for (0..N) |col| {
        const pt_idx = free_map.free_to_point[col / 2];
        const is_y = (col % 2) == 1;

        const orig = if (is_y) pts[pt_idx].y else pts[pt_idx].x;

        if (is_y) {
            pts[pt_idx].y = orig + delta;
        } else {
            pts[pt_idx].x = orig + delta;
        }

        var f_plus: [test_eqs.len]f64 = undefined;
        for (test_eqs, 0..) |eq, row| {
            f_plus[row] = residuals.evalResidual(eq, &pts);
        }

        if (is_y) {
            pts[pt_idx].y = orig - delta;
        } else {
            pts[pt_idx].x = orig - delta;
        }

        var f_minus: [test_eqs.len]f64 = undefined;
        for (test_eqs, 0..) |eq, row| {
            f_minus[row] = residuals.evalResidual(eq, &pts);
        }

        // Restore
        if (is_y) {
            pts[pt_idx].y = orig;
        } else {
            pts[pt_idx].x = orig;
        }

        for (0..M) |row| {
            const num_deriv = (f_plus[row] - f_minus[row]) / (2.0 * delta);
            const ana_deriv = J[row * N + col];
            try std.testing.expectApproxEqAbs(num_deriv, ana_deriv, 1e-5);
        }
    }
}
