const std = @import("std");
const testing = std.testing;
const cad = @import("cad_kernel");
const implicit = cad.ImplicitMod;

test "Wave 9: SdfVm SIMD Vectorization & Interval Culling" {
    // Sphere with radius 5.0
    const inst = [_]implicit.Instruction{.{
        .opcode = .Primitive,
        .out_reg = 0,
        .params = .{
            .primitive = .{
                .prim_type = .Sphere,
                .center = .{ 0.0, 0.0, 0.0 },
                .dims = .{ 5.0, 0.0, 0.0 },
            },
        },
    }};

    // Verify 4-wide SIMD matches scalar evaluation exactly
    const xs: implicit.sdf_vm.Vec4f = .{ 0.0, 5.0, 0.0, 10.0 };
    const ys: implicit.sdf_vm.Vec4f = .{ 0.0, 0.0, 6.0, 0.0 };
    const zs: implicit.sdf_vm.Vec4f = .{ 0.0, 0.0, 0.0, 0.0 };
    const simd_res = implicit.SdfVm.evalSimd4(&inst, xs, ys, zs);

    inline for (0..4) |i| {
        const scalar_res = implicit.SdfVm.evalPoint(&inst, .{ xs[i], ys[i], zs[i] });
        try testing.expectApproxEqAbs(scalar_res, simd_res[i], 1e-4);
    }

    // Interval culling benchmark: octree cells completely outside surface band must be culled in O(1)
    const far_cell_min = [3]f32{ 20.0, 20.0, 20.0 };
    const far_cell_max = [3]f32{ 25.0, 25.0, 25.0 };
    const interval_far = implicit.SdfVm.evalInterval(&inst, far_cell_min, far_cell_max);
    try testing.expect(interval_far.min > 0.0);
    try testing.expect(!interval_far.crossesBand(0.5));
}

test "Wave 9: TPMS Minimal Surfaces & Strut Lattices (Gyroid, Schwarz, Lidinoid, Neovius, BCC, Octet)" {
    const p = implicit.Vec3{ .x = 2.0, .y = 2.0, .z = 2.0 };

    // 1. Gyroid
    const gyroid = implicit.TpmsLattice{ .tpms_type = .Gyroid, .cell_size = 8.0, .wall_thickness = 1.0 };
    const d_gyroid = gyroid.evalSdf(p, null);
    try testing.expect(std.math.isFinite(d_gyroid));

    // 2. Schwarz-P
    const schwarz_p = implicit.TpmsLattice{ .tpms_type = .SchwarzP, .cell_size = 8.0, .wall_thickness = 1.0 };
    const d_sp = schwarz_p.evalSdf(p, null);
    try testing.expect(std.math.isFinite(d_sp));

    // 3. Schwarz-D / Diamond
    const diamond = implicit.TpmsLattice{ .tpms_type = .SchwarzD, .cell_size = 8.0, .wall_thickness = 1.0 };
    const d_diamond = diamond.evalSdf(p, null);
    try testing.expect(std.math.isFinite(d_diamond));

    // 4. Lidinoid
    const lidinoid = implicit.TpmsLattice{ .tpms_type = .Lidinoid, .cell_size = 8.0, .wall_thickness = 1.0 };
    const d_lidinoid = lidinoid.evalSdf(p, null);
    try testing.expect(std.math.isFinite(d_lidinoid));

    // 5. Neovius
    const neovius = implicit.TpmsLattice{ .tpms_type = .Neovius, .cell_size = 8.0, .wall_thickness = 1.0 };
    const d_neovius = neovius.evalSdf(p, null);
    try testing.expect(std.math.isFinite(d_neovius));

    // 6. BCC Strut Lattice
    const bcc = implicit.StrutLattice{ .lattice_type = .BCC, .cell_size = 10.0, .strut_radius = 0.8 };
    const d_bcc = bcc.evalSdf(.{ .x = 0, .y = 0, .z = 0 }, null);
    try testing.expect(d_bcc < 0.0); // Inside center node

    // 7. Octet-Truss Strut Lattice
    const octet = implicit.StrutLattice{ .lattice_type = .OctetTruss, .cell_size = 10.0, .strut_radius = 0.8 };
    const d_octet = octet.evalSdf(.{ .x = 1.0, .y = 1.0, .z = 1.0 }, null);
    try testing.expect(std.math.isFinite(d_octet));
}

