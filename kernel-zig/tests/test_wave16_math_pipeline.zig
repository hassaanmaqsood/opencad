const std = @import("std");
const testing = std.testing;
const cad = @import("cad_kernel");

test "Step 2 Unified Pipeline: Constrained NURBS Wire, Kinematic SE(3) Sweep, Fillet, Implicit Boolean, Tessellation, STEP/STL Export" {
    defer _ = cad.cad_kernel_deinit();

    // Initialize Kernel Control Block
    cad.kernel_init();

    // 1. Module 2 Constraint System: Allocate parameters for a 4-point rectangle and circular feature
    const sys_h = cad.sys_create();
    try testing.expect(sys_h != 0);
    try testing.expectEqual(@as(u64, 0b11), sys_h >> 62); // Rule 4: System tag

    // Rectangle corners: P0=(0,0), P1=(10,0), P2=(10,5), P3=(0,5)
    // 8 parameters for 4 2D points (x0, y0, x1, y1, x2, y2, x3, y3) + 1 unit weight
    const init_q = [_]f64{
        0.05, -0.05, // P0 near (0, 0)
        9.8, 0.2,    // P1 near (10, 0)
        10.1, 5.2,   // P2 near (10, 5)
        0.15, 4.85,  // P3 near (0, 5)
        1.0,         // unit weight (slot 8)
    };
    const param_offset = cad.sys_alloc_params(sys_h, &init_q, init_q.len);
    try testing.expectEqual(@as(u32, 0), param_offset);

    // Expressions
    const r_fix = cad.expr_compile("x0".ptr, 2);
    const r_dist10 = cad.expr_compile("(x0 - x2)^2 + (x1 - x3)^2 - 100.0".ptr, 33);
    const r_dist5 = cad.expr_compile("(x0 - x2)^2 + (x1 - x3)^2 - 25.0".ptr, 32);
    const r_ortho = cad.expr_compile("(x0 - x2)*(x4 - x0) + (x1 - x3)*(x5 - x1)".ptr, 41);

    // 1 & 2: P0 at origin
    const p0 = [_]u32{0};
    const p1 = [_]u32{1};
    _ = cad.sys_add_residual(sys_h, r_fix, &p0, 1);
    _ = cad.sys_add_residual(sys_h, r_fix, &p1, 1);

    // 3 & 4: P1 on X axis, dist = 10
    const p3 = [_]u32{3};
    const p_dist10_1 = [_]u32{ 2, 3, 0, 1 };
    _ = cad.sys_add_residual(sys_h, r_fix, &p3, 1);
    _ = cad.sys_add_residual(sys_h, r_dist10, &p_dist10_1, 4);

    // 5 & 6: P2 orthogonal to P0-P1, dist = 5
    const p_ortho_1 = [_]u32{ 2, 3, 0, 1, 4, 5 };
    const p_dist5_1 = [_]u32{ 4, 5, 2, 3 };
    _ = cad.sys_add_residual(sys_h, r_ortho, &p_ortho_1, 6);
    _ = cad.sys_add_residual(sys_h, r_dist5, &p_dist5_1, 4);

    // 7 & 8: P3 orthogonal to P1-P2, dist = 10
    const p_ortho_2 = [_]u32{ 4, 5, 2, 3, 6, 7 };
    const p_dist10_2 = [_]u32{ 6, 7, 4, 5 };
    _ = cad.sys_add_residual(sys_h, r_ortho, &p_ortho_2, 6);
    _ = cad.sys_add_residual(sys_h, r_dist10, &p_dist10_2, 4);

    // 9: Unit weight constraint w = 1.0
    const r_one = cad.expr_compile("x0 - 1.0".ptr, 8);
    const p8 = [_]u32{8};
    _ = cad.sys_add_residual(sys_h, r_one, &p8, 1);

    // Check DOF before solve: 9 params, 9 constraints => DOF = 0
    const dof = cad.sys_get_dof(sys_h);
    try testing.expectEqual(@as(i32, 0), dof);

    // Solve algebraic constraint system
    const solve_ok = cad.sys_solve(sys_h, 1e-12, 100);
    try testing.expectEqual(@as(u32, 0), solve_ok);

    var solved_q: [8]f64 = undefined;
    _ = cad.sys_read_params(sys_h, &solved_q, 8);
    try testing.expectApproxEqAbs(@as(f64, 0.0), solved_q[0], 1e-10);
    try testing.expectApproxEqAbs(@as(f64, 0.0), solved_q[1], 1e-10);
    try testing.expectApproxEqAbs(@as(f64, 10.0), solved_q[2], 1e-10);
    try testing.expectApproxEqAbs(@as(f64, 0.0), solved_q[3], 1e-10);
    try testing.expectApproxEqAbs(@as(f64, 10.0), solved_q[4], 1e-10);
    try testing.expectApproxEqAbs(@as(f64, 5.0), solved_q[5], 1e-10);
    try testing.expectApproxEqAbs(@as(f64, 0.0), solved_q[6], 1e-10);
    try testing.expectApproxEqAbs(@as(f64, 5.0), solved_q[7], 1e-10);

    // 2. Module 1: Assemble NURBS curves linked to parameter slots
    // Edge 1: P0 -> P1 (slots 0..3)
    const knots_deg1 = [_]f64{ 0.0, 0.0, 1.0, 1.0 };
    const c1_slots = [_]u32{ 0, 1, 8, 2, 3, 8 };
    const curve1_h = cad.curve_define_nurbs(sys_h, 2, 1, &c1_slots, 2, &knots_deg1, 4);
    try testing.expect(curve1_h != 0);

    // Edge 2: P1 -> P2 (slots 2..5)
    const c2_slots = [_]u32{ 2, 3, 8, 4, 5, 8 };
    const curve2_h = cad.curve_define_nurbs(sys_h, 2, 1, &c2_slots, 2, &knots_deg1, 4);
    try testing.expect(curve2_h != 0);

    // Edge 3: P2 -> P3 (slots 4..7)
    const c3_slots = [_]u32{ 4, 5, 8, 6, 7, 8 };
    const curve3_h = cad.curve_define_nurbs(sys_h, 2, 1, &c3_slots, 2, &knots_deg1, 4);
    try testing.expect(curve3_h != 0);

    // Edge 4: P3 -> P0 (slots 6, 7, 0, 1)
    const c4_slots = [_]u32{ 6, 7, 8, 0, 1, 8 };
    const curve4_h = cad.curve_define_nurbs(sys_h, 2, 1, &c4_slots, 2, &knots_deg1, 4);
    try testing.expect(curve4_h != 0);

    // Assemble closed rectangular wire on XY chart frame
    const curves = [_]u64{ curve1_h, curve2_h, curve3_h, curve4_h };
    const frame_data = [_]f64{
        0.0, 0.0, 0.0, // p0
        1.0, 0.0, 0.0, // u
        0.0, 1.0, 0.0, // v
    };
    const wire_h = cad.wire_assemble(sys_h, &frame_data, &curves, curves.len);
    try testing.expect(wire_h != 0);
    try testing.expectEqual(@as(u64, 0b11), wire_h >> 62);

    // 3. Kinematic SE(3) Sweep along Z-axis (linear trajectory depth = 10.0, capped ends)
    const swept_solid_h = cad.solid_kinematic_sweep(wire_h, 0, true);
    try testing.expect(swept_solid_h != 0);
    try testing.expectEqual(@as(u64, 0b00), swept_solid_h >> 62); // B-Rep solid tag

    // 4. Differential Envelope Fillet
    // Exact r = 0.2 blend on the four sweep-parallel corner edges (no predicate => all such edges)
    const r_expr = cad.expr_compile("0.2", 3);
    try testing.expect(r_expr != 0);
    const vol_before = cad.surface_brep.solid_brep_store.getPtr(swept_solid_h).?.computeEnclosedVolume();
    const filleted_solid_h = cad.solid_envelope_fillet(swept_solid_h, 0, r_expr);
    try testing.expect(filleted_solid_h != 0);
    const vol_after = cad.surface_brep.solid_brep_store.getPtr(filleted_solid_h).?.computeEnclosedVolume();
    // Each 90-degree corner loses (1 - pi/4) r^2 of profile area, swept over the sweep depth
    const depth = cad.surface_brep.active_sweep_depth;
    const expected_loss = 4.0 * (1.0 - std.math.pi / 4.0) * 0.2 * 0.2 * depth;
    try testing.expectApproxEqRel(expected_loss, vol_before - vol_after, 2e-3);

    // 5. Implicit Scalar Field: Sphere x^2 + y^2 + z^2 - 10000 = 0
    const sphere_expr = cad.expr_compile("x^2 + y^2 + z^2 - 10000".ptr, "x^2 + y^2 + z^2 - 10000".len);
    const domain_bbox = [_]f64{ -110.0, -110.0, -110.0, 110.0, 110.0, 110.0 };
    const implicit_solid_h = cad.solid_implicit_field(sphere_expr, &domain_bbox);
    try testing.expect(implicit_solid_h != 0);
    try testing.expectEqual(@as(u64, 0b10), implicit_solid_h >> 62); // Implicit field tag

    // 6. Lazy CSG Boolean: INTERSECTION (op=1)
    const bool_solid_h = cad.solid_boolean(1, filleted_solid_h, implicit_solid_h);
    try testing.expect(bool_solid_h != 0);
    try testing.expectEqual(@as(u64, 0b01), bool_solid_h >> 62); // CSG node tag

    // 7. Tessellation to Shared Memory at 0x0F0000
    cad.solid_tessellate(bool_solid_h, 0.1, 0.1);

    // Verify positions pointer and lengths
    const pos_ptr = cad.get_positions_ptr();
    const pos_len = cad.get_positions_len();
    const idx_ptr = cad.get_indices_ptr();
    const idx_len = cad.get_indices_len();

    try testing.expect(pos_ptr != null);
    try testing.expect(idx_ptr != null);
    try testing.expect(pos_len >= 8 * 3);
    try testing.expect(idx_len >= 12 * 3);

    // 8. Watertight STEP & STL Exports to 0x3F0000
    const step_len = cad.solid_export_step(bool_solid_h);
    try testing.expect(step_len > 100);
    const step_str_ptr = cad.get_string_ptr();
    const step_str_len = cad.get_string_len();
    try testing.expectEqual(step_len, step_str_len);
    try testing.expect(step_str_ptr != null);

    const stl_bin_len = cad.solid_export_stl(bool_solid_h, true);
    try testing.expect(stl_bin_len >= 84 + (idx_len / 3) * 50);

    const stl_ascii_len = cad.solid_export_stl(bool_solid_h, false);
    try testing.expect(stl_ascii_len > 100);
}

