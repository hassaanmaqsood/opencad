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

    /// Evaluates thickness modulated by Von Mises stress sigma_vm relative to yield strength sigma_y:
    pub fn stressDriven(self: FieldModulator, von_mises_stress: f64, max_stress: f64) f64 {
        const factor = std.math.clamp(von_mises_stress / max_stress, 0.0, 1.0);
        return self.min_thickness + factor * (self.max_thickness - self.min_thickness);
    }
};

test "FieldModulator gradient" {
    const mod = FieldModulator{ .min_thickness = 1.0, .max_thickness = 4.0 };
    const t = mod.linearGradient(.{ .x = 0, .y = 0, .z = 5 }, 0.0, 10.0);
    try std.testing.expectEqual(@as(f64, 2.5), t);
}
