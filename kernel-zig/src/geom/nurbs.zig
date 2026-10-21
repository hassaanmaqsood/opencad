const std = @import("std");

/// 3D double-precision vector for geometric modeling.
pub const Vec3d = extern struct {
    x: f64,
    y: f64,
    z: f64,

    pub fn init(x: f64, y: f64, z: f64) Vec3d {
        return .{ .x = x, .y = y, .z = z };
    }

    pub fn zero() Vec3d {
        return .{ .x = 0.0, .y = 0.0, .z = 0.0 };
    }

    pub fn add(self: Vec3d, other: Vec3d) Vec3d {
        return .{ .x = self.x + other.x, .y = self.y + other.y, .z = self.z + other.z };
    }

    pub fn sub(self: Vec3d, other: Vec3d) Vec3d {
        return .{ .x = self.x - other.x, .y = self.y - other.y, .z = self.z - other.z };
    }

    pub fn scale(self: Vec3d, s: f64) Vec3d {
        return .{ .x = self.x * s, .y = self.y * s, .z = self.z * s };
    }

    pub fn dot(self: Vec3d, other: Vec3d) f64 {
        return self.x * other.x + self.y * other.y + self.z * other.z;
    }

    pub fn cross(self: Vec3d, other: Vec3d) Vec3d {
        return .{
            .x = self.y * other.z - self.z * other.y,
            .y = self.z * other.x - self.x * other.z,
            .z = self.x * other.y - self.y * other.x,
        };
    }

    pub fn normSq(self: Vec3d) f64 {
        return self.dot(self);
    }

    pub fn norm(self: Vec3d) f64 {
        return @sqrt(self.normSq());
    }

    pub fn normalize(self: Vec3d) Vec3d {
        const n = self.norm();
        if (n < 1e-14) return Vec3d.zero();
        return self.scale(1.0 / n);
    }

    pub fn dist(self: Vec3d, other: Vec3d) f64 {
        return self.sub(other).norm();
    }
};

/// SIMD Vectorized homogeneous coordinate [w*x, w*y, w*z, w].
pub const HPoint = @Vector(4, f64);

pub fn hpointFromCartesian(x: f64, y: f64, z: f64, w: f64) HPoint {
    return .{ x * w, y * w, z * w, w };
}

pub fn hpointToCartesian(hp: HPoint) Vec3d {
    const w = hp[3];
    if (@abs(w) > 1e-15) {
        const inv_w = 1.0 / w;
        return Vec3d.init(hp[0] * inv_w, hp[1] * inv_w, hp[2] * inv_w);
    }
    return Vec3d.init(hp[0], hp[1], hp[2]);
}

/// 3D Axis-Aligned Bounding Box.
pub const AABB = struct {
    min: Vec3d,
    max: Vec3d,

    pub fn empty() AABB {
        return .{
            .min = Vec3d.init(1e30, 1e30, 1e30),
            .max = Vec3d.init(-1e30, -1e30, -1e30),
        };
    }

    pub fn includePoint(self: *AABB, p: Vec3d) void {
        if (p.x < self.min.x) self.min.x = p.x;
        if (p.y < self.min.y) self.min.y = p.y;
        if (p.z < self.min.z) self.min.z = p.z;
        if (p.x > self.max.x) self.max.x = p.x;
        if (p.y > self.max.y) self.max.y = p.y;
        if (p.z > self.max.z) self.max.z = p.z;
    }
};

/// 2D UV Domain Bounding Box.
pub const UVBox = struct {
    u_min: f64,
    u_max: f64,
    v_min: f64,
    v_max: f64,
};

/// Result of orthogonal point-to-surface projection.
pub const ProjectionResult = struct {
    u: f64,
    v: f64,
    point: Vec3d,
    distance: f64,
    converged: bool,
    iterations: u32,
};

/// Complete surface differential properties at a parameter (u, v).
pub const SurfaceDerivatives = struct {
    point: Vec3d,
    d_u: Vec3d,
    d_v: Vec3d,
    d_uu: Vec3d,
    d_vv: Vec3d,
    d_uv: Vec3d,
    normal: Vec3d,
};

// ---------------------------------------------------------------------------
// Knot Span and Basis Function Evaluation
// ---------------------------------------------------------------------------

pub fn findSpan(n: usize, p: u32, u: f64, U: []const f64) usize {
    if (u >= U[n + 1]) return n;
    if (u <= U[p]) return p;

    var low: usize = p;
    var high: usize = n + 1;
    var mid: usize = (low + high) / 2;

    while (u < U[mid] or u >= U[mid + 1]) {
        if (u < U[mid]) {
            high = mid;
        } else {
            low = mid;
        }
        mid = (low + high) / 2;
    }

    return mid;
}

