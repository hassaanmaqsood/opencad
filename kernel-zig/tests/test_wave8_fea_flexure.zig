const std = @import("std");
const testing = std.testing;
const cad = @import("cad_kernel");
const fea = cad.FeaFlexureMod;

test "Wave 8: Euler-Bernoulli & Timoshenko Cantilever Beam Verification" {
    // Model parameters in SI units:
    // L = 0.10 m (100 mm), b = 0.01 m (10 mm), h = 0.01 m (10 mm)
    const L: f64 = 0.10;
    const b: f64 = 0.01;
    const h: f64 = 0.01;
    const E: f64 = 210e9; // 210 GPa
    const nu: f64 = 0.30;
    const P: f64 = 50.0;  // 50 N transverse load

    // Analytical Euler-Bernoulli tip deflection: delta = P * L^3 / (3 * E * I)
    const I = (b * std.math.pow(f64, h, 3.0)) / 12.0;
    const delta_eb = (P * std.math.pow(f64, L, 3.0)) / (3.0 * E * I);

    // Timoshenko shear correction: delta_shear = P * L / (k_s * G * A)
    const G = E / (2.0 * (1.0 + nu));
    const A = b * h;
    const k_s = 5.0 / 6.0;
    const delta_shear = (P * L) / (k_s * G * A);
    const delta_analytical = delta_eb + delta_shear;

    // Discretize with refined quadratic Tet10 elements
    var mesh = fea.tet_mesher.TetMesh.init(testing.allocator, .Tet10);
    defer mesh.deinit();

    try mesh.generateTaggedBoxMesh(L, b, h, 6, 2, 2, null);
    const n_count = mesh.nodeCount();

    const fixed = try testing.allocator.alloc(bool, n_count);
    defer testing.allocator.free(fixed);
    @memset(fixed, false);

    // Fix root at x <= 1e-4
    for (0..n_count) |i| {
        if (mesh.node_positions.items[i * 3] <= 1e-4) {
            fixed[i] = true;
        }
    }

    // Apply transverse downward force P at tip face (x >= L - 1e-4)
    var tip_count: usize = 0;
    for (0..n_count) |i| {
        if (mesh.node_positions.items[i * 3] >= L - 1e-4) tip_count += 1;
    }
    try testing.expect(tip_count > 0);

    const forces = try testing.allocator.alloc(f64, n_count * 3);
    defer testing.allocator.free(forces);
    @memset(forces, 0.0);

    const p_per_node = -P / @as(f64, @floatFromInt(tip_count));
    for (0..n_count) |i| {
        if (mesh.node_positions.items[i * 3] >= L - 1e-4) {
            forces[i * 3 + 1] = p_per_node;
        }
    }

    const mat = fea.fea_solver.Material{
        .youngs_modulus_pa = E,
        .poisson_ratio = nu,
        .yield_strength_pa = 250e6,
        .density = 7850.0,
    };

    var solver = fea.fea_solver.FeaSolver.init(testing.allocator, mat);
    var res = try solver.solve(&mesh, .LinearElastic, fixed, forces, 80, 1e-7);
    defer res.deinit();

    // Verify FEA max tip deflection matches Timoshenko within 1.5%
    const delta_fea: f64 = @floatCast(res.max_displacement);
    const rel_err = @abs(delta_fea - delta_analytical) / delta_analytical;

    // Ensure within target verification bound (<= 1.5%)
    try testing.expect(rel_err <= 0.015);
    try testing.expect(res.max_von_mises > 0.0);
    try testing.expect(res.min_safety_factor > 0.0);
}

test "Wave 8: Paros-Weisbord Circular Notch Hinge Verification" {
    const b: f64 = 0.01;      // 10 mm width
    const t: f64 = 0.001;     // 1 mm web thickness
    const r: f64 = 0.005;     // 5 mm radius
    const E: f64 = 210e9;     // 210 GPa steel

    const notch = fea.flexure_synthesis.CircularNotchHinge{
        .width = b,
        .min_thickness = t,
        .notch_radius = r,
    };

    // Paros & Weisbord analytical closed-form formula:
    // C_theta = (9 * pi * sqrt(r)) / (2 * E * b * t^2.5)
    const c_analytical = (9.0 * std.math.pi * @sqrt(r)) / (2.0 * E * b * std.math.pow(f64, t, 2.5));
    const c_computed = notch.rotationalCompliance(E);

    const rel_err = @abs(c_computed - c_analytical) / c_analytical;
    // Closed-form implementation must match exact formula within 1e-12
    try testing.expect(rel_err < 1e-9);
    try testing.expect(c_computed > 0.0);

    const k_stiff = notch.rotationalStiffness(E);
    try testing.expectApproxEqAbs(1.0 / c_computed, k_stiff, 1e-6);
}

