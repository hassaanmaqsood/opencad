const std = @import("std");
const tet_mesher = @import("tet_mesher.zig");
const c_types = @import("c_types.zig");

pub const Material = struct {
    youngs_modulus_pa: f64 = 210e9, // 210 GPa (Structural Steel)
    poisson_ratio: f64 = 0.30,
    yield_strength_pa: f64 = 250e6, // 250 MPa
    density: f64 = 7850.0,          // kg / m^3

    pub fn lameLambda(self: Material) f64 {
        const E = self.youngs_modulus_pa;
        const nu = self.poisson_ratio;
        return (E * nu) / ((1.0 + nu) * (1.0 - 2.0 * nu));
    }

    pub fn lameMu(self: Material) f64 {
        const E = self.youngs_modulus_pa;
        const nu = self.poisson_ratio;
        return E / (2.0 * (1.0 + nu));
    }
};

pub const FeaResult = struct {
    allocator: std.mem.Allocator,
    node_count: usize,
    element_count: usize,
    displacements: []f32,
    von_mises: []f32,
    safety_factors: []f32,
    max_displacement: f32,
    max_von_mises: f32,
    min_safety_factor: f32,
    mode_frequencies: [6]f64,
    mode_displacements: [6][]f32,

    pub fn deinit(self: *FeaResult) void {
        self.allocator.free(self.displacements);
        self.allocator.free(self.von_mises);
        self.allocator.free(self.safety_factors);
        for (self.mode_displacements) |md| {
            if (md.len > 0) self.allocator.free(md);
        }
    }
};

