const std = @import("std");
const testing = std.testing;
const cad = @import("cad_kernel");

const sm_mod = cad.SheetMetalMod;
const fea_mod = cad.FeaFlexureMod;
const implicit_mod = cad.ImplicitMod;
const cam_mod = cad.CamHlrMod;

test "Wave 10 Pipeline - Template 1: Parametric CNC Machined Bracket" {
    const allocator = testing.allocator;

    // 1. Generate 2D/3D Orthographic Projection & Blueprint View
    var proj = cam_mod.HlrProjector.init(allocator);
    var view = try proj.projectBox([_]f64{ 0, 0, 0 }, [_]f64{ 80.0, 50.0, 20.0 }, .Front, true);
    defer view.deinit();

    try testing.expect(view.curves.items.len > 0);

    // 2. Export 2D AutoCAD DXF Blueprint
    var dxf_exp = cam_mod.DxfExporter.init(allocator);
    const dxf_text = try dxf_exp.exportDxf(&view);
    defer allocator.free(dxf_text);

    try testing.expect(std.mem.indexOf(u8, dxf_text, "0\nSECTION\n2\nHEADER") != null);
    try testing.expect(std.mem.indexOf(u8, dxf_text, "VISIBLE") != null);

    // 3. Generate 2.5D CNC Contour Toolpath G-Code
    const params = cam_mod.CamParams{
        .strategy = .Contour2D,
        .tool = .{ .tool_number = 1, .diameter_mm = 6.0 },
        .spindle_rpm = 12000.0,
        .feed_cutting_mmpm = 800.0,
        .feed_plunge_mmpm = 300.0,
        .stepdown_mm = 2.0,
        .stock_to_leave = 0.0,
        .clearance_height_mm = 5.0,
    };
    var cam = cam_mod.CncCamGenerator.init(allocator, params);

    const px = [_]f64{ 10.0, 70.0, 70.0, 10.0 };
    const py = [_]f64{ 10.0, 10.0, 40.0, 40.0 };

    var res = try cam.generateToolpath(&px, &py, 5.0);
    defer res.deinit();

    try testing.expect(res.gcode_text.len > 50);
    try testing.expect(std.mem.indexOf(u8, res.gcode_text, "G01") != null);
    try testing.expect(std.mem.indexOf(u8, res.gcode_text, "M30") != null);
}

test "Wave 10 Pipeline - Template 2: Sheet Metal Electronics Enclosure" {
    const allocator = testing.allocator;

    // 1. Initialize Sheet Metal Model with DIN 6935 K-factor 0.44
    const mat = sm_mod.SheetMetalMaterial{
        .thickness = 1.5,
        .inner_bend_radius = 2.0,
        .default_k_factor = 0.44,
    };
    var sm = sm_mod.SheetMetalSolid.init(allocator, mat, 120.0, 80.0);
    defer sm.deinit();

    // 2. Add 4 Bent Edge Flanges (Length 30mm & 25mm, 90 deg)
    try sm.addFlange(.{
        .edge_index = 0,
        .length = 30.0,
        .angle_rad = std.math.pi / 2.0,
        .relief_type = .Rectangular,
        .relief_width = 1.5,
        .relief_depth = 2.0,
    });
    try sm.addFlange(.{
        .edge_index = 1,
        .length = 30.0,
        .angle_rad = std.math.pi / 2.0,
        .relief_type = .Rectangular,
        .relief_width = 1.5,
        .relief_depth = 2.0,
    });
    try sm.addFlange(.{
        .edge_index = 2,
        .length = 25.0,
        .angle_rad = std.math.pi / 2.0,
        .relief_type = .Rectangular,
        .relief_width = 1.5,
        .relief_depth = 2.0,
    });
    try sm.addFlange(.{
        .edge_index = 3,
        .length = 25.0,
        .angle_rad = std.math.pi / 2.0,
        .relief_type = .Rectangular,
        .relief_width = 1.5,
        .relief_depth = 2.0,
    });

    try testing.expectEqual(@as(usize, 4), sm.flanges.items.len);

    // 3. Unfold Flat Pattern with exact Neutral Axis BA
    var unfolder = sm_mod.SheetMetalUnfolder.init(allocator);
    var flat = try unfolder.unfold(&sm);
    defer flat.deinit();

    try testing.expect(flat.bend_lines.items.len == 4);
    try testing.expect(flat.total_width > 120.0);
    try testing.expect(flat.total_length > 80.0);
}

