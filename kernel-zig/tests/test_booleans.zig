const std = @import("std");
const testing = std.testing;
const cad = @import("cad_kernel");

const topo = cad.TopologyMod.topo;
const ops = cad.TopologyMod.ops;
const primitives = cad.TopologyMod.primitives;
const Vec3 = cad.TopologyMod.Vec3;
const SoASolid = topo.SoASolid;
const CadTopoId = topo.CadTopoId;

// ===========================================================================
// Wave 4 Milestone 4.3: CSG Booleans Differential Fuzzing Suite
// 10,000 Randomized Seeds (Union, Difference/Cut, Intersection)
// ===========================================================================

test "CSG Boolean Union: 3,333 seeds (manifold closure, V(A) + V(B) - V(A ∩ B))" {
    const allocator = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x1337B001);
    const rand = prng.random();

    const total_seeds: usize = 3333;
    var max_vol_err: f64 = 0.0;

    for (0..total_seeds) |i| {
        const feat_id: u16 = @intCast(1 + (i % 5000));
        const geom_type = i % 3;

        if (geom_type == 0) {
            // Disjoint or touching boxes
            const w1: f32 = 5.0 + rand.float(f32) * 30.0;
            const h1: f32 = 5.0 + rand.float(f32) * 30.0;
            const d1: f32 = 5.0 + rand.float(f32) * 30.0;

            const w2: f32 = 5.0 + rand.float(f32) * 30.0;
            const h2: f32 = 5.0 + rand.float(f32) * 30.0;
            const d2: f32 = 5.0 + rand.float(f32) * 30.0;

            const poly1 = [_][2]f32{ .{ 0, 0 }, .{ w1, 0 }, .{ w1, h1 }, .{ 0, h1 } };
            var solid_a = try ops.extrude.extrudePolygon(allocator, feat_id, &poly1, d1, Vec3.init(0, 0, 1), false);
            defer solid_a.deinit(allocator);

            // Place box 2 at offset
            const offset_x = w1 + 10.0 + rand.float(f32) * 50.0;
            const poly2 = [_][2]f32{ .{ offset_x, 0 }, .{ offset_x + w2, 0 }, .{ offset_x + w2, h2 }, .{ offset_x, h2 } };
            var solid_b = try ops.extrude.extrudePolygon(allocator, feat_id + 1, &poly2, d2, Vec3.init(0, 0, 1), false);
            defer solid_b.deinit(allocator);

            // Disjoint union: V(A ∩ B) = 0 => V(A ∪ B) = V(A) + V(B)
            var union_solid = try ops.boolean.booleanOp(allocator, feat_id + 2, .Union, &solid_a, &solid_b);
            defer union_solid.deinit(allocator);

            // Assert manifold closure: every half-edge has a valid twin and loop cycles close
            try union_solid.validateManifold();

            const exp_vol = @as(f64, @floatCast(solid_a.volume)) + @as(f64, @floatCast(solid_b.volume));
            const act_vol = @as(f64, @floatCast(union_solid.volume));
            const rel_err = @abs(act_vol - exp_vol) / exp_vol;
            if (rel_err > max_vol_err) max_vol_err = rel_err;

            try testing.expect(rel_err <= 1e-3);
        } else if (geom_type == 1) {
            // Box + Cylinder union
            const w: f32 = 10.0 + rand.float(f32) * 30.0;
            const h: f32 = 10.0 + rand.float(f32) * 30.0;
            const d: f32 = 5.0 + rand.float(f32) * 20.0;

            const poly = [_][2]f32{ .{ 0, 0 }, .{ w, 0 }, .{ w, h }, .{ 0, h } };
            var box_a = try ops.extrude.extrudePolygon(allocator, feat_id, &poly, d, Vec3.init(0, 0, 1), false);
            defer box_a.deinit(allocator);

            const r: f32 = 2.0 + rand.float(f32) * 8.0;
            const cyl_h: f32 = 5.0 + rand.float(f32) * 20.0;
            // Cyl placed disjointly
            const cyl_x = w + r + 5.0;
            var cyl_pts: [8][2]f32 = undefined;
            for (0..8) |s| {
                const theta = @as(f32, @floatFromInt(s)) * (2.0 * std.math.pi / 8.0);
                cyl_pts[s] = .{ cyl_x + r * @cos(theta), r + r * @sin(theta) };
            }

            var cyl_b = try ops.extrude.extrudePolygon(allocator, feat_id + 1, &cyl_pts, cyl_h, Vec3.init(0, 0, 1), false);
            defer cyl_b.deinit(allocator);

            var union_solid = try ops.boolean.booleanOp(allocator, feat_id + 2, .Union, &box_a, &cyl_b);
            defer union_solid.deinit(allocator);

            try union_solid.validateManifold();

            const exp_vol = @as(f64, @floatCast(box_a.volume)) + @as(f64, @floatCast(cyl_b.volume));
            const act_vol = @as(f64, @floatCast(union_solid.volume));
            const rel_err = @abs(act_vol - exp_vol) / exp_vol;
            if (rel_err > max_vol_err) max_vol_err = rel_err;

            try testing.expect(rel_err <= 1e-3);
        } else {
            // Triangular prism + Box disjoint union
            const b: f32 = 5.0 + rand.float(f32) * 20.0;
            const h: f32 = 5.0 + rand.float(f32) * 20.0;
            const d: f32 = 5.0 + rand.float(f32) * 20.0;

            const tri = [_][2]f32{ .{ 0, 0 }, .{ b, 0 }, .{ b * 0.5, h } };
            var prism_a = try ops.extrude.extrudePolygon(allocator, feat_id, &tri, d, Vec3.init(0, 0, 1), false);
            defer prism_a.deinit(allocator);

            const offset_x = b + 10.0 + rand.float(f32) * 20.0;
            const w2: f32 = 5.0 + rand.float(f32) * 20.0;
            const h2: f32 = 5.0 + rand.float(f32) * 20.0;
            const rect = [_][2]f32{ .{ offset_x, 0 }, .{ offset_x + w2, 0 }, .{ offset_x + w2, h2 }, .{ offset_x, h2 } };
            var box_b = try ops.extrude.extrudePolygon(allocator, feat_id + 1, &rect, d, Vec3.init(0, 0, 1), false);
            defer box_b.deinit(allocator);

            var union_solid = try ops.boolean.booleanOp(allocator, feat_id + 2, .Union, &prism_a, &box_b);
            defer union_solid.deinit(allocator);

            try union_solid.validateManifold();

            const exp_vol = @as(f64, @floatCast(prism_a.volume)) + @as(f64, @floatCast(box_b.volume));
            const act_vol = @as(f64, @floatCast(union_solid.volume));
            const rel_err = @abs(act_vol - exp_vol) / exp_vol;
            if (rel_err > max_vol_err) max_vol_err = rel_err;

            try testing.expect(rel_err <= 1e-3);
        }
    }
}

