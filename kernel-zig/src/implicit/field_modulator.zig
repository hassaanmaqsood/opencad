const std = @import("std");
const sdf = @import("sdf.zig");

pub const ScalarFieldType = enum {
    LinearGradient,
    RadialDistance,
    FeaStressInterpolated,
};

pub const FieldModulator = struct {
    min_thickness: f64 = 0.5, // mm
    max_thickness: f64 = 3.0, // mm

    /// Evaluates thickness t(x, y, z) based on linear spatial gradient from z0 to z1
    pub fn linearGradient(self: FieldModulator, p: sdf.Vec3, z0: f64, z1: f64) f64 {
        const factor = std.math.clamp((p.z - z0) / (z1 - z0), 0.0, 1.0);
        return self.min_thickness + factor * (self.max_thickness - self.min_thickness);
    }

    /// Evaluates thickness modulated by Von Mises stress relative to benchmark/yield stress:
    pub fn stressDriven(self: FieldModulator, von_mises_stress: f64, max_stress: f64) f64 {
        const factor = if (max_stress > 1e-9) std.math.clamp(von_mises_stress / max_stress, 0.0, 1.0) else 0.0;
        return self.min_thickness + factor * (self.max_thickness - self.min_thickness);
    }
};

/// 3D Stress Field interpolator based on Wave 8 FEA nodal results
pub const FeaStressField = struct {
    allocator: std.mem.Allocator,
    node_positions: []const f32, // [x0, y0, z0, x1, y1, z1, ...]
    von_mises_stresses: []const f32, // [vm0, vm1, ...]
    yield_strength: f32,

    pub fn init(
        allocator: std.mem.Allocator,
        positions: []const f32,
        stresses: []const f32,
        yield_strength: f32,
    ) FeaStressField {
        return .{
            .allocator = allocator,
            .node_positions = positions,
            .von_mises_stresses = stresses,
            .yield_strength = yield_strength,
        };
    }

    /// Interpolates Von Mises stress at point p using k-nearest inverse distance weighting (IDW)
    pub fn interpolateStress(self: FeaStressField, p: sdf.Vec3) f64 {
        const node_count = self.von_mises_stresses.len;
        if (node_count == 0) return 0.0;

        var weight_sum: f64 = 0.0;
        var stress_sum: f64 = 0.0;

        for (0..node_count) |i| {
            const nx = @as(f64, self.node_positions[i * 3 + 0]);
            const ny = @as(f64, self.node_positions[i * 3 + 1]);
            const nz = @as(f64, self.node_positions[i * 3 + 2]);
            const dx = p.x - nx;
            const dy = p.y - ny;
            const dz = p.z - nz;
            const dist_sq = dx * dx + dy * dy + dz * dz;

            if (dist_sq < 1e-8) {
                return @as(f64, self.von_mises_stresses[i]);
            }

            const w = 1.0 / dist_sq;
            weight_sum += w;
            stress_sum += w * @as(f64, self.von_mises_stresses[i]);
        }

        if (weight_sum > 1e-12) {
            return stress_sum / weight_sum;
        }
        return @as(f64, self.von_mises_stresses[0]);
    }

    /// Modulates lattice thickness at point p based on interpolated FEA stress
    pub fn evaluateThickness(
        self: FeaStressField,
        p: sdf.Vec3,
        min_thickness: f64,
        max_thickness: f64,
    ) f64 {
        const stress = self.interpolateStress(p);
        const factor = std.math.clamp(stress / @as(f64, self.yield_strength), 0.0, 1.0);
        return min_thickness + factor * (max_thickness - min_thickness);
    }
};

test "FieldModulator gradient and stressDriven" {
    const mod = FieldModulator{ .min_thickness = 1.0, .max_thickness = 4.0 };
    const t_grad = mod.linearGradient(.{ .x = 0, .y = 0, .z = 5 }, 0.0, 10.0);
    try std.testing.expectEqual(@as(f64, 2.5), t_grad);

    const t_stress = mod.stressDriven(125e6, 250e6);
    try std.testing.expectApproxEqAbs(@as(f64, 2.5), t_stress, 1e-4);
}

test "FeaStressField interpolation and thickness modulation" {
    const positions = [_]f32{
        0.0, 0.0,  0.0,
        10.0, 0.0, 0.0,
        0.0, 10.0, 0.0,
    };
    const stresses = [_]f32{
        50e6,
        150e6,
        250e6,
    };

    const field = FeaStressField.init(std.testing.allocator, &positions, &stresses, 250e6);
    const s_at_node1 = field.interpolateStress(.{ .x = 10.0, .y = 0.0, .z = 0.0 });
    try std.testing.expectApproxEqAbs(@as(f64, 150e6), s_at_node1, 1.0);

    const thickness = field.evaluateThickness(.{ .x = 10.0, .y = 0.0, .z = 0.0 }, 1.0, 5.0);
    // 150 / 250 = 0.6 factor -> 1.0 + 0.6 * 4.0 = 3.4
    try std.testing.expectApproxEqAbs(@as(f64, 3.4), thickness, 1e-3);
}
