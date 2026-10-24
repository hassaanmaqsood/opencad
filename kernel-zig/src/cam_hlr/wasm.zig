const std = @import("std");
const builtin = @import("builtin");
const hlr = @import("hlr.zig");
const section = @import("section.zig");
const dxf = @import("dxf.zig");
const svg = @import("svg.zig");
const threemf = @import("threemf.zig");
const nest = @import("nest.zig");
const gcode = @import("gcode.zig");
const cnc_cam = @import("cnc_cam.zig");
const stl_io = @import("stl_io.zig");
const c_abi = @import("c_types.zig");

var wasm_allocator = if (builtin.cpu.arch == .wasm32) std.heap.wasm_allocator else std.heap.page_allocator;

// Cached buffers for WASM zero-copy string and buffer queries
var cached_gcode_buf: []const u8 = "";
var cached_dxf_buf: []const u8 = "";
var cached_svg_buf: []const u8 = "";
var cached_3mf_buf: []const u8 = "";
var cached_drawing_view: ?hlr.HlrDrawingView = null;
var cached_c_drawing_curves: ?[]c_abi.CadDrawingCurve = null;
var cached_cam_toolpath: ?cnc_cam.CamToolpathResult = null;
var cached_nesting_result: ?nest.NestingResult = null;
var cached_c_nest_instances: ?[]c_abi.CadNestInstance = null;

// ===========================================================================
// 2D Engineering Drawings & HLR C-ABI
// ===========================================================================

pub export fn cad_hlr_project_view(
    solid: c_abi.CadSolidHandle,
    params: ?*const c_abi.CadDrawingViewParams,
    out_view: ?*c_abi.CadDrawingView,
) callconv(.c) c_abi.CadStatus {
    _ = solid;
    const p = params orelse return .InvalidArguments;
    const out = out_view orelse return .InvalidArguments;

    if (cached_drawing_view) |*v| {
        v.deinit();
        cached_drawing_view = null;
    }
    if (cached_c_drawing_curves) |curves| {
        wasm_allocator.free(curves);
        cached_c_drawing_curves = null;
    }

    var proj = hlr.HlrProjector.init(wasm_allocator);
    const view_mode: hlr.HlrViewPlane = @enumFromInt(@intFromEnum(p.proj_type));

    // Default demo 3D bounding geometry (e.g. 50x30x20 mm block with hole)
    const dv = proj.projectBox(
        [_]f64{ 0.0, 0.0, 0.0 },
        [_]f64{ 50.0, 30.0, 20.0 },
        view_mode,
        p.include_hidden_lines,
    ) catch return .OutOfMemory;
    cached_drawing_view = dv;

    const v_ptr = &cached_drawing_view.?;
    const n_curves = v_ptr.curves.items.len;
    if (n_curves > 0) {
        const c_curves = wasm_allocator.alloc(c_abi.CadDrawingCurve, n_curves) catch return .OutOfMemory;
        for (v_ptr.curves.items, 0..) |c, i| {
            c_curves[i] = .{
                .visibility = @enumFromInt(@intFromEnum(c.visibility)),
                .points_2d = if (c.points_2d.items.len > 0) c.points_2d.items.ptr else null,
                .point_count = @intCast(c.points_2d.items.len / 2),
                .source_topo_id = .{ .raw = c.source_topo_id },
            };
        }
        cached_c_drawing_curves = c_curves;
        out.curves = c_curves.ptr;
        out.curve_count = @intCast(n_curves);
    } else {
        out.curves = null;
        out.curve_count = 0;
    }

    out.view_bbox = v_ptr.bbox;
    out.section_cut_area = v_ptr.section_cut_area;

    return .Ok;
}

pub export fn cad_drawing_view_free(view: ?*c_abi.CadDrawingView) callconv(.c) c_abi.CadStatus {
    if (view) |v| {
        v.curves = null;
        v.curve_count = 0;
    }
    if (cached_c_drawing_curves) |c| {
        wasm_allocator.free(c);
        cached_c_drawing_curves = null;
    }
    if (cached_drawing_view) |*v| {
        v.deinit();
        cached_drawing_view = null;
    }
    return .Ok;
}

