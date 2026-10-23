const std = @import("std");
const c_abi = @import("../c_abi.zig");
const Vec3 = @import("../math/vec3.zig").Vec3;
const se3 = @import("se3.zig");
const SE3 = se3.SE3;
const Quaternion = se3.Quaternion;
const qr = @import("qr.zig");

pub const CadAssemblyInstance = c_abi.CadAssemblyInstance;
pub const CadAssemblyMate = c_abi.CadAssemblyMate;
pub const CadAssemblyMateType = c_abi.CadAssemblyMateType;
pub const CadAssemblySolveStatus = c_abi.CadAssemblySolveStatus;
pub const CadSolveState = c_abi.CadSolveState;
pub const CadTopoId = c_abi.CadTopoId;

pub const EntityRef = struct {
    point: Vec3,
    direction: Vec3,
};

/// Resolve reference point and axis/normal from topological entity
pub fn resolveEntityRef(topo_id: CadTopoId) EntityRef {
    const subshape = topo_id.fields.subshape_type;
    const flags = topo_id.fields.flags;

    // Default reference geometry
    var pt = Vec3.init(0, 0, 0);
    var dir = Vec3.init(0, 0, 1);

    if (subshape == 2) {
        // Face subshape: decode flags or hash
        if (flags == 1) { // FLAG_CAP_BOTTOM
            dir = Vec3.init(0, 0, -1);
            pt = Vec3.init(0, 0, -1);
        } else if (flags == 2) { // FLAG_CAP_TOP
            dir = Vec3.init(0, 0, 1);
            pt = Vec3.init(0, 0, 1);
        } else if (flags == 3) { // FLAG_LATERAL
            dir = Vec3.init(1, 0, 0);
            pt = Vec3.init(1, 0, 0);
        } else {
            // Unpack direction from hash if available
            const h = topo_id.fields.subshape_hash;
            if (h != 0) {
                const qx = @as(f32, @floatFromInt((h >> 10) & 0x1F)) / 15.5 - 1.0;
                const qy = @as(f32, @floatFromInt((h >> 5) & 0x1F)) / 15.5 - 1.0;
                const qz = @as(f32, @floatFromInt(h & 0x1F)) / 15.5 - 1.0;
                const n = Vec3.init(qx, qy, qz).normalize();
                if (n.norm() > 0.5) {
                    dir = n;
                }
            }
        }
    } else if (subshape == 1) {
        // Edge subshape
        dir = Vec3.init(1, 0, 0);
    }

    return .{ .point = pt, .direction = dir };
}

/// Linear system solver with partial pivoting for A x = b (size N x N)
fn solveLinearSystem(allocator: std.mem.Allocator, A_in: []const f64, b_in: []const f64, N: usize, x_out: []f64) !bool {
    if (N == 0) return true;

    var A = try allocator.alloc(f64, N * N);
    defer allocator.free(A);
    @memcpy(A, A_in);

    var b = try allocator.alloc(f64, N);
    defer allocator.free(b);
    @memcpy(b, b_in);

    // Forward elimination with row pivoting
    for (0..N) |k| {
        var max_val = @abs(A[k * N + k]);
        var pivot_row = k;
        for (k + 1..N) |r| {
            const val = @abs(A[r * N + k]);
            if (val > max_val) {
                max_val = val;
                pivot_row = r;
            }
        }

        if (max_val < 1e-12) {
            // Singular or ill-conditioned
            return false;
        }

        if (pivot_row != k) {
            // Swap row k and pivot_row in A and b
            for (0..N) |c| {
                const tmp = A[k * N + c];
                A[k * N + c] = A[pivot_row * N + c];
                A[pivot_row * N + c] = tmp;
            }
            const tmp_b = b[k];
            b[k] = b[pivot_row];
            b[pivot_row] = tmp_b;
        }

        const pivot = A[k * N + k];
        for (k + 1..N) |r| {
            const factor = A[r * N + k] / pivot;
            A[r * N + k] = 0.0;
            for (k + 1..N) |c| {
                A[r * N + c] -= factor * A[k * N + c];
            }
            b[r] -= factor * b[k];
        }
    }

    // Back substitution
    var i: usize = N;
    while (i > 0) {
        i -= 1;
        var sum = b[i];
        for (i + 1..N) |c| {
            sum -= A[i * N + c] * x_out[c];
        }
        x_out[i] = sum / A[i * N + i];
    }

    return true;
}

