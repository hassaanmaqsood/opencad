const std = @import("std");
const builtin = @import("builtin");

pub const MAGIC_OCAD: u32 = 0x4F434144; // "OCAD"
pub const VERSION_2: u32 = 2;

pub const CONTROL_BLOCK_OFFSET: usize = 0x000000;
pub const SOLID_ARENA_OFFSET: usize = 0x001000;
pub const TESS_BUFFER_OFFSET: usize = 0x0F0000;
pub const FIELD_BUFFER_OFFSET: usize = 0x1F0000;
pub const SCRATCH_OFFSET: usize = 0x3F0000;

pub const ControlBlock = extern struct {
    magic: u32 = MAGIC_OCAD,
    version: u32 = VERSION_2,
    solid_arena_offset: u32 = @intCast(SOLID_ARENA_OFFSET),
    tess_buffer_offset: u32 = @intCast(TESS_BUFFER_OFFSET),
    field_buffer_offset: u32 = @intCast(FIELD_BUFFER_OFFSET),
    scratch_offset: u32 = @intCast(SCRATCH_OFFSET),
    active_solid_count: u32 = 0,
    tess_generation_counter: u32 = 0,
    reserved: [8]u32 = [_]u32{ 0, 0, 0, 0, 0, 0, 0, 0 }, // 32 bytes reserved padding to 64 bytes total
};

comptime {
    if (@sizeOf(ControlBlock) != 64) {
        @compileError("ControlBlock must be exactly 64 bytes");
    }
}

// Simulated memory buffer for native test mode
var simulated_native_mem: [0x400000]u8 = std.mem.zeroes([0x400000]u8);

pub fn initControlBlock() void {
    const cb = ControlBlock{
        .magic = MAGIC_OCAD,
        .version = VERSION_2,
        .solid_arena_offset = @intCast(SOLID_ARENA_OFFSET),
        .tess_buffer_offset = @intCast(TESS_BUFFER_OFFSET),
        .field_buffer_offset = @intCast(FIELD_BUFFER_OFFSET),
        .scratch_offset = @intCast(SCRATCH_OFFSET),
        .active_solid_count = 0,
        .tess_generation_counter = 0,
        .reserved = [_]u32{ 0, 0, 0, 0, 0, 0, 0, 0 },
    };
    if (builtin.target.cpu.arch == .wasm32) {
        const dest: [*]allowzero volatile u8 = @ptrFromInt(CONTROL_BLOCK_OFFSET);
        const src: [*]const u8 = @ptrCast(&cb);
        for (0..@sizeOf(ControlBlock)) |i| {
            dest[i] = src[i];
        }
    } else {
        @memcpy(simulated_native_mem[0..@sizeOf(ControlBlock)], std.mem.asBytes(&cb));
    }
}

pub fn getControlBlock() *allowzero const ControlBlock {
    if (builtin.target.cpu.arch == .wasm32) {
        return @ptrFromInt(CONTROL_BLOCK_OFFSET);
    } else {
        return @ptrCast(@alignCast(&simulated_native_mem[0]));
    }
}

pub fn getMemorySlice(offset: usize, len: usize) []u8 {
    if (builtin.target.cpu.arch == .wasm32) {
        const ptr: [*]u8 = @ptrFromInt(offset);
        return ptr[0..len];
    } else {
        return simulated_native_mem[offset..offset + len];
    }
}

pub fn incTessGenCounter() void {
    if (builtin.target.cpu.arch == .wasm32) {
        const ptr: *allowzero volatile u32 = @ptrFromInt(0x001C);
        ptr.* +%= 1;
    } else {
        const val = std.mem.readInt(u32, simulated_native_mem[0x001C..0x0020], .little);
        std.mem.writeInt(u32, simulated_native_mem[0x001C..0x0020], val +% 1, .little);
    }
}

test "ControlBlock initialization and layout" {
    initControlBlock();
    const cb = getControlBlock();
    try std.testing.expectEqual(MAGIC_OCAD, cb.magic);
    try std.testing.expectEqual(VERSION_2, cb.version);
    try std.testing.expectEqual(@as(u32, 0x001000), cb.solid_arena_offset);
    try std.testing.expectEqual(@as(u32, 0x0F0000), cb.tess_buffer_offset);
    try std.testing.expectEqual(@as(u32, 0x1F0000), cb.field_buffer_offset);
    try std.testing.expectEqual(@as(u32, 0x3F0000), cb.scratch_offset);
}
