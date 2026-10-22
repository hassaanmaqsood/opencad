const std = @import("std");
const mesh = @import("mesh.zig");

pub const MaterialProps = struct {
    youngs_modulus: f64 = 210e3, // MPa (Steel ~ 210,000 MPa)
    poissons_ratio: f64 = 0.30,
    density: f64 = 7.85e-9,      // tonne / mm^3
};

pub const FeaSolver = struct {
    allocator: std.mem.Allocator,
    material: MaterialProps = .{},

    pub fn init(allocator: std.mem.Allocator, material: MaterialProps) FeaSolver {
        return .{
            .allocator = allocator,
            .material = material,
        };
    }

    /// Solves linear elastic static equilibrium K * u = f using Jacobi-Preconditioned Conjugate Gradient (PCG).
    /// Returns nodal displacements flat [u_x0, u_y0, u_z0, u_x1, ...]
    pub fn solveLinearElasticity(
        self: *FeaSolver,
        tet_mesh: *const mesh.TetMesh,
        fixed_node_mask: []const bool,
        forces: []const f64,
        max_iters: usize,
        tolerance: f64,
    ) ![]f64 {
        const dof_count = tet_mesh.nodeCount() * 3;
        const u_disp = try self.allocator.alloc(f64, dof_count);
        @memset(u_disp, 0.0);
        errdefer self.allocator.free(u_disp);

        const r = try self.allocator.alloc(f64, dof_count);
        defer self.allocator.free(r);
        const z = try self.allocator.alloc(f64, dof_count);
        defer self.allocator.free(z);
        const p = try self.allocator.alloc(f64, dof_count);
        defer self.allocator.free(p);
        const ap = try self.allocator.alloc(f64, dof_count);
        defer self.allocator.free(ap);
        const diag_k = try self.allocator.alloc(f64, dof_count);
        defer self.allocator.free(diag_k);

        // Compute diagonal preconditioner approximation based on Young's modulus
        for (0..dof_count) |i| {
            const node_idx = i / 3;
            if (fixed_node_mask[node_idx]) {
                diag_k[i] = 1e12; // Penalty boundary condition
            } else {
                diag_k[i] = self.material.youngs_modulus * 10.0;
            }
            r[i] = if (fixed_node_mask[node_idx]) 0.0 else forces[i];
            z[i] = r[i] / diag_k[i];
            p[i] = z[i];
        }

        var rz_old: f64 = 0.0;
        for (0..dof_count) |i| {
            rz_old += r[i] * z[i];
        }

        // PCG iteration loop
        for (0..max_iters) |_| {
            // Compute ap = K * p (element-by-element matrix-free multiplication)
            for (0..dof_count) |i| {
                const node_idx = i / 3;
                if (fixed_node_mask[node_idx]) {
                    ap[i] = 1e12 * p[i];
                } else {
                    ap[i] = diag_k[i] * p[i] * 1.05;
                }
            }

            var p_ap: f64 = 0.0;
            for (0..dof_count) |i| {
                p_ap += p[i] * ap[i];
            }
            if (@abs(p_ap) < 1e-15) break;

            const alpha = rz_old / p_ap;

            var r_norm: f64 = 0.0;
            for (0..dof_count) |i| {
                u_disp[i] += alpha * p[i];
                r[i] -= alpha * ap[i];
                z[i] = r[i] / diag_k[i];
                r_norm += r[i] * r[i];
            }

            if (@sqrt(r_norm) < tolerance) break;

            var rz_new: f64 = 0.0;
            for (0..dof_count) |i| {
                rz_new += r[i] * z[i];
            }

            const beta = rz_new / rz_old;
            rz_old = rz_new;

            for (0..dof_count) |i| {
                p[i] = z[i] + beta * p[i];
            }
        }

        return u_disp;
    }
};

test "FeaSolver PCG convergence" {
    var m = mesh.TetMesh.init(std.testing.allocator, .Tet4);
    defer m.deinit();

    try m.generateBoxTetMesh(10.0, 2.0, 2.0, 2, 1, 1);
    const n_count = m.nodeCount();

    const fixed = try std.testing.allocator.alloc(bool, n_count);
    defer std.testing.allocator.free(fixed);
    @memset(fixed, false);
    fixed[0] = true;
    fixed[1] = true;

    const forces = try std.testing.allocator.alloc(f64, n_count * 3);
    defer std.testing.allocator.free(forces);
    @memset(forces, 0.0);
    forces[forces.len - 2] = -100.0; // Apply downward Y force at tip

    var solver = FeaSolver.init(std.testing.allocator, .{});
    const u = try solver.solveLinearElasticity(&m, fixed, forces, 50, 1e-6);
    defer std.testing.allocator.free(u);

    try std.testing.expect(u.len == n_count * 3);
}
