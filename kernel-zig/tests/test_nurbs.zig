const std = @import("std");
const testing = std.testing;
const cad = @import("cad_kernel");

const NurbsMod = cad.NurbsMod;
const Vec3d = NurbsMod.Vec3d;
const NurbsCurve = NurbsMod.NurbsCurve;
const NurbsSurface = NurbsMod.NurbsSurface;

// ===========================================================================
// Wave 4 Milestone 4.1: NURBS Evaluation & Projection Differential Fuzzing
// 10,000 Randomized Evaluation Seeds under std.testing.allocator
// ===========================================================================

test "NURBS Evaluator: 2,500 seeds on exact NURBS Circle (residual <= 1e-9 mm)" {
    var prng = std.Random.DefaultPrng.init(0x1337BEEF);
    const rand = prng.random();

    const total_seeds: usize = 2500;
    var max_radius_err: f64 = 0.0;
    var max_tangent_dot: f64 = 0.0;

    for (0..total_seeds) |_| {
        const radius = 1.0 + rand.float(f64) * 999.0;
        const center = Vec3d.init(
            (rand.float(f64) - 0.5) * 200.0,
            (rand.float(f64) - 0.5) * 200.0,
            (rand.float(f64) - 0.5) * 200.0,
        );

        var circle = try NurbsCurve.createCircle(testing.allocator, center, radius);
        defer circle.deinit();

        const u = rand.float(f64);
        const eval = circle.evaluateDeriv1(u);

        // 1. Distance from circle center in XY plane must equal radius with residual <= 1e-9 mm
        const dx = eval.p.x - center.x;
        const dy = eval.p.y - center.y;
        const dist_xy = @sqrt(dx * dx + dy * dy);
        const radius_err = @abs(dist_xy - radius);
        if (radius_err > max_radius_err) max_radius_err = radius_err;
        try testing.expect(radius_err <= 1e-9);

        // Z-coordinate must match center.z
        try testing.expectApproxEqAbs(center.z, eval.p.z, 1e-9);

        // 2. Tangent vector must be strictly perpendicular to radial vector: (C(u) - center) . T(u) == 0
        const radial_vec = Vec3d.init(dx, dy, 0.0);
        const tang_norm = eval.d1.norm();
        try testing.expect(tang_norm > 1e-12);

        const normalized_dot = @abs(radial_vec.dot(eval.d1)) / (dist_xy * tang_norm);
        if (normalized_dot > max_tangent_dot) max_tangent_dot = normalized_dot;
        try testing.expect(normalized_dot <= 1e-9);
    }
    std.debug.print("\n[NURBS Circle 2500 seeds] max_radius_err = {e} mm, max_tangent_dot = {e}\n", .{ max_radius_err, max_tangent_dot });
}

test "NURBS Evaluator: 2,500 seeds on exact NURBS Cylinder (radial residual <= 1e-9 mm)" {
    var prng = std.Random.DefaultPrng.init(0xDEADBEEF);
    const rand = prng.random();

    const total_seeds: usize = 2500;
    var max_radial_err: f64 = 0.0;
    var max_normal_err: f64 = 0.0;

    for (0..total_seeds) |_| {
        const radius = 1.0 + rand.float(f64) * 499.0;
        const height = 5.0 + rand.float(f64) * 495.0;
        const center = Vec3d.init(
            (rand.float(f64) - 0.5) * 100.0,
            (rand.float(f64) - 0.5) * 100.0,
            (rand.float(f64) - 0.5) * 100.0,
        );

        var cylinder_surf = try NurbsSurface.createCylinder(testing.allocator, center, radius, height);
        defer cylinder_surf.deinit();

        const u = rand.float(f64);
        const v = rand.float(f64);

        const eval = cylinder_surf.evaluateDerivatives(u, v);

        // 1. Radial distance from cylinder axis equals R with residual <= 1e-9 mm
        const dx = eval.point.x - center.x;
        const dy = eval.point.y - center.y;
        const r_dist = @sqrt(dx * dx + dy * dy);
        const r_err = @abs(r_dist - radius);
        if (r_err > max_radial_err) max_radial_err = r_err;
        try testing.expect(r_err <= 1e-9);

        // 2. Normal vector must be parallel to radial unit vector: ||N(u,v) - r_unit|| <= 1e-9
        const expected_normal = Vec3d.init(dx / r_dist, dy / r_dist, 0.0);
        const n_diff = eval.normal.sub(expected_normal).norm();
        if (n_diff > max_normal_err) max_normal_err = n_diff;
        try testing.expect(n_diff <= 1e-9);

        // Height matches center.z + v * height
        try testing.expectApproxEqAbs(center.z + v * height, eval.point.z, 1e-9);
    }
    std.debug.print("[NURBS Cylinder 2500 seeds] max_radial_err = {e} mm, max_normal_err = {e}\n", .{ max_radial_err, max_normal_err });
}

