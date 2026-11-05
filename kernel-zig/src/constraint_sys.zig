const std = @import("std");
const memory = @import("memory.zig");
const autodiff = @import("autodiff.zig");

pub const Dual = autodiff.Dual;
pub const Expression = autodiff.Expression;

// ============================================================================
// CDML §6.2 Solver & DOF Classification States
// ============================================================================

pub const SolveState = enum(u32) {
    Solved = 0, // ||R(q)||_inf <= eps_lin and DOF == 0 (M == r == N)
    Under = 1, // ||R(q)||_inf <= eps_lin and DOF > 0
    Over = 2, // ||R(q)||_inf <= eps_lin and M > r (consistent dependent rows)
    Conflicting = 3, // ||R(q)||_inf > eps_lin with non-zero left-nullspace projection ||(Q^T R)[r..M]||_inf > eps_lin
    Diverged = 4, // Exceeded max_iter without converging
};

// ============================================================================
// Residual Equation Definition
// ============================================================================

pub const Residual = struct {
    expr_handle: u64,
    param_indices: []u32,
};

// ============================================================================
// Constraint System
// ============================================================================

pub const ConstraintSystem = struct {
    params: std.ArrayList(f64) = .empty,
    residuals: std.ArrayList(Residual) = .empty,
    last_state: SolveState = .Solved,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ConstraintSystem {
        return .{
            .params = .empty,
            .residuals = .empty,
            .last_state = .Solved,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ConstraintSystem) void {
        for (self.residuals.items) |r| {
            self.allocator.free(r.param_indices);
        }
        self.residuals.deinit(self.allocator);
        self.params.deinit(self.allocator);
    }

    pub fn allocParams(self: *ConstraintSystem, init_vals: []const f64) !u32 {
        const start_idx: u32 = @intCast(self.params.items.len);
        try self.params.appendSlice(self.allocator, init_vals);
        return start_idx;
    }

    pub fn addResidual(self: *ConstraintSystem, expr_h: u64, param_indices: []const u32) !u32 {
        const idx_copy = try self.allocator.dupe(u32, param_indices);
        const res_idx: u32 = @intCast(self.residuals.items.len);
        try self.residuals.append(self.allocator, .{
            .expr_handle = expr_h,
            .param_indices = idx_copy,
        });
        return res_idx;
    }

    /// Evaluates all residuals and assembles the exact analytical Jacobian J_ij = dR_i / dq_j
    pub fn evaluateSystem(
        self: *const ConstraintSystem,
        out_residuals: []f64,
        out_jacobian: ?[]f64, // Row-major: M rows, N cols
    ) void {
        const n_params = self.params.items.len;
        const q = self.params.items;

        if (out_jacobian) |J| {
            @memset(J, 0.0);
        }

        var local_vars: [64]f64 = undefined;
        var local_grad: [64]f64 = undefined;

        for (self.residuals.items, 0..) |res, i| {
            const k = res.param_indices.len;
            for (0..k) |l| {
                const p_idx = res.param_indices[l];
                local_vars[l] = if (p_idx < n_params) q[p_idx] else 0.0;
            }

            if (out_jacobian) |J| {
                const r_val = autodiff.expr_eval(res.expr_handle, local_vars[0..k].ptr, @intCast(k), local_grad[0..k].ptr);
                out_residuals[i] = r_val;
                for (0..k) |l| {
                    const p_idx = res.param_indices[l];
                    if (p_idx < n_params) {
                        J[i * n_params + p_idx] += local_grad[l];
                    }
                }
            } else {
                const r_val = autodiff.expr_eval(res.expr_handle, local_vars[0..k].ptr, @intCast(k), null);
                out_residuals[i] = r_val;
            }
        }
    }

    /// Rank-revealing Householder QR with column pivoting (J * P = Q * R) to compute rank(J) and DOF = N - rank(J) (§6.2)
    pub fn getDof(self: *const ConstraintSystem) i32 {
        const n = self.params.items.len;
        const m = self.residuals.items.len;
        if (n == 0) return 0;
        if (m == 0) return @intCast(n);

        const residuals = self.allocator.alloc(f64, m) catch return @intCast(n);
        defer self.allocator.free(residuals);
        const J = self.allocator.alloc(f64, m * n) catch return @intCast(n);
        defer self.allocator.free(J);

        self.evaluateSystem(residuals, J);

        const rank = computeMatrixRank(J, m, n, 1e-10);
        return @intCast(n - rank);
    }

    /// Classifies the current state of the constraint system into SOLVED, UNDER, OVER, or CONFLICTING (CDML §6.2)
    pub fn classifyState(self: *const ConstraintSystem, tol: f64) SolveState {
        const n = self.params.items.len;
        const m = self.residuals.items.len;
        if (m == 0) {
            return if (n == 0) .Solved else .Under;
        }
        if (n == 0) return .Solved;

        const R_vec = self.allocator.alloc(f64, m) catch return .Diverged;
        defer self.allocator.free(R_vec);
        const J = self.allocator.alloc(f64, m * n) catch return .Diverged;
        defer self.allocator.free(J);
        const piv = self.allocator.alloc(usize, n) catch return .Diverged;
        defer self.allocator.free(piv);

        self.evaluateSystem(R_vec, J);

        var max_res: f64 = 0.0;
        for (R_vec) |r| {
            const abs_r = @abs(r);
            if (abs_r > max_res) max_res = abs_r;
        }

        const QtR = self.allocator.alloc(f64, m) catch return .Diverged;
        defer self.allocator.free(QtR);
        @memcpy(QtR, R_vec);

        const rank = householderQrPivot(J, QtR, piv, m, n, 1e-10);
        const dof = n - rank;

        if (max_res <= tol) {
            if (m > rank) return .Over;
            if (dof > 0) return .Under;
            return .Solved;
        }

        // Check left-nullspace projection ||(Q^T R)[r..M]||_inf > tol (§6.2)
        var nullspace_norm: f64 = 0.0;
        if (m > rank) {
            for (rank..m) |i| {
                const v = @abs(QtR[i]);
                if (v > nullspace_norm) nullspace_norm = v;
            }
        }
        if (nullspace_norm > tol) {
            return .Conflicting;
        }

        return .Diverged;
    }

    /// Computes 25% of the current parameter bounding box span for homotopy sub-stepping (CDML §13.2 Case 1)
    fn computeMaxHomotopyStep(self: *const ConstraintSystem) f64 {
        const q = self.params.items;
        if (q.len == 0) return 1.0;
        var q_min: f64 = q[0];
        var q_max: f64 = q[0];
        for (q) |v| {
            if (v < q_min) q_min = v;
            if (v > q_max) q_max = v;
        }
        const span = @max(1.0, q_max - q_min);
        return 0.25 * span;
    }

    /// Solves R(q) = 0 via Rank-Revealing Householder QR + Levenberg-Marquardt with Homotopy Sub-Stepping (§6.2 & §13.2 Case 1)
    pub fn solve(self: *ConstraintSystem, tol: f64, max_iter: u32) u32 {
        const n = self.params.items.len;
        const m = self.residuals.items.len;
        if (m == 0) {
            self.last_state = if (n == 0) .Solved else .Under;
            return 0;
        }
        if (n == 0) {
            self.last_state = .Solved;
            return 0;
        }

        const R = self.allocator.alloc(f64, m) catch return 1;
        defer self.allocator.free(R);
        const R_trial = self.allocator.alloc(f64, m) catch return 1;
        defer self.allocator.free(R_trial);
        const J = self.allocator.alloc(f64, m * n) catch return 1;
        defer self.allocator.free(J);
        const delta_q = self.allocator.alloc(f64, n) catch return 1;
        defer self.allocator.free(delta_q);
        const q_orig = self.allocator.alloc(f64, n) catch return 1;
        defer self.allocator.free(q_orig);

        var lambda: f64 = 1e-4;

        for (0..max_iter) |_| {
            self.evaluateSystem(R, J);

            var max_res: f64 = 0.0;
            for (R) |r| {
                const abs_r = @abs(r);
                if (abs_r > max_res) max_res = abs_r;
            }

            if (max_res <= tol) {
                self.last_state = self.classifyState(tol);
                return 0;
            }

            const max_step_limit = self.computeMaxHomotopyStep();
            var step_accepted = false;

            // First try direct minimum-norm Householder QR step (J * P * dq_piv = -R)
            if (solveLeastSquaresHouseholderQr(self.allocator, J, R, delta_q, m, n, 1e-10)) {
                // Homotopy continuation sub-stepping when ||delta_q||_inf > 25% of bounding box (§13.2 Case 1)
                var max_dq: f64 = 0.0;
                for (delta_q) |dq| {
                    if (@abs(dq) > max_dq) max_dq = @abs(dq);
                }
                const scale = if (max_dq > max_step_limit and max_dq > 0.0) max_step_limit / max_dq else 1.0;

                @memcpy(q_orig, self.params.items);
                for (0..n) |k| {
                    self.params.items[k] += scale * delta_q[k];
                }

                self.evaluateSystem(R_trial, null);
                var trial_max: f64 = 0.0;
                for (R_trial) |r| {
                    if (@abs(r) > trial_max) trial_max = @abs(r);
                }

                if (trial_max < max_res and !std.math.isNan(trial_max)) {
                    lambda = @max(1e-12, lambda * 0.2);
                    step_accepted = true;
                } else {
                    @memcpy(self.params.items, q_orig);
                }
            }

            // Fallback: Damped Levenberg-Marquardt step solved via Householder QR
            if (!step_accepted) {
                for (0..6) |_| {
                    if (solveDampedQrStep(self.allocator, J, R, delta_q, m, n, lambda)) {
                        var max_dq: f64 = 0.0;
                        for (delta_q) |dq| {
                            if (@abs(dq) > max_dq) max_dq = @abs(dq);
                        }
                        const scale = if (max_dq > max_step_limit and max_dq > 0.0) max_step_limit / max_dq else 1.0;

                        @memcpy(q_orig, self.params.items);
                        for (0..n) |k| {
                            self.params.items[k] += scale * delta_q[k];
                        }

                        self.evaluateSystem(R_trial, null);
                        var trial_max: f64 = 0.0;
                        for (R_trial) |r| {
                            if (@abs(r) > trial_max) trial_max = @abs(r);
                        }

                        if (trial_max < max_res and !std.math.isNan(trial_max)) {
                            lambda = @max(1e-12, lambda * 0.2);
                            step_accepted = true;
                            break;
                        } else {
                            @memcpy(self.params.items, q_orig);
                            lambda *= 10.0;
                        }
                    } else {
                        lambda *= 10.0;
                    }
                }
            }

            if (!step_accepted) {
                break;
            }
        }

        // Final evaluation and state classification
        self.last_state = self.classifyState(tol);
        return switch (self.last_state) {
            .Solved, .Under, .Over => 0,
            .Conflicting => 3,
            .Diverged => 4,
        };
    }
};

// ============================================================================
// Linear Algebra: Householder QR with Column Pivoting (J * P = Q * R, §6.2)
// ============================================================================

/// In-place Householder QR decomposition with column pivoting: J * P = Q * R.
/// - `mat`: m x n row-major matrix, overwritten with upper-triangular R.
/// - `rhs`: optional length-m vector b, overwritten with Q^T * b.
/// - `piv`: length-n permutation slice, overwritten with column pivot indices.
/// Returns numerical rank r = count(|R_ii| > eps_rank).
pub fn householderQrPivot(
    mat: []f64,
    rhs: ?[]f64,
    piv: []usize,
    m: usize,
    n: usize,
    eps_rank: f64,
) usize {
    for (0..n) |j| {
        piv[j] = j;
    }

    const min_mn = @min(m, n);
    var rank: usize = 0;

    for (0..min_mn) |k| {
        // 1. Find column p in k..n with largest Euclidean 2-norm over rows k..m
        var max_norm_sq: f64 = -1.0;
        var best_col: usize = k;
        for (k..n) |j| {
            var sum_sq: f64 = 0.0;
            for (k..m) |i| {
                const v = mat[i * n + j];
                sum_sq += v * v;
            }
            if (sum_sq > max_norm_sq) {
                max_norm_sq = sum_sq;
                best_col = j;
            }
        }

        // 2. Pivot column best_col to position k
        if (best_col != k) {
            for (0..m) |i| {
                const tmp = mat[i * n + k];
                mat[i * n + k] = mat[i * n + best_col];
                mat[i * n + best_col] = tmp;
            }
            const tmp_p = piv[k];
            piv[k] = piv[best_col];
            piv[best_col] = tmp_p;
        }

        const alpha = @sqrt(@max(0.0, max_norm_sq));
        if (alpha <= eps_rank) {
            break;
        }

        // 3. Construct Householder reflector H_k = I - 2 * (v * v^T) / (v^T * v)
        const x0 = mat[k * n + k];
        const s = if (x0 >= 0.0) -alpha else alpha;
        const v0 = x0 - s;

        // Norm squared of v = [v0, mat[k+1, k], ..., mat[m-1, k]]^T
        var v_norm_sq: f64 = v0 * v0;
        for (k + 1..m) |i| {
            const vi = mat[i * n + k];
            v_norm_sq += vi * vi;
        }

        if (v_norm_sq > 1e-30) {
            const beta = 2.0 / v_norm_sq;

            // Apply H_k to remaining columns k+1..n
            for (k + 1..n) |j| {
                var dot: f64 = v0 * mat[k * n + j];
                for (k + 1..m) |i| {
                    dot += mat[i * n + k] * mat[i * n + j];
                }
                const w = beta * dot;
                mat[k * n + j] -= w * v0;
                for (k + 1..m) |i| {
                    mat[i * n + j] -= w * mat[i * n + k];
                }
            }

            // Apply H_k to rhs vector if present (rhs <- H_k * rhs)
            if (rhs) |b| {
                var dot_b: f64 = v0 * b[k];
                for (k + 1..m) |i| {
                    dot_b += mat[i * n + k] * b[i];
                }
                const wb = beta * dot_b;
                b[k] -= wb * v0;
                for (k + 1..m) |i| {
                    b[i] -= wb * mat[i * n + k];
                }
            }
        }

        // Set diagonal R[k,k] = s and zero sub-diagonal entries
        mat[k * n + k] = s;
        for (k + 1..m) |i| {
            mat[i * n + k] = 0.0;
        }

        if (@abs(s) > eps_rank) {
            rank += 1;
        }
    }

    return rank;
}

/// Solves minimum-norm / basic QR system J * delta_q = -R using Householder QR with column pivoting
pub fn solveLeastSquaresHouseholderQr(
    allocator: std.mem.Allocator,
    J: []const f64,
    R_vec: []const f64,
    delta_q: []f64,
    m: usize,
    n: usize,
    eps_rank: f64,
) bool {
    const mat_R = allocator.alloc(f64, m * n) catch return false;
    defer allocator.free(mat_R);
    @memcpy(mat_R, J);

    const rhs = allocator.alloc(f64, m) catch return false;
    defer allocator.free(rhs);
    for (0..m) |i| {
        rhs[i] = -R_vec[i];
    }

    const piv = allocator.alloc(usize, n) catch return false;
    defer allocator.free(piv);

    const rank = householderQrPivot(mat_R, rhs, piv, m, n, eps_rank);
    if (rank == 0) return false;

    const y_piv = allocator.alloc(f64, n) catch return false;
    defer allocator.free(y_piv);
    @memset(y_piv, 0.0);

    // Back-substitution on upper-triangular R_11 (rank x rank)
    var idx = rank;
    while (idx > 0) {
        idx -= 1;
        var sum = rhs[idx];
        for (idx + 1..rank) |col| {
            sum -= mat_R[idx * n + col] * y_piv[col];
        }
        const diag = mat_R[idx * n + idx];
        if (@abs(diag) <= eps_rank) return false;
        y_piv[idx] = sum / diag;
    }

    // Un-permute into delta_q
    @memset(delta_q, 0.0);
    for (0..n) |j| {
        delta_q[piv[j]] = y_piv[j];
    }
    return true;
}

/// Solves damped Levenberg-Marquardt system [J; sqrt(lambda)*I] * delta_q = [-R; 0] via Householder QR
pub fn solveDampedQrStep(
    allocator: std.mem.Allocator,
    J: []const f64,
    R_vec: []const f64,
    delta_q: []f64,
    m: usize,
    n: usize,
    lambda: f64,
) bool {
    const m_aug = m + n;
    const mat_aug = allocator.alloc(f64, m_aug * n) catch return false;
    defer allocator.free(mat_aug);
    @memset(mat_aug, 0.0);
    @memcpy(mat_aug[0 .. m * n], J);

    const sqrt_lam = @sqrt(@max(1e-15, lambda));
    for (0..n) |j| {
        mat_aug[(m + j) * n + j] = sqrt_lam;
    }

    const rhs_aug = allocator.alloc(f64, m_aug) catch return false;
    defer allocator.free(rhs_aug);
    @memset(rhs_aug, 0.0);
    for (0..m) |i| {
        rhs_aug[i] = -R_vec[i];
    }

    const piv = allocator.alloc(usize, n) catch return false;
    defer allocator.free(piv);

    const rank = householderQrPivot(mat_aug, rhs_aug, piv, m_aug, n, 1e-12);
    if (rank == 0) return false;

    const y_piv = allocator.alloc(f64, n) catch return false;
    defer allocator.free(y_piv);
    @memset(y_piv, 0.0);

    var idx = rank;
    while (idx > 0) {
        idx -= 1;
        var sum = rhs_aug[idx];
        for (idx + 1..rank) |col| {
            sum -= mat_aug[idx * n + col] * y_piv[col];
        }
        const diag = mat_aug[idx * n + idx];
        if (@abs(diag) <= 1e-14) return false;
        y_piv[idx] = sum / diag;
    }

    @memset(delta_q, 0.0);
    for (0..n) |j| {
        delta_q[piv[j]] = y_piv[j];
    }
    return true;
}

/// Solves an n x n linear system A * x = b using Householder QR with column pivoting
pub fn solveLinearSystem(A: []f64, b: []f64, x: []f64, n: usize) bool {
    var stack_piv: [64]usize = undefined;
    var stack_y: [64]f64 = undefined;
    if (n <= 64) {
        const piv = stack_piv[0..n];
        const rank = householderQrPivot(A, b, piv, n, n, 1e-12);
        if (rank < n) return false;

        const y_piv = stack_y[0..n];
        var idx = n;
        while (idx > 0) {
            idx -= 1;
            var sum: f64 = b[idx];
            for (idx + 1..n) |col| {
                sum -= A[idx * n + col] * y_piv[col];
            }
            y_piv[idx] = sum / A[idx * n + idx];
        }

        for (0..n) |j| {
            x[piv[j]] = y_piv[j];
        }
        return true;
    }

    const alloc = memory.persistent_allocator;
    const piv = alloc.alloc(usize, n) catch return false;
    defer alloc.free(piv);

    const rank = householderQrPivot(A, b, piv, n, n, 1e-12);
    if (rank < n) return false;

    const y_piv = alloc.alloc(f64, n) catch return false;
    defer alloc.free(y_piv);

    var idx = n;
    while (idx > 0) {
        idx -= 1;
        var sum: f64 = b[idx];
        for (idx + 1..n) |col| {
            sum -= A[idx * n + col] * y_piv[col];
        }
        y_piv[idx] = sum / A[idx * n + idx];
    }

    for (0..n) |j| {
        x[piv[j]] = y_piv[j];
    }
    return true;
}

/// Computes numerical rank r of an m x n matrix J using Rank-Revealing Householder QR with column pivoting
pub fn computeMatrixRank(J: []const f64, m: usize, n: usize, tol: f64) usize {
    if (m == 0 or n == 0) return 0;
    const alloc = memory.persistent_allocator;
    const mat_copy = alloc.alloc(f64, m * n) catch return @min(m, n);
    defer alloc.free(mat_copy);
    @memcpy(mat_copy, J);

    const piv = alloc.alloc(usize, n) catch return @min(m, n);
    defer alloc.free(piv);

    return householderQrPivot(mat_copy, null, piv, m, n, tol);
}

// ============================================================================
// Constraint System Global Registry & C ABI Exports
// ============================================================================

var next_sys_id: u64 = 1;
pub var sys_store: std.AutoHashMap(u64, ConstraintSystem) = std.AutoHashMap(u64, ConstraintSystem).init(memory.persistent_allocator);

pub fn sys_create() u64 {
    const sys = ConstraintSystem.init(memory.persistent_allocator);
    // Rule 4: bits [63:62] == 0b11 for Constraint Systems
    const handle: u64 = (@as(u64, 0b11) << 62) | next_sys_id;
    next_sys_id += 1;

    sys_store.put(handle, sys) catch return 0;
    return handle;
}

pub fn sys_alloc_params(sys_h: u64, init_ptr: [*]const f64, count: u32) u32 {
    const sys = sys_store.getPtr(sys_h) orelse return 0;
    const vals = init_ptr[0..count];
    return sys.allocParams(vals) catch 0;
}

pub fn sys_add_residual(sys_h: u64, expr_h: u64, param_idx_ptr: [*]const u32, count: u32) u32 {
    const sys = sys_store.getPtr(sys_h) orelse return 0;
    const indices = param_idx_ptr[0..count];
    return sys.addResidual(expr_h, indices) catch 0;
}

pub fn sys_solve(sys_h: u64, tol: f64, max_iter: u32) u32 {
    const sys = sys_store.getPtr(sys_h) orelse return 1;
    return sys.solve(tol, max_iter);
}

pub fn sys_get_dof(sys_h: u64) i32 {
    const sys = sys_store.getPtr(sys_h) orelse return 0;
    return sys.getDof();
}

pub fn sys_read_params(sys_h: u64, out_ptr: [*]f64, count: u32) void {
    const sys = sys_store.getPtr(sys_h) orelse return;
    const n = @min(count, @as(u32, @intCast(sys.params.items.len)));
    @memcpy(out_ptr[0..n], sys.params.items[0..n]);
}

pub fn sys_free(sys_h: u64) void {
    if (sys_store.fetchRemove(sys_h)) |kv| {
        var sys = kv.value;
        sys.deinit();
    }
}

test "Householder QR column pivoting, DOF rank analysis, and 4-state classification" {
    const alloc = std.testing.allocator;

    // 1. Rank-deficient 3x3 matrix where row 2 = row 0 + row 1 -> rank must be 2
    const J_dep = [_]f64{
        1.0, 2.0, 3.0,
        4.0, 5.0, 6.0,
        5.0, 7.0, 9.0,
    };
    const r = computeMatrixRank(&J_dep, 3, 3, 1e-10);
    try std.testing.expectEqual(@as(usize, 2), r);

    // 2. Constrained 2D square with +/-10 seeds solved to width 37.5 via vector residuals
    var sys = ConstraintSystem.init(alloc);
    defer sys.deinit();

    const seeds = [_]f64{
        -10.0, -10.0,
        10.0,  -10.0,
        10.0,  10.0,
        -10.0, 10.0,
    };
    _ = try sys.allocParams(&seeds);

    const e_cx = autodiff.expr_compile("v0.u + v1.u", 11);
    const e_cy = autodiff.expr_compile("v0.v + v3.v", 11);
    const e_sy = autodiff.expr_compile("v2.u + v3.u", 11);
    const e_h0 = autodiff.expr_compile("v1.v - v0.v", 11);
    const e_h1 = autodiff.expr_compile("v2.v - v3.v", 11);
    const e_ot = autodiff.expr_compile("dot(v1 - v0, v2 - v1)", 21);
    const e_we = autodiff.expr_compile("norm(v1 - v0) - 37.5", 20);
    const e_he = autodiff.expr_compile("norm(v2 - v1) - 37.5", 20);
    defer {
        autodiff.expr_free(e_cx);
        autodiff.expr_free(e_cy);
        autodiff.expr_free(e_sy);
        autodiff.expr_free(e_h0);
        autodiff.expr_free(e_h1);
        autodiff.expr_free(e_ot);
        autodiff.expr_free(e_we);
        autodiff.expr_free(e_he);
    }

    const all_idx = [_]u32{ 0, 1, 2, 3, 4, 5, 6, 7 };
    _ = try sys.addResidual(e_cx, &all_idx);
    _ = try sys.addResidual(e_cy, &all_idx);
    _ = try sys.addResidual(e_sy, &all_idx);
    _ = try sys.addResidual(e_h0, &all_idx);
    _ = try sys.addResidual(e_h1, &all_idx);
    _ = try sys.addResidual(e_ot, &all_idx);
    _ = try sys.addResidual(e_we, &all_idx);
    _ = try sys.addResidual(e_he, &all_idx);

    const status = sys.solve(1e-9, 100);
    try std.testing.expectEqual(@as(u32, 0), status);
    try std.testing.expectEqual(@as(i32, 0), sys.getDof());
    try std.testing.expectEqual(SolveState.Solved, sys.last_state);

    // Width = v1.u - v0.u = 18.75 - (-18.75) = 37.5
    try std.testing.expectApproxEqAbs(@as(f64, -18.75), sys.params.items[0], 1e-7);
    try std.testing.expectApproxEqAbs(@as(f64, -18.75), sys.params.items[1], 1e-7);
    try std.testing.expectApproxEqAbs(@as(f64, 18.75), sys.params.items[2], 1e-7);
    try std.testing.expectApproxEqAbs(@as(f64, 18.75), sys.params.items[5], 1e-7);

    // 3. Conflicting system detection (x0 - 5 = 0 and x0 - 10 = 0)
    var sys_conf = ConstraintSystem.init(alloc);
    defer sys_conf.deinit();
    _ = try sys_conf.allocParams(&[_]f64{0.0});
    const r1 = autodiff.expr_compile("x0 - 5.0", 8);
    const r2 = autodiff.expr_compile("x0 - 10.0", 9);
    defer {
        autodiff.expr_free(r1);
        autodiff.expr_free(r2);
    }
    _ = try sys_conf.addResidual(r1, &[_]u32{0});
    _ = try sys_conf.addResidual(r2, &[_]u32{0});
    const conf_status = sys_conf.solve(1e-7, 50);
    try std.testing.expectEqual(@as(u32, 3), conf_status);
    try std.testing.expectEqual(SolveState.Conflicting, sys_conf.last_state);
}