/// Evaluates non-zero B-Spline basis functions and their 1st and 2nd derivatives.
/// N0: basis functions N_{span-p+i, p}(u), length p+1
/// N1: first derivatives N'_{span-p+i, p}(u), length p+1
/// N2: second derivatives N''_{span-p+i, p}(u), length p+1
pub fn evalBasisAndDerivs(
    span: usize,
    u: f64,
    p: u32,
    U: []const f64,
    N0: []f64,
    N1: []f64,
    N2: []f64,
) void {
    const p_sz: usize = p;
    var left: [16]f64 = undefined;
    var right: [16]f64 = undefined;
    var ndu: [16][16]f64 = undefined;

    ndu[0][0] = 1.0;
    for (1..p_sz + 1) |j| {
        left[j] = u - U[span + 1 - j];
        right[j] = U[span + j] - u;
        var saved: f64 = 0.0;
        for (0..j) |r| {
            ndu[j][r] = right[r + 1] + left[j - r];
            const temp = ndu[r][j - 1] / ndu[j][r];
            ndu[r][j] = saved + right[r + 1] * temp;
            saved = left[j - r] * temp;
        }
        ndu[j][j] = saved;
    }

    // Load 0th derivative (basis functions)
    for (0..p_sz + 1) |j| {
        N0[j] = ndu[j][p_sz];
    }

    // Compute derivatives using Piegl & Tiller Algorithm A2.3
    var a: [2][16]f64 = undefined;
    for (0..p_sz + 1) |r| {
        var s1: usize = 0;
        var s2: usize = 1;
        a[0][0] = 1.0;

        for (1..3) |k| {
            if (k > p_sz) {
                if (k == 1) N1[r] = 0.0 else N2[r] = 0.0;
                continue;
            }

            var d: f64 = 0.0;
            const r_i = @as(i32, @intCast(r));
            const k_i = @as(i32, @intCast(k));
            const p_i = @as(i32, @intCast(p_sz));
            const rk = r_i - k_i;
            const pk = p_i - k_i;

            if (r >= k) {
                const rk_idx = @as(usize, @intCast(rk));
                const pk_idx = @as(usize, @intCast(pk));
                a[s2][0] = a[s1][0] / ndu[pk_idx + 1][rk_idx];
                d = a[s2][0] * ndu[rk_idx][pk_idx];
            }

            const j1: usize = if (rk >= -1) 1 else @intCast(-rk);
            const j2: usize = if (r_i - 1 <= pk) k - 1 else @intCast(p_i - r_i);

            if (j1 <= j2) {
                for (j1..j2 + 1) |j| {
                    const rk_j = @as(usize, @intCast(rk + @as(i32, @intCast(j))));
                    const pk_idx = @as(usize, @intCast(pk));
                    a[s2][j] = (a[s1][j] - a[s1][j - 1]) / ndu[pk_idx + 1][rk_j];
                    d += a[s2][j] * ndu[rk_j][pk_idx];
                }
            }

            if (r_i <= pk) {
                const pk_idx = @as(usize, @intCast(pk));
                a[s2][k] = -a[s1][k - 1] / ndu[pk_idx + 1][r];
                d += a[s2][k] * ndu[r][pk_idx];
            }

            if (k == 1) {
                N1[r] = d;
            } else {
                N2[r] = d;
            }

            const tmp = s1;
            s1 = s2;
            s2 = tmp;
        }
    }

    // Multiply by correct factorial factor: p! / (p - k)!
    const p_f: f64 = @floatFromInt(p_sz);
    for (0..p_sz + 1) |j| {
        N1[j] *= p_f;
    }
    if (p_sz >= 2) {
        const factor2 = p_f * (p_f - 1.0);
        for (0..p_sz + 1) |j| {
            N2[j] *= factor2;
        }
    } else {
        for (0..p_sz + 1) |j| {
            N2[j] = 0.0;
        }
    }
}

// ---------------------------------------------------------------------------
// NURBS Curve
// ---------------------------------------------------------------------------