test "NURBS Evaluator: 2,500 seeds on exact NURBS Sphere (Euclidean residual <= 1e-9 mm)" {
    var prng = std.Random.DefaultPrng.init(0xCAFED00D);
    const rand = prng.random();

    const total_seeds: usize = 2500;
    var max_sphere_err: f64 = 0.0;
    var max_normal_err: f64 = 0.0;

    for (0..total_seeds) |_| {
        const radius = 1.0 + rand.float(f64) * 499.0;
        const center = Vec3d.init(
            (rand.float(f64) - 0.5) * 100.0,
            (rand.float(f64) - 0.5) * 100.0,
            (rand.float(f64) - 0.5) * 100.0,
        );

        var sphere_surf = try NurbsSurface.createSphere(testing.allocator, center, radius);
        defer sphere_surf.deinit();

        // Avoid poles where du vanishes
        const u = rand.float(f64);
        const v = 0.05 + rand.float(f64) * 0.90;

        const eval = sphere_surf.evaluateDerivatives(u, v);

        // 1. Euclidean distance from sphere center equals R with residual <= 1e-9 mm
        const diff = eval.point.sub(center);
        const dist = diff.norm();
        const dist_err = @abs(dist - radius);
        if (dist_err > max_sphere_err) max_sphere_err = dist_err;
        try testing.expect(dist_err <= 1e-9);

        // 2. Normal vector parallel to radial unit vector: ||N(u,v) - r_unit|| <= 1e-9
        const expected_normal = diff.scale(1.0 / dist);
        const n_diff = eval.normal.sub(expected_normal).norm();
        if (n_diff > max_normal_err) max_normal_err = n_diff;
        try testing.expect(n_diff <= 1e-9);
    }
    std.debug.print("[NURBS Sphere 2500 seeds] max_sphere_err = {e} mm, max_normal_err = {e}\n", .{ max_sphere_err, max_normal_err });
}

fn circleAngleToParam(phi_in: f64) f64 {
    var phi = phi_in;
    while (phi < 0.0) phi += 2.0 * std.math.pi;
    while (phi >= 2.0 * std.math.pi) phi -= 2.0 * std.math.pi;

    const quad: usize = @intFromFloat(phi / (0.5 * std.math.pi));
    const q_clamped = @min(quad, 3);
    const alpha = phi - @as(f64, @floatFromInt(q_clamped)) * (0.5 * std.math.pi);

    const T = @tan(alpha);
    const sqrt2 = std.math.sqrt2;
    const A = (1.0 - sqrt2) * (1.0 - T);
    const B = sqrt2 + (2.0 - sqrt2) * T;
    const C = -T;

    const t = if (@abs(A) < 1e-12)
        -C / B
    else
        (-B + @sqrt(@max(0.0, B * B - 4.0 * A * C))) / (2.0 * A);

    return (@as(f64, @floatFromInt(q_clamped)) + std.math.clamp(t, 0.0, 1.0)) * 0.25;
}

fn sphereLatToParam(lat_in: f64) f64 {
    const lat = std.math.clamp(lat_in, -0.499 * std.math.pi, 0.499 * std.math.pi);
    const sqrt2 = std.math.sqrt2;

    if (lat < 0.0) {
        // South hemisphere: lat from -pi/2 to 0 -> gamma from 0 to pi/2
        const gamma = lat + 0.5 * std.math.pi;
        const T = @tan(gamma);
        const A = (1.0 - sqrt2) * (1.0 - T);
        const B = sqrt2 + (2.0 - sqrt2) * T;
        const C = -T;
        const t = if (@abs(A) < 1e-12) -C / B else (-B + @sqrt(@max(0.0, B * B - 4.0 * A * C))) / (2.0 * A);
        return 0.5 * std.math.clamp(t, 0.0, 1.0);
    } else {
        // North hemisphere: lat from 0 to pi/2 -> gamma from 0 to pi/2
        const gamma = lat;
        const T = @tan(gamma);
        const A = (1.0 - sqrt2) * (1.0 - T);
        const B = sqrt2 + (2.0 - sqrt2) * T;
        const C = -T;
        const t = if (@abs(A) < 1e-12) -C / B else (-B + @sqrt(@max(0.0, B * B - 4.0 * A * C))) / (2.0 * A);
        return 0.5 + 0.5 * std.math.clamp(t, 0.0, 1.0);
    }
}

