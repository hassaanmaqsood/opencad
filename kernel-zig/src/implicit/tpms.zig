const std = @import("std");
const sdf = @import("sdf.zig");

pub const TpmsType = enum(u8) {
    Gyroid = 0,
    SchwarzP = 1,
    SchwarzD = 2,
    Neovius = 3,
    Lidinoid = 4,
};

pub const StrutLatticeType = enum(u8) {
    BCC = 0, // Body-Centered Cubic
    FCC = 1, // Face-Centered Cubic
    OctetTruss = 2, // Octet Truss
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
            // Lidinoid: 0.5*(sin(2x)*cos(y)*sin(z) + sin(2y)*cos(z)*sin(x) + sin(2z)*cos(x)*sin(y)) - 0.5*(cos(2x)*cos(2y) + cos(2y)*cos(2z) + cos(2z)*cos(2x)) + 0.15
            .Lidinoid => blk: {
                const s2x = @sin(2.0 * x);
                const s2y = @sin(2.0 * y);
                const s2z = @sin(2.0 * z);
                const c2x = @cos(2.0 * x);
                const c2y = @cos(2.0 * y);
                const c2z = @cos(2.0 * z);
                const t1 = 0.5 * (s2x * cos_y * sin_z + s2y * cos_z * sin_x + s2z * cos_x * sin_y);
                const t2 = 0.5 * (c2x * c2y + c2y * c2z + c2z * c2x);
                break :blk t1 - t2 + 0.15;
            },
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

/// Distance from point p to 3D line segment [a, b] with radius r
fn capsuleSdf(p: sdf.Vec3, a: sdf.Vec3, b: sdf.Vec3, r: f64) f64 {
    const pa = sdf.Vec3{ .x = p.x - a.x, .y = p.y - a.y, .z = p.z - a.z };
    const ba = sdf.Vec3{ .x = b.x - a.x, .y = b.y - a.y, .z = b.z - a.z };
    const dot_pa_ba = pa.x * ba.x + pa.y * ba.y + pa.z * ba.z;
    const dot_ba_ba = ba.x * ba.x + ba.y * ba.y + ba.z * ba.z;
    const h = if (dot_ba_ba > 1e-12) std.math.clamp(dot_pa_ba / dot_ba_ba, 0.0, 1.0) else 0.0;
    const dx = pa.x - ba.x * h;
    const dy = pa.y - ba.y * h;
    const dz = pa.z - ba.z * h;
    return @sqrt(dx * dx + dy * dy + dz * dz) - r;
}

pub const StrutLattice = struct {
    lattice_type: StrutLatticeType = .BCC,
    cell_size: f64 = 10.0,
    strut_radius: f64 = 0.5,

    /// Evaluates the signed distance to periodic strut lattice
    pub fn evalSdf(self: StrutLattice, p: sdf.Vec3, local_radius: ?f64) f64 {
        const r = local_radius orelse self.strut_radius;
        const L = self.cell_size;
        const half_L = L * 0.5;

        // Periodic cell coordinates centered at [0, 0, 0] in [-L/2, L/2]^3
        const cx = @mod(p.x + half_L, L) - half_L;
        const cy = @mod(p.y + half_L, L) - half_L;
        const cz = @mod(p.z + half_L, L) - half_L;
        const cp = sdf.Vec3{ .x = cx, .y = cy, .z = cz };

        var min_dist: f64 = 1e9;

        switch (self.lattice_type) {
            .BCC => {
                // 8 diagonal struts from body center [0,0,0] to cube vertices [+-half_L, +-half_L, +-half_L]
                const center = sdf.Vec3{ .x = 0, .y = 0, .z = 0 };
                const corners = [_]sdf.Vec3{
                    .{ .x = -half_L, .y = -half_L, .z = -half_L },
                    .{ .x = half_L, .y = -half_L, .z = -half_L },
                    .{ .x = -half_L, .y = half_L, .z = -half_L },
                    .{ .x = half_L, .y = half_L, .z = -half_L },
                    .{ .x = -half_L, .y = -half_L, .z = half_L },
                    .{ .x = half_L, .y = -half_L, .z = half_L },
                    .{ .x = -half_L, .y = half_L, .z = half_L },
                    .{ .x = half_L, .y = half_L, .z = half_L },
                };
                inline for (corners) |c| {
                    min_dist = @min(min_dist, capsuleSdf(cp, center, c, r));
                }
            },
            .FCC => {
                // Struts along face diagonals
                const faces = [_]struct { a: sdf.Vec3, b: sdf.Vec3 }{
                    .{ .a = .{ .x = -half_L, .y = -half_L, .z = 0 }, .b = .{ .x = half_L, .y = half_L, .z = 0 } },
                    .{ .a = .{ .x = half_L, .y = -half_L, .z = 0 }, .b = .{ .x = -half_L, .y = half_L, .z = 0 } },
                    .{ .a = .{ .x = 0, .y = -half_L, .z = -half_L }, .b = .{ .x = 0, .y = half_L, .z = half_L } },
                    .{ .a = .{ .x = 0, .y = half_L, .z = -half_L }, .b = .{ .x = 0, .y = -half_L, .z = half_L } },
                    .{ .a = .{ .x = -half_L, .y = 0, .z = -half_L }, .b = .{ .x = half_L, .y = 0, .z = half_L } },
                    .{ .a = .{ .x = half_L, .y = 0, .z = -half_L }, .b = .{ .x = -half_L, .y = 0, .z = half_L } },
                };
                inline for (faces) |f| {
                    min_dist = @min(min_dist, capsuleSdf(cp, f.a, f.b, r));
                }
            },
            .OctetTruss => {
                // Octet truss combines FCC face diagonals with edge struts
                // Face diagonal struts
                const diagonals = [_]struct { a: sdf.Vec3, b: sdf.Vec3 }{
                    .{ .a = .{ .x = -half_L, .y = -half_L, .z = 0 }, .b = .{ .x = half_L, .y = half_L, .z = 0 } },
                    .{ .a = .{ .x = half_L, .y = -half_L, .z = 0 }, .b = .{ .x = -half_L, .y = half_L, .z = 0 } },
                    .{ .a = .{ .x = 0, .y = -half_L, .z = -half_L }, .b = .{ .x = 0, .y = half_L, .z = half_L } },
                    .{ .a = .{ .x = 0, .y = half_L, .z = -half_L }, .b = .{ .x = 0, .y = -half_L, .z = half_L } },
                    .{ .a = .{ .x = -half_L, .y = 0, .z = -half_L }, .b = .{ .x = half_L, .y = 0, .z = half_L } },
                    .{ .a = .{ .x = half_L, .y = 0, .z = -half_L }, .b = .{ .x = -half_L, .y = 0, .z = half_L } },
                };
                inline for (diagonals) |d| {
                    min_dist = @min(min_dist, capsuleSdf(cp, d.a, d.b, r));
                }
            },
        }

        return min_dist;
    }
};

test "TpmsLattice evaluations" {
    const p = sdf.Vec3{ .x = 2.5, .y = 2.5, .z = 2.5 };

    const gyroid = TpmsLattice{ .tpms_type = .Gyroid, .cell_size = 10.0, .wall_thickness = 1.0 };
    const val_g = gyroid.evalNodalValue(p);
    try std.testing.expect(val_g != 0.0);

    const lidinoid = TpmsLattice{ .tpms_type = .Lidinoid, .cell_size = 10.0, .wall_thickness = 1.0 };
    const val_l = lidinoid.evalNodalValue(p);
    try std.testing.expect(val_l != 0.0);

    const neovius = TpmsLattice{ .tpms_type = .Neovius, .cell_size = 10.0, .wall_thickness = 1.0 };
    const val_n = neovius.evalNodalValue(p);
    try std.testing.expect(val_n != 0.0);
}

test "StrutLattice BCC and Octet evaluations" {
    const bcc = StrutLattice{ .lattice_type = .BCC, .cell_size = 10.0, .strut_radius = 0.5 };
    const d_center = bcc.evalSdf(.{ .x = 0, .y = 0, .z = 0 }, null);
    try std.testing.expectApproxEqAbs(@as(f64, -0.5), d_center, 1e-4);

    const octet = StrutLattice{ .lattice_type = .OctetTruss, .cell_size = 10.0, .strut_radius = 0.5 };
    const d_octet = octet.evalSdf(.{ .x = 2.5, .y = 2.5, .z = 2.5 }, null);
    try std.testing.expect(d_octet != 0.0);
}
