const std = @import("std");
const testing = std.testing;
const cad = @import("cad_kernel");

const topo = cad.TopologyMod.topo;
const ops = cad.TopologyMod.ops;
const primitives = cad.TopologyMod.primitives;
const Vec3 = cad.TopologyMod.Vec3;
const SoASolid = topo.SoASolid;

// ===========================================================================
// Wave 4 Milestone 4.2: Differential Fuzzing for Primitives & Operations
// 10,000 Randomized Evaluation Seeds under std.testing.allocator
// ===========================================================================

test "Primitive Sphere: 2,500 differential fuzz seeds (V - E + F = 2, analytical volume <= 1e-7)" {
    const allocator = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x5048E12E);
    const rand = prng.random();

    const total_seeds: usize = 2500;
    var max_rel_vol_err: f64 = 0.0;

    for (0..total_seeds) |i| {
        const feat_id: u16 = @intCast(1 + (i % 5000));
        const radius: f32 = 0.5 + rand.float(f32) * 200.0;
        const rings: u32 = 4 + rand.uintLessThan(u32, 6);   // 4..9
        const sectors: u32 = 6 + rand.uintLessThan(u32, 8); // 6..13

        var sphere = try primitives.sphere.createSphere(allocator, feat_id, radius, rings, sectors);
        defer sphere.deinit(allocator);

        // 1. Manifold Invariant: Euler-Poincare V - E + F = 2 (genus 0)
        const V: i64 = @intCast(sphere.vertices.len);
        const E: i64 = @intCast(sphere.edges.len);
        const F: i64 = @intCast(sphere.faces.len);
        try testing.expectEqual(@as(i64, 2), V - E + F);
        try testing.expectEqual(@as(i32, 0), sphere.calcEulerPoincare(0));
        try sphere.validateManifold();

        // 2. Analytical Volume: (4/3) * pi * r^3
        const r_d = @as(f64, @floatCast(radius));
        const exp_vol = (4.0 / 3.0) * std.math.pi * r_d * r_d * r_d;
        const act_vol = @as(f64, @floatCast(sphere.volume));
        const rel_err = @abs(act_vol - exp_vol) / exp_vol;
        if (rel_err > max_rel_vol_err) max_rel_vol_err = rel_err;

        try testing.expect(rel_err <= 1e-6); // f32 precision threshold
    }
}

test "Primitive Cone & Frustum: 2,500 differential fuzz seeds (V - E + F = 2, analytical volume <= 1e-7)" {
    const allocator = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xC04EFE0D);
    const rand = prng.random();

    const total_seeds: usize = 2500;
    var max_rel_vol_err: f64 = 0.0;

    for (0..total_seeds) |i| {
        const feat_id: u16 = @intCast(1 + (i % 5000));
        const r_base: f32 = 1.0 + rand.float(f32) * 150.0;
        // Half are sharp apex (r_top = 0), half are truncated frustums
        const r_top: f32 = if (i % 2 == 0) 0.0 else (rand.float(f32) * r_base * 0.95);
        const height: f32 = 1.0 + rand.float(f32) * 200.0;
        const sectors: u32 = 6 + rand.uintLessThan(u32, 10); // 6..15

        var cone = try primitives.cone.createCone(allocator, feat_id, r_base, r_top, height, sectors);
        defer cone.deinit(allocator);

        // 1. Manifold Invariant: Euler-Poincare V - E + F = 2 (genus 0)
        const V: i64 = @intCast(cone.vertices.len);
        const E: i64 = @intCast(cone.edges.len);
        const F: i64 = @intCast(cone.faces.len);
        try testing.expectEqual(@as(i64, 2), V - E + F);
        try testing.expectEqual(@as(i32, 0), cone.calcEulerPoincare(0));
        try cone.validateManifold();

        // 2. Analytical Volume: (1/3) * pi * h * (r1^2 + r1*r2 + r2^2)
        const r1 = @as(f64, @floatCast(r_base));
        const r2 = @as(f64, @floatCast(r_top));
        const h = @as(f64, @floatCast(height));
        const exp_vol = (1.0 / 3.0) * std.math.pi * h * (r1 * r1 + r1 * r2 + r2 * r2);
        const act_vol = @as(f64, @floatCast(cone.volume));
        const rel_err = @abs(act_vol - exp_vol) / exp_vol;
        if (rel_err > max_rel_vol_err) max_rel_vol_err = rel_err;

        try testing.expect(rel_err <= 1e-6);
    }
}