pub const AssemblySolver = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) AssemblySolver {
        return .{ .allocator = allocator };
    }

    pub fn solve(
        self: *AssemblySolver,
        instances: []const CadAssemblyInstance,
        mates: []const CadAssemblyMate,
        max_iterations: u32,
        convergence_tol: f64,
        out_transforms: []f32,
        out_status: *CadAssemblySolveStatus,
    ) !c_abi.CadStatus {
        if (instances.len == 0) {
            out_status.* = .{
                .solve_state = .Solved,
                .total_dof = 0,
                .iterations = 0,
                .max_residual = 0.0,
                .conflicting_count = 0,
                .conflicting_mate_ids = null,
            };
            return .Ok;
        }

        // Initialize instance SE3 transforms
        var transforms = try self.allocator.alloc(SE3, instances.len);
        defer self.allocator.free(transforms);

        // Instance ID to index mapping
        var id_to_index = std.AutoHashMap(u32, usize).init(self.allocator);
        defer id_to_index.deinit();

        // Free variable index mapping (ungrounded instances get 6 DOF)
        var ungrounded_indices = std.ArrayList(usize).empty;
        defer ungrounded_indices.deinit(self.allocator);

        var inst_to_var = try self.allocator.alloc(?usize, instances.len);
        defer self.allocator.free(inst_to_var);

        for (instances, 0..) |inst, i| {
            transforms[i] = SE3.fromTransform4x4(inst.initial_transform);
            try id_to_index.put(inst.instance_id, i);

            if (inst.is_grounded != 0) {
                inst_to_var[i] = null;
            } else {
                inst_to_var[i] = ungrounded_indices.items.len;
                try ungrounded_indices.append(self.allocator, i);
            }
        }

        const num_free_bodies = ungrounded_indices.items.len;
        const num_vars = num_free_bodies * 6;

        // If all bodies are grounded or no mates, trivially solved
        if (num_vars == 0 or mates.len == 0) {
            for (instances, 0..) |_, i| {
                const m4x4 = transforms[i].toColumnMajor4x4();
                @memcpy(out_transforms[i * 16 .. (i + 1) * 16], &m4x4);
            }
            out_status.* = .{
                .solve_state = if (mates.len == 0 and num_vars > 0) .UnderConstrained else .Solved,
                .total_dof = @intCast(num_vars),
                .iterations = 0,
                .max_residual = 0.0,
                .conflicting_count = 0,
                .conflicting_mate_ids = null,
            };
            return .Ok;
        }

        // Count equations
        var num_eqs: usize = 0;
        for (mates) |mate| {
            num_eqs += getMateEquationCount(mate.type);
        }

        const r = try self.allocator.alloc(f64, num_eqs);
        defer self.allocator.free(r);

        const r_cand = try self.allocator.alloc(f64, num_eqs);
        defer self.allocator.free(r_cand);

        var J = try self.allocator.alloc(f64, num_eqs * num_vars);
        defer self.allocator.free(J);

        var JTJ = try self.allocator.alloc(f64, num_vars * num_vars);
        defer self.allocator.free(JTJ);

        var JTr = try self.allocator.alloc(f64, num_vars);
        defer self.allocator.free(JTr);

        const delta = try self.allocator.alloc(f64, num_vars);
        defer self.allocator.free(delta);

        var cand_transforms = try self.allocator.alloc(SE3, instances.len);
        defer self.allocator.free(cand_transforms);

        var lambda: f64 = 1e-3;
        var iter: u32 = 0;
        var max_res: f64 = 0.0;
        var current_cost: f64 = std.math.inf(f64);

        const max_iter = @max(1, max_iterations);

        while (iter < max_iter) : (iter += 1) {
            // 1. Evaluate current residuals
            max_res = evaluateResiduals(transforms, instances, mates, &id_to_index, r);
            current_cost = computeCost(r);

            if (max_res <= convergence_tol) {
                break;
            }

            // 2. Compute Jacobian J via numerical central difference
            const eps: f64 = 1e-3;
            const inv_2eps: f64 = 0.5 / eps;

            @memcpy(cand_transforms, transforms);

            for (ungrounded_indices.items, 0..) |inst_idx, u_idx| {
                const var_base = u_idx * 6;

                // 3 rotational dofs
                for (0..3) |d| {
                    var omega_pos = [3]f64{ 0, 0, 0 };
                    var omega_neg = [3]f64{ 0, 0, 0 };
                    omega_pos[d] = eps;
                    omega_neg[d] = -eps;
                    const v_zero = [3]f64{ 0, 0, 0 };

                    cand_transforms[inst_idx] = transforms[inst_idx].retract(omega_pos, v_zero);
                    _ = evaluateResiduals(cand_transforms, instances, mates, &id_to_index, r_cand);
                    const var_col = var_base + d;

                    for (0..num_eqs) |eq| {
                        J[eq * num_vars + var_col] = r_cand[eq];
                    }

                    cand_transforms[inst_idx] = transforms[inst_idx].retract(omega_neg, v_zero);
                    _ = evaluateResiduals(cand_transforms, instances, mates, &id_to_index, r_cand);

                    for (0..num_eqs) |eq| {
                        J[eq * num_vars + var_col] = (J[eq * num_vars + var_col] - r_cand[eq]) * inv_2eps;
                    }

                    cand_transforms[inst_idx] = transforms[inst_idx];
                }

                // 3 translational dofs
                for (0..3) |d| {
                    var v_pos = [3]f64{ 0, 0, 0 };
                    var v_neg = [3]f64{ 0, 0, 0 };
                    v_pos[d] = eps;
                    v_neg[d] = -eps;
                    const o_zero = [3]f64{ 0, 0, 0 };

                    cand_transforms[inst_idx] = transforms[inst_idx].retract(o_zero, v_pos);
                    _ = evaluateResiduals(cand_transforms, instances, mates, &id_to_index, r_cand);
                    const var_col = var_base + 3 + d;

                    for (0..num_eqs) |eq| {
                        J[eq * num_vars + var_col] = r_cand[eq];
                    }

                    cand_transforms[inst_idx] = transforms[inst_idx].retract(o_zero, v_neg);
                    _ = evaluateResiduals(cand_transforms, instances, mates, &id_to_index, r_cand);

                    for (0..num_eqs) |eq| {
                        J[eq * num_vars + var_col] = (J[eq * num_vars + var_col] - r_cand[eq]) * inv_2eps;
                    }

                    cand_transforms[inst_idx] = transforms[inst_idx];
                }
            }

            // 3. Form Normal Equations: (J^T J + lambda * diag(J^T J + I)) delta = -J^T r
            for (0..num_vars) |i| {
                var jtr_sum: f64 = 0.0;
                for (0..num_eqs) |k| {
                    jtr_sum += J[k * num_vars + i] * r[k];
                }
                JTr[i] = -jtr_sum;

                for (0..num_vars) |j| {
                    var jtj_sum: f64 = 0.0;
                    for (0..num_eqs) |k| {
                        jtj_sum += J[k * num_vars + i] * J[k * num_vars + j];
                    }
                    if (i == j) {
                        JTJ[i * num_vars + j] = jtj_sum + lambda * (jtj_sum + 1.0);
                    } else {
                        JTJ[i * num_vars + j] = jtj_sum;
                    }
                }
            }

            // 4. Solve for delta
            const solved = try solveLinearSystem(self.allocator, JTJ, JTr, num_vars, delta);
            if (!solved) {
                lambda *= 10.0;
                continue;
            }

            // 5. Apply candidate update
            for (ungrounded_indices.items, 0..) |inst_idx, u_idx| {
                const var_base = u_idx * 6;
                const omega = [3]f64{ delta[var_base], delta[var_base + 1], delta[var_base + 2] };
                const v = [3]f64{ delta[var_base + 3], delta[var_base + 4], delta[var_base + 5] };
                cand_transforms[inst_idx] = transforms[inst_idx].retract(omega, v);
            }

            const cand_res = evaluateResiduals(cand_transforms, instances, mates, &id_to_index, r_cand);
            const cand_cost = computeCost(r_cand);

            if (cand_cost < current_cost) {
                // Accept step
                @memcpy(transforms, cand_transforms);
                lambda = @max(1e-7, lambda * 0.1);
                max_res = cand_res;
                current_cost = cand_cost;
                if (max_res <= convergence_tol) {
                    break;
                }
            } else {
                // Reject step
                lambda = @min(1e7, lambda * 10.0);
            }
        }

        // Rank-revealing QR on Jacobian to find true system DOF
        const J_copy = try self.allocator.alloc(f64, num_eqs * num_vars);
        defer self.allocator.free(J_copy);
        @memcpy(J_copy, J);

        const rrqr = try qr.rrqrDecompose(self.allocator, J_copy, num_eqs, num_vars, 1e-4);
        defer self.allocator.free(rrqr.pivots);

        const system_rank = rrqr.rank;
        const total_dof: u32 = if (num_vars >= system_rank) @intCast(num_vars - system_rank) else 0;

        // Determine solve state
        var state: CadSolveState = .Solved;
        if (max_res <= convergence_tol) {
            state = if (total_dof > 0) .UnderConstrained else .Solved;
        } else {
            state = if (system_rank < num_eqs) .Conflicting else .OverConstrained;
        }

        // Output transforms into Three.js column-major f32 buffer
        for (instances, 0..) |_, i| {
            const m4x4 = transforms[i].toColumnMajor4x4();
            @memcpy(out_transforms[i * 16 .. (i + 1) * 16], &m4x4);
        }

        out_status.* = .{
            .solve_state = state,
            .total_dof = total_dof,
            .iterations = iter,
            .max_residual = max_res,
            .conflicting_count = 0,
            .conflicting_mate_ids = null,
        };

        return .Ok;
    }
};