pub const NurbsCurve = struct {
    degree: u32,
    knots: []f64,
    control_points: []HPoint,
    allocator: ?std.mem.Allocator = null,

    pub fn deinit(self: *NurbsCurve) void {
        if (self.allocator) |alloc| {
            alloc.free(self.knots);
            alloc.free(self.control_points);
        }
        self.* = undefined;
    }

    pub fn getDomain(self: *const NurbsCurve) struct { min: f64, max: f64 } {
        const p = self.degree;
        const n = self.control_points.len - 1;
        return .{ .min = self.knots[p], .max = self.knots[n + 1] };
    }

    /// Vectorized De Boor's algorithm evaluating 3D point C(u).
    pub fn evaluate(self: *const NurbsCurve, u: f64) Vec3d {
        const p = self.degree;
        const n = self.control_points.len - 1;
        const dom = self.getDomain();
        const u_clamped = std.math.clamp(u, dom.min, dom.max);

        const span = findSpan(n, p, u_clamped, self.knots);

        var d: [16]HPoint = undefined;
        for (0..p + 1) |i| {
            d[i] = self.control_points[span - p + i];
        }

        for (1..p + 1) |r| {
            var i: usize = p;
            while (i >= r) : (i -= 1) {
                const denom = self.knots[span + 1 + i - r] - self.knots[span - p + i];
                const alpha: f64 = if (denom > 1e-15) (u_clamped - self.knots[span - p + i]) / denom else 0.0;
                const alpha_vec: HPoint = @splat(alpha);
                const one_minus: HPoint = @splat(1.0 - alpha);
                d[i] = d[i - 1] * one_minus + d[i] * alpha_vec;
            }
        }

        return hpointToCartesian(d[p]);
    }

    /// Evaluates C(u) and rational derivative C'(u).
    pub fn evaluateDeriv1(self: *const NurbsCurve, u: f64) struct { p: Vec3d, d1: Vec3d } {
        const p = self.degree;
        const n = self.control_points.len - 1;
        const dom = self.getDomain();
        const u_clamped = std.math.clamp(u, dom.min, dom.max);
        const span = findSpan(n, p, u_clamped, self.knots);

        var N0: [16]f64 = undefined;
        var N1: [16]f64 = undefined;
        var N2: [16]f64 = undefined;
        evalBasisAndDerivs(span, u_clamped, p, self.knots, N0[0 .. p + 1], N1[0 .. p + 1], N2[0 .. p + 1]);

        var Cw: HPoint = @splat(0.0);
        var Cw_prime: HPoint = @splat(0.0);

        for (0..p + 1) |i| {
            const cp = self.control_points[span - p + i];
            const s0: HPoint = @splat(N0[i]);
            const s1: HPoint = @splat(N1[i]);
            Cw += cp * s0;
            Cw_prime += cp * s1;
        }

        const w = Cw[3];
        const inv_w = if (@abs(w) > 1e-15) 1.0 / w else 1.0;
        const pt = Vec3d.init(Cw[0] * inv_w, Cw[1] * inv_w, Cw[2] * inv_w);

        const w_prime = Cw_prime[3];
        const d1 = Vec3d.init(
            (Cw_prime[0] - pt.x * w_prime) * inv_w,
            (Cw_prime[1] - pt.y * w_prime) * inv_w,
            (Cw_prime[2] - pt.z * w_prime) * inv_w,
        );

        return .{ .p = pt, .d1 = d1 };
    }

    /// Evaluates C(u), C'(u), C''(u), and exact curvature kappa(u).
    pub fn evaluateDeriv2(self: *const NurbsCurve, u: f64) struct { p: Vec3d, d1: Vec3d, d2: Vec3d, curvature: f64 } {
        const p = self.degree;
        const n = self.control_points.len - 1;
        const dom = self.getDomain();
        const u_clamped = std.math.clamp(u, dom.min, dom.max);
        const span = findSpan(n, p, u_clamped, self.knots);

        var N0: [16]f64 = undefined;
        var N1: [16]f64 = undefined;
        var N2: [16]f64 = undefined;
        evalBasisAndDerivs(span, u_clamped, p, self.knots, N0[0 .. p + 1], N1[0 .. p + 1], N2[0 .. p + 1]);

        var Cw: HPoint = @splat(0.0);
        var Cw_1: HPoint = @splat(0.0);
        var Cw_2: HPoint = @splat(0.0);

        for (0..p + 1) |i| {
            const cp = self.control_points[span - p + i];
            const s0: HPoint = @splat(N0[i]);
            const s1: HPoint = @splat(N1[i]);
            const s2: HPoint = @splat(N2[i]);
            Cw += cp * s0;
            Cw_1 += cp * s1;
            Cw_2 += cp * s2;
        }

        const w = Cw[3];
        const inv_w = if (@abs(w) > 1e-15) 1.0 / w else 1.0;
        const pt = Vec3d.init(Cw[0] * inv_w, Cw[1] * inv_w, Cw[2] * inv_w);

        const w1 = Cw_1[3];
        const d1 = Vec3d.init(
            (Cw_1[0] - pt.x * w1) * inv_w,
            (Cw_1[1] - pt.y * w1) * inv_w,
            (Cw_1[2] - pt.z * w1) * inv_w,
        );

        const w2 = Cw_2[3];
        const d2 = Vec3d.init(
            (Cw_2[0] - 2.0 * d1.x * w1 - pt.x * w2) * inv_w,
            (Cw_2[1] - 2.0 * d1.y * w1 - pt.y * w2) * inv_w,
            (Cw_2[2] - 2.0 * d1.z * w1 - pt.z * w2) * inv_w,
        );

        const cross = d1.cross(d2);
        const d1_norm = d1.norm();
        const d1_cube = d1_norm * d1_norm * d1_norm;
        const kappa = if (d1_cube > 1e-14) cross.norm() / d1_cube else 0.0;

        return .{ .p = pt, .d1 = d1, .d2 = d2, .curvature = kappa };
    }

    pub fn curvature(self: *const NurbsCurve, u: f64) f64 {
        return self.evaluateDeriv2(u).curvature;
    }

    pub fn getBounds(self: *const NurbsCurve) AABB {
        var box = AABB.empty();
        for (self.control_points) |cp| {
            box.includePoint(hpointToCartesian(cp));
        }
        return box;
    }

    /// Standard constructor: Exact full circle in XY plane.
    pub fn createCircle(allocator: std.mem.Allocator, center: Vec3d, radius: f64) !NurbsCurve {
        const knots = try allocator.alloc(f64, 12);
        const cp = try allocator.alloc(HPoint, 9);

        // Clamped uniform knot vector with 4 quarter-circle segments
        const k_vals = [_]f64{ 0.0, 0.0, 0.0, 0.25, 0.25, 0.5, 0.5, 0.75, 0.75, 1.0, 1.0, 1.0 };
        @memcpy(knots, &k_vals);

        const w = std.math.sqrt2 / 2.0;
        const dirs_x = [_]f64{ 1.0, 1.0, 0.0, -1.0, -1.0, -1.0, 0.0, 1.0, 1.0 };
        const dirs_y = [_]f64{ 0.0, 1.0, 1.0, 1.0, 0.0, -1.0, -1.0, -1.0, 0.0 };
        const weights = [_]f64{ 1.0, w, 1.0, w, 1.0, w, 1.0, w, 1.0 };

        for (0..9) |i| {
            const x = center.x + dirs_x[i] * radius;
            const y = center.y + dirs_y[i] * radius;
            const z = center.z;
            cp[i] = hpointFromCartesian(x, y, z, weights[i]);
        }

        return .{
            .degree = 2,
            .knots = knots,
            .control_points = cp,
            .allocator = allocator,
        };
    }

    /// Standard constructor: Exact circular arc in XY plane between start_angle and end_angle (radians).
    pub fn createArc(allocator: std.mem.Allocator, center: Vec3d, radius: f64, start_angle: f64, end_angle: f64) !NurbsCurve {
        var d_theta = end_angle - start_angle;
        while (d_theta < 0.0) d_theta += 2.0 * std.math.pi;
        while (d_theta > 2.0 * std.math.pi) d_theta -= 2.0 * std.math.pi;

        // Subdivide arc so each span is <= 90 degrees (pi / 2)
        const num_segments: usize = @intCast(@max(1, @as(usize, @intFromFloat(@ceil(d_theta / (0.5 * std.math.pi))))));
        const seg_angle = d_theta / @as(f64, @floatFromInt(num_segments));
        const num_cp = 2 * num_segments + 1;
        const num_knots = num_cp + 2 + 1;

        const knots = try allocator.alloc(f64, num_knots);
        const cp = try allocator.alloc(HPoint, num_cp);

        // Clamped knot vector
        knots[0] = 0.0;
        knots[1] = 0.0;
        knots[2] = 0.0;
        for (1..num_segments) |i| {
            const val = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(num_segments));
            knots[2 * i + 1] = val;
            knots[2 * i + 2] = val;
        }
        knots[num_knots - 3] = 1.0;
        knots[num_knots - 2] = 1.0;
        knots[num_knots - 1] = 1.0;

        const w = @cos(seg_angle * 0.5);

        for (0..num_segments) |i| {
            const theta0 = start_angle + @as(f64, @floatFromInt(i)) * seg_angle;
            const theta1 = theta0 + seg_angle;
            const theta_mid = theta0 + seg_angle * 0.5;

            if (i == 0) {
                const x0 = center.x + radius * @cos(theta0);
                const y0 = center.y + radius * @sin(theta0);
                cp[0] = hpointFromCartesian(x0, y0, center.z, 1.0);
            }

            // Shoulder control point
            const r_shoulder = radius / @cos(seg_angle * 0.5);
            const xm = center.x + r_shoulder * @cos(theta_mid);
            const ym = center.y + r_shoulder * @sin(theta_mid);
            cp[2 * i + 1] = hpointFromCartesian(xm, ym, center.z, w);

            // End control point
            const x1 = center.x + radius * @cos(theta1);
            const y1 = center.y + radius * @sin(theta1);
            cp[2 * i + 2] = hpointFromCartesian(x1, y1, center.z, 1.0);
        }

        return .{
            .degree = 2,
            .knots = knots,
            .control_points = cp,
            .allocator = allocator,
        };
    }
};