test "Tensor Loft & Offset Shell: Multi-Wire Frustum Loft, Quadratic Skinning, and Watertight Open-Top Shell" {
    defer _ = cad.cad_kernel_deinit();
    cad.kernel_init();

    const sys_h = cad.sys_create();
    try testing.expect(sys_h != 0);

    // Define 3 square profiles:
    // Wire 0 at z = 0:   40 x 40 ([-20, 20]^2), Area = 1600
    // Wire 1 at z = 10:  20 x 20 ([-10, 10]^2), Area = 400
    // Wire 2 at z = 20:  10 x 10 ([-5,  5]^2),  Area = 100
    const q_w0 = [_]f64{ -20.0, -20.0, 20.0, -20.0, 20.0, 20.0, -20.0, 20.0, 1.0 };
    const q_w1 = [_]f64{ -10.0, -10.0, 10.0, -10.0, 10.0, 10.0, -10.0, 10.0, 1.0 };
    const q_w2 = [_]f64{ -5.0, -5.0, 5.0, -5.0, 5.0, 5.0, -5.0, 5.0, 1.0 };

    const b0 = cad.sys_alloc_params(sys_h, &q_w0, q_w0.len);
    const b1 = cad.sys_alloc_params(sys_h, &q_w1, q_w1.len);
    const b2 = cad.sys_alloc_params(sys_h, &q_w2, q_w2.len);

    const knots_lin = [_]f64{ 0.0, 0.0, 1.0, 1.0 };
    const makeSquareWire = struct {
        fn build(sh: u64, base: u32, z_height: f64, kn: *const [4]f64) u64 {
            const w_slot = base + 8;
            var c_handles: [4]u64 = undefined;
            for (0..4) |edge_i| {
                const n_i = (edge_i + 1) % 4;
                const p_a = base + @as(u32, @intCast(edge_i * 2));
                const p_b = base + @as(u32, @intCast(n_i * 2));
                const slots = [6]u32{ p_a, p_a + 1, w_slot, p_b, p_b + 1, w_slot };
                c_handles[edge_i] = cad.curve_define_nurbs(sh, 2, 1, &slots, 2, kn, 4);
            }
            const frame = [9]f64{ 0.0, 0.0, z_height, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0 };
            return cad.wire_assemble(sh, &frame, &c_handles, 4);
        }
    }.build;

    const w0_h = makeSquareWire(sys_h, b0, 0.0, &knots_lin);
    const w1_h = makeSquareWire(sys_h, b1, 10.0, &knots_lin);
    const w2_h = makeSquareWire(sys_h, b2, 20.0, &knots_lin);

    // 1. Ruled 2-section frustum loft (w0 -> w1, degree_v = 1)
    // Exact frustum volume = (h / 3) * (A0 + A1 + sqrt(A0 * A1)) = (10 / 3) * (1600 + 400 + 800) = 9333.333333...
    const wires_2 = [2]u64{ w0_h, w1_h };
    const loft2_h = cad.solid_tensor_loft(&wires_2, 2, 1);
    try testing.expect(loft2_h != 0);
    const loft2_mesh = cad.surface_brep.solid_brep_store.getPtr(loft2_h).?;
    try testing.expect(loft2_mesh.verifyTwoManifoldEdges());
    try testing.expect(loft2_mesh.verifyEulerPoincare());
    const expected_frustum_vol: f64 = (10.0 / 3.0) * (1600.0 + 400.0 + 800.0);
    try testing.expectApproxEqRel(expected_frustum_vol, loft2_mesh.computeEnclosedVolume(), 1e-6);

    // 2. Smooth 3-section quadratic B-spline loft (w0 -> w1 -> w2, degree_v = 2)
    const wires_3 = [3]u64{ w0_h, w1_h, w2_h };
    const loft3_h = cad.solid_tensor_loft(&wires_3, 3, 2);
    try testing.expect(loft3_h != 0);
    const loft3_mesh = cad.surface_brep.solid_brep_store.getPtr(loft3_h).?;
    try testing.expect(loft3_mesh.verifyTwoManifoldEdges());
    try testing.expect(loft3_mesh.verifyEulerPoincare());
    try testing.expect(loft3_mesh.computeEnclosedVolume() > expected_frustum_vol);

    // 3. Non-destructive Offset Shell with Top Face Removed (face_pred = "nz - 0.9 > 0" -> "x5 > 0.9")
    // Extrude w0 (40x40) by depth 10 -> Box volume = 16000.0
    const box_h = cad.solid_kinematic_sweep(w0_h, 0, true);
    try testing.expect(box_h != 0);
    const orig_box_vol = cad.surface_brep.solid_brep_store.getPtr(box_h).?.computeEnclosedVolume();
    try testing.expectApproxEqAbs(@as(f64, 16000.0), orig_box_vol, 1e-6);

    // Predicate variable nz (outward unit normal Z component > 0.9 selects top cap)
    const top_face_pred = cad.expr_compile("nz > 0.9".ptr, "nz > 0.9".len);
    try testing.expect(top_face_pred != 0);

    // Shell with wall thickness 2.0 mm and top face open:
    // Expected volume = 40*40*10 - (40-4)*(40-4)*(10-2) = 16000 - 36*36*8 = 5632.0
    const shelled_h = cad.solid_offset_shell(box_h, top_face_pred, 2.0);
    try testing.expect(shelled_h != 0);
    try testing.expect(shelled_h != box_h); // Non-destructive!

    // Original box must remain untouched
    try testing.expectApproxEqAbs(@as(f64, 16000.0), cad.surface_brep.solid_brep_store.getPtr(box_h).?.computeEnclosedVolume(), 1e-6);

    const shelled_mesh = cad.surface_brep.solid_brep_store.getPtr(shelled_h).?;
    try testing.expect(shelled_mesh.verifyTwoManifoldEdges());
    try testing.expect(shelled_mesh.verifyEulerPoincare());
    try testing.expectApproxEqAbs(@as(f64, 5632.0), shelled_mesh.computeEnclosedVolume(), 1e-5);

    // Verify STEP export contains non-empty CLOSED_SHELL and ADVANCED_FACE entities
    const step_len = cad.solid_export_step(shelled_h);
    try testing.expect(step_len > 500);
    const step_slice = cad.get_string_ptr().?[0..step_len];
    try testing.expect(std.mem.indexOf(u8, step_slice, "ADVANCED_FACE") != null);
    try testing.expect(std.mem.indexOf(u8, step_slice, "CLOSED_SHELL('Shell_1',(#") != null);
    try testing.expect(std.mem.indexOf(u8, step_slice, ",.F.);") != null); // Shared EDGE_CURVE with opposite orientation!
}

