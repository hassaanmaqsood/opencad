const std = @import("std");

// ============================================================================
// OpenCAD Host Imports (§14 & Rule 9)
// ============================================================================

extern "opencad" fn field_alloc(slot: u32, grid_x: u32, grid_y: u32, grid_z: u32) u32;
extern "opencad" fn field_eval_scalar(slot: u32, x: f64, y: f64, z: f64, default_val: f64) f64;
extern "opencad" fn field_eval_vec3(slot: u32, x: f64, y: f64, z: f64, out_ptr: [*]f64) void;
extern "opencad" fn cmd_write(cmd_type: u32, arg0: u32, arg1: u32, arg2: u32, payload_ptr: ?[*]const u8) void;

pub const CMD_REQUEST_RETESSELLATE: u32 = 0x01;
pub const TESS_BUFFER_OFFSET: usize = 0x0F0000;
pub const FIELD_BUFFER_OFFSET: usize = 0x1F0000;
pub const SCRATCH_OFFSET: usize = 0x3F0000;

// ============================================================================
// Canary Extension Single Export
// ============================================================================

pub export fn extension_tick(dt_ms: f32) void {
    _ = dt_ms;

    // 1. Read solid ID and bounding box from 0x0F0000
    const tess_slice: [*]const u8 = @ptrFromInt(TESS_BUFFER_OFFSET);
    const solid_id = std.mem.readInt(u32, tess_slice[0x00..0x04], .little);

    var bbox: [6]f64 = undefined;
    for (0..6) |i| {
        bbox[i] = @bitCast(std.mem.readInt(u64, tess_slice[0x20 + i * 8 ..][0..8], .little));
    }

    const min_x = if (bbox[0] < bbox[3]) bbox[0] else -45.0;
    const min_y = if (bbox[1] < bbox[4]) bbox[1] else -45.0;
    const min_z = if (bbox[2] < bbox[5]) bbox[2] else 0.0;
    const max_x = if (bbox[3] > bbox[0]) bbox[3] else 45.0;
    const max_y = if (bbox[4] > bbox[1]) bbox[4] else 45.0;
    const max_z = if (bbox[5] > bbox[2]) bbox[5] else 16.0;

    // 2. Allocate Slot 0 (stress field) with 64 x 64 x 24 resolution
    const grid_x: u32 = 64;
    const grid_y: u32 = 64;
    const grid_z: u32 = 24;
    _ = field_alloc(0, grid_x, grid_y, grid_z);

    // 3. Populate 64 x 64 x 24 f32 grid at 0x1F0000 with analytical stress gradient:
    // sigma(x, y, z) = 80.0 * clamp(15.0 / sqrt(x^2 + y^2 + 1.0), 0.5, 2.5)
    const field_slice: [*]f32 = @ptrFromInt(FIELD_BUFFER_OFFSET);
    const dx = (max_x - min_x) / @as(f64, @floatFromInt(grid_x - 1));
    const dy = (max_y - min_y) / @as(f64, @floatFromInt(grid_y - 1));
    const dz = (max_z - min_z) / @as(f64, @floatFromInt(grid_z - 1));

    var idx: usize = 0;
    for (0..grid_z) |iz| {
        const z = min_z + @as(f64, @floatFromInt(iz)) * dz;
        _ = z;
        for (0..grid_y) |iy| {
            const y = min_y + @as(f64, @floatFromInt(iy)) * dy;
            for (0..grid_x) |ix| {
                const x = min_x + @as(f64, @floatFromInt(ix)) * dx;
                const r = @sqrt(x * x + y * y + 1.0);
                const factor = std.math.clamp(15.0 / r, 0.5, 2.5);
                const sigma: f32 = @floatCast(80.0 * factor);
                field_slice[idx] = sigma;
                idx += 1;
            }
        }
    }

    // 4. Send retessellation request command to Command Ring Buffer at 0x3F0000
    const cmd_buf: [*]u8 = @ptrFromInt(SCRATCH_OFFSET);
    std.mem.writeInt(u32, cmd_buf[0..4], CMD_REQUEST_RETESSELLATE, .little);
    std.mem.writeInt(u32, cmd_buf[4..8], solid_id, .little);
    cmd_write(CMD_REQUEST_RETESSELLATE, solid_id, 0, 0, cmd_buf);
}