// ---------------------------------------------------------------------------
// NURBS Surface
// ---------------------------------------------------------------------------

pub const NurbsSurface = struct {
    deg_u: u32,
    deg_v: u32,
    knots_u: []f64,
    knots_v: []f64,
    num_u: usize,
    num_v: usize,
    control_points: []HPoint, // Size num_u * num_v in row-major order: [i * num_v + j]
    allocator: ?std.mem.Allocator = null,

    pub fn deinit(self: *NurbsSurface) void {
        if (self.allocator) |alloc| {
            alloc.free(self.knots_u);
            alloc.free(self.knots_v);
            alloc.free(self.control_points);
        }
        self.* = undefined;
    }

    pub fn getDomain(self: *const NurbsSurface) UVBox {
        const pu = self.deg_u;
        const pv = self.deg_v;
        return .{
            .u_min = self.knots_u[pu],
            .u_max = self.knots_u[self.num_u],
            .v_min = self.knots_v[pv],
            .v_max = self.knots_v[self.num_v],
        };
    }

    pub fn getCP(self: *const NurbsSurface, i: usize, j: usize) HPoint {
        return self.control_points[i * self.num_v + j];
    }

    /// Evaluates 3D surface point S(u, v) using tensor-product De Boor.
    pub fn evaluate(self: *const NurbsSurface, u: f64, v: f64) Vec3d {
        const pu = self.deg_u;
        const pv = self.deg_v;
        const dom = self.getDomain();
        const u_c = std.math.clamp(u, dom.u_min, dom.u_max);
        const v_c = std.math.clamp(v, dom.v_min, dom.v_max);

        const span_u = findSpan(self.num_u - 1, pu, u_c, self.knots_u);
        const span_v = findSpan(self.num_v - 1, pv, v_c, self.knots_v);

        // De Boor along V for each active row of U
        var temp_u: [16]HPoint = undefined;

        for (0..pu + 1) |i| {
            var d_v: [16]HPoint = undefined;
            for (0..pv + 1) |j| {
                d_v[j] = self.getCP(span_u - pu + i, span_v - pv + j);
            }

            for (1..pv + 1) |r| {
                var j: usize = pv;
                while (j >= r) : (j -= 1) {
                    const denom = self.knots_v[span_v + 1 + j - r] - self.knots_v[span_v - pv + j];
                    const alpha = if (denom > 1e-15) (v_c - self.knots_v[span_v - pv + j]) / denom else 0.0;
                    const a_vec: HPoint = @splat(alpha);
                    const one_minus: HPoint = @splat(1.0 - alpha);
                    d_v[j] = d_v[j - 1] * one_minus + d_v[j] * a_vec;
                }
            }
            temp_u[i] = d_v[pv];
        }

        // De Boor along U
        for (1..pu + 1) |r| {
            var i: usize = pu;
            while (i >= r) : (i -= 1) {
                const denom = self.knots_u[span_u + 1 + i - r] - self.knots_u[span_u - pu + i];
                const alpha = if (denom > 1e-15) (u_c - self.knots_u[span_u - pu + i]) / denom else 0.0;
                const a_vec: HPoint = @splat(alpha);
                const one_minus: HPoint = @splat(1.0 - alpha);
                temp_u[i] = temp_u[i - 1] * one_minus + temp_u[i] * a_vec;
            }
        }

        return hpointToCartesian(temp_u[pu]);
    }

    /// Evaluates complete surface differential geometry: S, S_u, S_v, S_uu, S_vv, S_uv, Normal.
    pub fn evaluateDerivatives(self: *const NurbsSurface, u: f64, v: f64) SurfaceDerivatives {
        const pu = self.deg_u;
        const pv = self.deg_v;
        const dom = self.getDomain();
        const u_c = std.math.clamp(u, dom.u_min, dom.u_max);
        const v_c = std.math.clamp(v, dom.v_min, dom.v_max);

        const span_u = findSpan(self.num_u - 1, pu, u_c, self.knots_u);
        const span_v = findSpan(self.num_v - 1, pv, v_c, self.knots_v);

        var Nu0: [16]f64 = undefined;
        var Nu1: [16]f64 = undefined;
        var Nu2: [16]f64 = undefined;
        evalBasisAndDerivs(span_u, u_c, pu, self.knots_u, Nu0[0 .. pu + 1], Nu1[0 .. pu + 1], Nu2[0 .. pu + 1]);

        var Nv0: [16]f64 = undefined;
        var Nv1: [16]f64 = undefined;
        var Nv2: [16]f64 = undefined;
        evalBasisAndDerivs(span_v, v_c, pv, self.knots_v, Nv0[0 .. pv + 1], Nv1[0 .. pv + 1], Nv2[0 .. pv + 1]);

        var Sw: HPoint = @splat(0.0);
        var Sw_u: HPoint = @splat(0.0);
        var Sw_v: HPoint = @splat(0.0);
        var Sw_uu: HPoint = @splat(0.0);
        var Sw_vv: HPoint = @splat(0.0);
        var Sw_uv: HPoint = @splat(0.0);

        for (0..pu + 1) |i| {
            for (0..pv + 1) |j| {
                const cp = self.getCP(span_u - pu + i, span_v - pv + j);

                const bu0 = Nu0[i];
                const bu1 = Nu1[i];
                const bu2 = Nu2[i];

                const bv0 = Nv0[j];
                const bv1 = Nv1[j];
                const bv2 = Nv2[j];

                Sw += cp * @as(HPoint, @splat(bu0 * bv0));
                Sw_u += cp * @as(HPoint, @splat(bu1 * bv0));
                Sw_v += cp * @as(HPoint, @splat(bu0 * bv1));
                Sw_uu += cp * @as(HPoint, @splat(bu2 * bv0));
                Sw_vv += cp * @as(HPoint, @splat(bu0 * bv2));
                Sw_uv += cp * @as(HPoint, @splat(bu1 * bv1));
            }
        }

        const w = Sw[3];
        const inv_w = if (@abs(w) > 1e-15) 1.0 / w else 1.0;
        const pt = Vec3d.init(Sw[0] * inv_w, Sw[1] * inv_w, Sw[2] * inv_w);

        const wu = Sw_u[3];
        const wv = Sw_v[3];

        const Su = Vec3d.init(
            (Sw_u[0] - pt.x * wu) * inv_w,
            (Sw_u[1] - pt.y * wu) * inv_w,
            (Sw_u[2] - pt.z * wu) * inv_w,
        );

        const Sv = Vec3d.init(
            (Sw_v[0] - pt.x * wv) * inv_w,
            (Sw_v[1] - pt.y * wv) * inv_w,
            (Sw_v[2] - pt.z * wv) * inv_w,
        );

        const wuu = Sw_uu[3];
        const wvv = Sw_vv[3];
        const wuv = Sw_uv[3];

        const Suu = Vec3d.init(
            (Sw_uu[0] - 2.0 * Su.x * wu - pt.x * wuu) * inv_w,
            (Sw_uu[1] - 2.0 * Su.y * wu - pt.y * wuu) * inv_w,
            (Sw_uu[2] - 2.0 * Su.z * wu - pt.z * wuu) * inv_w,
        );

        const Svv = Vec3d.init(
            (Sw_vv[0] - 2.0 * Sv.x * wv - pt.x * wvv) * inv_w,
            (Sw_vv[1] - 2.0 * Sv.y * wv - pt.y * wvv) * inv_w,
            (Sw_vv[2] - 2.0 * Sv.z * wv - pt.z * wvv) * inv_w,
        );

        const Suv = Vec3d.init(
            (Sw_uv[0] - Su.x * wv - Sv.x * wu - pt.x * wuv) * inv_w,
            (Sw_uv[1] - Su.y * wv - Sv.y * wu - pt.y * wuv) * inv_w,
            (Sw_uv[2] - Su.z * wv - Sv.z * wu - pt.z * wuv) * inv_w,
        );

        var normal_vec = Su.cross(Sv).normalize();
        if (normal_vec.normSq() < 1e-14) {
            normal_vec = Vec3d.init(0.0, 0.0, 1.0);
        }

        return .{
            .point = pt,
            .d_u = Su,
            .d_v = Sv,
            .d_uu = Suu,
            .d_vv = Svv,
            .d_uv = Suv,
            .normal = normal_vec,
        };
    }

    pub fn normal(self: *const NurbsSurface, u: f64, v: f64) Vec3d {
        return self.evaluateDerivatives(u, v).normal;
    }

    /// Orthogonal Point-to-Surface Projection via 2D Newton-Raphson iteration.
    pub fn projectPoint(self: *const NurbsSurface, pt: Vec3d, max_iters: u32, tol: f64) ProjectionResult {
        const dom = self.getDomain();
        const threshold = if (tol > 0.0) tol else 1e-8;
        const max_it = if (max_iters > 0) max_iters else 50;

        // Step 1: Coarse grid sampling to establish reliable initial guess
        const SAMPLES_U: usize = 17;
        const SAMPLES_V: usize = 17;
        var best_u = dom.u_min;
        var best_v = dom.v_min;
        var best_dist_sq: f64 = 1e30;

        for (0..SAMPLES_U) |i| {
            const frac_u = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(SAMPLES_U - 1));
            const u_sample = dom.u_min + frac_u * (dom.u_max - dom.u_min);

            for (0..SAMPLES_V) |j| {
                const frac_v = @as(f64, @floatFromInt(j)) / @as(f64, @floatFromInt(SAMPLES_V - 1));
                const v_sample = dom.v_min + frac_v * (dom.v_max - dom.v_min);

                const sample_pt = self.evaluate(u_sample, v_sample);
                const d_sq = sample_pt.sub(pt).normSq();
                if (d_sq < best_dist_sq) {
                    best_dist_sq = d_sq;
                    best_u = u_sample;
                    best_v = v_sample;
                }
            }
        }

        var cur_u = best_u;
        var cur_v = best_v;
        var iter: u32 = 0;
        var is_converged = false;

        // Step 2: 2D Newton-Raphson on distance residual R(u, v) = S(u, v) - P
        while (iter < max_it) : (iter += 1) {
            const diff = self.evaluateDerivatives(cur_u, cur_v);
            const R = diff.point.sub(pt);
            const dist = R.norm();

            if (dist < 1e-12) {
                is_converged = true;
                break;
            }

            const f1 = R.dot(diff.d_u);
            const f2 = R.dot(diff.d_v);

            const su_norm = diff.d_u.norm();
            const sv_norm = diff.d_v.norm();

            if (@abs(f1) <= threshold * (su_norm * dist + 1e-12) and
                @abs(f2) <= threshold * (sv_norm * dist + 1e-12))
            {
                is_converged = true;
                break;
            }

            // Hessian of objective function
            const J11 = diff.d_u.dot(diff.d_u) + R.dot(diff.d_uu);
            const J12 = diff.d_u.dot(diff.d_v) + R.dot(diff.d_uv);
            const J21 = J12;
            const J22 = diff.d_v.dot(diff.d_v) + R.dot(diff.d_vv);

            const det = J11 * J22 - J12 * J21;
            var delta_u: f64 = 0.0;
            var delta_v: f64 = 0.0;

            if (@abs(det) > 1e-12) {
                delta_u = -(J22 * f1 - J12 * f2) / det;
                delta_v = -(J11 * f2 - J21 * f1) / det;
            } else {
                delta_u = -f1 / (diff.d_u.dot(diff.d_u) + 1e-6);
                delta_v = -f2 / (diff.d_v.dot(diff.d_v) + 1e-6);
            }

            // Damped step clamping
            const span_u_len = dom.u_max - dom.u_min;
            const span_v_len = dom.v_max - dom.v_min;
            delta_u = std.math.clamp(delta_u, -0.4 * span_u_len, 0.4 * span_u_len);
            delta_v = std.math.clamp(delta_v, -0.4 * span_v_len, 0.4 * span_v_len);

            // Handle periodic wrap in U (for closed/revolved surfaces)
            var new_u = cur_u + delta_u;
            if (new_u < dom.u_min) {
                const wrapped_u = new_u + span_u_len;
                if (self.evaluate(wrapped_u, cur_v).sub(pt).normSq() < self.evaluate(dom.u_min, cur_v).sub(pt).normSq()) {
                    new_u = wrapped_u;
                } else {
                    new_u = dom.u_min;
                }
            } else if (new_u > dom.u_max) {
                const wrapped_u = new_u - span_u_len;
                if (self.evaluate(wrapped_u, cur_v).sub(pt).normSq() < self.evaluate(dom.u_max, cur_v).sub(pt).normSq()) {
                    new_u = wrapped_u;
                } else {
                    new_u = dom.u_max;
                }
            }

            cur_u = new_u;
            cur_v = std.math.clamp(cur_v + delta_v, dom.v_min, dom.v_max);

            if (@abs(delta_u) < 1e-11 and @abs(delta_v) < 1e-11) {
                is_converged = true;
                break;
            }
        }

        const final_pt = self.evaluate(cur_u, cur_v);
        return .{
            .u = cur_u,
            .v = cur_v,
            .point = final_pt,
            .distance = final_pt.dist(pt),
            .converged = is_converged,
            .iterations = iter,
        };
    }

    pub fn getBounds(self: *const NurbsSurface) AABB {
        var box = AABB.empty();
        for (self.control_points) |cp| {
            box.includePoint(hpointToCartesian(cp));
        }
        return box;
    }

    /// Standard constructor: Exact Cylinder Surface (Degree 2 in U, Degree 1 in V).
    pub fn createCylinder(allocator: std.mem.Allocator, center: Vec3d, radius: f64, height: f64) !NurbsSurface {
        const knots_u = try allocator.alloc(f64, 12);
        const k_u = [_]f64{ 0.0, 0.0, 0.0, 0.25, 0.25, 0.5, 0.5, 0.75, 0.75, 1.0, 1.0, 1.0 };
        @memcpy(knots_u, &k_u);

        const knots_v = try allocator.alloc(f64, 4);
        const k_v = [_]f64{ 0.0, 0.0, 1.0, 1.0 };
        @memcpy(knots_v, &k_v);

        const cp = try allocator.alloc(HPoint, 18); // 9 x 2

        const w = std.math.sqrt2 / 2.0;
        const dirs_x = [_]f64{ 1.0, 1.0, 0.0, -1.0, -1.0, -1.0, 0.0, 1.0, 1.0 };
        const dirs_y = [_]f64{ 0.0, 1.0, 1.0, 1.0, 0.0, -1.0, -1.0, -1.0, 0.0 };
        const weights = [_]f64{ 1.0, w, 1.0, w, 1.0, w, 1.0, w, 1.0 };

        for (0..9) |i| {
            const x = center.x + dirs_x[i] * radius;
            const y = center.y + dirs_y[i] * radius;

            // v = 0 bottom
            cp[i * 2 + 0] = hpointFromCartesian(x, y, center.z, weights[i]);
            // v = 1 top
            cp[i * 2 + 1] = hpointFromCartesian(x, y, center.z + height, weights[i]);
        }

        return .{
            .deg_u = 2,
            .deg_v = 1,
            .knots_u = knots_u,
            .knots_v = knots_v,
            .num_u = 9,
            .num_v = 2,
            .control_points = cp,
            .allocator = allocator,
        };
    }

    /// Standard constructor: Exact Sphere Surface (Degree 2 in U, Degree 2 in V).
    pub fn createSphere(allocator: std.mem.Allocator, center: Vec3d, radius: f64) !NurbsSurface {
        const knots_u = try allocator.alloc(f64, 12);
        const k_u = [_]f64{ 0.0, 0.0, 0.0, 0.25, 0.25, 0.5, 0.5, 0.75, 0.75, 1.0, 1.0, 1.0 };
        @memcpy(knots_u, &k_u);

        const knots_v = try allocator.alloc(f64, 8);
        const k_v = [_]f64{ 0.0, 0.0, 0.0, 0.5, 0.5, 1.0, 1.0, 1.0 };
        @memcpy(knots_v, &k_v);

        const cp = try allocator.alloc(HPoint, 45); // 9 x 5

        const w = std.math.sqrt2 / 2.0;
        const dirs_x = [_]f64{ 1.0, 1.0, 0.0, -1.0, -1.0, -1.0, 0.0, 1.0, 1.0 };
        const dirs_y = [_]f64{ 0.0, 1.0, 1.0, 1.0, 0.0, -1.0, -1.0, -1.0, 0.0 };
        const wu = [_]f64{ 1.0, w, 1.0, w, 1.0, w, 1.0, w, 1.0 };

        // Semicircle profile in (r, z) from South Pole to North Pole
        const Q_r = [_]f64{ 0.0, radius, radius, radius, 0.0 };
        const Q_z = [_]f64{ -radius, -radius, 0.0, radius, radius };
        const wv = [_]f64{ 1.0, w, 1.0, w, 1.0 };

        for (0..9) |i| {
            for (0..5) |j| {
                const total_w = wu[i] * wv[j];
                const x = center.x + dirs_x[i] * Q_r[j];
                const y = center.y + dirs_y[i] * Q_r[j];
                const z = center.z + Q_z[j];
                cp[i * 5 + j] = hpointFromCartesian(x, y, z, total_w);
            }
        }

        return .{
            .deg_u = 2,
            .deg_v = 2,
            .knots_u = knots_u,
            .knots_v = knots_v,
            .num_u = 9,
            .num_v = 5,
            .control_points = cp,
            .allocator = allocator,
        };
    }

    /// Standard constructor: Bicubic Bézier / B-Spline Freeform Patch.
    pub fn createBicubicPatch(allocator: std.mem.Allocator, control_pts_4x4: [16]Vec3d) !NurbsSurface {
        const knots_u = try allocator.alloc(f64, 8);
        const k_u = [_]f64{ 0.0, 0.0, 0.0, 0.0, 1.0, 1.0, 1.0, 1.0 };
        @memcpy(knots_u, &k_u);

        const knots_v = try allocator.alloc(f64, 8);
        const k_v = [_]f64{ 0.0, 0.0, 0.0, 0.0, 1.0, 1.0, 1.0, 1.0 };
        @memcpy(knots_v, &k_v);

        const cp = try allocator.alloc(HPoint, 16);
        for (0..16) |i| {
            const p = control_pts_4x4[i];
            cp[i] = hpointFromCartesian(p.x, p.y, p.z, 1.0);
        }

        return .{
            .deg_u = 3,
            .deg_v = 3,
            .knots_u = knots_u,
            .knots_v = knots_v,
            .num_u = 4,
            .num_v = 4,
            .control_points = cp,
            .allocator = allocator,
        };
    }
};

