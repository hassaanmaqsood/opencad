const std = @import("std");
const vec2_mod = @import("vec2.zig");
pub const Vec2 = vec2_mod.Vec2;
const nurbs_mod = @import("nurbs.zig");
pub const Vec3d = nurbs_mod.Vec3d;
pub const NurbsSurface = nurbs_mod.NurbsSurface;
pub const SurfaceDerivatives = nurbs_mod.SurfaceDerivatives;
pub const UVBox = nurbs_mod.UVBox;
pub const ProjectionResult = nurbs_mod.ProjectionResult;

// ---------------------------------------------------------------------------
// 1. Analytical Geometry Primitives
// ---------------------------------------------------------------------------

/// Infinite analytical plane defined by origin and unit normal.
pub const Plane = struct {
    origin: Vec3d,
    normal: Vec3d,

    pub fn init(origin: Vec3d, normal: Vec3d) Plane {
        return .{
            .origin = origin,
            .normal = normal.normalize(),
        };
    }

    pub fn distanceToPoint(self: Plane, p: Vec3d) f64 {
        return p.sub(self.origin).dot(self.normal);
    }

    pub fn projectPoint(self: Plane, p: Vec3d) Vec3d {
        const d = self.distanceToPoint(p);
        return p.sub(self.normal.scale(d));
    }
};

/// Infinite analytical cylinder defined by origin, unit axis, and radius.
pub const Cylinder = struct {
    origin: Vec3d,
    axis: Vec3d,
    radius: f64,

    pub fn init(origin: Vec3d, axis: Vec3d, radius: f64) Cylinder {
        return .{
            .origin = origin,
            .axis = axis.normalize(),
            .radius = @abs(radius),
        };
    }

    pub fn distanceToPoint(self: Cylinder, p: Vec3d) f64 {
        const delta = p.sub(self.origin);
        const axial = delta.dot(self.axis);
        const radial_vec = delta.sub(self.axis.scale(axial));
        return radial_vec.norm() - self.radius;
    }

    pub fn projectPoint(self: Cylinder, p: Vec3d) Vec3d {
        const delta = p.sub(self.origin);
        const axial = delta.dot(self.axis);
        const radial_vec = delta.sub(self.axis.scale(axial));
        const r = radial_vec.norm();
        if (r < 1e-14) {
            // Point is on axis; choose arbitrary radial direction
            const up = if (@abs(self.axis.z) < 0.9) Vec3d.init(0, 0, 1) else Vec3d.init(1, 0, 0);
            const u = self.axis.cross(up).normalize();
            return self.origin.add(self.axis.scale(axial)).add(u.scale(self.radius));
        }
        return self.origin.add(self.axis.scale(axial)).add(radial_vec.scale(self.radius / r));
    }
};

/// 3D Infinite Line.
pub const Line3d = struct {
    origin: Vec3d,
    direction: Vec3d,

    pub fn init(origin: Vec3d, direction: Vec3d) Line3d {
        return .{
            .origin = origin,
            .direction = direction.normalize(),
        };
    }

    pub fn pointAt(self: Line3d, t: f64) Vec3d {
        return self.origin.add(self.direction.scale(t));
    }
};

/// 3D Circle in space.
pub const Circle3d = struct {
    center: Vec3d,
    normal: Vec3d,
    radius: f64,
    axis_u: Vec3d,
    axis_v: Vec3d,

    pub fn init(center: Vec3d, normal: Vec3d, radius: f64) Circle3d {
        const n = normal.normalize();
        const up = if (@abs(n.z) < 0.9) Vec3d.init(0, 0, 1) else Vec3d.init(1, 0, 0);
        const u = n.cross(up).normalize();
        const v = n.cross(u).normalize();
        return .{
            .center = center,
            .normal = n,
            .radius = radius,
            .axis_u = u,
            .axis_v = v,
        };
    }

    pub fn pointAt(self: Circle3d, theta: f64) Vec3d {
        const cu = self.axis_u.scale(@cos(theta) * self.radius);
        const cv = self.axis_v.scale(@sin(theta) * self.radius);
        return self.center.add(cu).add(cv);
    }
};

/// 3D Ellipse in space.
pub const Ellipse3d = struct {
    center: Vec3d,
    normal: Vec3d,
    major_axis: Vec3d, // Length equals semi-major axis a
    minor_axis: Vec3d, // Length equals semi-minor axis b

    pub fn semiMajor(self: Ellipse3d) f64 {
        return self.major_axis.norm();
    }

    pub fn semiMinor(self: Ellipse3d) f64 {
        return self.minor_axis.norm();
    }

    pub fn pointAt(self: Ellipse3d, theta: f64) Vec3d {
        const cu = self.major_axis.scale(@cos(theta));
        const cv = self.minor_axis.scale(@sin(theta));
        return self.center.add(cu).add(cv);
    }
};

// ---------------------------------------------------------------------------
// 2. Intersection Results Data Structures
// ---------------------------------------------------------------------------

pub const IntersectionPoint = struct {
    point: Vec3d,
    uv1: Vec2,
    uv2: Vec2,
};

pub const IntersectionCurve = struct {
    points: []IntersectionPoint,
    is_closed: bool,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *IntersectionCurve) void {
        self.allocator.free(self.points);
        self.* = undefined;
    }
};

pub const PlanePlaneResult = struct {
    line: Line3d,
};

pub const PlaneCylinderResult = union(enum) {
    none,
    circle: Circle3d,
    ellipse: Ellipse3d,
    single_line: Line3d,
    two_lines: struct { line1: Line3d, line2: Line3d },
};

pub const CylinderCylinderResult = union(enum) {
    none,
    parallel_lines: struct { line1: Line3d, line2: ?Line3d },
    planar_ellipses: struct { ellipse1: Ellipse3d, ellipse2: Ellipse3d },
    spatial_curves: struct {
        curve1: IntersectionCurve,
        curve2: ?IntersectionCurve,
    },

    pub fn deinit(self: *CylinderCylinderResult) void {
        switch (self.*) {
            .spatial_curves => |*sc| {
                sc.curve1.deinit();
                if (sc.curve2) |*c2| {
                    c2.deinit();
                }
            },
            else => {},
        }
        self.* = undefined;
    }
};

pub const NurbsSSIResult = struct {
    curves: []IntersectionCurve,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *NurbsSSIResult) void {
        for (self.curves) |*c| {
            c.deinit();
        }
        self.allocator.free(self.curves);
        self.* = undefined;
    }
};

pub const MarchingConfig = struct {
    step_size: f64 = 0.05,
    min_step: f64 = 1e-4,
    max_step: f64 = 0.25,
    max_points: usize = 2000,
    tolerance: f64 = 1e-7,
    grid_samples: usize = 16,
};

// ---------------------------------------------------------------------------
// 3. Linear Algebra Helper (3x3 Gaussian Elimination with Partial Pivoting)
// ---------------------------------------------------------------------------