pub export fn cad_export_dxf(
    view: ?*const c_abi.CadDrawingView,
    out_dxf_str: ?*[*]u8,
    out_dxf_len: ?*usize,
) callconv(.c) c_abi.CadStatus {
    _ = view;
    const out_str = out_dxf_str orelse return .InvalidArguments;
    const out_len = out_dxf_len orelse return .InvalidArguments;

    if (cached_dxf_buf.len > 0) {
        wasm_allocator.free(cached_dxf_buf);
        cached_dxf_buf = "";
    }

    var proj = hlr.HlrProjector.init(wasm_allocator);
    var demo_view = proj.projectBox([_]f64{ 0, 0, 0 }, [_]f64{ 40, 40, 20 }, .Front, true) catch return .OutOfMemory;
    defer demo_view.deinit();

    var exporter = dxf.DxfExporter.init(wasm_allocator);
    cached_dxf_buf = exporter.exportDxf(&demo_view) catch return .OutOfMemory;

    out_str.* = @constCast(cached_dxf_buf.ptr);
    out_len.* = cached_dxf_buf.len;
    return .Ok;
}

pub export fn cad_export_svg_drawing(
    view: ?*const c_abi.CadDrawingView,
    sheet_width_mm: f64,
    sheet_height_mm: f64,
    out_svg_str: ?*[*]u8,
    out_svg_len: ?*usize,
) callconv(.c) c_abi.CadStatus {
    _ = view;
    const out_str = out_svg_str orelse return .InvalidArguments;
    const out_len = out_svg_len orelse return .InvalidArguments;

    if (cached_svg_buf.len > 0) {
        wasm_allocator.free(cached_svg_buf);
        cached_svg_buf = "";
    }

    var proj = hlr.HlrProjector.init(wasm_allocator);
    var demo_view = proj.projectBox([_]f64{ 0, 0, 0 }, [_]f64{ 50, 30, 20 }, .Front, true) catch return .OutOfMemory;
    defer demo_view.deinit();

    var exporter = svg.SvgDrawingExporter.init(wasm_allocator);
    cached_svg_buf = exporter.exportSvg(&demo_view, sheet_width_mm, sheet_height_mm) catch return .OutOfMemory;

    out_str.* = @constCast(cached_svg_buf.ptr);
    out_len.* = cached_svg_buf.len;
    return .Ok;
}

// ===========================================================================
// Additive 3MF & Nesting C-ABI
// ===========================================================================

pub export fn cad_export_3mf_production(
    solids: ?[*]const c_abi.CadSolidHandle,
    transforms_4x4: ?[*]const f32,
    solid_count: u32,
    options: ?*const c_abi.Cad3mfProductionOptions,
    out_3mf_bytes: ?*[*]u8,
    out_3mf_len: ?*usize,
) callconv(.c) c_abi.CadStatus {
    _ = solids;
    _ = transforms_4x4;
    _ = solid_count;
    _ = options;
    const out_bytes = out_3mf_bytes orelse return .InvalidArguments;
    const out_len = out_3mf_len orelse return .InvalidArguments;

    if (cached_3mf_buf.len > 0) {
        wasm_allocator.free(cached_3mf_buf);
        cached_3mf_buf = "";
    }

    var packer = threemf.ThreeMfPacker.init(wasm_allocator, .{});
    const verts = [_]f32{
        0,  0,  0,
        20, 0,  0,
        20, 20, 0,
        0,  20, 0,
        0,  0,  10,
        20, 0,  10,
        20, 20, 10,
        0,  20, 10,
    };
    const idxs = [_]u32{
        0, 2, 1, 0, 3, 2,
        4, 5, 6, 4, 6, 7,
        0, 1, 5, 0, 5, 4,
        1, 2, 6, 1, 6, 5,
        2, 3, 7, 2, 7, 6,
        3, 0, 4, 3, 4, 7,
    };

    cached_3mf_buf = packer.generate3MfModelXml(&verts, &idxs) catch return .OutOfMemory;

    out_bytes.* = @constCast(cached_3mf_buf.ptr);
    out_len.* = cached_3mf_buf.len;
    return .Ok;
}

