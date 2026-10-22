const std = @import("std");
const builtin = @import("builtin");
const kfactor = @import("kfactor.zig");
const flange = @import("flange.zig");
const unfold = @import("unfold.zig");
const c_abi = @import("c_types.zig");

var wasm_allocator = if (builtin.cpu.arch == .wasm32) std.heap.wasm_allocator else std.heap.page_allocator;
var cached_flat_pattern: ?unfold.FlatPattern2D = null;
var cached_c_bend_lines: ?[]c_abi.CadBendCenterline = null;

// Persistent sheet metal solid registry for WASM handle tracking
var sm_handle_counter: u64 = 1000;
var sm_solids: std.AutoHashMap(u64, flange.SheetMetalSolid) = undefined;
var sm_initialized: bool = false;

fn ensureSmInit() void {
    if (!sm_initialized) {
        sm_solids = std.AutoHashMap(u64, flange.SheetMetalSolid).init(wasm_allocator);
        sm_initialized = true;
    }
}

pub export fn cad_sheetmetal_calc_bend_allowance(
    thickness: f64,
    inner_radius: f64,
    k_factor: f64,
    angle_rad: f64,
) f64 {
    const mat = kfactor.SheetMetalMaterial{
        .thickness = thickness,
        .inner_bend_radius = inner_radius,
        .default_k_factor = k_factor,
    };
    return mat.calcBendAllowance(angle_rad);
}

pub export fn cad_sheetmetal_calc_bend_deduction(
    thickness: f64,
    inner_radius: f64,
    k_factor: f64,
    angle_rad: f64,
) f64 {
    const mat = kfactor.SheetMetalMaterial{
        .thickness = thickness,
        .inner_bend_radius = inner_radius,
        .default_k_factor = k_factor,
    };
    return mat.calcBendDeduction(angle_rad);
}

pub export fn cad_sheetmetal_create_solid(
    width: f64,
    length: f64,
    thickness: f64,
    inner_radius: f64,
    k_factor: f64,
) u64 {
    ensureSmInit();
    const mat = kfactor.SheetMetalMaterial{
        .thickness = thickness,
        .inner_bend_radius = inner_radius,
        .default_k_factor = k_factor,
    };
    const sm = flange.SheetMetalSolid.init(wasm_allocator, mat, width, length);
    sm_handle_counter += 1;
    const handle = sm_handle_counter;
    sm_solids.put(handle, sm) catch return 0;
    return handle;
}

pub export fn cad_sheetmetal_flange(
    solid: c_abi.CadSolidHandle,
    flange_op: ?*const c_abi.CadFlangeOp,
    out_solid: ?*c_abi.CadSolidHandle,
) callconv(.c) c_abi.CadStatus {
    ensureSmInit();
    const op = flange_op orelse return .InvalidArguments;
    const out = out_solid orelse return .InvalidArguments;

    var ptr = sm_solids.getPtr(solid);
    if (ptr == null) {
        // Create new solid if not present
        const mat = kfactor.SheetMetalMaterial{
            .thickness = op.config.thickness,
            .inner_bend_radius = op.config.bend_radius,
            .default_k_factor = op.config.k_factor,
        };
        const new_sm = flange.SheetMetalSolid.init(wasm_allocator, mat, 50.0, 50.0);
        sm_handle_counter += 1;
        sm_solids.put(sm_handle_counter, new_sm) catch return .OutOfMemory;
        ptr = sm_solids.getPtr(sm_handle_counter);
    }

    if (ptr) |sm| {
        sm.addFlange(.{
            .edge_index = @intCast(op.target_edge_id.raw & 0xFF),
            .length = op.length,
            .angle_rad = op.angle_rad,
            .bend_radius = op.config.bend_radius,
            .offset_start = op.offset_start,
            .offset_end = op.offset_end,
            .relief_type = @enumFromInt(@intFromEnum(op.config.relief_type)),
            .relief_width = op.config.relief_width,
            .relief_depth = op.config.relief_depth,
        }) catch return .OutOfMemory;
        out.* = solid;
        return .Ok;
    }

    return .OpFailed;
}