pub fn solve3x3(M_in: [3][3]f64, b_in: Vec3d) ?Vec3d {
    var a = M_in;
    var b = [3]f64{ b_in.x, b_in.y, b_in.z };

    for (0..3) |k| {
        var max_val = @abs(a[k][k]);
        var pivot_row = k;
        for (k + 1..3) |i| {
            const v = @abs(a[i][k]);
            if (v > max_val) {
                max_val = v;
                pivot_row = i;
            }
        }

        if (max_val < 1e-15) return null;

        if (pivot_row != k) {
            const tmp_row = a[k];
            a[k] = a[pivot_row];
            a[pivot_row] = tmp_row;
            const tmp_b = b[k];
            b[k] = b[pivot_row];
            b[pivot_row] = tmp_b;
        }

        const pivot = a[k][k];
        for (k + 1..3) |i| {
            const factor = a[i][k] / pivot;
            a[i][k] = 0.0;
            for (k + 1..3) |j| {
                a[i][j] -= factor * a[k][j];
            }
            b[i] -= factor * b[k];
        }
    }

    var x: [3]f64 = undefined;
    var i: isize = 2;
    while (i >= 0) : (i -= 1) {
        const row: usize = @intCast(i);
        var sum = b[row];
        var j: usize = row + 1;
        while (j < 3) : (j += 1) {
            sum -= a[row][j] * x[j];
        }
        x[row] = sum / a[row][row];
    }

    return Vec3d.init(x[0], x[1], x[2]);
}

// ---------------------------------------------------------------------------
// 4. Analytical Surface-Surface Intersection Solvers
// ---------------------------------------------------------------------------

/// Analytical SSI: Plane / Plane Intersection.
/// Returns Line3d of intersection P(t) = P0 + t * d, or null if planes are parallel.
pub fn intersectPlanePlane(p1: Plane, p2: Plane) ?PlanePlaneResult {
    const d = p1.normal.cross(p2.normal);
    const len_sq = d.normSq();
    if (len_sq < 1e-20) {
        return null; // Planes are parallel or coincident
    }

    const d_norm = d.scale(1.0 / @sqrt(len_sq));
    const d1 = p1.origin.dot(p1.normal);
    const d2 = p2.origin.dot(p2.normal);
    const c = p1.normal.dot(p2.normal);

    // Exact closed-form point closest to origin on the intersection line
    const p0 = p1.normal.scale(d1 - d2 * c).add(p2.normal.scale(d2 - d1 * c)).scale(1.0 / len_sq);

    return .{
        .line = .{
            .origin = p0,
            .direction = d_norm,
        },
    };
}

/// Analytical SSI: Plane / Cylinder Intersection.
/// Produces Circle (perpendicular cut), Ellipse (angled cut), or Line(s) (axial/tangent cut).
pub fn intersectPlaneCylinder(plane: Plane, cyl: Cylinder) PlaneCylinderResult {
    const N = plane.normal;
    const A = cyl.axis;
    const R = cyl.radius;
    const c_dot = N.dot(A);

    // Case 1: Perpendicular cut (|N . A| >= 1.0 - 1e-11) -> Circle
    if (@abs(c_dot) >= 1.0 - 1e-11) {
        const t = plane.origin.sub(cyl.origin).dot(A);
        const center = cyl.origin.add(A.scale(t));
        return .{
            .circle = Circle3d.init(center, A, R),
        };
    }

    // Case 2: Parallel / Axial cut (|N . A| <= 1e-11) -> Lines
    if (@abs(c_dot) <= 1e-11) {
        const delta = cyl.origin.sub(plane.origin);
        const h = delta.dot(N);
        const abs_h = @abs(h);

        if (abs_h > R + 1e-11) {
            return .none;
        }

        if (@abs(abs_h - R) <= 1e-11) {
            // Tangent plane: 1 line
            const p_tan = cyl.origin.sub(N.scale(h));
            return .{
                .single_line = .{
                    .origin = p_tan,
                    .direction = A,
                },
            };
        }

        // Cutting through: 2 parallel lines
        const w = @sqrt(@max(0.0, R * R - h * h));
        const M = A.cross(N).normalize();
        const p_mid = cyl.origin.sub(N.scale(h));
        return .{
            .two_lines = .{
                .line1 = .{
                    .origin = p_mid.add(M.scale(w)),
                    .direction = A,
                },
                .line2 = .{
                    .origin = p_mid.sub(M.scale(w)),
                    .direction = A,
                },
            },
        };
    }

    // Case 3: Angled cut -> Ellipse
    const t = plane.origin.sub(cyl.origin).dot(N) / c_dot;
    const center = cyl.origin.add(A.scale(t));

    // Minor axis direction: perpendicular to both A and N
    const M = A.cross(N).normalize();
    const v_minor = M.scale(R);

    // Major axis direction: in the plane, perpendicular to minor axis and N
    const U_maj = M.cross(N).normalize();
    const a = R / @abs(c_dot);
    const v_major = U_maj.scale(a);

    return .{
        .ellipse = .{
            .center = center,
            .normal = N,
            .major_axis = v_major,
            .minor_axis = v_minor,
        },
    };
}