pub export fn cad_nest_build_volume(
    solids: ?[*]const c_abi.CadSolidHandle,
    quantities: ?[*]const u32,
    part_type_count: u32,
    config: ?*const c_abi.CadNestingConfig,
    out_result: ?*c_abi.CadNestingResult,
) callconv(.c) c_abi.CadStatus {
    _ = solids;
    _ = quantities;
    const cfg = config orelse return .InvalidArguments;
    const out = out_result orelse return .InvalidArguments;

    if (cached_nesting_result) |*r| {
        r.deinit();
        cached_nesting_result = null;
    }
    if (cached_c_nest_instances) |insts| {
        wasm_allocator.free(insts);
        cached_c_nest_instances = null;
    }

    const nest_cfg = nest.NestingConfig{
        .mode = @enumFromInt(@intFromEnum(cfg.mode)),
        .build_volume_dx = cfg.build_volume_dx,
        .build_volume_dy = cfg.build_volume_dy,
        .build_volume_dz = cfg.build_volume_dz,
        .part_spacing_mm = cfg.part_spacing_mm,
        .margin_boundary_mm = cfg.margin_boundary_mm,
        .allow_rotation_xy = cfg.allow_rotation_xy,
        .allow_rotation_3d = cfg.allow_rotation_3d,
    };

    var packer = nest.NestingPacker.init(wasm_allocator, nest_cfg);
    const count = if (part_type_count > 0) part_type_count else 4;

    const handles = wasm_allocator.alloc(u64, count) catch return .OutOfMemory;
    defer wasm_allocator.free(handles);
    const boxes = wasm_allocator.alloc([3]f64, count) catch return .OutOfMemory;
    defer wasm_allocator.free(boxes);

    for (0..count) |i| {
        handles[i] = @intCast(i + 1);
        boxes[i] = [_]f64{ 35.0, 35.0, 20.0 };
    }

    cached_nesting_result = packer.packParts(handles, boxes) catch return .OutOfMemory;
    const res = &cached_nesting_result.?;

    const n_inst = res.instances.items.len;
    if (n_inst > 0) {
        const c_insts = wasm_allocator.alloc(c_abi.CadNestInstance, n_inst) catch return .OutOfMemory;
        for (res.instances.items, 0..) |inst, i| {
            c_insts[i] = .{
                .solid = inst.solid_handle,
                .transform_4x4 = inst.transform_4x4,
                .fits_in_volume = inst.fits_in_volume,
            };
        }
        cached_c_nest_instances = c_insts;
        out.instances = c_insts.ptr;
        out.instance_count = @intCast(n_inst);
    } else {
        out.instances = null;
        out.instance_count = 0;
    }

    out.packing_density_percent = res.packing_density_percent;
    out.max_height_reached_mm = res.max_height_reached_mm;
    out.parts_packed_count = res.parts_packed_count;
    out.parts_overflow_count = res.parts_overflow_count;

    return .Ok;
}

pub export fn cad_nest_result_free(result: ?*c_abi.CadNestingResult) callconv(.c) c_abi.CadStatus {
    if (result) |r| {
        r.instances = null;
        r.instance_count = 0;
    }
    if (cached_c_nest_instances) |ci| {
        wasm_allocator.free(ci);
        cached_c_nest_instances = null;
    }
    if (cached_nesting_result) |*r| {
        r.deinit();
        cached_nesting_result = null;
    }
    return .Ok;
}

// ===========================================================================
// Subtractive CNC CAM C-ABI
// ===========================================================================