test "Wave 10 Pipeline - Template 3: Precision Planar XY Compliant Flexure Stage" {
    const allocator = testing.allocator;

    // 1. Analytical leaf spring initial sizing
    const E = 200e9; // 200 GPa Structural Steel
    const leaf = fea_mod.flexure_synthesis.LeafSpring{
        .length = 0.035,
        .width = 0.010,
        .thickness = 0.0008,
    };
    const c_rot = leaf.rotationalCompliance(E);
    const k_ax = leaf.axialStiffness(E);

    try testing.expect(c_rot > 0.0);
    try testing.expect(k_ax > 1e6);

    // 2. Tetrahedral Meshing & 6x6 Spatial Compliance Matrix Extraction
    var mesh = fea_mod.tet_mesher.TetMesh.init(allocator, .Tet4);
    defer mesh.deinit();

    try mesh.generateTaggedBoxMesh(0.060, 0.010, 0.010, 4, 1, 1, null);
    try testing.expect(mesh.nodeCount() > 0);
    try testing.expect(mesh.elementCount() > 0);

    const n_count = mesh.nodeCount();

    var fixed_nodes: std.ArrayListUnmanaged(u32) = .empty;
    defer fixed_nodes.deinit(allocator);
    var stage_nodes: std.ArrayListUnmanaged(u32) = .empty;
    defer stage_nodes.deinit(allocator);

    for (0..n_count) |i| {
        if (mesh.node_positions.items[i * 3] <= 1e-4) {
            try fixed_nodes.append(allocator, @intCast(i));
        }
        if (mesh.node_positions.items[i * 3] >= 0.059) {
            try stage_nodes.append(allocator, @intCast(i));
        }
    }

    const mat = fea_mod.fea_solver.Material{};
    var analyzer = fea_mod.flexure_synthesis.FlexureAnalyzer.init(allocator);
    var analysis = try analyzer.analyze(&mesh, fixed_nodes.items, stage_nodes.items, mat);
    defer analysis.deinit();

    try testing.expect(analysis.compliance_matrix_6x6.len == 36);
    try testing.expect(analysis.stiffness_matrix_6x6.len == 36);
    try testing.expect(analysis.fact_screws.len > 0);
}

test "Wave 10 Pipeline - Template 4: Stress-Driven Gyroid Aerospace Mount" {
    const allocator = testing.allocator;

    // 1. Modulate Gyroid Thickness from Simulated FEA Stress Field
    const gyroid = implicit_mod.TpmsLattice{
        .tpms_type = .Gyroid,
        .cell_size = 12.0,
        .wall_thickness = 1.2,
    };

    const eval = struct {
        var g: implicit_mod.TpmsLattice = undefined;
        fn f(p: implicit_mod.Vec3) f64 {
            return g.evalSdf(p, null);
        }
    };
    eval.g = gyroid;

    // 2. Dual Contouring Mesher
    var mesher = implicit_mod.AdaptiveDualContouring.init(allocator, 3);
    var mesh = try mesher.mesh(eval.f, .{ .x = -6.0, .y = -6.0, .z = -6.0 }, .{ .x = 6.0, .y = 6.0, .z = 6.0 });
    defer mesh.deinit();

    try testing.expect(mesh.vertices.items.len > 0);
    try testing.expect(mesh.indices.items.len > 0);
    try testing.expect(mesh.indices.items.len % 3 == 0);

    // 3. 3MF Production Packaging
    var packer = cam_mod.ThreeMfPacker.init(allocator, .{});
    const xml = try packer.generate3MfModelXml(mesh.vertices.items, mesh.indices.items);
    defer allocator.free(xml);

    try testing.expect(std.mem.indexOf(u8, xml, "<model unit=\"millimeter\"") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<object id=\"1\"") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<item objectid=\"1\"") != null);
}