/// Analytical SSI: Cylinder / Cylinder Intersection.
/// Handles parallel axes (lines) and orthogonal axes (Steinmetz planar ellipses or spatial Viviani curves).
pub fn intersectCylinderCylinder(allocator: std.mem.Allocator, cyl1: Cylinder, cyl2: Cylinder) !CylinderCylinderResult {
    const A1 = cyl1.axis;
    const A2 = cyl2.axis;
    const cross_axes = A1.cross(A2);
    const cross_norm = cross_axes.norm();

    // Case 1: Parallel axes
    if (cross_norm < 1e-11) {
        const delta = cyl2.origin.sub(cyl1.origin);
        const t = delta.dot(A1);
        const delta_perp = delta.sub(A1.scale(t));
        const d = delta_perp.norm();
        const R1 = cyl1.radius;
        const R2 = cyl2.radius;

        if (d > R1 + R2 + 1e-11 or d < @abs(R1 - R2) - 1e-11) {
            return .none;
        }

        if (@abs(d - (R1 + R2)) <= 1e-11 or @abs(d - @abs(R1 - R2)) <= 1e-11) {
            const U = if (d > 1e-14) delta_perp.scale(1.0 / d) else Vec3d.init(1, 0, 0);
            const p_tan = cyl1.origin.add(U.scale(R1));
            return .{
                .parallel_lines = .{
                    .line1 = .{ .origin = p_tan, .direction = A1 },
                    .line2 = null,
                },
            };
        }

        const U = delta_perp.scale(1.0 / d);
        const V = A1.cross(U).normalize();
        const x = (d * d - R2 * R2 + R1 * R1) / (2.0 * d);
        const y = @sqrt(@max(0.0, R1 * R1 - x * x));

        const p1 = cyl1.origin.add(U.scale(x)).add(V.scale(y));
        const p2 = cyl1.origin.add(U.scale(x)).sub(V.scale(y));

        return .{
            .parallel_lines = .{
                .line1 = .{ .origin = p1, .direction = A1 },
                .line2 = .{ .origin = p2, .direction = A1 },
            },
        };
    }

    // Case 2: Orthogonal axes (|A1 . A2| <= 1e-11)
    if (@abs(A1.dot(A2)) <= 1e-11) {
        const delta = cyl2.origin.sub(cyl1.origin);
        const s0 = delta.dot(A1);
        const t0 = -delta.dot(A2);

        const Q1 = cyl1.origin.add(A1.scale(s0));
        const Q2 = cyl2.origin.add(A2.scale(t0));
        const A3 = cross_axes.normalize();
        const h = Q2.sub(Q1).dot(A3);

        const R1 = cyl1.radius;
        const R2 = cyl2.radius;

        // Subcase 2A: Intersecting axes (h == 0) and identical radius (R1 == R2) -> 2 Planar Ellipses (Steinmetz)
        if (@abs(h) <= 1e-11 and @abs(R1 - R2) <= 1e-11) {
            const P0 = Q1;
            const v_maj1 = A2.add(A1).scale(R1);
            const v_min1 = A3.scale(R1);
            const n1 = A1.sub(A2).normalize();

            const v_maj2 = A2.sub(A1).scale(R1);
            const v_min2 = A3.scale(R1);
            const n2 = A1.add(A2).normalize();

            return .{
                .planar_ellipses = .{
                    .ellipse1 = .{
                        .center = P0,
                        .normal = n1,
                        .major_axis = v_maj1,
                        .minor_axis = v_min1,
                    },
                    .ellipse2 = .{
                        .center = P0,
                        .normal = n2,
                        .major_axis = v_maj2,
                        .minor_axis = v_min2,
                    },
                },
            };
        }

        // Subcase 2B: Orthogonal with different radii or offset -> Analytical spatial curves
        // If R1 <= R2: Parameterize around cylinder 1
        // (y - h)^2 + z^2 = R2^2 where y = R1 * sin(theta), x = R1 * cos(theta)
        // z = +/- sqrt(R2^2 - (R1 * sin(theta) - h)^2)
        const swapped = R1 > R2;
        const r_inner = if (swapped) R2 else R1;
        const r_outer = if (swapped) R1 else R2;
        const ax_inner = if (swapped) A2 else A1;
        const ax_outer = if (swapped) A1 else A2;
        const q_inner = if (swapped) Q2 else Q1;
        const h_eff = if (swapped) -h else h;

        if (@abs(h_eff) - r_inner > r_outer + 1e-11) {
            return .none;
        }

        const num_pts = 128;
        var pts1 = try allocator.alloc(IntersectionPoint, num_pts);
        errdefer allocator.free(pts1);
        var pts2 = try allocator.alloc(IntersectionPoint, num_pts);
        errdefer allocator.free(pts2);

        for (0..num_pts) |idx| {
            const theta = (@as(f64, @floatFromInt(idx)) / @as(f64, @floatFromInt(num_pts))) * 2.0 * std.math.pi;
            const cos_t = @cos(theta);
            const sin_t = @sin(theta);
            const y = r_inner * sin_t;
            const x = r_inner * cos_t;
            const radicand = @max(0.0, r_outer * r_outer - (y - h_eff) * (y - h_eff));
            const z = @sqrt(radicand);

            const pt1 = q_inner.add(ax_outer.scale(x)).add(A3.scale(y)).add(ax_inner.scale(z));
            const pt2 = q_inner.add(ax_outer.scale(x)).add(A3.scale(y)).sub(ax_inner.scale(z));

            pts1[idx] = .{
                .point = pt1,
                .uv1 = Vec2.init(theta / (2.0 * std.math.pi), z),
                .uv2 = Vec2.init(std.math.atan2(z, y - h_eff) / (2.0 * std.math.pi), x),
            };
            pts2[idx] = .{
                .point = pt2,
                .uv1 = Vec2.init(theta / (2.0 * std.math.pi), -z),
                .uv2 = Vec2.init(std.math.atan2(-z, y - h_eff) / (2.0 * std.math.pi), x),
            };
        }

        return .{
            .spatial_curves = .{
                .curve1 = .{
                    .points = pts1,
                    .is_closed = true,
                    .allocator = allocator,
                },
                .curve2 = .{
                    .points = pts2,
                    .is_closed = true,
                    .allocator = allocator,
                },
            },
        };
    }

    return .none;
}

// ---------------------------------------------------------------------------
// 5. 4-Variable Newton-Raphson SSI Corrector & Boundary Solver
// ---------------------------------------------------------------------------

pub const State4D = struct {
    u1: f64,
    v1: f64,
    u2: f64,
    v2: f64,
};

/// 4-Variable Minimum Norm Pseudo-Inverse Newton-Raphson Corrector.
/// Solves S1(u1, v1) - S2(u2, v2) = 0 by taking minimum-norm steps in the normal plane.
pub fn correct4D(
    s1: *const NurbsSurface,
    s2: *const NurbsSurface,
    init_state: State4D,
    tol: f64,
    max_iters: u32,
) ?struct { state: State4D, pt: Vec3d } {
    var cur = init_state;
    const dom1 = s1.getDomain();
    const dom2 = s2.getDomain();

    var iter: u32 = 0;
    while (iter < max_iters) : (iter += 1) {
        const d1 = s1.evaluateDerivatives(cur.u1, cur.v1);
        const d2 = s2.evaluateDerivatives(cur.u2, cur.v2);

        const R = d1.point.sub(d2.point);
        const res_norm = R.norm();
        if (res_norm <= tol) {
            const mid_pt = d1.point.add(d2.point).scale(0.5);
            return .{ .state = cur, .pt = mid_pt };
        }

        // Columns of 3x4 Jacobian J = [S1_u, S1_v, -S2_u, -S2_v]
        const c0 = d1.d_u;
        const c1 = d1.d_v;
        const c2 = d2.d_u.scale(-1.0);
        const c3 = d2.d_v.scale(-1.0);

        // M = J * J^T (3x3 symmetric matrix)
        var M: [3][3]f64 = undefined;
        M[0][0] = c0.x * c0.x + c1.x * c1.x + c2.x * c2.x + c3.x * c3.x;
        M[0][1] = c0.x * c0.y + c1.x * c1.y + c2.x * c2.y + c3.x * c3.y;
        M[0][2] = c0.x * c0.z + c1.x * c1.z + c2.x * c2.z + c3.x * c3.z;

        M[1][0] = M[0][1];
        M[1][1] = c0.y * c0.y + c1.y * c1.y + c2.y * c2.y + c3.y * c3.y;
        M[1][2] = c0.y * c0.z + c1.y * c1.z + c2.y * c2.z + c3.y * c3.z;

        M[2][0] = M[0][2];
        M[2][1] = M[1][2];
        M[2][2] = c0.z * c0.z + c1.z * c1.z + c2.z * c2.z + c3.z * c3.z;

        // Levenberg-Marquardt diagonal regularizer
        const trace = M[0][0] + M[1][1] + M[2][2];
        const damp = 1e-12 * (trace + 1.0);
        M[0][0] += damp;
        M[1][1] += damp;
        M[2][2] += damp;

        const Y = solve3x3(M, R) orelse return null;

        // Delta X = - J^T * Y
        var du1 = -c0.dot(Y);
        var dv1 = -c1.dot(Y);
        var du2 = -c2.dot(Y);
        var dv2 = -c3.dot(Y);

        // Damp oversized steps
        const max_step = 0.5;
        const max_delta = @max(@max(@abs(du1), @abs(dv1)), @max(@abs(du2), @abs(dv2)));
        if (max_delta > max_step) {
            const factor = max_step / max_delta;
            du1 *= factor;
            dv1 *= factor;
            du2 *= factor;
            dv2 *= factor;
        }

        cur.u1 = std.math.clamp(cur.u1 + du1, dom1.u_min, dom1.u_max);
        cur.v1 = std.math.clamp(cur.v1 + dv1, dom1.v_min, dom1.v_max);
        cur.u2 = std.math.clamp(cur.u2 + du2, dom2.u_min, dom2.u_max);
        cur.v2 = std.math.clamp(cur.v2 + dv2, dom2.v_min, dom2.v_max);
    }

    return null;
}