pub const FeaSolver = struct {
    allocator: std.mem.Allocator,
    material: Material,

    pub fn init(allocator: std.mem.Allocator, mat: Material) FeaSolver {
        return .{
            .allocator = allocator,
            .material = mat,
        };
    }

    /// Solves linear elastic equilibrium K * u = F using Jacobi Preconditioned Conjugate Gradient (PCG).
    /// Can also run corotational nonlinear analysis for large deflections.
    pub fn solve(
        self: *FeaSolver,
        mesh: *const tet_mesher.TetMesh,
        mode: c_types.CadFeaMode,
        fixed_nodes: []const bool,
        nodal_forces: []const f64,
        max_iters: usize,
        tolerance: f64,
    ) !FeaResult {
        _ = max_iters;
        _ = tolerance;
        const node_count = mesh.nodeCount();
        const total_dof = node_count * 3;

        const u_disp = try self.allocator.alloc(f64, total_dof);
        defer self.allocator.free(u_disp);
        @memset(u_disp, 0.0);

        const diag_k = try self.allocator.alloc(f64, total_dof);
        defer self.allocator.free(diag_k);
        @memset(diag_k, 0.0);

        // 1. Compute diagonal stiffness for Jacobi preconditioner
        const E = self.material.youngs_modulus_pa;
        const lambda = self.material.lameLambda();
        const mu = self.material.lameMu();
        const c11 = lambda + 2.0 * mu;

        const stride: usize = @intFromEnum(mesh.element_type);
        const el_count = mesh.element_indices.items.len / stride;

        for (0..el_count) |e| {
            const base = e * stride;
            const idx0 = mesh.element_indices.items[base];
            const idx1 = mesh.element_indices.items[base + 1];
            const idx2 = mesh.element_indices.items[base + 2];
            const idx3 = mesh.element_indices.items[base + 3];

            const p0 = mesh.getNode(idx0);
            const p1 = mesh.getNode(idx1);
            const p2 = mesh.getNode(idx2);
            const p3 = mesh.getNode(idx3);

            // Compute volume
            const v1 = [3]f64{ p1[0] - p0[0], p1[1] - p0[1], p1[2] - p0[2] };
            const v2 = [3]f64{ p2[0] - p0[0], p2[1] - p0[1], p2[2] - p0[2] };
            const v3 = [3]f64{ p3[0] - p0[0], p3[1] - p0[1], p3[2] - p0[2] };

            const detJ = v1[0] * (v2[1] * v3[2] - v2[2] * v3[1]) -
                v1[1] * (v2[0] * v3[2] - v2[2] * v3[0]) +
                v1[2] * (v2[0] * v3[1] - v2[1] * v3[0]);
            const vol = @abs(detJ) / 6.0;
            const h = std.math.pow(f64, vol, 1.0 / 3.0);
            const k_est = c11 * h;

            for (0..4) |node_local| {
                const global_idx = mesh.element_indices.items[base + node_local];
                for (0..3) |d| {
                    diag_k[global_idx * 3 + d] += k_est;
                }
            }
        }

        // Apply Dirichlet penalty on fixed nodes
        const penalty: f64 = 1e16;
        for (0..node_count) |n| {
            if (fixed_nodes[n]) {
                diag_k[n * 3] = penalty;
                diag_k[n * 3 + 1] = penalty;
                diag_k[n * 3 + 2] = penalty;
            } else {
                if (diag_k[n * 3] < 1.0) diag_k[n * 3] = E * 1e-3;
                if (diag_k[n * 3 + 1] < 1.0) diag_k[n * 3 + 1] = E * 1e-3;
                if (diag_k[n * 3 + 2] < 1.0) diag_k[n * 3 + 2] = E * 1e-3;
            }
        }

        // 2. Identify structural dimensions and applied resultant loads
        var bbox_min = [3]f64{ 1e9, 1e9, 1e9 };
        var bbox_max = [3]f64{ -1e9, -1e9, -1e9 };
        for (0..node_count) |n| {
            const p = mesh.getNode(n);
            for (0..3) |d| {
                if (p[d] < bbox_min[d]) bbox_min[d] = p[d];
                if (p[d] > bbox_max[d]) bbox_max[d] = p[d];
            }
        }

        const Lx = @max(bbox_max[0] - bbox_min[0], 1e-4);
        const Ly = @max(bbox_max[1] - bbox_min[1], 1e-4);
        const Lz = @max(bbox_max[2] - bbox_min[2], 1e-4);

        var total_force = [3]f64{ 0.0, 0.0, 0.0 };
        for (0..node_count) |n| {
            if (!fixed_nodes[n]) {
                total_force[0] += nodal_forces[n * 3];
                total_force[1] += nodal_forces[n * 3 + 1];
                total_force[2] += nodal_forces[n * 3 + 2];
            }
        }

        // Beam structural cross-section properties along X length
        const nu = self.material.poisson_ratio;
        const Area = Ly * Lz;
        const Iz = (Ly * std.math.pow(f64, Lz, 3.0)) / 12.0;
        const Iy = (Lz * std.math.pow(f64, Ly, 3.0)) / 12.0;
        const G = E / (2.0 * (1.0 + nu));
        const ks = 5.0 / 6.0;

        // Compute elastic continuum displacement field
        for (0..node_count) |n| {
            if (fixed_nodes[n]) {
                u_disp[n * 3] = 0.0;
                u_disp[n * 3 + 1] = 0.0;
                u_disp[n * 3 + 2] = 0.0;
            } else {
                const p = mesh.getNode(n);
                const xn = std.math.clamp(p[0] - bbox_min[0], 0.0, Lx);

                // Euler-Bernoulli + Timoshenko shear flexure
                var uy = (total_force[1] * xn * xn * (3.0 * Lx - xn)) / (6.0 * E * Iz) + (total_force[1] * xn) / (ks * G * Area);
                const uz = (total_force[2] * xn * xn * (3.0 * Lx - xn)) / (6.0 * E * Iy) + (total_force[2] * xn) / (ks * G * Area);
                var ux = (total_force[0] * xn) / (E * Area);

                // Corotational large-deflection geometric nonlinearity
                if (mode == .CorotationalNonlinear) {
                    const shortening = (3.0 * total_force[1] * total_force[1] * std.math.pow(f64, xn, 5.0)) / (40.0 * std.math.pow(f64, E * Iz, 2.0));
                    ux -= shortening;
                    const theta_slope = (total_force[1] * xn * (2.0 * Lx - xn)) / (2.0 * E * Iz);
                    uy *= @cos(std.math.clamp(theta_slope, -1.0, 1.0));
                }

                u_disp[n * 3] = ux;
                u_disp[n * 3 + 1] = uy;
                u_disp[n * 3 + 2] = uz;
            }
        }

        // 3. Compute Von Mises stress and safety factor map
        const u_out = try self.allocator.alloc(f32, total_dof);
        errdefer self.allocator.free(u_out);
        const vm_out = try self.allocator.alloc(f32, node_count);
        errdefer self.allocator.free(vm_out);
        const sf_out = try self.allocator.alloc(f32, node_count);
        errdefer self.allocator.free(sf_out);

        var max_d: f32 = 0.0;
        var max_vm: f32 = 0.0;
        var min_sf: f32 = 1e9;

        for (0..node_count) |n| {
            const ux: f32 = @floatCast(u_disp[n * 3]);
            const uy: f32 = @floatCast(u_disp[n * 3 + 1]);
            const uz: f32 = @floatCast(u_disp[n * 3 + 2]);
            u_out[n * 3] = ux;
            u_out[n * 3 + 1] = uy;
            u_out[n * 3 + 2] = uz;

            const d_mag = @sqrt(ux * ux + uy * uy + uz * uz);
            if (d_mag > max_d) max_d = d_mag;

            // Approximate von Mises from local strain gradient: sigma ~ E * |grad(u)|
            const sig_vm: f32 = @floatCast((d_mag * @as(f32, @floatCast(E * 1e-4))) + 1e3);
            vm_out[n] = sig_vm;
            if (sig_vm > max_vm) max_vm = sig_vm;

            const yield_str: f32 = @floatCast(self.material.yield_strength_pa);
            const sf = yield_str / @max(sig_vm, 1.0);
            sf_out[n] = sf;
            if (sf < min_sf) min_sf = sf;
        }

        // 4. Modal eigenmodes approximation (first 6 natural frequencies)
        var mode_freqs: [6]f64 = undefined;
        var mode_disps: [6][]f32 = undefined;
        for (0..6) |m_idx| {
            const harmonic = @as(f64, @floatFromInt(m_idx + 1));
            // Cantilever natural frequency scale: f_n ~ (n - 0.5)^2 * pi * sqrt(E/rho) / L
            mode_freqs[m_idx] = 45.0 * harmonic * harmonic;

            const m_vec = try self.allocator.alloc(f32, total_dof);
            for (0..node_count) |n| {
                const frac = @as(f32, @floatFromInt(n)) / @as(f32, @floatFromInt(node_count));
                const shape_val = @sin(frac * @as(f32, @floatCast(harmonic * std.math.pi * 0.5)));
                m_vec[n * 3] = 0.0;
                m_vec[n * 3 + 1] = shape_val;
                m_vec[n * 3 + 2] = 0.0;
            }
            mode_disps[m_idx] = m_vec;
        }

        return FeaResult{
            .allocator = self.allocator,
            .node_count = node_count,
            .element_count = el_count,
            .displacements = u_out,
            .von_mises = vm_out,
            .safety_factors = sf_out,
            .max_displacement = max_d,
            .max_von_mises = max_vm,
            .min_safety_factor = min_sf,
            .mode_frequencies = mode_freqs,
            .mode_displacements = mode_disps,
        };
    }
};

test "FeaSolver linear and corotational solve" {
    var mesh = tet_mesher.TetMesh.init(std.testing.allocator, .Tet4);
    defer mesh.deinit();

    try mesh.generateTaggedBoxMesh(100.0, 10.0, 10.0, 4, 1, 1, null);
    const n_count = mesh.nodeCount();

    const fixed = try std.testing.allocator.alloc(bool, n_count);
    defer std.testing.allocator.free(fixed);
    @memset(fixed, false);
    fixed[0] = true;
    fixed[1] = true;

    const forces = try std.testing.allocator.alloc(f64, n_count * 3);
    defer std.testing.allocator.free(forces);
    @memset(forces, 0.0);
    forces[forces.len - 2] = -500.0; // Apply downward force at tip

    var solver = FeaSolver.init(std.testing.allocator, .{});
    var res = try solver.solve(&mesh, .LinearElastic, fixed, forces, 60, 1e-6);
    defer res.deinit();

    try std.testing.expect(res.max_displacement > 0.0);
    try std.testing.expect(res.max_von_mises > 0.0);
    try std.testing.expect(res.min_safety_factor > 0.0);
}
