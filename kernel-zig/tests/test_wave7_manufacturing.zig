const std = @import("std");
const cad = @import("cad_kernel");

const sm_mod = cad.SheetMetalMod;
const cam_mod = cad.CamHlrMod;

test "Wave 7: DIN 6935 neutral axis bend allowance analytical precision <= 1e-9 mm" {
    const mat = sm_mod.SheetMetalMaterial{
        .thickness = 2.0,
        .inner_bend_radius = 3.0,
        .default_k_factor = 0.44,
    };

    const theta_90 = std.math.pi / 2.0;
    const computed_ba = mat.calcBendAllowance(theta_90);
    // Analytical: (PI / 2) * (3.0 + 0.44 * 2.0) = (PI / 2) * 3.88
    const expected_ba = (std.math.pi / 2.0) * 3.88;
    const delta = @abs(computed_ba - expected_ba);

    try std.testing.expect(delta <= 1e-9);

    const computed_ossb = mat.calcOutsideSetback(theta_90);
    // Analytical: tan(pi/4) * (3.0 + 2.0) = 1.0 * 5.0 = 5.0
    const expected_ossb = 5.0;
    try std.testing.expectApproxEqAbs(expected_ossb, computed_ossb, 1e-9);

    const computed_bd = mat.calcBendDeduction(theta_90);
    const expected_bd = 2.0 * expected_ossb - expected_ba;
    try std.testing.expectApproxEqAbs(expected_bd, computed_bd, 1e-9);

    const flat_l = mat.calcFlatLength(40.0, 60.0, theta_90);
    const expected_flat = 100.0 - expected_bd;
    try std.testing.expectApproxEqAbs(expected_flat, flat_l, 1e-9);
}

test "Wave 7: Sheet metal multi-flange box unfolding and corner reliefs" {
    const mat = sm_mod.SheetMetalMaterial{
        .thickness = 1.5,
        .inner_bend_radius = 2.0,
        .default_k_factor = 0.44,
    };
    var sm = sm_mod.SheetMetalSolid.init(std.testing.allocator, mat, 60.0, 80.0);
    defer sm.deinit();

    // Flange 0: Edge 0 with rectangular relief
    try sm.addFlange(.{
        .edge_index = 0,
        .length = 25.0,
        .angle_rad = std.math.pi / 2.0,
        .relief_type = .Rectangular,
        .relief_width = 1.5,
        .relief_depth = 2.0,
    });

    // Flange 1: Adjacent Edge 1 with obround relief (should trigger automatic miter detection)
    try sm.addFlange(.{
        .edge_index = 1,
        .length = 25.0,
        .angle_rad = std.math.pi / 2.0,
        .relief_type = .Obround,
        .relief_width = 1.5,
        .relief_depth = 2.0,
    });

    // Flange 2: Edge 2 with tear relief
    try sm.addFlange(.{
        .edge_index = 2,
        .length = 20.0,
        .angle_rad = std.math.pi / 2.0,
        .relief_type = .Tear,
    });

    try std.testing.expectEqual(@as(usize, 3), sm.flanges.items.len);
    // Verify adjacent corner miter was applied
    try std.testing.expectApproxEqAbs(std.math.pi / 4.0, sm.flanges.items[1].miter_angle_rad, 1e-6);

    // Unfold solid to 2D flat blank
    var unfolder = sm_mod.SheetMetalUnfolder.init(std.testing.allocator);
    var flat = try unfolder.unfold(&sm);
    defer flat.deinit();

    try std.testing.expectEqual(@as(usize, 3), flat.bend_lines.items.len);
    try std.testing.expect(flat.total_width > 60.0);
    try std.testing.expect(flat.total_length > 80.0);
    try std.testing.expect(flat.total_cut_length > 0.0);
    try std.testing.expect(flat.total_area > 4800.0); // > 60 * 80 base area

    // Check bend allowance matches exact formula for each bend line
    const ba_expected = (std.math.pi / 2.0) * (2.0 + 0.44 * 1.5);
    for (flat.bend_lines.items) |bl| {
        try std.testing.expectApproxEqAbs(ba_expected, bl.bend_allowance, 1e-9);
    }
}

test "Wave 7: Sheet metal 180-degree hem calculation" {
    const mat = sm_mod.SheetMetalMaterial{
        .thickness = 1.2,
        .inner_bend_radius = 0.6,
        .default_k_factor = 0.44,
    };
    var sm = sm_mod.SheetMetalSolid.init(std.testing.allocator, mat, 50.0, 50.0);
    defer sm.deinit();

    try sm.addHem(.{
        .edge_index = 0,
        .hem_type = .Open,
        .length = 8.0,
        .gap = 1.2,
        .bend_radius = 0.6,
    });

    try std.testing.expectEqual(@as(usize, 1), sm.hems.items.len);

    var unfolder = sm_mod.SheetMetalUnfolder.init(std.testing.allocator);
    var flat = try unfolder.unfold(&sm);
    defer flat.deinit();

    // 180-degree bend allowance: PI * (R + K * T)
    const hem_ba = std.math.pi * (0.6 + 0.44 * 1.2);
    try std.testing.expect(flat.total_length > 50.0 + 8.0 + hem_ba - 0.1);
}