/// 3-Variable Newton-Raphson Solver on a fixed domain boundary coordinate.
/// Solves S1 - S2 = 0 with one coordinate fixed on a domain boundary.
pub fn correctBoundary(
    s1: *const NurbsSurface,
    s2: *const NurbsSurface,
    state: State4D,
    fixed_coord: usize, // 0: u1, 1: v1, 2: u2, 3: v2
    tol: f64,
) ?struct { state: State4D, pt: Vec3d } {
    var cur = state;
    const dom1 = s1.getDomain();
    const dom2 = s2.getDomain();

    var iter: u32 = 0;
    while (iter < 10) : (iter += 1) {
        const d1 = s1.evaluateDerivatives(cur.u1, cur.v1);
        const d2 = s2.evaluateDerivatives(cur.u2, cur.v2);

        const R = d1.point.sub(d2.point);
        if (R.norm() <= tol) {
            return .{ .state = cur, .pt = d1.point.add(d2.point).scale(0.5) };
        }

        var J: [3][3]f64 = undefined;
        const neg_s2u = d2.d_u.scale(-1.0);
        const neg_s2v = d2.d_v.scale(-1.0);

        const cols: [3]Vec3d = switch (fixed_coord) {
            0 => .{ d1.d_v, neg_s2u, neg_s2v },
            1 => .{ d1.d_u, neg_s2u, neg_s2v },
            2 => .{ d1.d_u, d1.d_v, neg_s2v },
            3 => .{ d1.d_u, d1.d_v, neg_s2u },
            else => unreachable,
        };

        for (0..3) |r| {
            J[r][0] = if (r == 0) cols[0].x else if (r == 1) cols[0].y else cols[0].z;
            J[r][1] = if (r == 0) cols[1].x else if (r == 1) cols[1].y else cols[1].z;
            J[r][2] = if (r == 0) cols[2].x else if (r == 1) cols[2].y else cols[2].z;
        }

        const delta = solve3x3(J, R.scale(-1.0)) orelse return null;

        switch (fixed_coord) {
            0 => {
                cur.v1 = std.math.clamp(cur.v1 + delta.x, dom1.v_min, dom1.v_max);
                cur.u2 = std.math.clamp(cur.u2 + delta.y, dom2.u_min, dom2.u_max);
                cur.v2 = std.math.clamp(cur.v2 + delta.z, dom2.v_min, dom2.v_max);
            },
            1 => {
                cur.u1 = std.math.clamp(cur.u1 + delta.x, dom1.u_min, dom1.u_max);
                cur.u2 = std.math.clamp(cur.u2 + delta.y, dom2.u_min, dom2.u_max);
                cur.v2 = std.math.clamp(cur.v2 + delta.z, dom2.v_min, dom2.v_max);
            },
            2 => {
                cur.u1 = std.math.clamp(cur.u1 + delta.x, dom1.u_min, dom1.u_max);
                cur.v1 = std.math.clamp(cur.v1 + delta.y, dom1.v_min, dom1.v_max);
                cur.v2 = std.math.clamp(cur.v2 + delta.z, dom2.v_min, dom2.v_max);
            },
            3 => {
                cur.u1 = std.math.clamp(cur.u1 + delta.x, dom1.u_min, dom1.u_max);
                cur.v1 = std.math.clamp(cur.v1 + delta.y, dom1.v_min, dom1.v_max);
                cur.u2 = std.math.clamp(cur.u2 + delta.z, dom2.u_min, dom2.u_max);
            },
            else => unreachable,
        }
    }

    return null;
}

// ---------------------------------------------------------------------------
// 6. Tangent & Parameter Space Direction Computation
// ---------------------------------------------------------------------------

pub const TangentResult = struct {
    t_3d: Vec3d,
    dot_u1: f64,
    dot_v1: f64,
    dot_u2: f64,
    dot_v2: f64,
};

pub fn computeCurveTangent(
    d1: SurfaceDerivatives,
    d2: SurfaceDerivatives,
) ?TangentResult {
    const cross_n = d1.normal.cross(d2.normal);
    const len = cross_n.norm();
    if (len < 1e-11) return null; // Surfaces are tangent

    const T = cross_n.scale(1.0 / len);

    // Solve for parameter velocity on Surface 1: [E1, F1; F1, G1] * [u1'; v1'] = [T . S1_u; T . S1_v]
    const E1 = d1.d_u.normSq();
    const F1 = d1.d_u.dot(d1.d_v);
    const G1 = d1.d_v.normSq();
    const det1 = E1 * G1 - F1 * F1;
    if (det1 < 1e-15) return null;

    const r1u = T.dot(d1.d_u);
    const r1v = T.dot(d1.d_v);
    const dot_u1 = (G1 * r1u - F1 * r1v) / det1;
    const dot_v1 = (E1 * r1v - F1 * r1u) / det1;

    // Solve for parameter velocity on Surface 2: [E2, F2; F2, G2] * [u2'; v2'] = [T . S2_u; T . S2_v]
    const E2 = d2.d_u.normSq();
    const F2 = d2.d_u.dot(d2.d_v);
    const G2 = d2.d_v.normSq();
    const det2 = E2 * G2 - F2 * F2;
    if (det2 < 1e-15) return null;

    const r2u = T.dot(d2.d_u);
    const r2v = T.dot(d2.d_v);
    const dot_u2 = (G2 * r2u - F2 * r2v) / det2;
    const dot_v2 = (E2 * r2v - F2 * r2u) / det2;

    return .{
        .t_3d = T,
        .dot_u1 = dot_u1,
        .dot_v1 = dot_v1,
        .dot_u2 = dot_u2,
        .dot_v2 = dot_v2,
    };
}

// ---------------------------------------------------------------------------
// 7. Marching NURBS-NURBS Surface-Surface Intersection
// ---------------------------------------------------------------------------

