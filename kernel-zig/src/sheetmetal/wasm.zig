const std = @import("std");
const kfactor = @import("kfactor.zig");
const flange = @import("flange.zig");
const unfold = @import("unfold.zig");

var wasm_allocator = std.heap.wasm_allocator;
var cached_flat_pattern: ?unfold.FlatPattern2D = null;

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

    var unfolder = unfold.SheetMetalUnfolder.init(wasm_allocator);
    cached_flat_pattern = unfolder.unfold(&sm) catch return 0;

    return @intCast(cached_flat_pattern.?.boundary_points_x.items.len);
}

pub export fn cad_sheetmetal_get_unfolded_length() f64 {
    if (cached_flat_pattern) |p| {
        return p.total_length;
    }
    return 0.0;
}

pub export fn cad_sheetmetal_get_unfolded_width() f64 {
    if (cached_flat_pattern) |p| {
        return p.total_width;
    }
    return 0.0;
}
