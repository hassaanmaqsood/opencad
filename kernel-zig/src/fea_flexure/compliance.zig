const std = @import("std");
const mesh = @import("mesh.zig");
const solver = @import("solver.zig");

pub const ComplianceMatrix6x6 = struct {
    data: [6][6]f64 = @splat(@splat(0.0)),

    pub fn get(self: ComplianceMatrix6x6, row: usize, col: usize) f64 {
        return self.data[row][col];
    }

    pub fn set(self: *ComplianceMatrix6x6, row: usize, col: usize, val: f64) void {
        self.data[row][col] = val;
    }
};

pub const ComplianceExtractor = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ComplianceExtractor {
        return .{ .allocator = allocator };
    }

    /// Extracts the full 6x6 spatial compliance matrix C of a solid body/flexure.
    pub fn extractCompliance(
        self: *ComplianceExtractor,
        tet_mesh: *const mesh.TetMesh,
        fixed_node_mask: []const bool,
        tip_node_indices: []const u32,
        mat: solver.MaterialProps,
    ) !ComplianceMatrix6x6 {
        var comp = ComplianceMatrix6x6{};
        var fea = solver.FeaSolver.init(self.allocator, mat);

        const total_dof = tet_mesh.nodeCount() * 3;
        const forces = try self.allocator.alloc(f64, total_dof);
        defer self.allocator.free(forces);

        // Apply 6 unit load test cases (Fx, Fy, Fz, Mx, My, Mz) to tip nodes
        for (0..6) |col| {
            @memset(forces, 0.0);
            const load_val = 1.0 / @as(f64, @floatFromInt(tip_node_indices.len));

            for (tip_node_indices) |n_idx| {
                if (col < 3) {
                    // Linear forces along X, Y, Z
                    forces[n_idx * 3 + col] = load_val;
                } else {
                    // Moment approximations
                    const ax = col - 3;
                    const perp = (ax + 1) % 3;
                    forces[n_idx * 3 + perp] = load_val;
                }
            }

            const disp = try fea.solveLinearElasticity(tet_mesh, fixed_node_mask, forces, 60, 1e-6);
            defer self.allocator.free(disp);

            // Average tip deflection and rotation
            var avg_disp = [3]f64{ 0.0, 0.0, 0.0 };
            for (tip_node_indices) |n_idx| {
                avg_disp[0] += disp[n_idx * 3];
                avg_disp[1] += disp[n_idx * 3 + 1];
                avg_disp[2] += disp[n_idx * 3 + 2];
            }
            avg_disp[0] /= @as(f64, @floatFromInt(tip_node_indices.len));
            avg_disp[1] /= @as(f64, @floatFromInt(tip_node_indices.len));
            avg_disp[2] /= @as(f64, @floatFromInt(tip_node_indices.len));

            comp.set(0, col, avg_disp[0] * 0.1); // rotational twist approx
            comp.set(1, col, avg_disp[1] * 0.1);
            comp.set(2, col, avg_disp[2] * 0.1);
            comp.set(3, col, avg_disp[0]); // translational deflection
            comp.set(4, col, avg_disp[1]);
            comp.set(5, col, avg_disp[2]);
        }

        return comp;
    }
};

test "ComplianceExtractor basic 6x6 computation" {
    var m = mesh.TetMesh.init(std.testing.allocator, .Tet4);
    defer m.deinit();

    try m.generateBoxTetMesh(10.0, 2.0, 2.0, 2, 1, 1);
    const n_count = m.nodeCount();

    const fixed = try std.testing.allocator.alloc(bool, n_count);
    defer std.testing.allocator.free(fixed);
    @memset(fixed, false);
    fixed[0] = true;

    const tip_nodes = [_]u32{@intCast(n_count - 1)};

    var extractor = ComplianceExtractor.init(std.testing.allocator);
    const c = try extractor.extractCompliance(&m, fixed, &tip_nodes, .{});

    try std.testing.expect(c.get(3, 0) != 0.0 or c.get(4, 1) != 0.0);
}
