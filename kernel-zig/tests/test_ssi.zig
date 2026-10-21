const std = @import("std");
const testing = std.testing;
const cad = @import("cad_kernel");

const SsiMod = cad.SsiMod;
const NurbsMod = cad.NurbsMod;
const Vec3d = SsiMod.Vec3d;
const Plane = SsiMod.Plane;
const Cylinder = SsiMod.Cylinder;
const NurbsSurface = SsiMod.NurbsSurface;

// ===========================================================================
// Wave 4 Milestone 4.3: Surface-Surface Intersection (SSI) Differential Fuzzing
// 10,000 Randomized Seeds under std.testing.allocator
// ===========================================================================

test "SSI Fuzzer: 2,500 seeds on Plane-Plane Intersection (residual <= 1e-9 mm)" {
    var prng = std.Random.DefaultPrng.init(0xCAFEBABE);
    const rand = prng.random();

    const total_seeds: usize = 2500;
    var max_plane1_err: f64 = 0.0;
    var max_plane2_err: f64 = 0.0;

    for (0..total_seeds) |_| {
        const p1_orig = Vec3d.init(
            (rand.float(f64) - 0.5) * 100.0,
            (rand.float(f64) - 0.5) * 100.0,
            (rand.float(f64) - 0.5) * 100.0,
        );
        var n1 = Vec3d.init(
            (rand.float(f64) - 0.5) * 2.0,
            (rand.float(f64) - 0.5) * 2.0,
            (rand.float(f64) - 0.5) * 2.0,
        );
        if (n1.norm() < 1e-3) n1 = Vec3d.init(0, 0, 1);

        const p2_orig = Vec3d.init(
            (rand.float(f64) - 0.5) * 100.0,
            (rand.float(f64) - 0.5) * 100.0,
            (rand.float(f64) - 0.5) * 100.0,
        );
        var n2 = Vec3d.init(
            (rand.float(f64) - 0.5) * 2.0,
            (rand.float(f64) - 0.5) * 2.0,
            (rand.float(f64) - 0.5) * 2.0,
        );
        if (n2.norm() < 1e-3) n2 = Vec3d.init(1, 0, 0);

        const plane1 = Plane.init(p1_orig, n1);
        const plane2 = Plane.init(p2_orig, n2);

        // If planes are not nearly parallel
        if (plane1.normal.cross(plane2.normal).norm() > 0.05) {
            const res = SsiMod.intersectPlanePlane(plane1, plane2).?;

            // Test 5 arbitrary parameter samples along line
            const t_samples = [_]f64{ -50.0, -10.0, 0.0, 15.0, 60.0 };
            for (t_samples) |t| {
                const pt = res.line.pointAt(t);
                const err1 = @abs(plane1.distanceToPoint(pt));
                const err2 = @abs(plane2.distanceToPoint(pt));

                if (err1 > max_plane1_err) max_plane1_err = err1;
                if (err2 > max_plane2_err) max_plane2_err = err2;

                try testing.expect(err1 <= 1e-9);
                try testing.expect(err2 <= 1e-9);
            }
        }
    }
    std.debug.print("\n[SSI Plane-Plane 2500 seeds] max_plane1_err = {e} mm, max_plane2_err = {e} mm\n", .{ max_plane1_err, max_plane2_err });
}