pub fn intersectNurbsNurbs(
    allocator: std.mem.Allocator,
    s1: *const NurbsSurface,
    s2: *const NurbsSurface,
    config: MarchingConfig,
) !NurbsSSIResult {
    const b1 = s1.getBounds();
    const b2 = s2.getBounds();
    const margin = config.tolerance + 1e-4;

    // Fast bounding box intersection test
    if (b1.max.x < b2.min.x - margin or b1.min.x > b2.max.x + margin or
        b1.max.y < b2.min.y - margin or b1.min.y > b2.max.y + margin or
        b1.max.z < b2.min.z - margin or b1.min.z > b2.max.z + margin)
    {
        return .{
            .curves = try allocator.alloc(IntersectionCurve, 0),
            .allocator = allocator,
        };
    }

    const dom1 = s1.getDomain();
    const dom2 = s2.getDomain();

    // 1. Gather starting seeds via domain sampling and projection
    var candidate_seeds = std.ArrayList(State4D).empty;
    defer candidate_seeds.deinit(allocator);

    const N = config.grid_samples;
    for (0..N + 1) |i| {
        const sample_u1 = dom1.u_min + (@as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(N))) * (dom1.u_max - dom1.u_min);
        for (0..N + 1) |j| {
            const sample_v1 = dom1.v_min + (@as(f64, @floatFromInt(j)) / @as(f64, @floatFromInt(N))) * (dom1.v_max - dom1.v_min);
            const p1 = s1.evaluate(sample_u1, sample_v1);

            // Fast distance check against surface 2 AABB
            const dx = @max(0.0, @max(b2.min.x - p1.x, p1.x - b2.max.x));
            const dy = @max(0.0, @max(b2.min.y - p1.y, p1.y - b2.max.y));
            const dz = @max(0.0, @max(b2.min.z - p1.z, p1.z - b2.max.z));
            const box_dist = @sqrt(dx * dx + dy * dy + dz * dz);
            if (box_dist > 0.5) continue;

            const proj = s2.projectPoint(p1, 20, 1e-5);

            if (proj.distance < 1.0) {
                const init_s = State4D{ .u1 = sample_u1, .v1 = sample_v1, .u2 = proj.u, .v2 = proj.v };
                if (correct4D(s1, s2, init_s, config.tolerance, 15)) |corr| {
                    // Check if inside domain
                    if (corr.state.u1 >= dom1.u_min and corr.state.u1 <= dom1.u_max and
                        corr.state.v1 >= dom1.v_min and corr.state.v1 <= dom1.v_max and
                        corr.state.u2 >= dom2.u_min and corr.state.u2 <= dom2.u_max and
                        corr.state.v2 >= dom2.v_min and corr.state.v2 <= dom2.v_max)
                    {
                        var is_dup = false;
                        for (candidate_seeds.items) |existing| {
                            const p_ex = s1.evaluate(existing.u1, existing.v1);
                            if (p_ex.dist(corr.pt) < config.step_size * 0.8) {
                                is_dup = true;
                                break;
                            }
                        }
                        if (!is_dup) {
                            try candidate_seeds.append(allocator, corr.state);
                        }
                    }
                }
            }
        }
    }

    var result_curves = std.ArrayList(IntersectionCurve).empty;
    errdefer {
        for (result_curves.items) |*c| {
            c.deinit();
        }
        result_curves.deinit(allocator);
    }

    // 2. March along each seed
    for (candidate_seeds.items) |seed| {
        const p_seed = s1.evaluate(seed.u1, seed.v1);

        // Check if seed is already covered by a previously traced curve
        var already_covered = false;
        for (result_curves.items) |*existing_curve| {
            for (existing_curve.points) |cp| {
                if (cp.point.dist(p_seed) < config.step_size * 0.8) {
                    already_covered = true;
                    break;
                }
            }
            if (already_covered) break;
        }
        if (already_covered) continue;

        const d1_0 = s1.evaluateDerivatives(seed.u1, seed.v1);
        const d2_0 = s2.evaluateDerivatives(seed.u2, seed.v2);
        const init_tan = computeCurveTangent(d1_0, d2_0) orelse continue;

        // March Forward (+T)
        var forward_pts = std.ArrayList(IntersectionPoint).empty;
        defer forward_pts.deinit(allocator);

        try forward_pts.append(allocator, .{
            .point = p_seed,
            .uv1 = Vec2.init(seed.u1, seed.v1),
            .uv2 = Vec2.init(seed.u2, seed.v2),
        });

        var cur_state = seed;
        var cur_tan = init_tan;
        var step_h = config.step_size;
        var is_closed = false;

        var f_step: usize = 0;
        while (f_step < config.max_points) : (f_step += 1) {
            // Predict
            const next_u1 = cur_state.u1 + step_h * cur_tan.dot_u1;
            const next_v1 = cur_state.v1 + step_h * cur_tan.dot_v1;
            const next_u2 = cur_state.u2 + step_h * cur_tan.dot_u2;
            const next_v2 = cur_state.v2 + step_h * cur_tan.dot_v2;

            // Check if boundary crossed
            var hit_boundary = false;
            var bound_coord: usize = 0;
            var bound_val: f64 = 0.0;

            if (next_u1 < dom1.u_min or next_u1 > dom1.u_max) {
                hit_boundary = true;
                bound_coord = 0;
                bound_val = if (next_u1 < dom1.u_min) dom1.u_min else dom1.u_max;
            } else if (next_v1 < dom1.v_min or next_v1 > dom1.v_max) {
                hit_boundary = true;
                bound_coord = 1;
                bound_val = if (next_v1 < dom1.v_min) dom1.v_min else dom1.v_max;
            } else if (next_u2 < dom2.u_min or next_u2 > dom2.u_max) {
                hit_boundary = true;
                bound_coord = 2;
                bound_val = if (next_u2 < dom2.u_min) dom2.u_min else dom2.u_max;
            } else if (next_v2 < dom2.v_min or next_v2 > dom2.v_max) {
                hit_boundary = true;
                bound_coord = 3;
                bound_val = if (next_v2 < dom2.v_min) dom2.v_min else dom2.v_max;
            }

            if (hit_boundary) {
                var clamped_state = State4D{
                    .u1 = next_u1,
                    .v1 = next_v1,
                    .u2 = next_u2,
                    .v2 = next_v2,
                };
                if (bound_coord == 0) clamped_state.u1 = bound_val;
                if (bound_coord == 1) clamped_state.v1 = bound_val;
                if (bound_coord == 2) clamped_state.u2 = bound_val;
                if (bound_coord == 3) clamped_state.v2 = bound_val;

                if (correctBoundary(s1, s2, clamped_state, bound_coord, config.tolerance)) |bound_corr| {
                    try forward_pts.append(allocator, .{
                        .point = bound_corr.pt,
                        .uv1 = Vec2.init(bound_corr.state.u1, bound_corr.state.v1),
                        .uv2 = Vec2.init(bound_corr.state.u2, bound_corr.state.v2),
                    });
                }
                break;
            }

            // Correct
            const pred_state = State4D{ .u1 = next_u1, .v1 = next_v1, .u2 = next_u2, .v2 = next_v2 };
            if (correct4D(s1, s2, pred_state, config.tolerance, 12)) |corr| {
                // Check loop closure
                if (forward_pts.items.len > 5 and corr.pt.dist(p_seed) < step_h * 1.5) {
                    is_closed = true;
                    try forward_pts.append(allocator, .{
                        .point = p_seed,
                        .uv1 = Vec2.init(seed.u1, seed.v1),
                        .uv2 = Vec2.init(seed.u2, seed.v2),
                    });
                    break;
                }

                try forward_pts.append(allocator, .{
                    .point = corr.pt,
                    .uv1 = Vec2.init(corr.state.u1, corr.state.v1),
                    .uv2 = Vec2.init(corr.state.u2, corr.state.v2),
                });

                cur_state = corr.state;
                const d1_next = s1.evaluateDerivatives(cur_state.u1, cur_state.v1);
                const d2_next = s2.evaluateDerivatives(cur_state.u2, cur_state.v2);
                if (computeCurveTangent(d1_next, d2_next)) |new_tan| {
                    if (new_tan.t_3d.dot(cur_tan.t_3d) < 0.0) {
                        cur_tan = .{
                            .t_3d = new_tan.t_3d.scale(-1.0),
                            .dot_u1 = -new_tan.dot_u1,
                            .dot_v1 = -new_tan.dot_v1,
                            .dot_u2 = -new_tan.dot_u2,
                            .dot_v2 = -new_tan.dot_v2,
                        };
                    } else {
                        cur_tan = new_tan;
                    }
                } else break;
            } else {
                step_h *= 0.5;
                if (step_h < config.min_step) break;
            }
        }

        // March Backward (-T) if open curve
        var backward_pts = std.ArrayList(IntersectionPoint).empty;
        defer backward_pts.deinit(allocator);

        if (!is_closed) {
            cur_state = seed;
            cur_tan = .{
                .t_3d = init_tan.t_3d.scale(-1.0),
                .dot_u1 = -init_tan.dot_u1,
                .dot_v1 = -init_tan.dot_v1,
                .dot_u2 = -init_tan.dot_u2,
                .dot_v2 = -init_tan.dot_v2,
            };
            step_h = config.step_size;

            var b_step: usize = 0;
            while (b_step < config.max_points) : (b_step += 1) {
                const next_u1 = cur_state.u1 + step_h * cur_tan.dot_u1;
                const next_v1 = cur_state.v1 + step_h * cur_tan.dot_v1;
                const next_u2 = cur_state.u2 + step_h * cur_tan.dot_u2;
                const next_v2 = cur_state.v2 + step_h * cur_tan.dot_v2;

                var hit_boundary = false;
                var bound_coord: usize = 0;
                var bound_val: f64 = 0.0;

                if (next_u1 < dom1.u_min or next_u1 > dom1.u_max) {
                    hit_boundary = true;
                    bound_coord = 0;
                    bound_val = if (next_u1 < dom1.u_min) dom1.u_min else dom1.u_max;
                } else if (next_v1 < dom1.v_min or next_v1 > dom1.v_max) {
                    hit_boundary = true;
                    bound_coord = 1;
                    bound_val = if (next_v1 < dom1.v_min) dom1.v_min else dom1.v_max;
                } else if (next_u2 < dom2.u_min or next_u2 > dom2.u_max) {
                    hit_boundary = true;
                    bound_coord = 2;
                    bound_val = if (next_u2 < dom2.u_min) dom2.u_min else dom2.u_max;
                } else if (next_v2 < dom2.v_min or next_v2 > dom2.v_max) {
                    hit_boundary = true;
                    bound_coord = 3;
                    bound_val = if (next_v2 < dom2.v_min) dom2.v_min else dom2.v_max;
                }

                if (hit_boundary) {
                    var clamped_state = State4D{
                        .u1 = next_u1,
                        .v1 = next_v1,
                        .u2 = next_u2,
                        .v2 = next_v2,
                    };
                    if (bound_coord == 0) clamped_state.u1 = bound_val;
                    if (bound_coord == 1) clamped_state.v1 = bound_val;
                    if (bound_coord == 2) clamped_state.u2 = bound_val;
                    if (bound_coord == 3) clamped_state.v2 = bound_val;

                    if (correctBoundary(s1, s2, clamped_state, bound_coord, config.tolerance)) |bound_corr| {
                        try backward_pts.append(allocator, .{
                            .point = bound_corr.pt,
                            .uv1 = Vec2.init(bound_corr.state.u1, bound_corr.state.v1),
                            .uv2 = Vec2.init(bound_corr.state.u2, bound_corr.state.v2),
                        });
                    }
                    break;
                }

                const pred_state = State4D{ .u1 = next_u1, .v1 = next_v1, .u2 = next_u2, .v2 = next_v2 };
                if (correct4D(s1, s2, pred_state, config.tolerance, 12)) |corr| {
                    try backward_pts.append(allocator, .{
                        .point = corr.pt,
                        .uv1 = Vec2.init(corr.state.u1, corr.state.v1),
                        .uv2 = Vec2.init(corr.state.u2, corr.state.v2),
                    });

                    cur_state = corr.state;
                    const d1_next = s1.evaluateDerivatives(cur_state.u1, cur_state.v1);
                    const d2_next = s2.evaluateDerivatives(cur_state.u2, cur_state.v2);
                    if (computeCurveTangent(d1_next, d2_next)) |new_tan| {
                        if (new_tan.t_3d.dot(cur_tan.t_3d) < 0.0) {
                            cur_tan = .{
                                .t_3d = new_tan.t_3d.scale(-1.0),
                                .dot_u1 = -new_tan.dot_u1,
                                .dot_v1 = -new_tan.dot_v1,
                                .dot_u2 = -new_tan.dot_u2,
                                .dot_v2 = -new_tan.dot_v2,
                            };
                        } else {
                            cur_tan = new_tan;
                        }
                    } else break;
                } else {
                    step_h *= 0.5;
                    if (step_h < config.min_step) break;
                }
            }
        }

        // Combine points: reversed(backward_pts) + forward_pts
        const total_count = backward_pts.items.len + forward_pts.items.len;
        if (total_count < 2) continue;

        const merged_points = try allocator.alloc(IntersectionPoint, total_count);
        var write_idx: usize = 0;

        if (backward_pts.items.len > 0) {
            var rev_idx: isize = @as(isize, @intCast(backward_pts.items.len)) - 1;
            while (rev_idx >= 0) : (rev_idx -= 1) {
                merged_points[write_idx] = backward_pts.items[@intCast(rev_idx)];
                write_idx += 1;
            }
        }

        for (forward_pts.items) |pt| {
            merged_points[write_idx] = pt;
            write_idx += 1;
        }

        // Check if endpoints coincide in 3D (closed loop across seam)
        if (!is_closed and merged_points.len > 4) {
            const first_p = merged_points[0].point;
            const last_p = merged_points[merged_points.len - 1].point;
            if (first_p.dist(last_p) < config.step_size * 1.5) {
                is_closed = true;
            }
        }

        try result_curves.append(allocator, .{
            .points = merged_points,
            .is_closed = is_closed,
            .allocator = allocator,
        });
    }

    return .{
        .curves = try result_curves.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

// ---------------------------------------------------------------------------
// 8. Unit Tests
// ---------------------------------------------------------------------------

test "SSI: Plane-Plane Intersection" {
    // 1. Orthogonal planes: Z = 0 and X = 0
    const p1 = Plane.init(Vec3d.init(0, 0, 0), Vec3d.init(0, 0, 1));
    const p2 = Plane.init(Vec3d.init(0, 0, 0), Vec3d.init(1, 0, 0));
    const res = intersectPlanePlane(p1, p2).?;

    // Direction must be along Y axis (+/-)
    try std.testing.expectApproxEqAbs(0.0, res.line.direction.x, 1e-12);
    try std.testing.expectApproxEqAbs(1.0, @abs(res.line.direction.y), 1e-12);
    try std.testing.expectApproxEqAbs(0.0, res.line.direction.z, 1e-12);

    // Origin must be on line X=0, Z=0
    try std.testing.expectApproxEqAbs(0.0, res.line.origin.x, 1e-12);
    try std.testing.expectApproxEqAbs(0.0, res.line.origin.z, 1e-12);

    // 2. Parallel planes: Z = 0 and Z = 5
    const p3 = Plane.init(Vec3d.init(0, 0, 5), Vec3d.init(0, 0, 1));
    try std.testing.expect(intersectPlanePlane(p1, p3) == null);

    // 3. Tilted planes: Z = 2 and X + Y = 4
    const p4 = Plane.init(Vec3d.init(0, 0, 2), Vec3d.init(0, 0, 1));
    const p5 = Plane.init(Vec3d.init(2, 2, 0), Vec3d.init(1, 1, 0));
    const res_tilted = intersectPlanePlane(p4, p5).?;

    // Check that points on the resulting line satisfy both plane equations
    const test_ts = [_]f64{ -5.0, -1.0, 0.0, 2.5, 10.0 };
    for (test_ts) |t| {
        const pt = res_tilted.line.pointAt(t);
        try std.testing.expectApproxEqAbs(0.0, p4.distanceToPoint(pt), 1e-12);
        try std.testing.expectApproxEqAbs(0.0, p5.distanceToPoint(pt), 1e-12);
    }
}

test "SSI: Plane-Cylinder Intersection" {
    const R: f64 = 4.0;
    const cyl = Cylinder.init(Vec3d.init(0, 0, 0), Vec3d.init(0, 0, 1), R);

    // 1. Perpendicular cut: Z = 3 -> Circle of radius 4.0
    const p_perp = Plane.init(Vec3d.init(0, 0, 3), Vec3d.init(0, 0, 1));
    const res_circle = intersectPlaneCylinder(p_perp, cyl);
    switch (res_circle) {
        .circle => |c| {
            try std.testing.expectApproxEqAbs(3.0, c.center.z, 1e-12);
            try std.testing.expectApproxEqAbs(R, c.radius, 1e-12);
            // Verify sampled points on circle satisfy cylinder and plane equations
            for (0..12) |idx| {
                const theta = (@as(f64, @floatFromInt(idx)) / 12.0) * 2.0 * std.math.pi;
                const pt = c.pointAt(theta);
                try std.testing.expectApproxEqAbs(3.0, pt.z, 1e-12);
                try std.testing.expectApproxEqAbs(0.0, cyl.distanceToPoint(pt), 1e-12);
            }
        },
        else => try std.testing.expect(false),
    }

    // 2. Angled cut: Z = X (Plane normal (-1, 0, 1) / sqrt(2)) -> Ellipse
    const p_angled = Plane.init(Vec3d.init(0, 0, 0), Vec3d.init(-1, 0, 1));
    const res_ellipse = intersectPlaneCylinder(p_angled, cyl);
    switch (res_ellipse) {
        .ellipse => |el| {
            try std.testing.expectApproxEqAbs(0.0, el.center.x, 1e-12);
            try std.testing.expectApproxEqAbs(0.0, el.center.y, 1e-12);
            try std.testing.expectApproxEqAbs(0.0, el.center.z, 1e-12);
            try std.testing.expectApproxEqAbs(R, el.semiMinor(), 1e-12);
            try std.testing.expectApproxEqAbs(R * @sqrt(2.0), el.semiMajor(), 1e-12);

            for (0..16) |idx| {
                const theta = (@as(f64, @floatFromInt(idx)) / 16.0) * 2.0 * std.math.pi;
                const pt = el.pointAt(theta);
                try std.testing.expectApproxEqAbs(0.0, p_angled.distanceToPoint(pt), 1e-12);
                try std.testing.expectApproxEqAbs(0.0, cyl.distanceToPoint(pt), 1e-12);
            }
        },
        else => try std.testing.expect(false),
    }

    // 3. Tangent cut: X = 4 -> 1 line at X = 4, Y = 0
    const p_tan = Plane.init(Vec3d.init(4, 0, 0), Vec3d.init(1, 0, 0));
    const res_tan = intersectPlaneCylinder(p_tan, cyl);
    switch (res_tan) {
        .single_line => |l| {
            try std.testing.expectApproxEqAbs(4.0, l.origin.x, 1e-12);
            try std.testing.expectApproxEqAbs(0.0, l.origin.y, 1e-12);
            try std.testing.expectApproxEqAbs(1.0, @abs(l.direction.z), 1e-12);
        },
        else => try std.testing.expect(false),
    }

    // 4. Axial cut through: X = 2 -> 2 lines at X = 2, Y = +/- sqrt(12)
    const p_axial = Plane.init(Vec3d.init(2, 0, 0), Vec3d.init(1, 0, 0));
    const res_lines = intersectPlaneCylinder(p_axial, cyl);
    switch (res_lines) {
        .two_lines => |lines| {
            const expected_y = @sqrt(16.0 - 4.0); // sqrt(12)
            try std.testing.expectApproxEqAbs(2.0, lines.line1.origin.x, 1e-12);
            try std.testing.expectApproxEqAbs(expected_y, @abs(lines.line1.origin.y), 1e-12);
            try std.testing.expectApproxEqAbs(2.0, lines.line2.origin.x, 1e-12);
            try std.testing.expectApproxEqAbs(expected_y, @abs(lines.line2.origin.y), 1e-12);
        },
        else => try std.testing.expect(false),
    }

    // 5. Disjoint plane: X = 10 -> None
    const p_disjoint = Plane.init(Vec3d.init(10, 0, 0), Vec3d.init(1, 0, 0));
    try std.testing.expect(intersectPlaneCylinder(p_disjoint, cyl) == .none);
}

test "SSI: Cylinder-Cylinder Intersection" {
    // 1. Orthogonal intersecting cylinders of identical radius (Steinmetz solid)
    // Cylinder 1: axis Z, radius 3.0
    // Cylinder 2: axis X, radius 3.0
    const cyl1 = Cylinder.init(Vec3d.init(0, 0, 0), Vec3d.init(0, 0, 1), 3.0);
    const cyl2 = Cylinder.init(Vec3d.init(0, 0, 0), Vec3d.init(1, 0, 0), 3.0);

    var res_steinmetz = try intersectCylinderCylinder(std.testing.allocator, cyl1, cyl2);
    defer res_steinmetz.deinit();

    switch (res_steinmetz) {
        .planar_ellipses => |el| {
            // Verify points on both ellipses satisfy both cylinders
            for (0..20) |idx| {
                const theta = (@as(f64, @floatFromInt(idx)) / 20.0) * 2.0 * std.math.pi;
                const pt1 = el.ellipse1.pointAt(theta);
                const pt2 = el.ellipse2.pointAt(theta);

                try std.testing.expectApproxEqAbs(0.0, cyl1.distanceToPoint(pt1), 1e-12);
                try std.testing.expectApproxEqAbs(0.0, cyl2.distanceToPoint(pt1), 1e-12);

                try std.testing.expectApproxEqAbs(0.0, cyl1.distanceToPoint(pt2), 1e-12);
                try std.testing.expectApproxEqAbs(0.0, cyl2.distanceToPoint(pt2), 1e-12);
            }
        },
        else => try std.testing.expect(false),
    }

    // 2. Parallel intersecting cylinders:
    // Cyl 1: origin (0, 0, 0), radius 5.0
    // Cyl 2: origin (6, 0, 0), radius 5.0
    const cyl3 = Cylinder.init(Vec3d.init(0, 0, 0), Vec3d.init(0, 0, 1), 5.0);
    const cyl4 = Cylinder.init(Vec3d.init(6, 0, 0), Vec3d.init(0, 0, 1), 5.0);

    var res_parallel = try intersectCylinderCylinder(std.testing.allocator, cyl3, cyl4);
    defer res_parallel.deinit();

    switch (res_parallel) {
        .parallel_lines => |lines| {
            // Distance d = 6, x = 3, y = 4 (since 3^2 + 4^2 = 25)
            try std.testing.expectApproxEqAbs(3.0, lines.line1.origin.x, 1e-12);
            try std.testing.expectApproxEqAbs(4.0, @abs(lines.line1.origin.y), 1e-12);

            const l2 = lines.line2.?;
            try std.testing.expectApproxEqAbs(3.0, l2.origin.x, 1e-12);
            try std.testing.expectApproxEqAbs(4.0, @abs(l2.origin.y), 1e-12);
        },
        else => try std.testing.expect(false),
    }

    // 3. Orthogonal with different radii (R1 = 3, R2 = 5) -> Spatial curves
    const cyl5 = Cylinder.init(Vec3d.init(0, 0, 0), Vec3d.init(0, 0, 1), 3.0);
    const cyl6 = Cylinder.init(Vec3d.init(0, 0, 0), Vec3d.init(1, 0, 0), 5.0);

    var res_spatial = try intersectCylinderCylinder(std.testing.allocator, cyl5, cyl6);
    defer res_spatial.deinit();

    switch (res_spatial) {
        .spatial_curves => |sc| {
            try std.testing.expect(sc.curve1.points.len > 0);
            for (sc.curve1.points) |cp| {
                try std.testing.expectApproxEqAbs(0.0, cyl5.distanceToPoint(cp.point), 1e-12);
                try std.testing.expectApproxEqAbs(0.0, cyl6.distanceToPoint(cp.point), 1e-12);
            }
            if (sc.curve2) |c2| {
                for (c2.points) |cp| {
                    try std.testing.expectApproxEqAbs(0.0, cyl5.distanceToPoint(cp.point), 1e-12);
                    try std.testing.expectApproxEqAbs(0.0, cyl6.distanceToPoint(cp.point), 1e-12);
                }
            }
        },
        else => try std.testing.expect(false),
    }
}

test "SSI: Marching NURBS-NURBS Intersection" {
    // 1. Two intersecting planar Bézier patches
    // Patch 1 in XY plane (Z = 0)
    var p1_pts: [16]Vec3d = undefined;
    for (0..4) |i| {
        for (0..4) |j| {
            const x = -5.0 + (@as(f64, @floatFromInt(i)) / 3.0) * 10.0;
            const y = -5.0 + (@as(f64, @floatFromInt(j)) / 3.0) * 10.0;
            p1_pts[i * 4 + j] = Vec3d.init(x, y, 0.0);
        }
    }
    var patch1 = try NurbsSurface.createBicubicPatch(std.testing.allocator, p1_pts);
    defer patch1.deinit();

    // Patch 2 in YZ plane (X = 0)
    var p2_pts: [16]Vec3d = undefined;
    for (0..4) |i| {
        for (0..4) |j| {
            const z = -5.0 + (@as(f64, @floatFromInt(i)) / 3.0) * 10.0;
            const y = -5.0 + (@as(f64, @floatFromInt(j)) / 3.0) * 10.0;
            p2_pts[i * 4 + j] = Vec3d.init(0.0, y, z);
        }
    }
    var patch2 = try NurbsSurface.createBicubicPatch(std.testing.allocator, p2_pts);
    defer patch2.deinit();

    var ssi_res = try intersectNurbsNurbs(std.testing.allocator, &patch1, &patch2, .{
        .step_size = 0.2,
        .tolerance = 1e-7,
    });
    defer ssi_res.deinit();

    // Must find the intersection line along Y axis (X = 0, Z = 0)
    try std.testing.expect(ssi_res.curves.len > 0);
    const main_curve = ssi_res.curves[0];
    try std.testing.expect(main_curve.points.len >= 5);

    for (main_curve.points) |cp| {
        try std.testing.expectApproxEqAbs(0.0, cp.point.x, 1e-6);
        try std.testing.expectApproxEqAbs(0.0, cp.point.z, 1e-6);
        // Distance between S1(uv1) and S2(uv2) must be <= tolerance
        const s1_p = patch1.evaluate(cp.uv1.x, cp.uv1.y);
        const s2_p = patch2.evaluate(cp.uv2.x, cp.uv2.y);
        try std.testing.expectApproxEqAbs(0.0, s1_p.dist(s2_p), 1e-6);
    }

    // 2. Cylinder NURBS Surface and Cutting Plane Patch
    // Cylinder radius 4.0, height 10.0 centered at (0, 0, 0)
    var cyl_surf = try NurbsSurface.createCylinder(std.testing.allocator, Vec3d.init(0, 0, 0), 4.0, 10.0);
    defer cyl_surf.deinit();

    // Cutting patch at Z = 5.0
    var cut_pts: [16]Vec3d = undefined;
    for (0..4) |i| {
        for (0..4) |j| {
            const x = -6.0 + (@as(f64, @floatFromInt(i)) / 3.0) * 12.0;
            const y = -6.0 + (@as(f64, @floatFromInt(j)) / 3.0) * 12.0;
            cut_pts[i * 4 + j] = Vec3d.init(x, y, 5.0);
        }
    }
    var cut_patch = try NurbsSurface.createBicubicPatch(std.testing.allocator, cut_pts);
    defer cut_patch.deinit();

    var cyl_ssi = try intersectNurbsNurbs(std.testing.allocator, &cyl_surf, &cut_patch, .{
        .step_size = 0.2,
        .tolerance = 1e-7,
    });
    defer cyl_ssi.deinit();

    try std.testing.expect(cyl_ssi.curves.len > 0);
    for (cyl_ssi.curves) |c| {
        for (c.points) |cp| {
            // Must lie on Z = 5.0
            try std.testing.expectApproxEqAbs(5.0, cp.point.z, 1e-5);
            // Must have radius 4.0 from Z axis
            const r = @sqrt(cp.point.x * cp.point.x + cp.point.y * cp.point.y);
            try std.testing.expectApproxEqAbs(4.0, r, 1e-5);
            // S1(uv1) and S2(uv2) must coincide
            const p1 = cyl_surf.evaluate(cp.uv1.x, cp.uv1.y);
            const p2 = cut_patch.evaluate(cp.uv2.x, cp.uv2.y);
            try std.testing.expectApproxEqAbs(0.0, p1.dist(p2), 1e-5);
        }
    }

    // 3. Disjoint NURBS surfaces
    var disjoint_pts: [16]Vec3d = undefined;
    for (0..4) |i| {
        for (0..4) |j| {
            const x = 50.0 + (@as(f64, @floatFromInt(i)) / 3.0) * 5.0;
            const y = 50.0 + (@as(f64, @floatFromInt(j)) / 3.0) * 5.0;
            disjoint_pts[i * 4 + j] = Vec3d.init(x, y, 50.0);
        }
    }
    var disjoint_patch = try NurbsSurface.createBicubicPatch(std.testing.allocator, disjoint_pts);
    defer disjoint_patch.deinit();

    var disjoint_ssi = try intersectNurbsNurbs(std.testing.allocator, &patch1, &disjoint_patch, .{});
    defer disjoint_ssi.deinit();
    try std.testing.expectEqual(@as(usize, 0), disjoint_ssi.curves.len);
}
