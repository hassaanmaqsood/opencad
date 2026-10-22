const std = @import("std");

pub const Vec3 = struct {
    x: f64,
    y: f64,
    z: f64,

    pub fn length(self: Vec3) f64 {
        return @sqrt(self.x * self.x + self.y * self.y + self.z * self.z);
    }

    pub fn sub(self: Vec3, other: Vec3) Vec3 {
        return .{ .x = self.x - other.x, .y = self.y - other.y, .z = self.z - other.z };
    }
};

pub const SdfPrimitive = struct {
    /// Signed distance to sphere centered at origin with radius r: d(p) = |p| - r
    pub fn sphere(p: Vec3, r: f64) f64 {
        return p.length() - r;
    }

    /// Signed distance to box with half-dimensions b: d(p) = |max(|p| - b, 0)| + min(max(q.x, max(q.y, q.z)), 0)
    pub fn box(p: Vec3, b: Vec3) f64 {
        const q = Vec3{
            .x = @abs(p.x) - b.x,
            .y = @abs(p.y) - b.y,
            .z = @abs(p.z) - b.z,
        };
        const outside = (Vec3{
            .x = @max(q.x, 0.0),
            .y = @max(q.y, 0.0),
            .z = @max(q.z, 0.0),
        }).length();
        const inside = @min(@max(q.x, @max(q.y, q.z)), 0.0);
        return outside + inside;
    }

    /// Signed distance to cylinder with radius r and half-height h
    pub fn cylinder(p: Vec3, r: f64, h: f64) f64 {
        const d_r = @sqrt(p.x * p.x + p.z * p.z) - r;
        const d_y = @abs(p.y) - h;
        return @min(@max(d_r, d_y), 0.0) + (Vec3{ .x = @max(d_r, 0.0), .y = @max(d_y, 0.0), .z = 0.0 }).length();
    }

    /// Smooth Boolean Union (Polynomial smin):
    /// smin(a, b, k) = -ln(exp(-k*a) + exp(-k*b)) / k or cubic Hermite
    pub fn smoothUnion(d1: f64, d2: f64, k: f64) f64 {
        const h = @max(k - @abs(d1 - d2), 0.0) / k;
        return @min(d1, d2) - h * h * h * k * (1.0 / 6.0);
    }

    /// Smooth Boolean Difference (Cut)
    pub fn smoothDifference(d1: f64, d2: f64, k: f64) f64 {
        return -smoothUnion(-d1, d2, k);
    }

    /// Smooth Boolean Intersection
    pub fn smoothIntersection(d1: f64, d2: f64, k: f64) f64 {
        const h = @max(k - @abs(d1 - d2), 0.0) / k;
        return @max(d1, d2) + h * h * h * k * (1.0 / 6.0);
    }
};

test "SdfPrimitive sphere and smooth union" {
    const p = Vec3{ .x = 0.0, .y = 3.0, .z = 0.0 };
    const d_sph = SdfPrimitive.sphere(p, 2.0);
    try std.testing.expectEqual(@as(f64, 1.0), d_sph);

    const su = SdfPrimitive.smoothUnion(1.0, 1.0, 0.5);
    try std.testing.expect(su < 1.0);
}