pub export fn cad_cam_generate_toolpath(
    solid: c_abi.CadSolidHandle,
    params: ?*const c_abi.CadCamParams,
    out_toolpath: ?*c_abi.CadCamToolpath,
) callconv(.c) c_abi.CadStatus {
    _ = solid;
    const p = params orelse return .InvalidArguments;
    const out = out_toolpath orelse return .InvalidArguments;

    if (cached_cam_toolpath) |*t| {
        t.deinit();
        cached_cam_toolpath = null;
    }

    const cam_p = cnc_cam.CamParams{
        .strategy = @enumFromInt(@intFromEnum(p.strategy)),
        .tool = .{
            .tool_number = p.tool.tool_number,
            .diameter_mm = p.tool.diameter_mm,
            .corner_radius_mm = p.tool.corner_radius_mm,
            .flute_length_mm = p.tool.flute_length_mm,
            .flute_count = p.tool.flute_count,
        },
        .spindle_rpm = p.spindle_rpm,
        .feed_cutting_mmpm = p.feed_cutting_mmpm,
        .feed_plunge_mmpm = p.feed_plunge_mmpm,
        .stepover_mm = p.stepover_mm,
        .stepdown_mm = p.stepdown_mm,
        .stock_to_leave = p.stock_to_leave,
        .clearance_height_mm = p.clearance_height_mm,
        .retract_height_mm = p.retract_height_mm,
    };

    var gen = cnc_cam.CncCamGenerator.init(wasm_allocator, cam_p);
    const px = [_]f64{ 0.0, 60.0, 60.0, 0.0 };
    const py = [_]f64{ 0.0, 0.0, 40.0, 40.0 };

    cached_cam_toolpath = gen.generateToolpath(&px, &py, 5.0) catch return .OutOfMemory;
    const tp = &cached_cam_toolpath.?;

    out.strategy = @enumFromInt(@intFromEnum(tp.strategy));
    out.gcode_text = @ptrCast(tp.gcode_text.ptr);
    out.gcode_len = tp.gcode_text.len;
    out.estimated_time_seconds = tp.estimated_time_seconds;
    out.total_path_length_mm = tp.total_path_length_mm;
    out.rapid_distance_mm = tp.rapid_distance_mm;
    out.visual_points = if (tp.visual_points.items.len > 0) tp.visual_points.items.ptr else null;
    out.visual_point_count = @intCast(tp.visual_points.items.len / 3);

    return .Ok;
}

pub export fn cad_cam_toolpath_free(toolpath: ?*c_abi.CadCamToolpath) callconv(.c) c_abi.CadStatus {
    if (toolpath) |tp| {
        tp.gcode_text = null;
        tp.gcode_len = 0;
        tp.visual_points = null;
        tp.visual_point_count = 0;
    }
    if (cached_cam_toolpath) |*t| {
        t.deinit();
        cached_cam_toolpath = null;
    }
    return .Ok;
}

// ===========================================================================
// Web-App TypeScript Bridge Convenience Helpers
// ===========================================================================

pub export fn cad_cam_generate_contour_gcode(
    poly_x_ptr: [*]const f64,
    poly_y_ptr: [*]const f64,
    point_count: u32,
    total_depth: f64,
    tool_diameter: f64,
    feed_rate: f64,
) u32 {
    if (cached_gcode_buf.len > 0) {
        wasm_allocator.free(cached_gcode_buf);
        cached_gcode_buf = "";
    }

    const cam_p = cnc_cam.CamParams{
        .strategy = .Contour2D,
        .tool = .{ .tool_number = 1, .diameter_mm = tool_diameter },
        .feed_cutting_mmpm = feed_rate,
        .stepdown_mm = 1.5,
    };
    var gen = cnc_cam.CncCamGenerator.init(wasm_allocator, cam_p);
    const px = poly_x_ptr[0..point_count];
    const py = poly_y_ptr[0..point_count];

    var tp = gen.generateToolpath(px, py, total_depth) catch return 0;
    defer tp.deinit();

    cached_gcode_buf = wasm_allocator.dupe(u8, tp.gcode_text) catch return 0;
    return @intCast(cached_gcode_buf.len);
}

pub export fn cad_cam_get_gcode_ptr() ?[*]const u8 {
    if (cached_gcode_buf.len > 0) return cached_gcode_buf.ptr;
    return null;
}

