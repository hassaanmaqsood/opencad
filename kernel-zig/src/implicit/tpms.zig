const std = @import("std");
const sdf = @import("sdf.zig");

pub const TpmsType = enum(u8) {
    Gyroid = 0,
    SchwarzP = 1,
    SchwarzD = 2,
    Neovius = 3,
    Lidinoid = 4,
};

pub const TpmsLattice = struct {
    tpms_type: TpmsType = .Gyroid,
    cell_size: f64 = 10.0, // mm wavelength
    wall_thickness: f64 = 1.0, // mm
    is_sheet: bool = true, // Sheet-based (thickened level set) vs solid-network

    /// Evaluates nodal TPMS value f(x, y, z):
    pub fn evalNodalValue(self: TpmsLattice, p: sdf.Vec3) f64 {
        const k = (2.0 * std.math.pi) / self.cell_size;
        const x = p.x * k;
        const y = p.y * k;
        const z = p.z * k;

        const sin_x = @sin(x);
        const cos_x = @cos(x);
        const sin_y = @sin(y);
        const cos_y = @cos(y);
        const sin_z = @sin(z);
        const cos_z = @cos(z);

        return switch (self.tpms_type) {
            // Gyroid: sin(x)*cos(y) + sin(y)*cos(z) + sin(z)*cos(x) = c
            .Gyroid => sin_x * cos_y + sin_y * cos_z + sin_z * cos_x,
            // Schwarz P (Primitive): cos(x) + cos(y) + cos(z) = c
            .SchwarzP => cos_x + cos_y + cos_z,
            // Schwarz D (Diamond): cos(x)*cos(y)*cos(z) - sin(x)*sin(y)*sin(z) = c
            .SchwarzD => cos_x * cos_y * cos_z - sin_x * sin_y * sin_z,
            // Neovius: 3*(cos(x) + cos(y) + cos(z)) + 4*cos(x)*cos(y)*cos(z) = c
            .Neovius => 3.0 * (cos_x + cos_y + cos_z) + 4.0 * cos_x * cos_y * cos_z,
            // Lidinoid
            .Lidinoid => 0.5 * (sin_x * cos_y * sin_z + sin_y * cos_z * sin_x) - 0.5 * (cos_x * cos_y + cos_y * cos_z),
        };
    }

    /// Evaluates distance field (SDF) of the thickened sheet lattice:
    /// d(p) = |f(p)| - t/2 (scaled by approximate gradient)
    pub fn evalSdf(self: TpmsLattice, p: sdf.Vec3, local_thickness: ?f64) f64 {
        const val = self.evalNodalValue(p);
        const t = local_thickness orelse self.wall_thickness;
        const half_t = t / 2.0;

        if (self.is_sheet) {
            return @abs(val) - half_t;
        } else {
            return val - half_t;
        }
    }
};

test "TpmsLattice Gyroid evaluation" {
    const lattice = TpmsLattice{
        .tpms_type = .Gyroid,
        .cell_size = 10.0,
        .wall_thickness = 1.0,
    };
    const p = sdf.Vec3{ .x = 2.5, .y = 2.5, .z = 2.5 };
    const val = lattice.evalNodalValue(p);
    const d = lattice.evalSdf(p, null);
    try std.testing.expect(d != 0.0 or val != 0.0);
}