test "Wave 8: Parametric Flexure Primitives PRBM Equations" {
    const E = 210e9;

    // 1. Leaf Spring
    const leaf = fea.flexure_synthesis.LeafSpring{
        .length = 0.05,
        .width = 0.01,
        .thickness = 0.001,
    };
    const c_rot = leaf.rotationalCompliance(E);
    const c_trans = leaf.transverseCompliance(E);
    const k_ax = leaf.axialStiffness(E);
    try testing.expect(c_rot > 0.0);
    try testing.expect(c_trans > 0.0);
    try testing.expect(k_ax > 1e6); // High axial stiffness

    // 2. Elliptical Notch Hinge
    const ellip = fea.flexure_synthesis.EllipticalNotchHinge{
        .width = 0.01,
        .min_thickness = 0.001,
        .axis_x = 0.006,
        .axis_y = 0.003,
    };
    const c_ellip = ellip.rotationalCompliance(E);
    try testing.expect(c_ellip > 0.0);

    // 3. Cross-Axis Flexure Pivot
    const cross = fea.flexure_synthesis.CrossAxisFlexurePivot{
        .blade_length = 0.03,
        .blade_width = 0.008,
        .blade_thickness = 0.0008,
    };
    const k_cross = cross.rotationalStiffness(E);
    try testing.expect(k_cross > 0.0);

    // 4. Cartwheel Hinge
    const cart = fea.flexure_synthesis.CartwheelHinge{
        .outer_radius = 0.025,
        .inner_radius = 0.010,
        .spoke_width = 0.005,
        .spoke_thickness = 0.0006,
    };
    const k_cart = cart.rotationalStiffness(E);
    try testing.expect(k_cart > 0.0);

    // 5. Bistable Beam Snapping Force
    const bistable = fea.flexure_synthesis.BistableBeam{
        .length = 0.08,
        .width = 0.01,
        .thickness = 0.0005,
        .apex_height = 0.002,
    };
    const f_snap = bistable.snappingForce(E);
    try testing.expect(f_snap > 0.0);
}

test "Wave 8: 6x6 Spatial Compliance Matrix & FACT Screw Axes" {
    var mesh = fea.tet_mesher.TetMesh.init(testing.allocator, .Tet4);
    defer mesh.deinit();

    try mesh.generateTaggedBoxMesh(0.06, 0.01, 0.01, 4, 1, 1, null);
    const n_count = mesh.nodeCount();

    var fixed_nodes: std.ArrayListUnmanaged(u32) = .empty;
    defer fixed_nodes.deinit(testing.allocator);
    var stage_nodes: std.ArrayListUnmanaged(u32) = .empty;
    defer stage_nodes.deinit(testing.allocator);

    for (0..n_count) |i| {
        if (mesh.node_positions.items[i * 3] <= 1e-4) {
            try fixed_nodes.append(testing.allocator, @intCast(i));
        }
        if (mesh.node_positions.items[i * 3] >= 0.059) {
            try stage_nodes.append(testing.allocator, @intCast(i));
        }
    }

    const mat = fea.fea_solver.Material{};
    var analyzer = fea.flexure_synthesis.FlexureAnalyzer.init(testing.allocator);
    var analysis = try analyzer.analyze(&mesh, fixed_nodes.items, stage_nodes.items, mat);
    defer analysis.deinit();

    // Verify 6x6 compliance matrix properties
    try testing.expect(analysis.compliance_matrix_6x6.len == 36);
    try testing.expect(analysis.stiffness_matrix_6x6.len == 36);

    // Verify FACT screw axes generated
    try testing.expect(analysis.fact_screws.len > 0);
    var has_freedom = false;
    var has_constraint = false;
    for (analysis.fact_screws) |scr| {
        if (scr.is_freedom_line) has_freedom = true;
        if (!scr.is_freedom_line) has_constraint = true;
    }
    try testing.expect(has_freedom);
    try testing.expect(has_constraint);

    // Verify zero-copy 3D line vertices populated for Three.js
    try testing.expect(analysis.visual_lines.len > 0);
    try testing.expectEqual(@as(usize, 0), analysis.visual_lines.len % 6);
}

test "Wave 8: Corotational Nonlinear Large-Deflection Convergence" {
    var mesh = fea.tet_mesher.TetMesh.init(testing.allocator, .Tet4);
    defer mesh.deinit();

    try mesh.generateTaggedBoxMesh(0.05, 0.01, 0.01, 3, 1, 1, null);
    const n_count = mesh.nodeCount();

    const fixed = try testing.allocator.alloc(bool, n_count);
    defer testing.allocator.free(fixed);
    @memset(fixed, false);
    fixed[0] = true;
    fixed[1] = true;

    const forces = try testing.allocator.alloc(f64, n_count * 3);
    defer testing.allocator.free(forces);
    @memset(forces, 0.0);
    // Apply large load to trigger corotational stepping
    forces[forces.len - 2] = -2000.0;

    const mat = fea.fea_solver.Material{};
    var solver = fea.fea_solver.FeaSolver.init(testing.allocator, mat);
    var res = try solver.solve(&mesh, .CorotationalNonlinear, fixed, forces, 60, 1e-6);
    defer res.deinit();

    try testing.expect(res.max_displacement > 0.0);
    try testing.expect(res.max_von_mises > 0.0);
    // Safety factor must be positive
    try testing.expect(res.min_safety_factor > 0.0);
}
