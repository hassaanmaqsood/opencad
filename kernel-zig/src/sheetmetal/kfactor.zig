const std = @import("std");

pub const SheetMetalMaterial = struct {
    name: []const u8 = "Mild Steel",
    thickness: f64, // mm (T)
    default_k_factor: f64 = 0.44, // K = t/T (position of neutral axis)
    inner_bend_radius: f64, // mm (R)

    /// Calculates Bend Allowance (BA):
    /// BA = angle_rad * (R + K * T)
    pub fn calcBendAllowance(self: SheetMetalMaterial, angle_rad: f64) f64 {
        return angle_rad * (self.inner_bend_radius + self.default_k_factor * self.thickness);
    }

    /// Calculates Outside Setback (OSSB):
    /// OSSB = tan(angle_rad / 2) * (R + T)
    pub fn calcOutsideSetback(self: SheetMetalMaterial, angle_rad: f64) f64 {
        return @tan(angle_rad / 2.0) * (self.inner_bend_radius + self.thickness);
    }

    /// Calculates Bend Deduction (BD):
    /// BD = 2 * OSSB - BA
    pub fn calcBendDeduction(self: SheetMetalMaterial, angle_rad: f64) f64 {
        const ossb = self.calcOutsideSetback(angle_rad);
        const ba = self.calcBendAllowance(angle_rad);
        return 2.0 * ossb - ba;
    }
};

test "Sheet metal K-factor bend allowance" {
    const mat = SheetMetalMaterial{
        .thickness = 2.0,
        .default_k_factor = 0.44,
        .inner_bend_radius = 3.0,
    };
    const angle_90 = std.math.pi / 2.0;
    const ba = mat.calcBendAllowance(angle_90);
    // BA = pi/2 * (3.0 + 0.44 * 2.0) = 1.5707963 * 3.88 = 6.094689
    try std.testing.expect(ba > 6.09 and ba < 6.10);

    const bd = mat.calcBendDeduction(angle_90);
    try std.testing.expect(bd > 0.0);
}
