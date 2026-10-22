const std = @import("std");
const c_abi = @import("../c_abi.zig");
const CadStatus = c_abi.CadStatus;
const CadKernelLimits = c_abi.CadKernelLimits;
const CadPluginOpVTable = c_abi.CadPluginOpVTable;
const CadFeatureNode = c_abi.CadFeatureNode;
const CadSolidHandle = c_abi.CadSolidHandle;
const CadTessellatedSolidSlice = c_abi.CadTessellatedSolidSlice;

pub const DEFAULT_LIMITS = CadKernelLimits{
    .max_wasm_memory_bytes = 256 * 1024 * 1024, // 256 MiB
    .max_solver_iterations = 500,
    .max_boolean_faces = 100_000,
    .eval_timeout_ms = 5000,
};

pub const MAX_REGISTERED_PLUGINS = 128;
pub const MIN_PLUGIN_OP_ID: u32 = 1000;

var global_limits: CadKernelLimits = DEFAULT_LIMITS;
var registered_count: usize = 0;
var plugin_vtables: [MAX_REGISTERED_PLUGINS]CadPluginOpVTable = undefined;
var plugin_registered: [MAX_REGISTERED_PLUGINS]bool = @splat(false);

pub fn setLimits(limits: CadKernelLimits) CadStatus {
    if (limits.max_wasm_memory_bytes == 0 or limits.max_solver_iterations == 0) {
        return .InvalidArguments;
    }
    global_limits = limits;
    return .Ok;
}

pub fn getLimits() CadKernelLimits {
    return global_limits;
}

pub fn checkMemoryLimit(current_bytes: u64, additional_bytes: usize) bool {
    const total = current_bytes + @as(u64, additional_bytes);
    return total <= global_limits.max_wasm_memory_bytes;
}

pub fn checkSolverIterations(iterations: u32) bool {
    return iterations <= global_limits.max_solver_iterations;
}

pub fn checkBooleanFaces(face_count: u32) bool {
    return face_count <= global_limits.max_boolean_faces;
}

pub fn registerPlugin(vtable: *const CadPluginOpVTable) CadStatus {
    if (vtable.op_type_id < MIN_PLUGIN_OP_ID) {
        return .InvalidArguments;
    }
    if (vtable.evaluate_fn == null) {
        return .InvalidArguments;
    }

    // Check if already registered
    var free_idx: ?usize = null;
    for (0..MAX_REGISTERED_PLUGINS) |i| {
        if (plugin_registered[i]) {
            if (plugin_vtables[i].op_type_id == vtable.op_type_id) {
                // Update existing
                plugin_vtables[i] = vtable.*;
                return .Ok;
            }
        } else if (free_idx == null) {
            free_idx = i;
        }
    }

    if (free_idx) |idx| {
        plugin_vtables[idx] = vtable.*;
        plugin_registered[idx] = true;
        registered_count += 1;
        return .Ok;
    }

    return .OutOfMemory;
}

pub fn unregisterPlugin(op_type_id: u32) CadStatus {
    for (0..MAX_REGISTERED_PLUGINS) |i| {
        if (plugin_registered[i] and plugin_vtables[i].op_type_id == op_type_id) {
            plugin_registered[i] = false;
            if (registered_count > 0) registered_count -= 1;
            return .Ok;
        }
    }
    return .InvalidArguments;
}

pub fn getPlugin(op_type_id: u32) ?CadPluginOpVTable {
    for (0..MAX_REGISTERED_PLUGINS) |i| {
        if (plugin_registered[i] and plugin_vtables[i].op_type_id == op_type_id) {
            return plugin_vtables[i];
        }
    }
    return null;
}

pub fn executePlugin(
    op_type_id: u32,
    node: ?*const CadFeatureNode,
    input_solids: ?[*]const CadSolidHandle,
    input_count: u32,
    out_solid: *CadSolidHandle,
) CadStatus {
    const plugin = getPlugin(op_type_id) orelse return .NotImplemented;
    if (plugin.evaluate_fn) |eval| {
        return eval(op_type_id, node, input_solids, input_count, out_solid);
    }
    return .NotImplemented;
}

pub fn tessellatePlugin(
    solid: CadSolidHandle,
    op_type_id: u32,
    chordal_tol: f64,
    angular_tol: f64,
    out_slice: *CadTessellatedSolidSlice,
) ?CadStatus {
    const plugin = getPlugin(op_type_id) orelse return null;
    if (plugin.tessellate_fn) |tess| {
        return tess(solid, chordal_tol, angular_tol, out_slice);
    }
    return null;
}