fn computeCost(residuals: []const f64) f64 {
    var sum: f64 = 0.0;
    for (residuals) |v| {
        sum += v * v;
    }
    return sum;
}

fn getMateEquationCount(mate_type: CadAssemblyMateType) usize {
    return switch (mate_type) {
        .Coincident => 3, // 1 normal distance + 2 normal cross product components
        .Concentric => 4, // 2 axis alignment + 2 radial offset components
        .Parallel => 2,   // 2 normal cross product components
        .Distance => 3,   // 1 distance along normal + 2 normal alignment
        .Angle => 1,      // 1 dot product angle
        .Gear => 1,       // 1 rotational ratio
        .RackPinion => 1, // 1 rack-pinion ratio
        .Screw => 1,      // 1 lead-screw ratio
        .Cam => 1,        // 1 cam-follower curve
    };
}

fn getOrthonormalBasis(n: Vec3) struct { u: Vec3, v: Vec3 } {
    const a = if (@abs(n.z) < 0.9) Vec3.init(0, 0, 1) else Vec3.init(1, 0, 0);
    const u = n.cross(a).normalize();
    const v = n.cross(u).normalize();
    return .{ .u = u, .v = v };
}

fn evaluateResiduals(
    transforms: []const SE3,
    instances: []const CadAssemblyInstance,
    mates: []const CadAssemblyMate,
    id_to_index: *const std.AutoHashMap(u32, usize),
    r_out: []f64,
) f64 {
    _ = instances;
    var eq_idx: usize = 0;
    var max_res: f64 = 0.0;

    for (mates) |mate| {
        const idx1 = id_to_index.get(mate.instance1_id) orelse continue;
        const idx2 = id_to_index.get(mate.instance2_id) orelse continue;

        const T1 = transforms[idx1];
        const T2 = transforms[idx2];

        const ref1 = resolveEntityRef(mate.entity1_topo_id);
        const ref2 = resolveEntityRef(mate.entity2_topo_id);

        // Transform local entity references to world coordinates
        const P1 = T1.transformPoint(ref1.point);
        const N1 = T1.transformDirection(ref1.direction).normalize();

        const P2 = T2.transformPoint(ref2.point);
        const N2 = T2.transformDirection(ref2.direction).normalize();

        const target_N2 = if (mate.is_anti_aligned != 0) N1.scale(-1.0) else N1;
        const basis = getOrthonormalBasis(target_N2);

        const diff = P2.sub(P1);

        switch (mate.type) {
            .Coincident => {
                // 1. Planar distance: (P2 - P1) . N1 = 0
                const d_res = @as(f64, @floatCast(diff.dot(N1)));
                r_out[eq_idx] = d_res;
                eq_idx += 1;
                if (@abs(d_res) > max_res) max_res = @abs(d_res);

                // 2. Normal orientation: N2 . basis.u = 0, N2 . basis.v = 0
                const res_u = @as(f64, @floatCast(N2.dot(basis.u)));
                const res_v = @as(f64, @floatCast(N2.dot(basis.v)));
                r_out[eq_idx] = res_u;
                eq_idx += 1;
                r_out[eq_idx] = res_v;
                eq_idx += 1;

                if (@abs(res_u) > max_res) max_res = @abs(res_u);
                if (@abs(res_v) > max_res) max_res = @abs(res_v);
            },
            .Concentric => {
                // 1. Axes parallel: N2 . basis.u = 0, N2 . basis.v = 0
                const res_u = @as(f64, @floatCast(N2.dot(basis.u)));
                const res_v = @as(f64, @floatCast(N2.dot(basis.v)));
                r_out[eq_idx] = res_u;
                eq_idx += 1;
                r_out[eq_idx] = res_v;
                eq_idx += 1;

                if (@abs(res_u) > max_res) max_res = @abs(res_u);
                if (@abs(res_v) > max_res) max_res = @abs(res_v);

                // 2. Collinear: radial offset (P2 - P1) . basis.u = 0, (P2 - P1) . basis.v = 0
                const p_u = @as(f64, @floatCast(diff.dot(basis.u)));
                const p_v = @as(f64, @floatCast(diff.dot(basis.v)));
                r_out[eq_idx] = p_u;
                eq_idx += 1;
                r_out[eq_idx] = p_v;
                eq_idx += 1;

                if (@abs(p_u) > max_res) max_res = @abs(p_u);
                if (@abs(p_v) > max_res) max_res = @abs(p_v);
            },
            .Parallel => {
                const res_u = @as(f64, @floatCast(N2.dot(basis.u)));
                const res_v = @as(f64, @floatCast(N2.dot(basis.v)));
                r_out[eq_idx] = res_u;
                eq_idx += 1;
                r_out[eq_idx] = res_v;
                eq_idx += 1;

                if (@abs(res_u) > max_res) max_res = @abs(res_u);
                if (@abs(res_v) > max_res) max_res = @abs(res_v);
            },
            .Distance => {
                const d = @as(f64, @floatCast(diff.dot(N1))) - mate.parameter_value;
                r_out[eq_idx] = d;
                eq_idx += 1;
                if (@abs(d) > max_res) max_res = @abs(d);

                const res_u = @as(f64, @floatCast(N2.dot(basis.u)));
                const res_v = @as(f64, @floatCast(N2.dot(basis.v)));
                r_out[eq_idx] = res_u;
                eq_idx += 1;
                r_out[eq_idx] = res_v;
                eq_idx += 1;

                if (@abs(res_u) > max_res) max_res = @abs(res_u);
                if (@abs(res_v) > max_res) max_res = @abs(res_v);
            },
            .Angle => {
                // Dihedral angle between normals
                const target_cos = @cos(mate.parameter_value);
                const actual_cos = @as(f64, @floatCast(N1.dot(N2)));
                const angle_res = actual_cos - target_cos;
                r_out[eq_idx] = angle_res;
                eq_idx += 1;
                if (@abs(angle_res) > max_res) max_res = @abs(angle_res);
            },
            .Gear => {
                const ratio = if (@abs(mate.parameter_value) > 1e-6) mate.parameter_value else 1.0;
                const theta1 = @as(f64, @floatCast(T1.rotation.z));
                const theta2 = @as(f64, @floatCast(T2.rotation.z));
                const gear_res = theta2 - (theta1 * ratio);
                r_out[eq_idx] = gear_res;
                eq_idx += 1;
                if (@abs(gear_res) > max_res) max_res = @abs(gear_res);
            },
            .RackPinion => {
                const pitch_r = if (@abs(mate.parameter_value) > 1e-6) mate.parameter_value else 10.0;
                const theta1 = @as(f64, @floatCast(T1.rotation.z));
                const x2 = @as(f64, @floatCast(T2.translation.x));
                const rp_res = x2 - (theta1 * pitch_r);
                r_out[eq_idx] = rp_res;
                eq_idx += 1;
                if (@abs(rp_res) > max_res) max_res = @abs(rp_res);
            },
            .Screw => {
                const lead = if (@abs(mate.parameter_value) > 1e-6) mate.parameter_value else 5.0;
                const theta1 = @as(f64, @floatCast(T1.rotation.z));
                const z2 = @as(f64, @floatCast(T2.translation.z));
                const screw_res = z2 - (theta1 * (lead / (2.0 * std.math.pi)));
                r_out[eq_idx] = screw_res;
                eq_idx += 1;
                if (@abs(screw_res) > max_res) max_res = @abs(screw_res);
            },
            .Cam => {
                const r0 = if (@abs(mate.parameter_value) > 1e-6) mate.parameter_value else 20.0;
                const theta1 = @as(f64, @floatCast(T1.rotation.z));
                const y2 = @as(f64, @floatCast(T2.translation.y));
                const cam_r = r0 + 5.0 * @sin(theta1);
                const cam_res = y2 - cam_r;
                r_out[eq_idx] = cam_res;
                eq_idx += 1;
                if (@abs(cam_res) > max_res) max_res = @abs(cam_res);
            },
        }
    }

    return max_res;
}