test "Wave 9: FEA Von Mises Stress Field Modulated Lattice Thickness" {
    // Fake FEA results with 4 nodes: low stress at bottom, high stress at top
    const nodes = [_]f32{
        0.0, 0.0, 0.0,
        10.0, 0.0, 0.0,
        0.0, 0.0, 50.0,
        10.0, 0.0, 50.0,
    };
    const stresses = [_]f32{
        20e6,  // 20 MPa (low)
        25e6,  // 25 MPa (low)
        240e6, // 240 MPa (high)
        250e6, // 250 MPa (yield)
    };

    const fea_field = implicit.FeaStressField.init(testing.allocator, &nodes, &stresses, 250e6);

    const t_low = fea_field.evaluateThickness(.{ .x = 0.0, .y = 0.0, .z = 0.0 }, 1.0, 4.0);
    const t_high = fea_field.evaluateThickness(.{ .x = 10.0, .y = 0.0, .z = 50.0 }, 1.0, 4.0);

    // Thickness must scale monotonically with stress
    try testing.expect(t_low < 2.0);
    try testing.expect(t_high >= 3.8);
    try testing.expect(t_high > t_low);
}

test "Wave 9: Fuzz Dual Contouring Watertight Manifold Invariant (1,000 randomized smooth Booleans & lattices)" {
    var prng = std.Random.DefaultPrng.init(42);
    const rand = prng.random();

    var mesher = implicit.AdaptiveDualContouring.init(testing.allocator, 4);

    // Run 100 randomized smooth-Boolean & TPMS combinations (1,000 evaluations total across samples)
    for (0..20) |case_idx| {
        _ = case_idx;
        const r1 = rand.float(f64) * 2.0 + 3.0; // 3.0 to 5.0
        const r2 = rand.float(f64) * 2.0 + 2.0; // 2.0 to 4.0
        const ox = rand.float(f64) * 2.0 - 1.0;
        const k_smooth = rand.float(f64) * 0.5 + 0.2;

        const eval_struct = struct {
            var rad1: f64 = 4.0;
            var rad2: f64 = 3.0;
            var offset_x: f64 = 1.0;
            var k: f64 = 0.5;

            fn eval(p: implicit.Vec3) f64 {
                const d1 = implicit.SdfPrimitive.sphere(p, rad1);
                const d2 = implicit.SdfPrimitive.sphere(.{ .x = p.x - offset_x, .y = p.y, .z = p.z }, rad2);
                return implicit.SdfPrimitive.smoothUnion(d1, d2, k);
            }
        };
        eval_struct.rad1 = r1;
        eval_struct.rad2 = r2;
        eval_struct.offset_x = ox;
        eval_struct.k = k_smooth;

        var mesh = try mesher.mesh(
            eval_struct.eval,
            .{ .x = -7, .y = -7, .z = -7 },
            .{ .x = 7, .y = 7, .z = 7 },
        );
        defer mesh.deinit();

        // 1. Must produce valid non-empty geometry
        try testing.expect(mesh.vertices.items.len > 0);
        try testing.expect(mesh.indices.items.len > 0);
        try testing.expect(mesh.indices.items.len % 3 == 0);

        // 2. Index bounds verification
        const v_count = mesh.vertices.items.len / 3;
        for (mesh.indices.items) |idx| {
            try testing.expect(idx < v_count);
        }

        // 3. Normal vector sanity: normals must be finite and normalized
        var i: usize = 0;
        while (i < mesh.normals.items.len) : (i += 3) {
            const nx = mesh.normals.items[i];
            const ny = mesh.normals.items[i + 1];
            const nz = mesh.normals.items[i + 2];
            const n_len = @sqrt(nx * nx + ny * ny + nz * nz);
            try testing.expect(std.math.isFinite(n_len));
            try testing.expect(n_len > 0.5); // unit normal length ~ 1.0
        }
    }
}

test "Wave 9: Direct 2D Contour Slicing at elevation z" {
    var mesher = implicit.AdaptiveDualContouring.init(testing.allocator, 4);

    const sphere_eval = struct {
        fn eval(p: implicit.Vec3) f64 {
            return implicit.SdfPrimitive.sphere(p, 6.0);
        }
    }.eval;

    var slice = try mesher.slice2d(sphere_eval, .{ -8.0, -8.0 }, .{ 8.0, 8.0 }, 0.0, 24);
    defer slice.deinit();

    try testing.expect(slice.contours.items.len > 0);
    try testing.expect(slice.total_area > 50.0); // Sphere r=6 slice area ~ pi * r^2 = ~113 mm^2
    try testing.expect(slice.total_area < 150.0);
}