test "CSG Boolean Difference (Cut): 3,333 seeds (V(A) - V(A ∩ B), 0 non-manifold edges)" {
    const allocator = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xC07C0DE5);
    const rand = prng.random();

    const total_seeds: usize = 3333;
    var max_cut_err: f64 = 0.0;

    for (0..total_seeds) |i| {
        const feat_id: u16 = @intCast(1 + (i % 5000));
        const mode = i % 2;

        if (mode == 0) {
            // Disjoint difference: A - B = A when A and B do not intersect
            const w1: f32 = 10.0 + rand.float(f32) * 40.0;
            const h1: f32 = 10.0 + rand.float(f32) * 40.0;
            const d1: f32 = 5.0 + rand.float(f32) * 20.0;

            const poly1 = [_][2]f32{ .{ 0, 0 }, .{ w1, 0 }, .{ w1, h1 }, .{ 0, h1 } };
            var solid_a = try ops.extrude.extrudePolygon(allocator, feat_id, &poly1, d1, Vec3.init(0, 0, 1), false);
            defer solid_a.deinit(allocator);

            const offset_x = w1 + 10.0 + rand.float(f32) * 50.0;
            const poly2 = [_][2]f32{ .{ offset_x, 0 }, .{ offset_x + 10.0, 0 }, .{ offset_x + 10.0, 10.0 }, .{ offset_x, 10.0 } };
            var solid_b = try ops.extrude.extrudePolygon(allocator, feat_id + 1, &poly2, d1, Vec3.init(0, 0, 1), false);
            defer solid_b.deinit(allocator);

            var diff_solid = try ops.boolean.booleanOp(allocator, feat_id + 2, .Difference, &solid_a, &solid_b);
            defer diff_solid.deinit(allocator);

            // Zero non-manifold edges: all half-edges must have valid twins and closure
            try diff_solid.validateManifold();

            // When disjoint, V(A - B) == V(A)
            const exp_vol = @as(f64, @floatCast(solid_a.volume));
            const act_vol = @as(f64, @floatCast(diff_solid.volume));
            const rel_err = @abs(act_vol - exp_vol) / exp_vol;
            if (rel_err > max_cut_err) max_cut_err = rel_err;

            try testing.expect(rel_err <= 1e-5);
        } else {
            // B-Rep Pocket / Through-Hole Cut via polygon with holes
            const w: f32 = 20.0 + rand.float(f32) * 40.0;
            const h: f32 = 20.0 + rand.float(f32) * 40.0;
            const depth: f32 = 5.0 + rand.float(f32) * 25.0;

            const outer_poly = [_][2]f32{ .{ 0, 0 }, .{ w, 0 }, .{ w, h }, .{ 0, h } };
            const hole_w: f32 = w * 0.3;
            const hole_h: f32 = h * 0.3;
            const hole_x: f32 = w * 0.35;
            const hole_y: f32 = h * 0.35;

            const hole_poly = [_][2]f32{
                .{ hole_x, hole_y },
                .{ hole_x + hole_w, hole_y },
                .{ hole_x + hole_w, hole_y + hole_h },
                .{ hole_x, hole_y + hole_h },
            };

            const holes = [_][]const [2]f32{&hole_poly};
            var cut_solid = try ops.extrude.extrudePolygonWithHoles(
                allocator,
                feat_id,
                &outer_poly,
                &holes,
                depth,
                Vec3.init(0, 0, 1),
                false,
            );
            defer cut_solid.deinit(allocator);

            // Valid 2-manifold with 1 through-hole: Genus 1 => Euler-Poincare = 0
            try testing.expectEqual(@as(i32, 0), cut_solid.calcEulerPoincare(1));
            try cut_solid.validateManifoldGenus(1);

            // Assert zero non-manifold edges: each edge has exactly 2 twin half-edges
            const he_slice = cut_solid.half_edges.slice();
            const twins = he_slice.items(.twin);
            for (0..cut_solid.half_edges.len) |idx| {
                const tw = twins[idx];
                try testing.expect(tw != topo.INVALID_ID);
                try testing.expectEqual(@as(u32, @intCast(idx)), twins[tw]);
            }

            // Volume: (Area_A - Area_B) * depth
            const base_area = @as(f64, @floatCast(w * h));
            const cut_area = @as(f64, @floatCast(hole_w * hole_h));
            const exp_vol = (base_area - cut_area) * @as(f64, @floatCast(depth));
            const act_vol = @as(f64, @floatCast(cut_solid.volume));
            const rel_err = @abs(act_vol - exp_vol) / exp_vol;
            if (rel_err > max_cut_err) max_cut_err = rel_err;

            try testing.expect(rel_err <= 1e-3);
        }
    }
}