pub export fn cad_sheetmetal_hem(
    solid: c_abi.CadSolidHandle,
    hem_op: ?*const c_abi.CadHemOp,
    out_solid: ?*c_abi.CadSolidHandle,
) callconv(.c) c_abi.CadStatus {
    ensureSmInit();
    const op = hem_op orelse return .InvalidArguments;
    const out = out_solid orelse return .InvalidArguments;

    const ptr = sm_solids.getPtr(solid);
    if (ptr) |sm| {
        sm.addHem(.{
            .edge_index = @intCast(op.target_edge_id.raw & 0xFF),
            .hem_type = @enumFromInt(@intFromEnum(op.hem_type)),
            .length = op.length,
            .gap = op.gap,
            .bend_radius = op.config.bend_radius,
        }) catch return .OutOfMemory;
        out.* = solid;
        return .Ok;
    }

    return .OpFailed;
}

pub export fn cad_sheetmetal_unfold(
    solid: c_abi.CadSolidHandle,
    fixed_face_id: c_abi.CadTopoId,
    out_flat_pattern: ?*c_abi.CadFlatPattern,
) callconv(.c) c_abi.CadStatus {
    _ = fixed_face_id;
    ensureSmInit();
    const out = out_flat_pattern orelse return .InvalidArguments;

    if (cached_flat_pattern) |*p| {
        p.deinit();
        cached_flat_pattern = null;
    }
    if (cached_c_bend_lines) |lines| {
        wasm_allocator.free(lines);
        cached_c_bend_lines = null;
    }

    const sm_ptr = sm_solids.getPtr(solid);
    var unfolder = unfold.SheetMetalUnfolder.init(wasm_allocator);

    if (sm_ptr) |sm| {
        cached_flat_pattern = unfolder.unfold(sm) catch return .OutOfMemory;
    } else {
        // Fallback demo plate solid for testing
        const mat = kfactor.SheetMetalMaterial{
            .thickness = 1.5,
            .inner_bend_radius = 2.0,
            .default_k_factor = 0.44,
        };
        var demo_sm = flange.SheetMetalSolid.init(wasm_allocator, mat, 60.0, 80.0);
        defer demo_sm.deinit();
        demo_sm.addFlange(.{
            .edge_index = 0,
            .length = 20.0,
            .angle_rad = std.math.pi / 2.0,
        }) catch return .OutOfMemory;
        cached_flat_pattern = unfolder.unfold(&demo_sm) catch return .OutOfMemory;
    }

    const fp = &cached_flat_pattern.?;

    // Allocate and convert bend lines to C-ABI layout
    const count = fp.bend_lines.items.len;
    if (count > 0) {
        const c_lines = wasm_allocator.alloc(c_abi.CadBendCenterline, count) catch return .OutOfMemory;
        for (fp.bend_lines.items, 0..) |bl, i| {
            c_lines[i] = .{
                .start_point = bl.start_point,
                .end_point = bl.end_point,
                .bend_angle_rad = bl.bend_angle_rad,
                .bend_radius = bl.bend_radius,
                .direction = if (bl.direction == .Up) .Up else .Down,
                .bend_allowance = bl.bend_allowance,
                .source_bend_edge = .{ .raw = bl.source_bend_edge },
            };
        }
        cached_c_bend_lines = c_lines;
        out.bend_lines = c_lines.ptr;
        out.bend_line_count = @intCast(count);
    } else {
        out.bend_lines = null;
        out.bend_line_count = 0;
    }

    out.flat_solid = solid;
    out.bounding_box_2d = fp.bounding_box;
    out.total_cut_length = fp.total_cut_length;
    out.total_area = fp.total_area;

    return .Ok;
}