// ---------------------------------------------------------------------------
// Unit Tests
// ---------------------------------------------------------------------------

test "NURBS Curve: Exact Circle Evaluation and Curvature" {
    const R: f64 = 10.0;
    const center = Vec3d.init(5.0, 5.0, 0.0);
    var circle = try NurbsCurve.createCircle(std.testing.allocator, center, R);
    defer circle.deinit();

    // Test evaluation at parameter intervals
    const test_us = [_]f64{ 0.0, 0.125, 0.25, 0.375, 0.5, 0.625, 0.75, 0.875, 1.0 };
    for (test_us) |u| {
        const pt = circle.evaluate(u);
        const dist_to_center = pt.dist(center);
        try std.testing.expectApproxEqAbs(R, dist_to_center, 1e-6);

        // Curvature of circle must be exactly 1 / R everywhere
        const res = circle.evaluateDeriv2(u);
        try std.testing.expectApproxEqAbs(1.0 / R, res.curvature, 1e-5);
    }
}

test "NURBS Surface: Exact Cylinder Evaluation, Normals and Projection" {
    const R: f64 = 8.0;
    const H: f64 = 20.0;
    const center = Vec3d.init(0.0, 0.0, 0.0);
    var cyl = try NurbsSurface.createCylinder(std.testing.allocator, center, R, H);
    defer cyl.deinit();

    // Verify points lie on cylinder surface and normal points radially outward
    const test_params = [_][2]f64{
        .{ 0.0, 0.0 },
        .{ 0.25, 0.5 },
        .{ 0.5, 0.25 },
        .{ 0.75, 0.8 },
        .{ 1.0, 1.0 },
    };

    for (test_params) |uv| {
        const diff = cyl.evaluateDerivatives(uv[0], uv[1]);
        const r_measured = @sqrt(diff.point.x * diff.point.x + diff.point.y * diff.point.y);
        try std.testing.expectApproxEqAbs(R, r_measured, 1e-6);

        // Radial outward normal: (x/R, y/R, 0)
        try std.testing.expectApproxEqAbs(diff.point.x / R, diff.normal.x, 1e-5);
        try std.testing.expectApproxEqAbs(diff.point.y / R, diff.normal.y, 1e-5);
        try std.testing.expectApproxEqAbs(0.0, diff.normal.z, 1e-5);
    }

    // Point projection: query point outside cylinder at (15, 0, 10)
    const query = Vec3d.init(15.0, 0.0, 10.0);
    const proj = cyl.projectPoint(query, 50, 1e-8);
    try std.testing.expect(proj.converged);
    try std.testing.expectApproxEqAbs(7.0, proj.distance, 1e-5); // 15 - 8 = 7
    try std.testing.expectApproxEqAbs(8.0, proj.point.x, 1e-5);
    try std.testing.expectApproxEqAbs(0.0, proj.point.y, 1e-5);
    try std.testing.expectApproxEqAbs(10.0, proj.point.z, 1e-5);
}