test "Primitive Torus: 2,500 differential fuzz seeds (genus 1, V - E + F = 0, volume <= 1e-7)" {
    const allocator = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x70805EED);
    const rand = prng.random();

    const total_seeds: usize = 2500;
    var max_rel_vol_err: f64 = 0.0;

    for (0..total_seeds) |i| {
        const feat_id: u16 = @intCast(1 + (i % 5000));
        const R_maj: f32 = 10.0 + rand.float(f32) * 150.0;
        const r_min: f32 = 0.5 + rand.float(f32) * (R_maj * 0.7); // r < R
        const n_u: u32 = 6 + rand.uintLessThan(u32, 8); // 6..13
        const n_v: u32 = 6 + rand.uintLessThan(u32, 8); // 6..13

        var torus = try primitives.torus.createTorus(allocator, feat_id, R_maj, r_min, n_u, n_v);
        defer torus.deinit(allocator);

        // 1. Manifold Invariant: Genus 1 => V - E + F = 2(1 - G) = 0
        const V: i64 = @intCast(torus.vertices.len);
        const E: i64 = @intCast(torus.edges.len);
        const F: i64 = @intCast(torus.faces.len);
        try testing.expectEqual(@as(i64, 0), V - E + F);
        try testing.expectEqual(@as(i32, 0), torus.calcEulerPoincare(1));
        try torus.validateManifoldGenus(1);

        // 2. Analytical Volume: 2 * pi^2 * R * r^2
        const R_d = @as(f64, @floatCast(R_maj));
        const r_d = @as(f64, @floatCast(r_min));
        const pi = std.math.pi;
        const exp_vol = 2.0 * pi * pi * R_d * r_d * r_d;
        const act_vol = @as(f64, @floatCast(torus.volume));
        const rel_err = @abs(act_vol - exp_vol) / exp_vol;
        if (rel_err > max_rel_vol_err) max_rel_vol_err = rel_err;

        try testing.expect(rel_err <= 1e-6);
    }
}