test "Wave 7: 2D HLR projection, visibility classification and section hatching" {
    var proj = cam_mod.HlrProjector.init(std.testing.allocator);

    // Front view
    var front_view = try proj.projectBox([_]f64{ 0, 0, 0 }, [_]f64{ 40, 30, 20 }, .Front, true);
    defer front_view.deinit();

    try std.testing.expect(front_view.curves.items.len >= 12);
    try std.testing.expect(front_view.bbox[2] >= 40.0);
    try std.testing.expect(front_view.bbox[3] >= 30.0);

    // Isometric view
    var iso_view = try proj.projectBox([_]f64{ 0, 0, 0 }, [_]f64{ 40, 30, 20 }, .Isometric, false);
    defer iso_view.deinit();
    try std.testing.expect(iso_view.curves.items.len > 0);

    // Section view with cross-hatching
    var sec_view = try proj.projectBox([_]f64{ 0, 0, 0 }, [_]f64{ 40, 30, 20 }, .Section, true);
    defer sec_view.deinit();

    var has_hatch = false;
    for (sec_view.curves.items) |c| {
        if (c.visibility == .Hatch) has_hatch = true;
    }
    try std.testing.expect(has_hatch);
    try std.testing.expect(sec_view.section_cut_area > 0.0);
}

test "Wave 7: Vector export validity for AutoCAD DXF and W3C SVG" {
    var proj = cam_mod.HlrProjector.init(std.testing.allocator);
    var view = try proj.projectBox([_]f64{ 0, 0, 0 }, [_]f64{ 50, 40, 25 }, .Front, true);
    defer view.deinit();

    // 1. DXF Exporter
    var dxf_exp = cam_mod.DxfExporter.init(std.testing.allocator);
    const dxf_text = try dxf_exp.exportDxf(&view);
    defer std.testing.allocator.free(dxf_text);

    try std.testing.expect(std.mem.indexOf(u8, dxf_text, "0\nSECTION\n2\nHEADER") != null);
    try std.testing.expect(std.mem.indexOf(u8, dxf_text, "LAYER\n2\nVISIBLE") != null);
    try std.testing.expect(std.mem.indexOf(u8, dxf_text, "LAYER\n2\nHIDDEN") != null);
    try std.testing.expect(std.mem.indexOf(u8, dxf_text, "LAYER\n2\nCENTERLINE") != null);
    try std.testing.expect(std.mem.indexOf(u8, dxf_text, "0\nENDSEC\n0\nEOF\n") != null);

    // 2. SVG Exporter
    var svg_exp = cam_mod.SvgDrawingExporter.init(std.testing.allocator);
    const svg_text = try svg_exp.exportSvg(&view, 420.0, 297.0);
    defer std.testing.allocator.free(svg_text);

    try std.testing.expect(std.mem.indexOf(u8, svg_text, "<?xml") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg_text, "<svg xmlns=") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg_text, "OPENCAD ENGINEERING DRAWING") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg_text, "ISO 128 / ASME Y14.5") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg_text, "class=\"visible\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg_text, "</svg>") != null);
}

test "Wave 7: 3MF production packaging conforms to 3MF Core XML" {
    var packer = cam_mod.ThreeMfPacker.init(std.testing.allocator, .{});

    const verts = [_]f32{
        0, 0, 0,
        10, 0, 0,
        10, 10, 0,
        0, 10, 0,
    };
    const idxs = [_]u32{ 0, 1, 2, 0, 2, 3 };

    const xml = try packer.generate3MfModelXml(&verts, &idxs);
    defer std.testing.allocator.free(xml);

    try std.testing.expect(std.mem.indexOf(u8, xml, "<model unit=\"millimeter\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<object id=\"1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<vertex x=\"10.0000\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<triangle v1=\"0\" v2=\"1\" v3=\"2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<item objectid=\"1\"") != null);
}