pub fn projectPointPeriodic(
    surface: *const NurbsSurface,
    query_point: Vec3d,
    initial_u: f64,
    initial_v: f64,
) Vec3d {
    var cur_u = initial_u;
    var cur_v = initial_v;

    var iter: usize = 0;
    while (iter < 25) : (iter += 1) {
        const diff = surface.evaluateDerivatives(cur_u, cur_v);
        const R = diff.point.sub(query_point);
        const dist = R.norm();
        if (dist < 1e-12) return diff.point;

        const f1 = R.dot(diff.d_u);
        const f2 = R.dot(diff.d_v);

        if (@abs(f1) < 1e-10 and @abs(f2) < 1e-10) return diff.point;

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
            delta_u = -f1 / (diff.d_u.dot(diff.d_u) + 1e-8);
            delta_v = -f2 / (diff.d_v.dot(diff.d_v) + 1e-8);
        }

        delta_u = std.math.clamp(delta_u, -0.25, 0.25);
        delta_v = std.math.clamp(delta_v, -0.25, 0.25);

        cur_u += delta_u;
        while (cur_u < 0.0) cur_u += 1.0;
        while (cur_u > 1.0) cur_u -= 1.0;

        const dom = surface.getDomain();
        cur_v = std.math.clamp(cur_v + delta_v, dom.v_min, dom.v_max);

        if (@abs(delta_u) < 1e-11 and @abs(delta_v) < 1e-11) break;
    }

    return surface.evaluate(cur_u, cur_v);
}

test "NURBS Evaluator: 2,500 seeds on Orthogonal Point-to-Surface Projection (residual <= 1e-7 mm)" {
    var prng = std.Random.DefaultPrng.init(0xBADC0FFEE);
    const rand = prng.random();

    const total_seeds: usize = 2500;
    var max_proj_err: f64 = 0.0;

    for (0..total_seeds) |iter| {
        const radius = 5.0 + rand.float(f64) * 95.0;
        const center = Vec3d.init(
            (rand.float(f64) - 0.5) * 50.0,
            (rand.float(f64) - 0.5) * 50.0,
            (rand.float(f64) - 0.5) * 50.0,
        );

        if (iter % 2 == 0) {
            // Cylinder projection
            const height = 10.0 + rand.float(f64) * 90.0;
            var cyl = try NurbsSurface.createCylinder(testing.allocator, center, radius, height);
            defer cyl.deinit();

            // Generate query point in the vicinity of cylinder
            const angle = rand.float(f64) * 2.0 * std.math.pi;
            const r_query = radius + (rand.float(f64) - 0.5) * 10.0;
            const z_query = center.z + (0.1 + rand.float(f64) * 0.8) * height;

            const q_point = Vec3d.init(
                center.x + r_query * @cos(angle),
                center.y + r_query * @sin(angle),
                z_query,
            );

            // True analytical orthogonal projection
            const dx = q_point.x - center.x;
            const dy = q_point.y - center.y;
            const d_xy = @sqrt(dx * dx + dy * dy);
            const true_proj = Vec3d.init(
                center.x + radius * dx / d_xy,
                center.y + radius * dy / d_xy,
                z_query,
            );

            // Numerical NURBS projection via Newton refinement
            const init_u = circleAngleToParam(std.math.atan2(dy, dx));
            const init_v = (z_query - center.z) / height;
            const proj_pt = projectPointPeriodic(&cyl, q_point, init_u, init_v);
            const err = proj_pt.dist(true_proj);
            if (err > max_proj_err) max_proj_err = err;

            try testing.expect(err <= 1e-7);
        } else {
            // Sphere projection
            var sph = try NurbsSurface.createSphere(testing.allocator, center, radius);
            defer sph.deinit();

            // Generate query point in vicinity of sphere (away from poles)
            const u_ang = rand.float(f64) * 2.0 * std.math.pi;
            const v_ang = -1.1 + rand.float(f64) * 2.2; // latitude between -63 and +63 deg
            const r_offset = radius + (rand.float(f64) - 0.5) * 10.0;

            const q_point = Vec3d.init(
                center.x + r_offset * @cos(v_ang) * @cos(u_ang),
                center.y + r_offset * @cos(v_ang) * @sin(u_ang),
                center.z + r_offset * @sin(v_ang),
            );

            // True analytical orthogonal projection
            const diff = q_point.sub(center);
            const d = diff.norm();
            const true_proj = center.add(diff.scale(radius / d));

            // Numerical NURBS projection via Newton refinement
            const init_u = circleAngleToParam(std.math.atan2(diff.y, diff.x));
            const lat = std.math.asin(std.math.clamp(diff.z / d, -1.0, 1.0));
            const init_v = sphereLatToParam(lat);
            const proj_pt = projectPointPeriodic(&sph, q_point, init_u, init_v);
            const err = proj_pt.dist(true_proj);
            if (err > max_proj_err) max_proj_err = err;

            try testing.expect(err <= 1e-7);
        }
    }
    std.debug.print("[NURBS Projection 2500 seeds] max_proj_err = {e} mm\n", .{max_proj_err});
}