pub fn serializePluginAst(
    op_type_id: u32,
    node: ?*const CadFeatureNode,
    out_buf: [*]u8,
    buf_size: usize,
    out_written: *usize,
) ?CadStatus {
    const plugin = getPlugin(op_type_id) orelse return null;
    if (plugin.serialize_ast_fn) |ser| {
        return ser(node, out_buf, buf_size, out_written);
    }
    return null;
}

pub fn freePluginSolid(solid: CadSolidHandle, op_type_id: u32) void {
    if (getPlugin(op_type_id)) |plugin| {
        if (plugin.free_fn) |free_fn| {
            free_fn(solid);
        }
    }
}

pub fn clearAllPlugins() void {
    for (0..MAX_REGISTERED_PLUGINS) |i| {
        plugin_registered[i] = false;
    }
    registered_count = 0;
    global_limits = DEFAULT_LIMITS;
}

// -------------------------------------------------------------------------
// Unit Tests
// -------------------------------------------------------------------------

fn mockEvaluate(
    op_type_id: u32,
    node: ?*const CadFeatureNode,
    input_solids: ?[*]const CadSolidHandle,
    input_count: u32,
    out_solid: *CadSolidHandle,
) callconv(.c) CadStatus {
    _ = op_type_id;
    _ = node;
    _ = input_solids;
    _ = input_count;
    out_solid.* = 4242;
    return .Ok;
}

test "Plugin Registry: Register, execute, and unregister custom plugin op" {
    clearAllPlugins();
    defer clearAllPlugins();

    const vtable = CadPluginOpVTable{
        .op_type_id = 1001,
        .op_name = "MockSheetMetalFlange",
        .evaluate_fn = mockEvaluate,
        .tessellate_fn = null,
        .serialize_ast_fn = null,
        .free_fn = null,
    };

    // Op ID < 1000 should be rejected
    var invalid_vtable = vtable;
    invalid_vtable.op_type_id = 999;
    try std.testing.expectEqual(CadStatus.InvalidArguments, registerPlugin(&invalid_vtable));

    // Register valid custom op
    try std.testing.expectEqual(CadStatus.Ok, registerPlugin(&vtable));
    try std.testing.expect(getPlugin(1001) != null);

    // Execute registered op
    var out_solid: CadSolidHandle = 0;
    const exec_status = executePlugin(1001, null, null, 0, &out_solid);
    try std.testing.expectEqual(CadStatus.Ok, exec_status);
    try std.testing.expectEqual(@as(CadSolidHandle, 4242), out_solid);

    // Unregister
    try std.testing.expectEqual(CadStatus.Ok, unregisterPlugin(1001));
    try std.testing.expect(getPlugin(1001) == null);

    // Execute after unregister should return NotImplemented
    try std.testing.expectEqual(CadStatus.NotImplemented, executePlugin(1001, null, null, 0, &out_solid));
}

test "Kernel Limits: Set, get, and enforce limits" {
    clearAllPlugins();
    defer clearAllPlugins();

    const custom_limits = CadKernelLimits{
        .max_wasm_memory_bytes = 128 * 1024 * 1024,
        .max_solver_iterations = 250,
        .max_boolean_faces = 50_000,
        .eval_timeout_ms = 3000,
    };

    try std.testing.expectEqual(CadStatus.Ok, setLimits(custom_limits));
    const curr = getLimits();
    try std.testing.expectEqual(custom_limits.max_wasm_memory_bytes, curr.max_wasm_memory_bytes);
    try std.testing.expectEqual(custom_limits.max_solver_iterations, curr.max_solver_iterations);

    // Iterations limit checks
    try std.testing.expect(checkSolverIterations(200));
    try std.testing.expect(!checkSolverIterations(300));

    // Faces limit checks
    try std.testing.expect(checkBooleanFaces(40_000));
    try std.testing.expect(!checkBooleanFaces(60_000));

    // Memory limit checks
    try std.testing.expect(checkMemoryLimit(100 * 1024 * 1024, 20 * 1024 * 1024));
    try std.testing.expect(!checkMemoryLimit(100 * 1024 * 1024, 30 * 1024 * 1024));
}