test "CSG Straddling Triangle Subdivision, Off-Axis Analytic Region Seed, Cap-Edge Fillet & Octree-Depth 5 Implicit Mesh" {
    defer _ = cad.cad_kernel_deinit();
    cad.kernel_init();

    // 1. Off-axis Analytic Region Cylinder centered at (35.0, -25.0), R = 12.0, Z in [0, 25]
    // Completely disjoint from the Z-axis (0, 0, z): tests 3D Interval Arithmetic seed discovery!
    var var_map = std.StringHashMap(u32).init(testing.allocator);
    defer var_map.deinit();
    const terms = [_]cad.surface_brep.RegionIneqTerm{
        .{ .id = "wall", .branch_hash = 0x1111, .expr_str = "144.0 - ((x - 35.0)^2 + (y + 25.0)^2)" },
        .{ .id = "bot", .branch_hash = 0x2222, .expr_str = "z" },
        .{ .id = "top", .branch_hash = 0x3333, .expr_str = "25.0 - z" },
    };
    const cyl_h = try cad.surface_brep.constructAnalyticRegionBrep(
        testing.allocator,
        0xABCD,
        &terms,
        &var_map,
        &[_]f64{},
    );
    try testing.expect(cyl_h != 0);
    const cyl_mesh = cad.surface_brep.solid_brep_store.getPtr(cyl_h).?;
    try testing.expect(cyl_mesh.verifyTwoManifoldEdges());
    try testing.expect(cyl_mesh.verifyEulerPoincare());
    const expected_cyl_vol = std.math.pi * 12.0 * 12.0 * 25.0;
    const cyl_vol_before = cyl_mesh.computeEnclosedVolume();
    try testing.expectApproxEqRel(expected_cyl_vol, cyl_vol_before, 1e-3);

    // Verify all 512 triangles of the cylinder are exported to STEP without truncation
    const step_len = cad.solid_export_step(cyl_h);
    try testing.expect(step_len > 10000);

    // 2. Cap-Edge Rolling-Ball Fillet (abs(tz) < 0.001) on top and bottom cap edges of the cylinder (r = 1.5 mm)
    const cap_pred = cad.expr_compile("abs(tz) < 0.001".ptr, "abs(tz) < 0.001".len);
    const cap_r_expr = cad.expr_compile("1.5".ptr, "1.5".len);
    try testing.expect(cap_pred != 0 and cap_r_expr != 0);
    const cap_filleted_h = cad.solid_envelope_fillet(cyl_h, cap_pred, cap_r_expr);
    try testing.expect(cap_filleted_h != 0);
    const cap_filleted_mesh = cad.surface_brep.solid_brep_store.getPtr(cap_filleted_h).?;
    try testing.expect(cap_filleted_mesh.verifyTwoManifoldEdges());
    try testing.expect(cap_filleted_mesh.verifyEulerPoincare());
    const cyl_vol_after = cap_filleted_mesh.computeEnclosedVolume();
    try testing.expect(cyl_vol_after < cyl_vol_before);

    // Verify analytical curvature k_max = 1 / 1.5 on cap fillet rolling-ball strip triangles
    var found_fillet_curv = false;
    for (cap_filleted_mesh.triangle_curvatures.items) |curv| {
        if (@abs(curv.k_max - (1.0 / 1.5)) < 1e-6) {
            found_fillet_curv = true;
            break;
        }
    }
    try testing.expect(found_fillet_curv);

    // 3. CSG Straddling Triangle Subdivision:
    // (a) Subtract an implicit sphere of radius 10.0 centered at (35, -25, 25) from the cap-filleted cylinder
    // and verify enclosed volume decreases by the exact intersection volume via straddling triangle subdivision.
    const cut_sphere_str = "(x - 35.0)^2 + (y + 25.0)^2 + (z - 25.0)^2 - 100.0";
    const cut_sphere_expr = cad.expr_compile(cut_sphere_str.ptr, cut_sphere_str.len);
    const cut_bbox = [6]f64{ 15.0, -45.0, -5.0, 55.0, -5.0, 45.0 };
    const cut_sphere_h = cad.solid_implicit_field(cut_sphere_expr, &cut_bbox);
    const csg_cut_h = cad.solid_boolean(1, cap_filleted_h, cut_sphere_h); // op=1 (Subtract)
    try testing.expect(csg_cut_h != 0);
    const csg_cut_mesh = cad.surface_brep.solid_brep_store.getPtr(csg_cut_h).?;
    const cut_vol = csg_cut_mesh.computeEnclosedVolume();
    // Hemisphere of R=10 inside the top of the cylinder has volume ~ (2/3)*pi*10^3 = 2094.4 mm^3
    try testing.expect(cut_vol < cyl_vol_after - 1500.0);
    try testing.expect(cut_vol > cyl_vol_after - 2600.0);

    // (b) Intersect Gyroid Lattice with Annular Mask (r >= 18.0 mm) and verify ZERO vertices protrude inside r < 17.95 mm
    const gyroid_str = "abs_smooth(sin(0.7*x)*cos(0.7*y) + sin(0.7*y)*cos(0.7*z) + sin(0.7*z)*cos(0.7*x), 1e-4) - 0.35";
    const gyroid_expr = cad.expr_compile(gyroid_str.ptr, gyroid_str.len);
    const mask_str = "18.0 - sqrt(x^2 + y^2)";
    const mask_expr = cad.expr_compile(mask_str.ptr, mask_str.len);
    const bbox = [6]f64{ -30.0, -30.0, 0.0, 30.0, 30.0, 10.0 };
    const gyroid_h = cad.solid_implicit_field(gyroid_expr, &bbox);
    const mask_h = cad.solid_implicit_field(mask_expr, &bbox);
    const clipped_h = cad.solid_boolean(2, mask_h, gyroid_h);
    const clipped_mesh = cad.surface_brep.solid_brep_store.getPtr(clipped_h).?;
    try testing.expect(clipped_mesh.indices.items.len > 0);
    for (clipped_mesh.vertices.items) |v| {
        const r = @sqrt(v.x * v.x + v.y * v.y);
        try testing.expect(r >= 17.95);
    }

    // 4. Explicit octree-depth="5" (32^3 Dual Contouring with Newton-Gradient surface projection)
    const oct5_sphere_str = "x^2 + y^2 + z^2 - 64.0"; // Sphere R = 8.0
    const oct5_expr = cad.expr_compile(oct5_sphere_str.ptr, oct5_sphere_str.len);
    const oct5_bbox = [6]f64{ -12.0, -12.0, -12.0, 12.0, 12.0, 12.0 };
    const oct5_h = cad.implicit_field.solid_implicit_field_WithParams(oct5_expr, &oct5_bbox, 5, 1e-4);
    try testing.expect(oct5_h != 0);
    const oct5_mesh = cad.surface_brep.solid_brep_store.getPtr(oct5_h).?;
    try testing.expect(oct5_mesh.vertices.items.len > 200);
    // Every projected Dual Contouring vertex should lie tightly on the R = 8.0 sphere surface
    for (oct5_mesh.vertices.items) |v| {
        const rad = @sqrt(v.x * v.x + v.y * v.y + v.z * v.z);
        try testing.expectApproxEqAbs(@as(f64, 8.0), rad, 0.25);
    }
}