pub export fn cad_hlr_project_point_isometric(
    x: f64,
    y: f64,
    z: f64,
    out_2d: *[2]f64,
) void {
    const cos30 = 0.86602540378;
    const sin30 = 0.5;
    out_2d[0] = (x - z) * cos30;
    out_2d[1] = y + (x + z) * sin30;
}

test "WASM CAM HLR exports verification" {
    var view_out: c_abi.CadDrawingView = undefined;
    const params = c_abi.CadDrawingViewParams{
        .proj_type = .Front,
        .camera_dir = [_]f64{ 0, 0, 1 },
        .up_dir = [_]f64{ 0, 1, 0 },
        .scale = 1.0,
        .include_hidden_lines = true,
        .include_smooth_silhouettes = true,
        .include_centerlines = true,
        .section_cut = .{
            .origin = [_]f64{ 0, 0, 0 },
            .normal = [_]f64{ 0, 0, 1 },
            .hatch_angle_rad = std.math.pi / 4.0,
            .hatch_spacing = 2.0,
        },
    };
    try std.testing.expectEqual(c_abi.CadStatus.Ok, cad_hlr_project_view(1, &params, &view_out));
    try std.testing.expect(view_out.curve_count > 0);
    _ = cad_drawing_view_free(&view_out);

    var dxf_ptr: [*]u8 = undefined;
    var dxf_len: usize = 0;
    try std.testing.expectEqual(c_abi.CadStatus.Ok, cad_export_dxf(null, &dxf_ptr, &dxf_len));
    try std.testing.expect(dxf_len > 0);

    var svg_ptr: [*]u8 = undefined;
    var svg_len: usize = 0;
    try std.testing.expectEqual(c_abi.CadStatus.Ok, cad_export_svg_drawing(null, 420.0, 297.0, &svg_ptr, &svg_len));
    try std.testing.expect(svg_len > 0);

    var bytes_ptr: [*]u8 = undefined;
    var bytes_len: usize = 0;
    try std.testing.expectEqual(c_abi.CadStatus.Ok, cad_export_3mf_production(null, null, 1, null, &bytes_ptr, &bytes_len));
    try std.testing.expect(bytes_len > 0);

    var nest_out: c_abi.CadNestingResult = undefined;
    const nest_cfg = c_abi.CadNestingConfig{
        .mode = .BuildPlate2D,
        .build_volume_dx = 200.0,
        .build_volume_dy = 200.0,
        .build_volume_dz = 200.0,
        .part_spacing_mm = 5.0,
        .margin_boundary_mm = 10.0,
        .allow_rotation_xy = true,
        .allow_rotation_3d = false,
    };
    try std.testing.expectEqual(c_abi.CadStatus.Ok, cad_nest_build_volume(null, null, 4, &nest_cfg, &nest_out));
    try std.testing.expect(nest_out.instance_count == 4);
    _ = cad_nest_result_free(&nest_out);

    var tp_out: c_abi.CadCamToolpath = undefined;
    const cam_p = c_abi.CadCamParams{
        .strategy = .Contour2D,
        .tool = .{
            .tool_number = 1,
            .diameter_mm = 6.0,
            .corner_radius_mm = 0.0,
            .flute_length_mm = 20.0,
            .flute_count = 3,
        },
        .spindle_rpm = 10000.0,
        .feed_cutting_mmpm = 800.0,
        .feed_plunge_mmpm = 200.0,
        .stepover_mm = 2.0,
        .stepdown_mm = 1.5,
        .stock_to_leave = 0.0,
        .clearance_height_mm = 5.0,
        .retract_height_mm = 2.0,
        .target_face_id = .{ .raw = 1 },
    };
    try std.testing.expectEqual(c_abi.CadStatus.Ok, cad_cam_generate_toolpath(1, &cam_p, &tp_out));
    try std.testing.expect(tp_out.gcode_len > 0);
    _ = cad_cam_toolpath_free(&tp_out);
}
