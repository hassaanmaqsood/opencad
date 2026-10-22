const std = @import("std");

pub const SheetMetalMaterial = struct {
    name: []const u8 = "Mild Steel",
    thickness: f64, // mm (T)
    default_k_factor: f64 = 0.44, // K = t/T (position of neutral axis, DIN 6935)
    inner_bend_radius: f64, // mm (R)

    /// Calculates DIN 6935 Bend Allowance (BA):
    /// BA = angle_rad * (R + K * T)
    pub fn calcBendAllowance(self: SheetMetalMaterial, angle_rad: f64) f64 {
        return angle_rad * (self.inner_bend_radius + self.default_k_factor * self.thickness);
    }

    /// Calculates Outside Setback (OSSB):
    /// OSSB = tan(angle_rad / 2) * (R + T)
    /// For hem angles approaching PI (180 deg), tan(PI/2) is singular; clamp gracefully.
    pub fn calcOutsideSetback(self: SheetMetalMaterial, angle_rad: f64) f64 {
        const half_angle = angle_rad / 2.0;
        if (half_angle >= std.math.pi / 2.0 - 1e-4) {
            // For 180-deg hem, OSSB is equivalent to outer bend radius (R + T)
            return self.inner_bend_radius + self.thickness;
        }
        return @tan(half_angle) * (self.inner_bend_radius + self.thickness);
    }

    /// Calculates Bend Deduction (BD):
    /// BD = 2 * OSSB - BA
    pub fn calcBendDeduction(self: SheetMetalMaterial, angle_rad: f64) f64 {
        const ossb = self.calcOutsideSetback(angle_rad);
        const ba = self.calcBendAllowance(angle_rad);
        return 2.0 * ossb - ba;
    }

    /// Calculates flat blank length for two leg lengths L1 and L2 meeting at angle_rad:
    /// L_flat = L1 + L2 - BD
    pub fn calcFlatLength(self: SheetMetalMaterial, l1: f64, l2: f64, angle_rad: f64) f64 {
        const bd = self.calcBendDeduction(angle_rad);
        return l1 + l2 - bd;
    }
};

test "Sheet metal K-factor bend allowance and deduction" {
    const mat = SheetMetalMaterial{
        .thickness = 2.0,
        .default_k_factor = 0.44,
        .inner_bend_radius = 3.0,
    };
    const angle_90 = std.math.pi / 2.0;
    const ba = mat.calcBendAllowance(angle_90);
    // BA = pi/2 * (3.0 + 0.44 * 2.0) = 1.5707963 * 3.88 = 6.0946897
    try std.testing.expectApproxEqAbs(6.0946897, ba, 1e-6);

    const ossb = mat.calcOutsideSetback(angle_90);
    // OSSB = tan(45 deg) * (3.0 + 2.0) = 5.0
    try std.testing.expectApproxEqAbs(5.0, ossb, 1e-6);

    const bd = mat.calcBendDeduction(angle_90);
    // BD = 2 * 5.0 - 6.0946897 = 3.9053103
    try std.testing.expectApproxEqAbs(3.9053103, bd, 1e-6);

    const flat_len = mat.calcFlatLength(50.0, 50.0, angle_90);
    // Flat = 100.0 - 3.9053103 = 96.0946897
    try std.testing.expectApproxEqAbs(96.0946897, flat_len, 1e-6);
}

test "Sheet metal 180-degree hem calculation" {
    const mat = SheetMetalMaterial{
        .thickness = 1.0,
        .default_k_factor = 0.44,
        .inner_bend_radius = 0.5,
    };
    const angle_180 = std.math.pi;
    const ba = mat.calcBendAllowance(angle_180);
    // BA = pi * (0.5 + 0.44 * 1.0) = pi * 0.94 = 2.953097
    try std.testing.expectApproxEqAbs(std.math.pi * 0.94, ba, 1e-6);

    const ossb = mat.calcOutsideSetback(angle_180);
    try std.testing.expect(ossb > 0.0);
}
