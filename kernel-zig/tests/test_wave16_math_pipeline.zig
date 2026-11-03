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
    const filleted_solid_h = cad.solid_envelope_fillet(swept_solid_h, 0, 0);
    try testing.expect(filleted_solid_h != 0);

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
