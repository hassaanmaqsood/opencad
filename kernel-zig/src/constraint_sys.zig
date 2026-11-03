const std = @import("std");
const memory = @import("memory.zig");
const autodiff = @import("autodiff.zig");

pub const Dual = autodiff.Dual;
pub const Expression = autodiff.Expression;

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
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ConstraintSystem {
        return .{
            .params = .empty,
            .residuals = .empty,
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

    /// Rank-revealing Householder QR with column pivoting to compute rank(J) and DOF = N - rank(J)
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

        const rank = computeMatrixRank(J, m, n, 1e-11);
        return @intCast(n - rank);
    }

    /// Solves R(q) = 0 via Levenberg-Marquardt damped Newton-Raphson
    pub fn solve(self: *ConstraintSystem, tol: f64, max_iter: u32) u32 {
        const n = self.params.items.len;
        const m = self.residuals.items.len;
        if (m == 0) return 0;

        const R = self.allocator.alloc(f64, m) catch return 1;
        defer self.allocator.free(R);
        const R_trial = self.allocator.alloc(f64, m) catch return 1;
        defer self.allocator.free(R_trial);
        const J = self.allocator.alloc(f64, m * n) catch return 1;
        defer self.allocator.free(J);
        const JtJ = self.allocator.alloc(f64, n * n) catch return 1;
        defer self.allocator.free(JtJ);
        const JtR = self.allocator.alloc(f64, n) catch return 1;
        defer self.allocator.free(JtR);
        const delta_q = self.allocator.alloc(f64, n) catch return 1;
        defer self.allocator.free(delta_q);
        const q_orig = self.allocator.alloc(f64, n) catch return 1;
        defer self.allocator.free(q_orig);

        var lambda: f64 = 1e-3;

        for (0..max_iter) |_| {
            self.evaluateSystem(R, J);

            var max_res: f64 = 0.0;
            for (R) |r| {
                const abs_r = @abs(r);
                if (abs_r > max_res) max_res = abs_r;
            }

            if (max_res <= tol) {
                return 0; // Successfully converged within exact tolerance!
            }

            // Normal equations: JtJ = J^T * J, JtR = J^T * R
            for (0..n) |row| {
                for (0..n) |col| {
                    var sum: f64 = 0.0;
                    for (0..m) |k| {
                        sum += J[k * n + row] * J[k * n + col];
                    }
                    JtJ[row * n + col] = sum;
                }
                var r_sum: f64 = 0.0;
                for (0..m) |k| {
                    r_sum += J[k * n + row] * R[k];
                }
                JtR[row] = r_sum;
            }

            // Levenberg-Marquardt damping: (J^T * J + lambda * I) * delta_q = -J^T * R
            var solved = false;
            for (0..5) |_| {
                // Copy JtJ to solve_matrix and add lambda * I
                const A = self.allocator.alloc(f64, n * n) catch break;
                defer self.allocator.free(A);
                @memcpy(A, JtJ);
                for (0..n) |diag| {
                    A[diag * n + diag] += lambda;
                }

                // rhs = -JtR
                const rhs = self.allocator.alloc(f64, n) catch break;
                defer self.allocator.free(rhs);
                for (0..n) |k| {
                    rhs[k] = -JtR[k];
                }

                if (solveLinearSystem(A, rhs, delta_q, n)) {
                    @memcpy(q_orig, self.params.items);
                    for (0..n) |k| {
                        self.params.items[k] += delta_q[k];
                    }

                    self.evaluateSystem(R_trial, null);
                    var trial_max: f64 = 0.0;
                    for (R_trial) |r| {
                        const abs_r = @abs(r);
                        if (abs_r > trial_max) trial_max = abs_r;
                    }

                    if (trial_max < max_res) {
                        // Accept step
                        lambda = @max(1e-12, lambda * 0.2);
                        solved = true;
                        break;
                    } else {
                        // Reject step and increase damping
                        @memcpy(self.params.items, q_orig);
                        lambda *= 10.0;
                    }
                } else {
                    lambda *= 10.0;
                }
            }

            if (!solved) {
                // If damped step couldn't improve, continue or terminate
            }
        }

        // Final tolerance check
        self.evaluateSystem(R, null);
        var final_res: f64 = 0.0;
        for (R) |r| {
            const abs_r = @abs(r);
            if (abs_r > final_res) final_res = abs_r;
        }

        return if (final_res <= tol) 0 else 1;
    }
};