pub export fn cad_flat_pattern_free(flat_pattern: ?*c_abi.CadFlatPattern) callconv(.c) c_abi.CadStatus {
    if (flat_pattern) |fp| {
        fp.bend_lines = null;
        fp.bend_line_count = 0;
    }
    if (cached_c_bend_lines) |lines| {
        wasm_allocator.free(lines);
        cached_c_bend_lines = null;
    }
    if (cached_flat_pattern) |*p| {
        p.deinit();
        cached_flat_pattern = null;
    }
    return .Ok;
}

pub export fn cad_sheetmetal_unfold_box(
    width: f64,
    length: f64,
    thickness: f64,
    inner_radius: f64,
    k_factor: f64,
    flange_length: f64,
) u32 {
    if (cached_flat_pattern) |*p| {
        p.deinit();
        cached_flat_pattern = null;
    }

    const mat = kfactor.SheetMetalMaterial{
        .thickness = thickness,
        .inner_bend_radius = inner_radius,
        .default_k_factor = k_factor,
    };
    var sm = flange.SheetMetalSolid.init(wasm_allocator, mat, width, length);
    defer sm.deinit();

    sm.addFlange(.{
        .edge_index = 0,
        .length = flange_length,
        .angle_rad = std.math.pi / 2.0,
    }) catch return 0;
    sm.addFlange(.{
        .edge_index = 1,
        .length = flange_length,
        .angle_rad = std.math.pi / 2.0,
    }) catch return 0;

    var unfolder = unfold.SheetMetalUnfolder.init(wasm_allocator);
    cached_flat_pattern = unfolder.unfold(&sm) catch return 0;

    return @intCast(cached_flat_pattern.?.boundary_points_x.items.len);
}

pub export fn cad_sheetmetal_get_unfolded_length() f64 {
    if (cached_flat_pattern) |p| return p.total_length;
    return 0.0;
}

pub export fn cad_sheetmetal_get_unfolded_width() f64 {
    if (cached_flat_pattern) |p| return p.total_width;
    return 0.0;
}

pub export fn cad_sheetmetal_get_cut_length() f64 {
    if (cached_flat_pattern) |p| return p.total_cut_length;
    return 0.0;
}

pub export fn cad_sheetmetal_get_total_area() f64 {
    if (cached_flat_pattern) |p| return p.total_area;
    return 0.0;
}

pub export fn cad_sheetmetal_get_bend_line_count() u32 {
    if (cached_flat_pattern) |p| return @intCast(p.bend_lines.items.len);
    return 0;
}

pub export fn cad_sheetmetal_get_boundary_count() u32 {
    if (cached_flat_pattern) |p| return @intCast(p.boundary_points_x.items.len);
    return 0;
}

pub export fn cad_sheetmetal_get_boundary_x_ptr() ?[*]const f64 {
    if (cached_flat_pattern) |p| {
        if (p.boundary_points_x.items.len > 0) return p.boundary_points_x.items.ptr;
    }
    return null;
}

pub export fn cad_sheetmetal_get_boundary_y_ptr() ?[*]const f64 {
    if (cached_flat_pattern) |p| {
        if (p.boundary_points_y.items.len > 0) return p.boundary_points_y.items.ptr;
    }
    return null;
}

test "WASM sheet metal exports verification" {
    const ba = cad_sheetmetal_calc_bend_allowance(2.0, 3.0, 0.44, std.math.pi / 2.0);
    try std.testing.expect(ba > 6.0 and ba < 6.1);

    const bd = cad_sheetmetal_calc_bend_deduction(2.0, 3.0, 0.44, std.math.pi / 2.0);
    try std.testing.expect(bd > 3.8 and bd < 4.0);

    const pts_cnt = cad_sheetmetal_unfold_box(40.0, 60.0, 1.5, 2.0, 0.44, 20.0);
    try std.testing.expect(pts_cnt > 0);
    try std.testing.expect(cad_sheetmetal_get_unfolded_length() > 60.0);
    try std.testing.expect(cad_sheetmetal_get_cut_length() > 0.0);
    try std.testing.expect(cad_sheetmetal_get_total_area() > 0.0);
    try std.testing.expect(cad_sheetmetal_get_bend_line_count() == 2);

    _ = cad_flat_pattern_free(null);
}