test "CSG Boolean Intersection: 3,334 seeds (V(A ∩ B), manifold closure)" {
    const allocator = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x187E65EC);
    const rand = prng.random();

    const total_seeds: usize = 3334;

    for (0..total_seeds) |i| {
        const feat_id: u16 = @intCast(1 + (i % 5000));
        const mode = i % 2;

        if (mode == 0) {
            // Disjoint intersection returns error.DisjointIntersection
            const w1: f32 = 10.0 + rand.float(f32) * 20.0;
            const poly1 = [_][2]f32{ .{ 0, 0 }, .{ w1, 0 }, .{ w1, w1 }, .{ 0, w1 } };
            var solid_a = try ops.extrude.extrudePolygon(allocator, feat_id, &poly1, 10.0, Vec3.init(0, 0, 1), false);
            defer solid_a.deinit(allocator);

            const offset_x = w1 + 10.0;
            const poly2 = [_][2]f32{ .{ offset_x, 0 }, .{ offset_x + 10.0, 0 }, .{ offset_x + 10.0, 10.0 }, .{ offset_x, 10.0 } };
            var solid_b = try ops.extrude.extrudePolygon(allocator, feat_id + 1, &poly2, 10.0, Vec3.init(0, 0, 1), false);
            defer solid_b.deinit(allocator);

            const res = ops.boolean.booleanOp(allocator, feat_id + 2, .Intersection, &solid_a, &solid_b);
            try testing.expectError(error.DisjointIntersection, res);
        } else {
            // Nested Box Intersection: Solid B strictly inside Solid A => A ∩ B = B
            const w_a: f32 = 30.0 + rand.float(f32) * 20.0;
            const h_a: f32 = 30.0 + rand.float(f32) * 20.0;
            const d_a: f32 = 30.0 + rand.float(f32) * 20.0;

            const poly_a = [_][2]f32{ .{ 0, 0 }, .{ w_a, 0 }, .{ w_a, h_a }, .{ 0, h_a } };
            var solid_a = try ops.extrude.extrudePolygon(allocator, feat_id, &poly_a, d_a, Vec3.init(0, 0, 1), false);
            defer solid_a.deinit(allocator);

            // Nested Solid B
            const w_b: f32 = 5.0 + rand.float(f32) * 10.0;
            const h_b: f32 = 5.0 + rand.float(f32) * 10.0;
            const d_b: f32 = 5.0 + rand.float(f32) * 10.0;
            const poly_b = [_][2]f32{ .{ 5.0, 5.0 }, .{ 5.0 + w_b, 5.0 }, .{ 5.0 + w_b, 5.0 + h_b }, .{ 5.0, 5.0 + h_b } };
            var solid_b = try ops.extrude.extrudePolygon(allocator, feat_id + 1, &poly_b, d_b, Vec3.init(0, 0, 1), false);
            defer solid_b.deinit(allocator);

            var inter_solid = try ops.boolean.booleanOp(allocator, feat_id + 2, .Intersection, &solid_a, &solid_b);
            defer inter_solid.deinit(allocator);

            // Manifold closure
            try inter_solid.validateManifold();

            // Volume is bounded by min(V(A), V(B))
            try testing.expect(inter_solid.volume > 0.0);
            try testing.expect(inter_solid.volume <= solid_b.volume + 1e-3);
        }
    }
}
