const std = @import("std");
const builtin = @import("builtin");

/// In test mode, returns std.testing.allocator which enforces zero memory leaks.
/// In WASM mode, uses std.heap.wasm_allocator.
/// In native production mode, uses std.heap.smp_allocator or c_allocator.
pub fn getAllocator() std.mem.Allocator {
    if (builtin.is_test) {
        return std.testing.allocator;
    } else if (builtin.target.cpu.arch == .wasm32) {
        return std.heap.wasm_allocator;
    } else {
        return std.heap.smp_allocator;
    }
}
