const std = @import("std");
const Allocator = std.mem.Allocator;
const c_types = @import("c_types.zig");
const CadStatus = c_types.CadStatus;
const CadOptGoal = c_types.CadOptGoal;
const CadParamBound = c_types.CadParamBound;
const CadOptimizationResult = c_types.CadOptimizationResult;
const CadFeatureNode = c_types.CadFeatureNode;

pub const ParameterOptimizer = struct {
    allocator: Allocator,

    pub fn init(allocator: Allocator) ParameterOptimizer {
        return .{ .allocator = allocator };
    }

    pub fn optimize(
        self: ParameterOptimizer,
        nodes: []const CadFeatureNode,
        bounds: []const CadParamBound,
        goals: []const CadOptGoal,
        max_iterations: u32,
        tolerance: f64,
    ) !CadOptimizationResult {
        _ = nodes;
        const n_params = bounds.len;
        if (n_params == 0 or goals.len == 0) {
            return CadOptimizationResult{
                .status = .InvalidArguments,
                .iterations = 0,
                .final_objective = 0.0,
                .optimal_values = null,
                .param_count = 0,
            };
        }

        const optimal = try self.allocator.alloc(f64, n_params);
        for (bounds, 0..) |b, i| {
            optimal[i] = std.math.clamp(b.initial_value, b.min_value, b.max_value);
        }

        var iter: u32 = 0;
        var prev_obj: f64 = std.math.inf(f64);
        var current_obj: f64 = 0.0;
        const max_iter = if (max_iterations > 0) max_iterations else 50;
        const tol = if (tolerance > 0.0) tolerance else 1e-4;

        while (iter < max_iter) : (iter += 1) {
            current_obj = evaluateObjective(optimal, bounds, goals);

            if (@abs(prev_obj - current_obj) < tol) {
                break;
            }
            prev_obj = current_obj;

            // Compute numerical gradient via forward finite difference
            const step_size: f64 = 1e-4;
            const grad = try self.allocator.alloc(f64, n_params);
            defer self.allocator.free(grad);

            for (0..n_params) |i| {
                const orig = optimal[i];
                const delta = step_size * @max(1.0, @abs(orig));
                optimal[i] = orig + delta;
                const obj_plus = evaluateObjective(optimal, bounds, goals);
                optimal[i] = orig;
                grad[i] = (obj_plus - current_obj) / delta;
            }

            // Gradient descent step with backtracking / learning rate
            var alpha: f64 = 0.1;
            var best_cand_obj = current_obj;
            const best_cand = try self.allocator.alloc(f64, n_params);
            defer self.allocator.free(best_cand);
            @memcpy(best_cand, optimal);

            var line_step: usize = 0;
            while (line_step < 5) : (line_step += 1) {
                const test_cand = try self.allocator.alloc(f64, n_params);
                defer self.allocator.free(test_cand);
                for (0..n_params) |i| {
                    const next_val = optimal[i] - alpha * grad[i];
                    test_cand[i] = std.math.clamp(next_val, bounds[i].min_value, bounds[i].max_value);
                }
                const cand_obj = evaluateObjective(test_cand, bounds, goals);
                if (cand_obj < best_cand_obj) {
                    best_cand_obj = cand_obj;
                    @memcpy(best_cand, test_cand);
                    break;
                }
                alpha *= 0.5;
            }

            @memcpy(optimal, best_cand);
        }

        return CadOptimizationResult{
            .status = .Ok,
            .iterations = iter,
            .final_objective = current_obj,
            .optimal_values = optimal.ptr,
            .param_count = @intCast(n_params),
        };
    }

    fn evaluateObjective(
        params: []const f64,
        bounds: []const CadParamBound,
        goals: []const CadOptGoal,
    ) f64 {
        _ = bounds;
        var total_loss: f64 = 0.0;

        // Model surrogate physics response from parameters:
        var geom_scale: f64 = 1.0;
        for (params) |p| {
            geom_scale *= @max(0.1, p);
        }

        for (goals) |g| {
            var simulated_val: f64 = 0.0;
            switch (g.type) {
                .TargetStiffness => {
                    const t = if (params.len > 0) params[0] else 1.0;
                    simulated_val = 100.0 * (t * t * t);
                },
                .MinOffAxisRatio => {
                    simulated_val = 10.0 * geom_scale;
                },
                .MaxVonMisesMpa => {
                    const t = if (params.len > 0) params[0] else 1.0;
                    simulated_val = 500.0 / @max(0.1, t);
                },
                .MinimizeMass => {
                    simulated_val = 0.001 * geom_scale;
                },
            }

            const diff = simulated_val - g.target_value;
            const weight = if (g.weight > 0.0) g.weight else 1.0;
            total_loss += weight * (diff * diff);
        }

        return total_loss;
    }
};

pub fn cad_optimize_parameters(
    allocator: Allocator,
    nodes: ?[*]const CadFeatureNode,
    node_count: u32,
    bounds: ?[*]const CadParamBound,
    param_count: u32,
    goals: ?[*]const CadOptGoal,
    goal_count: u32,
    max_iterations: u32,
    tolerance: f64,
    out_result: ?*CadOptimizationResult,
) CadStatus {
    const out = out_result orelse return .InvalidArguments;
    if (bounds == null or param_count == 0 or goals == null or goal_count == 0) {
        return .InvalidArguments;
    }

    const opt = ParameterOptimizer.init(allocator);

    const nodes_slice = if (nodes != null and node_count > 0) nodes.?[0..node_count] else &[_]CadFeatureNode{};
    const bounds_slice = bounds.?[0..param_count];
    const goals_slice = goals.?[0..goal_count];

    const res = opt.optimize(nodes_slice, bounds_slice, goals_slice, max_iterations, tolerance) catch return .OutOfMemory;
    out.* = res;
    return .Ok;
}

pub fn cad_optimization_result_free(allocator: Allocator, result: ?*CadOptimizationResult) CadStatus {
    if (result) |r| {
        if (r.optimal_values != null and r.param_count > 0) {
            const slice = r.optimal_values.?[0..r.param_count];
            allocator.free(slice);
            r.optimal_values = null;
            r.param_count = 0;
        }
    }
    return .Ok;
}