test "NURBS Surface: Exact Sphere Evaluation, Normals and Projection" {
    const R: f64 = 12.0;
    const center = Vec3d.init(0.0, 0.0, 0.0);
    var sphere = try NurbsSurface.createSphere(std.testing.allocator, center, R);
    defer sphere.deinit();

    // Verify points lie on sphere surface
    const test_params = [_][2]f64{
        .{ 0.0, 0.5 }, // Equator
        .{ 0.25, 0.5 },
        .{ 0.5, 0.5 },
        .{ 0.75, 0.25 },
        .{ 0.5, 0.75 },
    };

    for (test_params) |uv| {
        const diff = sphere.evaluateDerivatives(uv[0], uv[1]);
        const r_measured = diff.point.dist(center);
        try std.testing.expectApproxEqAbs(R, r_measured, 1e-5);

        // Outward normal equals point / R
        try std.testing.expectApproxEqAbs(diff.point.x / R, diff.normal.x, 1e-4);
        try std.testing.expectApproxEqAbs(diff.point.y / R, diff.normal.y, 1e-4);
        try std.testing.expectApproxEqAbs(diff.point.z / R, diff.normal.z, 1e-4);
    }

    // Point projection: query point outside sphere at (20, 0, 0)
    const query = Vec3d.init(20.0, 0.0, 0.0);
    const proj = sphere.projectPoint(query, 50, 1e-8);
    try std.testing.expect(proj.converged);
    try std.testing.expectApproxEqAbs(8.0, proj.distance, 1e-5); // 20 - 12 = 8
    try std.testing.expectApproxEqAbs(12.0, proj.point.x, 1e-5);
    try std.testing.expectApproxEqAbs(0.0, proj.point.y, 1e-5);
    try std.testing.expectApproxEqAbs(0.0, proj.point.z, 1e-5);
}

test "NURBS Surface: Bicubic Freeform Patch Evaluation and Projection" {
    var pts: [16]Vec3d = undefined;
    for (0..4) |i| {
        for (0..4) |j| {
            const x = @as(f64, @floatFromInt(i)) * 10.0;
            const y = @as(f64, @floatFromInt(j)) * 10.0;
            const z = @sin(@as(f64, @floatFromInt(i + j)) * 0.5) * 5.0;
            pts[i * 4 + j] = Vec3d.init(x, y, z);
        }
    }

    var patch = try NurbsSurface.createBicubicPatch(std.testing.allocator, pts);
    defer patch.deinit();

    // Evaluate midpoint
    const mid_diff = patch.evaluateDerivatives(0.5, 0.5);
    try std.testing.expect(mid_diff.normal.norm() > 0.99);

    // Project point directly above midpoint
    const query = Vec3d.init(mid_diff.point.x, mid_diff.point.y, mid_diff.point.z + 10.0);
    const proj = patch.projectPoint(query, 50, 1e-8);
    try std.testing.expect(proj.converged);
    try std.testing.expectApproxEqAbs(0.5, proj.u, 1e-2);
    try std.testing.expectApproxEqAbs(0.5, proj.v, 1e-2);
}