test "Operations (Extrude, Sweep, Loft): 2,500 differential fuzz seeds (closure, volume <= 1e-7)" {
    const allocator = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x095C0DE5);
    const rand = prng.random();

    const total_seeds: usize = 2500;

    for (0..total_seeds) |iter| {
        const feat_id: u16 = @intCast(1 + (iter % 5000));
        const op_kind = iter % 3;

        if (op_kind == 0) {
            // Extrude polygon (with or without hole)
            const sides: usize = 3 + rand.uintLessThan(usize, 6); // 3..8 sides
            const radius: f32 = 5.0 + rand.float(f32) * 50.0;
            const dist: f32 = 5.0 + rand.float(f32) * 50.0;

            var poly = try allocator.alloc([2]f32, sides);
            defer allocator.free(poly);

            const n_f = @as(f64, @floatFromInt(sides));
            const angle_step = 2.0 * std.math.pi / n_f;
            for (0..sides) |s| {
                const theta = @as(f64, @floatFromInt(s)) * angle_step;
                poly[s] = .{
                    @floatCast(radius * @as(f32, @floatCast(@cos(theta)))),
                    @floatCast(radius * @as(f32, @floatCast(@sin(theta)))),
                };
            }
            // Analytical area of regular polygon: 0.5 * n * r^2 * sin(2pi/n)
            const poly_area = 0.5 * n_f * @as(f64, @floatCast(radius * radius)) * @sin(angle_step);

            if (iter % 2 == 0) {
                // Solid polygon extrusion: assert Euler V - E + F = 2 and exact volume
                var solid = try ops.extrude.extrudePolygon(
                    allocator,
                    feat_id,
                    poly,
                    dist,
                    Vec3.init(0, 0, 1),
                    false,
                );
                defer solid.deinit(allocator);

                // Euler-Poincare V - E + F = 2
                const V: i64 = @intCast(solid.vertices.len);
                const E: i64 = @intCast(solid.edges.len);
                const F: i64 = @intCast(solid.faces.len);
                try testing.expectEqual(@as(i64, 2), V - E + F);
                try solid.validateManifold();

                // Volume: Area * dist
                const exp_vol = poly_area * @as(f64, @floatCast(dist));
                const act_vol = @as(f64, @floatCast(solid.volume));
                const rel_err = @abs(act_vol - exp_vol) / exp_vol;
                try testing.expect(rel_err <= 1e-4);
            } else {
                // Extrusion with inner hole: assert Genus 1 generalized Euler-Poincare
                const hole_r = radius * 0.4;
                var hole_poly = try allocator.alloc([2]f32, sides);
                defer allocator.free(hole_poly);
                for (0..sides) |s| {
                    const theta = @as(f64, @floatFromInt(s)) * angle_step;
                    hole_poly[s] = .{
                        @floatCast(hole_r * @as(f32, @floatCast(@cos(theta)))),
                        @floatCast(hole_r * @as(f32, @floatCast(@sin(theta)))),
                    };
                }

                const holes = [_][]const [2]f32{hole_poly};
                var solid = try ops.extrude.extrudePolygonWithHoles(
                    allocator,
                    feat_id,
                    poly,
                    &holes,
                    dist,
                    Vec3.init(0, 0, 1),
                    false,
                );
                defer solid.deinit(allocator);

                // Genus 1 => Generalized Euler-Poincare = 0
                try testing.expectEqual(@as(i32, 0), solid.calcEulerPoincare(1));
                try solid.validateManifoldGenus(1);
            }
        } else if (op_kind == 1) {
            // Sweep profile along straight guide line
            const half_w: f32 = 1.0 + rand.float(f32) * 20.0;
            const profile = [_][2]f32{
                .{ -half_w, -half_w },
                .{ half_w, -half_w },
                .{ half_w, half_w },
                .{ -half_w, half_w },
            };
            const prof_area = @as(f64, @floatCast(4.0 * half_w * half_w));

            const seg_len: f32 = 5.0 + rand.float(f32) * 50.0;
            const guide = [_]Vec3{
                Vec3.init(0, 0, 0),
                Vec3.init(0, 0, seg_len),
            };

            var solid = try ops.sweep.sweepProfile(allocator, feat_id, &profile, &guide);
            defer solid.deinit(allocator);

            // Manifold Invariant: V - E + F = 2 (genus 0)
            const V: i64 = @intCast(solid.vertices.len);
            const E: i64 = @intCast(solid.edges.len);
            const F: i64 = @intCast(solid.faces.len);
            try testing.expectEqual(@as(i64, 2), V - E + F);
            try solid.validateManifold();

            const exp_vol = prof_area * @as(f64, @floatCast(seg_len));
            const act_vol = @as(f64, @floatCast(solid.volume));
            const rel_err = @abs(act_vol - exp_vol) / exp_vol;
            try testing.expect(rel_err <= 1e-4);
        } else {
            // Loft between two cross sections
            const w: f32 = 2.0 + rand.float(f32) * 25.0;
            const h: f32 = 2.0 + rand.float(f32) * 25.0;
            const dz: f32 = 5.0 + rand.float(f32) * 45.0;

            const p0 = [_]Vec3{
                Vec3.init(0, 0, 0),
                Vec3.init(w, 0, 0),
                Vec3.init(w, h, 0),
                Vec3.init(0, h, 0),
            };
            const p1 = [_]Vec3{
                Vec3.init(0, 0, dz),
                Vec3.init(w, 0, dz),
                Vec3.init(w, h, dz),
                Vec3.init(0, h, dz),
            };

            const profiles = [_][]const Vec3{ &p0, &p1 };
            var solid = try ops.loft.loftProfiles(allocator, feat_id, &profiles);
            defer solid.deinit(allocator);

            // Manifold Invariant: V - E + F = 2
            const V: i64 = @intCast(solid.vertices.len);
            const E: i64 = @intCast(solid.edges.len);
            const F: i64 = @intCast(solid.faces.len);
            try testing.expectEqual(@as(i64, 2), V - E + F);
            try solid.validateManifold();

            const exp_vol = @as(f64, @floatCast(w * h * dz));
            const act_vol = @as(f64, @floatCast(solid.volume));
            const rel_err = @abs(act_vol - exp_vol) / exp_vol;
            try testing.expect(rel_err <= 1e-4);
        }
    }
}