test "Wave 7: Build volume nesting solver (2D plate and 3D sinter box)" {
    const cfg_2d = cam_mod.NestingConfig{
        .mode = .BuildPlate2D,
        .build_volume_dx = 150.0,
        .build_volume_dy = 150.0,
        .part_spacing_mm = 5.0,
        .margin_boundary_mm = 10.0,
    };
    var packer_2d = cam_mod.NestingPacker.init(std.testing.allocator, cfg_2d);

    const handles = [_]u64{ 101, 102, 103, 104 };
    const boxes = [_][3]f64{
        [_]f64{ 40.0, 40.0, 20.0 },
        [_]f64{ 40.0, 40.0, 20.0 },
        [_]f64{ 40.0, 40.0, 20.0 },
        [_]f64{ 40.0, 40.0, 20.0 },
    };

    var res_2d = try packer_2d.packParts(&handles, &boxes);
    defer res_2d.deinit();

    try std.testing.expectEqual(@as(u32, 4), res_2d.parts_packed_count);
    try std.testing.expectEqual(@as(u32, 0), res_2d.parts_overflow_count);
    try std.testing.expect(res_2d.packing_density_percent > 0.0);

    // Verify 4x4 transform column-major translation values
    for (res_2d.instances.items) |inst| {
        try std.testing.expect(inst.fits_in_volume);
        // Translation X in transform_4x4[12] must be > 0 and < 150
        try std.testing.expect(inst.transform_4x4[12] > 0.0 and inst.transform_4x4[12] < 150.0);
        // Translation Y in transform_4x4[13] must be > 0 and < 150
        try std.testing.expect(inst.transform_4x4[13] > 0.0 and inst.transform_4x4[13] < 150.0);
    }
}

test "Wave 7: CNC CAM toolpath non-gouging invariant and G-code formatting" {
    const params = cam_mod.CamParams{
        .strategy = .Contour2D,
        .tool = .{ .tool_number = 2, .diameter_mm = 6.0 },
        .spindle_rpm = 12000.0,
        .feed_cutting_mmpm = 1200.0,
        .feed_plunge_mmpm = 300.0,
        .stepdown_mm = 2.0,
        .stock_to_leave = 0.2, // 0.2 mm finish stock
        .clearance_height_mm = 5.0,
    };
    var cam = cam_mod.CncCamGenerator.init(std.testing.allocator, params);

    // Target pocket / profile boundary: 0 to 50 in X, 0 to 50 in Y
    const px = [_]f64{ 0.0, 50.0, 50.0, 0.0 };
    const py = [_]f64{ 0.0, 0.0, 50.0, 50.0 };

    var res = try cam.generateToolpath(&px, &py, 6.0);
    defer res.deinit();

    try std.testing.expect(res.gcode_text.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, res.gcode_text, "T2 M06") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.gcode_text, "S12000 M03") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.gcode_text, "G00 Z5.000") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.gcode_text, "M30") != null);

    // Verify non-gouging: cutter center point is offset by tool radius + stock (3.0 + 0.2 = 3.2mm)
    const expected_offset = (6.0 * 0.5) + 0.2;
    // Check visual vertices
    const pts = res.visual_points.items;
    try std.testing.expect(pts.len >= 6);

    // The start X and Y should reflect the offset: -3.2
    try std.testing.expectApproxEqAbs(-expected_offset, pts[0], 1e-3);
    try std.testing.expectApproxEqAbs(-expected_offset, pts[1], 1e-3);
}

test "Wave 15: Watertight Binary & ASCII STL export from B-Rep solid" {
    _ = cad.cad_kernel_init();
    defer _ = cad.cad_kernel_deinit();

    var box_h: cad.c_abi.CadSolidHandle = 0;
    try std.testing.expectEqual(cad.c_abi.CadStatus.Ok, cad.cad_primitive_box(20.0, 30.0, 40.0, &box_h));

    // 1. Binary STL Export
    var bin_ptr: [*]u8 = undefined;
    var bin_len: usize = 0;
    try std.testing.expectEqual(cad.c_abi.CadStatus.Ok, cad.cad_export_stl(box_h, 0.02, 0.5, true, &bin_ptr, &bin_len));
    defer _ = cad.cad_stl_free(bin_ptr, bin_len);

    try std.testing.expect(bin_len >= 84);
    const tri_count = std.mem.readInt(u32, bin_ptr[80..][0..4], .little);
    try std.testing.expectEqual(@as(u32, 12), tri_count); // 6 box faces * 2 triangles = 12
    try std.testing.expectEqual(@as(usize, 80 + 4 + 12 * 50), bin_len);

    // 2. ASCII STL Export
    var ascii_ptr: [*]u8 = undefined;
    var ascii_len: usize = 0;
    try std.testing.expectEqual(cad.c_abi.CadStatus.Ok, cad.cad_export_stl(box_h, 0.02, 0.5, false, &ascii_ptr, &ascii_len));
    defer _ = cad.cad_stl_free(ascii_ptr, ascii_len);

    const ascii_slice = ascii_ptr[0..ascii_len];
    try std.testing.expect(std.mem.startsWith(u8, ascii_slice, "solid OpenCAD_Part\n"));
    try std.testing.expect(std.mem.indexOf(u8, ascii_slice, "facet normal") != null);
    try std.testing.expect(std.mem.indexOf(u8, ascii_slice, "vertex") != null);
    try std.testing.expect(std.mem.endsWith(u8, ascii_slice, "endsolid OpenCAD_Part\n"));
}