pub fn stepMotion(
    instances: []const CadAssemblyInstance,
    mates: []const CadAssemblyMate,
    delta_time: f64,
    out_transforms: []f32,
    out_status: *CadAssemblySolveStatus,
) !void {
    for (instances, 0..) |inst, i| {
        @memcpy(out_transforms[i * 16 .. (i + 1) * 16], &inst.initial_transform);
        if (inst.is_grounded == 0) {
            const speed = 1.5;
            const angle = @as(f32, @floatCast(delta_time * speed));
            const c = @cos(angle);
            const s = @sin(angle);
            out_transforms[i * 16 + 0] = c;
            out_transforms[i * 16 + 1] = s;
            out_transforms[i * 16 + 4] = -s;
            out_transforms[i * 16 + 5] = c;
        }
    }

    _ = mates;
    out_status.* = .{
        .solve_state = .Solved,
        .total_dof = 1,
        .iterations = 1,
        .max_residual = 0.0,
        .conflicting_count = 0,
        .conflicting_mate_ids = null,
    };
}

pub fn explodedView(
    instances: []const CadAssemblyInstance,
    explode_factor: f32,
    out_transforms: []f32,
    out_trails: []c_abi.CadExplodeTrailLine,
    out_trail_count: *u32,
) !void {
    var centroid_x: f32 = 0.0;
    var centroid_y: f32 = 0.0;
    var centroid_z: f32 = 0.0;

    for (instances) |inst| {
        centroid_x += inst.initial_transform[12];
        centroid_y += inst.initial_transform[13];
        centroid_z += inst.initial_transform[14];
    }
    const n = @as(f32, @floatFromInt(@max(1, instances.len)));
    centroid_x /= n;
    centroid_y /= n;
    centroid_z /= n;

    var trail_idx: u32 = 0;

    for (instances, 0..) |inst, i| {
        @memcpy(out_transforms[i * 16 .. (i + 1) * 16], &inst.initial_transform);

        const init_x = inst.initial_transform[12];
        const init_y = inst.initial_transform[13];
        const init_z = inst.initial_transform[14];

        if (inst.is_grounded == 0 and explode_factor > 0.0) {
            var dx = init_x - centroid_x;
            var dy = init_y - centroid_y;
            var dz = init_z - centroid_z;
            const dist = @sqrt(dx * dx + dy * dy + dz * dz);
            if (dist < 1e-4) {
                dz = 50.0;
            } else {
                dx = (dx / dist) * 50.0;
                dy = (dy / dist) * 50.0;
                dz = (dz / dist) * 50.0;
            }

            const exp_x = init_x + dx * explode_factor;
            const exp_y = init_y + dy * explode_factor;
            const exp_z = init_z + dz * explode_factor;

            out_transforms[i * 16 + 12] = exp_x;
            out_transforms[i * 16 + 13] = exp_y;
            out_transforms[i * 16 + 14] = exp_z;

            if (trail_idx < out_trails.len) {
                out_trails[trail_idx] = .{
                    .start = [3]f32{ init_x, init_y, init_z },
                    .end = [3]f32{ exp_x, exp_y, exp_z },
                    .instance_id = inst.instance_id,
                };
                trail_idx += 1;
            }
        }
    }

    out_trail_count.* = trail_idx;
}
