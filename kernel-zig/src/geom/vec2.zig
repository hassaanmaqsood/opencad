const std = @import("std");

pub const Vec2 = extern struct {
    x: f64,
    y: f64,

    pub fn init(x: f64, y: f64) Vec2 {
        return .{ .x = x, .y = y };
    }

    pub fn zero() Vec2 {
        return .{ .x = 0.0, .y = 0.0 };
    }

    pub fn add(self: Vec2, other: Vec2) Vec2 {
        return .{ .x = self.x + other.x, .y = self.y + other.y };
    }

    pub fn sub(self: Vec2, other: Vec2) Vec2 {
        return .{ .x = self.x - other.x, .y = self.y - other.y };
    }

    pub fn scale(self: Vec2, s: f64) Vec2 {
        return .{ .x = self.x * s, .y = self.y * s };
    }

    pub fn dot(self: Vec2, other: Vec2) f64 {
        return self.x * other.x + self.y * other.y;
    }

    pub fn cross(self: Vec2, other: Vec2) f64 {
        return self.x * other.y - self.y * other.x;
    }

    pub fn normSq(self: Vec2) f64 {
        return self.x * self.x + self.y * self.y;
    }

    pub fn norm(self: Vec2) f64 {
        return @sqrt(self.normSq());
    }

    pub fn normalize(self: Vec2) Vec2 {
        const n = self.norm();
        if (n < 1e-14) {
            return .{ .x = 0.0, .y = 0.0 };
        }
        return self.scale(1.0 / n);
    }

    pub fn distSq(self: Vec2, other: Vec2) f64 {
        return self.sub(other).normSq();
    }

    pub fn dist(self: Vec2, other: Vec2) f64 {
        return @sqrt(self.distSq(other));
    }

    pub fn perp(self: Vec2) Vec2 {
        return .{ .x = -self.y, .y = self.x };
    }

    pub fn angleTo(self: Vec2, other: Vec2) f64 {
        const c = self.cross(other);
        const d = self.dot(other);
        return std.math.atan2(c, d);
    }
};

test "Vec2 basic operations" {
    const a = Vec2.init(3.0, 4.0);
    const b = Vec2.init(1.0, 2.0);

    try std.testing.expectApproxEqAbs(5.0, a.norm(), 1e-9);
    try std.testing.expectApproxEqAbs(25.0, a.normSq(), 1e-9);

    const sum = a.add(b);
    try std.testing.expectApproxEqAbs(4.0, sum.x, 1e-9);
    try std.testing.expectApproxEqAbs(6.0, sum.y, 1e-9);

    const diff = a.sub(b);
    try std.testing.expectApproxEqAbs(2.0, diff.x, 1e-9);
    try std.testing.expectApproxEqAbs(2.0, diff.y, 1e-9);

    const dot_prod = a.dot(b);
    try std.testing.expectApproxEqAbs(11.0, dot_prod, 1e-9);

    const cross_prod = a.cross(b);
    try std.testing.expectApproxEqAbs(2.0, cross_prod, 1e-9);

    const norm_a = a.normalize();
    try std.testing.expectApproxEqAbs(1.0, norm_a.norm(), 1e-9);
    try std.testing.expectApproxEqAbs(0.6, norm_a.x, 1e-9);
    try std.testing.expectApproxEqAbs(0.8, norm_a.y, 1e-9);
}