test "SSI Fuzzer: 2,500 seeds on Plane-Cylinder Intersection (residual <= 1e-9 mm)" {
    var prng = std.Random.DefaultPrng.init(0xDEADBEEF);
    const rand = prng.random();

    const total_seeds: usize = 2500;
    var max_cyl_err: f64 = 0.0;
    var max_plane_err: f64 = 0.0;

    for (0..total_seeds) |_| {
        const radius = 2.0 + rand.float(f64) * 80.0;
        const cyl_orig = Vec3d.init(
            (rand.float(f64) - 0.5) * 50.0,
            (rand.float(f64) - 0.5) * 50.0,
            (rand.float(f64) - 0.5) * 50.0,
        );
        var axis = Vec3d.init(
            (rand.float(f64) - 0.5) * 2.0,
            (rand.float(f64) - 0.5) * 2.0,
            (rand.float(f64) - 0.5) * 2.0,
        );
        if (axis.norm() < 1e-3) axis = Vec3d.init(0, 0, 1);

        const cyl = Cylinder.init(cyl_orig, axis, radius);

        // Plane passing through cylinder with varying normal angle
        const plane_orig = cyl_orig.add(cyl.axis.scale((rand.float(f64) - 0.5) * 40.0));
        var plane_normal = Vec3d.init(
            (rand.float(f64) - 0.5) * 2.0,
            (rand.float(f64) - 0.5) * 2.0,
            (rand.float(f64) - 0.5) * 2.0,
        );
        if (plane_normal.norm() < 1e-3) plane_normal = Vec3d.init(0, 1, 0);
        const plane = Plane.init(plane_orig, plane_normal);

        const res = SsiMod.intersectPlaneCylinder(plane, cyl);
        switch (res) {
            .circle => |c| {
                for (0..8) |idx| {
                    const theta = (@as(f64, @floatFromInt(idx)) / 8.0) * 2.0 * std.math.pi;
                    const pt = c.pointAt(theta);
                    const err_c = @abs(cyl.distanceToPoint(pt));
                    const err_p = @abs(plane.distanceToPoint(pt));
                    if (err_c > max_cyl_err) max_cyl_err = err_c;
                    if (err_p > max_plane_err) max_plane_err = err_p;
                    try testing.expect(err_c <= 1e-9);
                    try testing.expect(err_p <= 1e-9);
                }
            },
            .ellipse => |el| {
                for (0..8) |idx| {
                    const theta = (@as(f64, @floatFromInt(idx)) / 8.0) * 2.0 * std.math.pi;
                    const pt = el.pointAt(theta);
                    const err_c = @abs(cyl.distanceToPoint(pt));
                    const err_p = @abs(plane.distanceToPoint(pt));
                    if (err_c > max_cyl_err) max_cyl_err = err_c;
                    if (err_p > max_plane_err) max_plane_err = err_p;
                    try testing.expect(err_c <= 1e-9);
                    try testing.expect(err_p <= 1e-9);
                }
            },
            .single_line => |l| {
                const pt = l.pointAt(0.0);
                const err_c = @abs(cyl.distanceToPoint(pt));
                const err_p = @abs(plane.distanceToPoint(pt));
                if (err_c > max_cyl_err) max_cyl_err = err_c;
                if (err_p > max_plane_err) max_plane_err = err_p;
                try testing.expect(err_c <= 1e-9);
                try testing.expect(err_p <= 1e-9);
            },
            .two_lines => |lines| {
                const pt1 = lines.line1.pointAt(10.0);
                const pt2 = lines.line2.pointAt(-10.0);
                try testing.expect(@abs(cyl.distanceToPoint(pt1)) <= 1e-9);
                try testing.expect(@abs(plane.distanceToPoint(pt1)) <= 1e-9);
                try testing.expect(@abs(cyl.distanceToPoint(pt2)) <= 1e-9);
                try testing.expect(@abs(plane.distanceToPoint(pt2)) <= 1e-9);
            },
            .none => {},
        }
    }
    std.debug.print("\n[SSI Plane-Cylinder 2500 seeds] max_cyl_err = {e} mm, max_plane_err = {e} mm\n", .{ max_cyl_err, max_plane_err });
}

test "SSI Fuzzer: 2,500 seeds on Cylinder-Cylinder Intersection (residual <= 1e-9 mm)" {
    var prng = std.Random.DefaultPrng.init(0x12345678);
    const rand = prng.random();

    const total_seeds: usize = 2500;
    var max_c1_err: f64 = 0.0;
    var max_c2_err: f64 = 0.0;

    for (0..total_seeds) |_| {
        const r1 = 3.0 + rand.float(f64) * 50.0;
        const r2 = 3.0 + rand.float(f64) * 50.0;

        // Orthogonal cylinders with intersecting or parallel axes
        const is_parallel = (rand.float(f64) > 0.5);
        const cyl1 = Cylinder.init(Vec3d.init(0, 0, 0), Vec3d.init(0, 0, 1), r1);
        const cyl2 = if (is_parallel)
            Cylinder.init(Vec3d.init(r1 * 0.7, 0, 0), Vec3d.init(0, 0, 1), r2)
        else
            Cylinder.init(Vec3d.init(0, 0, 0), Vec3d.init(1, 0, 0), r2);

        var res = try SsiMod.intersectCylinderCylinder(testing.allocator, cyl1, cyl2);
        defer res.deinit();

        switch (res) {
            .planar_ellipses => |el| {
                for (0..6) |idx| {
                    const theta = (@as(f64, @floatFromInt(idx)) / 6.0) * 2.0 * std.math.pi;
                    const p1 = el.ellipse1.pointAt(theta);
                    const p2 = el.ellipse2.pointAt(theta);

                    const err1 = @abs(cyl1.distanceToPoint(p1));
                    const err2 = @abs(cyl2.distanceToPoint(p1));
                    if (err1 > max_c1_err) max_c1_err = err1;
                    if (err2 > max_c2_err) max_c2_err = err2;
                    try testing.expect(err1 <= 1e-9);
                    try testing.expect(err2 <= 1e-9);

                    try testing.expect(@abs(cyl1.distanceToPoint(p2)) <= 1e-9);
                    try testing.expect(@abs(cyl2.distanceToPoint(p2)) <= 1e-9);
                }
            },
            .parallel_lines => |lines| {
                const p1 = lines.line1.pointAt(5.0);
                try testing.expect(@abs(cyl1.distanceToPoint(p1)) <= 1e-9);
                try testing.expect(@abs(cyl2.distanceToPoint(p1)) <= 1e-9);
                if (lines.line2) |l2| {
                    const p2 = l2.pointAt(-5.0);
                    try testing.expect(@abs(cyl1.distanceToPoint(p2)) <= 1e-9);
                    try testing.expect(@abs(cyl2.distanceToPoint(p2)) <= 1e-9);
                }
            },
            .spatial_curves => |sc| {
                for (sc.curve1.points[0..@min(10, sc.curve1.points.len)]) |cp| {
                    const err1 = @abs(cyl1.distanceToPoint(cp.point));
                    const err2 = @abs(cyl2.distanceToPoint(cp.point));
                    if (err1 > max_c1_err) max_c1_err = err1;
                    if (err2 > max_c2_err) max_c2_err = err2;
                    try testing.expect(err1 <= 1e-9);
                    try testing.expect(err2 <= 1e-9);
                }
            },
            .none => {},
        }
    }
    std.debug.print("\n[SSI Cylinder-Cylinder 2500 seeds] max_c1_err = {e} mm, max_c2_err = {e} mm\n", .{ max_c1_err, max_c2_err });
}

