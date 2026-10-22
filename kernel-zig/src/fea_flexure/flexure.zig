const std = @import("std");

pub const FactDoFType = enum(u8) {
    Translation1D = 1,
    Rotation1D = 2,
    Planar2D = 3,
    Cylindrical2D = 4,
    Spatial3D = 5,
};

pub const NotchHingeType = enum(u8) {
    Circular = 0,
    Parabolic = 1,
    Elliptic = 2,
    CornerFilleted = 3,
};

pub const FlexureBlade = struct {
    length: f64,    // L (mm)
    width: f64,     // b (mm)
    thickness: f64, // t (mm)

    /// Rotational stiffness of a flat leaf flexure: K_theta = E * I / L = E * (b * t^3 / 12) / L
    pub fn calcRotationalStiffness(self: FlexureBlade, youngs_modulus: f64) f64 {
        const I = (self.width * std.math.pow(f64, self.thickness, 3.0)) / 12.0;
        return (youngs_modulus * I) / self.length;
    }

    /// Translational stiffness in transverse direction: K_trans = 12 * E * I / L^3
    pub fn calcTransverseStiffness(self: FlexureBlade, youngs_modulus: f64) f64 {
        const I = (self.width * std.math.pow(f64, self.thickness, 3.0)) / 12.0;
        return (12.0 * youngs_modulus * I) / std.math.pow(f64, self.length, 3.0);
    }
};

pub const CircularNotchHinge = struct {
    width: f64,          // b
    min_thickness: f64,  // t
    notch_radius: f64,   // r

    /// Paros & Weisbord empirical rotational compliance formula:
    /// C_theta = (9 * pi * r^(1/2)) / (2 * E * b * t^(5/2))
    pub fn calcRotationalCompliance(self: CircularNotchHinge, youngs_modulus: f64) f64 {
        const num = 9.0 * std.math.pi * @sqrt(self.notch_radius);
        const den = 2.0 * youngs_modulus * self.width * std.math.pow(f64, self.min_thickness, 2.5);
        return num / den;
    }
};

test "Flexure synthesis blade stiffness" {
    const blade = FlexureBlade{
        .length = 50.0,
        .width = 10.0,
        .thickness = 1.0,
    };
    const k_rot = blade.calcRotationalStiffness(210e3);
    try std.testing.expect(k_rot > 0.0);

    const hinge = CircularNotchHinge{
        .width = 10.0,
        .min_thickness = 0.8,
        .notch_radius = 5.0,
    };
    const c_rot = hinge.calcRotationalCompliance(210e3);
    try std.testing.expect(c_rot > 0.0);
}