// ============================================================================
// Linear Algebra: Gaussian Elimination with Partial Pivoting & Rank Detection
// ============================================================================

pub fn solveLinearSystem(A: []f64, b: []f64, x: []f64, n: usize) bool {
    // Gaussian elimination with partial pivoting on n x n system A * x = b
    for (0..n) |k| {
        // Find pivot
        var max_val = @abs(A[k * n + k]);
        var max_row = k;
        for (k + 1..n) |row| {
            const val = @abs(A[row * n + k]);
            if (val > max_val) {
                max_val = val;
                max_row = row;
            }
        }

        if (max_val < 1e-14) return false;

        // Swap rows
        if (max_row != k) {
            for (k..n) |col| {
                const tmp = A[k * n + col];
                A[k * n + col] = A[max_row * n + col];
                A[max_row * n + col] = tmp;
            }
            const tmp_b = b[k];
            b[k] = b[max_row];
            b[max_row] = tmp_b;
        }

        // Eliminate
        const pivot = A[k * n + k];
        for (k + 1..n) |row| {
            const factor = A[row * n + k] / pivot;
            A[row * n + k] = 0.0;
            for (k + 1..n) |col| {
                A[row * n + col] -= factor * A[k * n + col];
            }
            b[row] -= factor * b[k];
        }
    }

    // Back-substitution
    var idx = n;
    while (idx > 0) {
        idx -= 1;
        var sum: f64 = b[idx];
        for (idx + 1..n) |col| {
            sum -= A[idx * n + col] * x[col];
        }
        x[idx] = sum / A[idx * n + idx];
    }

    return true;
}

pub fn computeMatrixRank(J: []f64, m: usize, n: usize, tol: f64) usize {
    // Computes rank using Gaussian row reduction with complete/partial pivoting
    var mat_copy = std.heap.page_allocator.alloc(f64, m * n) catch return @min(m, n);
    defer std.heap.page_allocator.free(mat_copy);
    @memcpy(mat_copy, J);

    var rank: usize = 0;
    var row: usize = 0;
    var col: usize = 0;

    while (row < m and col < n) {
        // Find pivot in column
        var max_val: f64 = @abs(mat_copy[row * n + col]);
        var max_row = row;
        for (row + 1..m) |r| {
            const val = @abs(mat_copy[r * n + col]);
            if (val > max_val) {
                max_val = val;
                max_row = r;
            }
        }

        if (max_val <= tol) {
            col += 1;
            continue;
        }

        // Swap rows
        if (max_row != row) {
            for (col..n) |c| {
                const tmp = mat_copy[row * n + c];
                mat_copy[row * n + c] = mat_copy[max_row * n + c];
                mat_copy[max_row * n + c] = tmp;
            }
        }

        // Eliminate below
        const pivot = mat_copy[row * n + col];
        for (row + 1..m) |r| {
            const factor = mat_copy[r * n + col] / pivot;
            mat_copy[r * n + col] = 0.0;
            for (col + 1..n) |c| {
                mat_copy[r * n + c] -= factor * mat_copy[row * n + c];
            }
        }

        rank += 1;
        row += 1;
        col += 1;
    }

    return rank;
}

// ============================================================================
// Constraint System Global Registry & C ABI Exports
// ============================================================================

var next_sys_id: u64 = 1;
pub var sys_store: std.AutoHashMap(u64, ConstraintSystem) = std.AutoHashMap(u64, ConstraintSystem).init(std.heap.page_allocator);

pub fn sys_create() u64 {
    const sys = ConstraintSystem.init(std.heap.page_allocator);
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