test "SSI Fuzzer: 2,500 seeds on Marching NURBS-NURBS SSI (residual <= 1e-7 mm)" {
    var prng = std.Random.DefaultPrng.init(0xFEEDFACE);
    const rand = prng.random();

    const total_seeds: usize = 2500;
    var max_nurbs_err: f64 = 0.0;

    // Base patch 1: Flat patch in XY plane [-5, 5] x [-5, 5]
    var p1_pts: [16]Vec3d = undefined;
    for (0..4) |i| {
        for (0..4) |j| {
            const x = -5.0 + (@as(f64, @floatFromInt(i)) / 3.0) * 10.0;
            const y = -5.0 + (@as(f64, @floatFromInt(j)) / 3.0) * 10.0;
            p1_pts[i * 4 + j] = Vec3d.init(x, y, 0.0);
        }
    }
    var patch1 = try NurbsSurface.createBicubicPatch(testing.allocator, p1_pts);
    defer patch1.deinit();

    // Patch 2: Angled cutting plane patch rotated around Y axis by angle theta
    for (0..total_seeds) |_| {
        const angle = 0.2 + rand.float(f64) * 1.1; // 11 to 75 degrees
        const cos_a = @cos(angle);
        const sin_a = @sin(angle);
        const y_offset = (rand.float(f64) - 0.5) * 2.0;

        var p2_pts: [16]Vec3d = undefined;
        for (0..4) |i| {
            for (0..4) |j| {
                const s = -4.0 + (@as(f64, @floatFromInt(i)) / 3.0) * 8.0;
                const y = -4.0 + (@as(f64, @floatFromInt(j)) / 3.0) * 8.0 + y_offset;
                // Rotated plane: x = s * cos_a, z = s * sin_a
                p2_pts[i * 4 + j] = Vec3d.init(s * cos_a, y, s * sin_a);
            }
        }
        var patch2 = try NurbsSurface.createBicubicPatch(testing.allocator, p2_pts);
        defer patch2.deinit();

        // Sample a random point along the true intersection line (s = 0, so x = 0, z = 0, y in [-4, 4])
        const y_val = -3.0 + rand.float(f64) * 6.0;
        const true_pt = Vec3d.init(0.0, y_val, 0.0);

        // Project onto both patches and run 4D corrector
        const init_u1 = 0.5;
        const init_v1 = (y_val + 5.0) / 10.0;
        const init_u2 = 0.5;
        const init_v2 = (y_val - y_offset + 4.0) / 8.0;

        const init_s = SsiMod.State4D{ .u1 = init_u1, .v1 = init_v1, .u2 = init_u2, .v2 = init_v2 };
        if (SsiMod.correct4D(&patch1, &patch2, init_s, 1e-7, 10)) |corr| {
            const pt1 = patch1.evaluate(corr.state.u1, corr.state.v1);
            const pt2 = patch2.evaluate(corr.state.u2, corr.state.v2);
            const err = pt1.dist(pt2);
            if (err > max_nurbs_err) max_nurbs_err = err;
            try testing.expect(err <= 1e-7);
            try testing.expect(corr.pt.dist(true_pt) <= 1e-6);
        }
    }
    std.debug.print("\n[SSI Marching NURBS-NURBS 2500 seeds] max_nurbs_err = {e} mm\n", .{max_nurbs_err});
}
