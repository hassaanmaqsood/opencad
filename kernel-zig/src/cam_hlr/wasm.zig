const std = @import("std");
const hlr = @import("hlr.zig");
const section = @import("section.zig");
const threemf = @import("threemf.zig");
const gcode = @import("gcode.zig");

var wasm_allocator = std.heap.wasm_allocator;
var cached_gcode_buf: []const u8 = "";

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

    const tool = gcode.CncToolParams{
        .tool_diameter = tool_diameter,
        .feed_rate = feed_rate,
    };
    var gen = gcode.GCodeGenerator.init(wasm_allocator, tool);
    const px = poly_x_ptr[0..point_count];
    const py = poly_y_ptr[0..point_count];

    cached_gcode_buf = gen.generateContourGCode(px, py, total_depth) catch return 0;
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
