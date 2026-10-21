const std = @import("std");
const memory = @import("memory.zig");
const c_abi = @import("c_abi.zig");
const types = @import("solver/types.zig");
const solver = @import("solver/solver.zig");

// Global persistent buffers for WASM zero-copy readback
var wasm_coords_buf: std.ArrayList(f64) = .empty;
var wasm_conflicts_buf: std.ArrayList(u32) = .empty;
var global_solver_status: c_abi.CadSolverStatus = std.mem.zeroes(c_abi.CadSolverStatus);

pub fn deinitWasmBuffers() void {
    const alloc = memory.getAllocator();
    wasm_coords_buf.deinit(alloc);
    wasm_conflicts_buf.deinit(alloc);
    wasm_coords_buf = .empty;
    wasm_conflicts_buf = .empty;
    global_solver_status = std.mem.zeroes(c_abi.CadSolverStatus);
}

pub export fn cad_sketch_solve(
    points: ?*anyopaque,
    point_count: u32,
    lines: ?*const anyopaque,
    line_count: u32,
    arcs: ?*const anyopaque,
    arc_count: u32,
    circles: ?*const anyopaque,
    circle_count: u32,
    constraints: ?*const anyopaque,
    constraint_count: u32,
    max_iterations: u32,
    convergence_tol: f64,
    out_status: ?*c_abi.CadSolverStatus,
) c_abi.CadStatus {
    const typed_points: ?[*]c_abi.CadSketchPoint2D = if (points) |p| @ptrCast(@alignCast(p)) else null;
    const typed_lines: ?[*]const c_abi.CadSketchLine2D = if (lines) |l| @ptrCast(@alignCast(l)) else null;
    const typed_arcs: ?[*]const c_abi.CadSketchArc2D = if (arcs) |a| @ptrCast(@alignCast(a)) else null;
    const typed_circles: ?[*]const c_abi.CadSketchCircle2D = if (circles) |c| @ptrCast(@alignCast(c)) else null;
    const typed_constraints: ?[*]const c_abi.CadSketchConstraint = if (constraints) |k| @ptrCast(@alignCast(k)) else null;

    var empty_pts: [0]c_abi.CadSketchPoint2D = .{};
    const pts_slice: []c_abi.CadSketchPoint2D = if (typed_points != null and point_count > 0)
        typed_points.?[0..point_count]
    else
        &empty_pts;

    const lines_slice = if (typed_lines != null and line_count > 0)
        typed_lines.?[0..line_count]
    else
        &[_]c_abi.CadSketchLine2D{};

    const arcs_slice = if (typed_arcs != null and arc_count > 0)
        typed_arcs.?[0..arc_count]
    else
        &[_]c_abi.CadSketchArc2D{};

    const circles_slice = if (typed_circles != null and circle_count > 0)
        typed_circles.?[0..circle_count]
    else
        &[_]c_abi.CadSketchCircle2D{};

    const constraints_slice = if (typed_constraints != null and constraint_count > 0)
        typed_constraints.?[0..constraint_count]
    else
        &[_]c_abi.CadSketchConstraint{};

    // Use an explicit ArenaAllocator per solve invocation to guarantee 100% reclamation of scratch memory
    var arena = std.heap.ArenaAllocator.init(memory.getAllocator());
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const result = solver.solve(
        arena_allocator,
        pts_slice,
        lines_slice,
        arcs_slice,
        circles_slice,
        constraints_slice,
        max_iterations,
        convergence_tol,
    ) catch {
        return .OutOfMemory;
    };

    // Store updated coordinates and conflict IDs in global WASM buffers
    const mem_alloc = memory.getAllocator();
    wasm_coords_buf.clearRetainingCapacity();
    for (pts_slice) |pt| {
        wasm_coords_buf.append(mem_alloc, pt.x) catch return .OutOfMemory;
        wasm_coords_buf.append(mem_alloc, pt.y) catch return .OutOfMemory;
    }

    wasm_conflicts_buf.clearRetainingCapacity();
    for (result.conflicting_ids) |c_id| {
        wasm_conflicts_buf.append(mem_alloc, c_id) catch return .OutOfMemory;
    }

    global_solver_status = .{
        .solve_state = result.solve_state,
        .degrees_of_freedom = result.dof,
        .iterations = result.iterations,
        .max_residual = result.max_residual,
        .updated_coords = if (wasm_coords_buf.items.len > 0) wasm_coords_buf.items.ptr else null,
        .coord_count = point_count,
        .conflicting_constraint_ids = if (wasm_conflicts_buf.items.len > 0) wasm_conflicts_buf.items.ptr else null,
        .conflicting_count = @intCast(wasm_conflicts_buf.items.len),
    };

    if (out_status) |st| {
        st.* = global_solver_status;
    }

    return .Ok;
}

pub export fn cad_sketch_get_dof(
    point_count: u32,
    lines: ?*const anyopaque,
    line_count: u32,
    arcs: ?*const anyopaque,
    arc_count: u32,
    circles: ?*const anyopaque,
    circle_count: u32,
    constraints: ?*const anyopaque,
    constraint_count: u32,
    out_dof: ?*u32,
) c_abi.CadStatus {
    const typed_lines: ?[*]const c_abi.CadSketchLine2D = if (lines) |l| @ptrCast(@alignCast(l)) else null;
    const typed_arcs: ?[*]const c_abi.CadSketchArc2D = if (arcs) |a| @ptrCast(@alignCast(a)) else null;
    const typed_circles: ?[*]const c_abi.CadSketchCircle2D = if (circles) |c| @ptrCast(@alignCast(c)) else null;
    const typed_constraints: ?[*]const c_abi.CadSketchConstraint = if (constraints) |k| @ptrCast(@alignCast(k)) else null;

    const lines_slice = if (typed_lines != null and line_count > 0)
        typed_lines.?[0..line_count]
    else
        &[_]c_abi.CadSketchLine2D{};

    const arcs_slice = if (typed_arcs != null and arc_count > 0)
        typed_arcs.?[0..arc_count]
    else
        &[_]c_abi.CadSketchArc2D{};

    const circles_slice = if (typed_circles != null and circle_count > 0)
        typed_circles.?[0..circle_count]
    else
        &[_]c_abi.CadSketchCircle2D{};

    const constraints_slice = if (typed_constraints != null and constraint_count > 0)
        typed_constraints.?[0..constraint_count]
    else
        &[_]c_abi.CadSketchConstraint{};

    var arena = std.heap.ArenaAllocator.init(memory.getAllocator());
    defer arena.deinit();

    const dof = solver.getDof(
        arena.allocator(),
        point_count,
        lines_slice,
        arcs_slice,
        circles_slice,
        constraints_slice,
    ) catch {
        return .OutOfMemory;
    };

    if (out_dof) |d| {
        d.* = dof;
    }

    return .Ok;
}

// ---------------------------------------------------------------------------
// WASM Zero-Copy Helpers
// ---------------------------------------------------------------------------

pub export fn cad_wasm_sketch_get_status() *const c_abi.CadSolverStatus {
    return &global_solver_status;
}

pub export fn cad_wasm_sketch_get_coords_ptr() ?[*]const f64 {
    return if (wasm_coords_buf.items.len > 0) wasm_coords_buf.items.ptr else null;
}

pub export fn cad_wasm_sketch_get_coords_len() u32 {
    return @intCast(wasm_coords_buf.items.len);
}

pub export fn cad_wasm_sketch_get_conflicts_ptr() ?[*]const u32 {
    return if (wasm_conflicts_buf.items.len > 0) wasm_conflicts_buf.items.ptr else null;
}

pub export fn cad_wasm_sketch_get_conflicts_len() u32 {
    return @intCast(wasm_conflicts_buf.items.len);
}

pub export fn cad_wasm_sketch_get_dof() u32 {
    return global_solver_status.degrees_of_freedom;
}

pub export fn cad_wasm_sketch_get_solve_state() c_int {
    return @intFromEnum(global_solver_status.solve_state);
}

pub export fn cad_wasm_sketch_get_iterations() u32 {
    return global_solver_status.iterations;
}

pub export fn cad_wasm_sketch_get_max_residual() f64 {
    return global_solver_status.max_residual;
}

test "C ABI cad_sketch_solve and cad_sketch_get_dof end-to-end" {
    defer deinitWasmBuffers();

    var points = [_]c_abi.CadSketchPoint2D{
        .{ .id = 1, .x = 0.0, .y = 0.0, .is_fixed = 1 },
        .{ .id = 2, .x = 5.0, .y = 2.0, .is_fixed = 0 },
    };

    const lines = [_]c_abi.CadSketchLine2D{
        .{ .id = 10, .start_point_id = 1, .end_point_id = 2 },
    };

    const constraints = [_]c_abi.CadSketchConstraint{
        .{
            .id = 101,
            .type = .Horizontal,
            .entity1_id = 10,
            .entity2_id = c_abi.CAD_SKETCH_INVALID_ID,
            .entity3_id = c_abi.CAD_SKETCH_INVALID_ID,
            .entity4_id = c_abi.CAD_SKETCH_INVALID_ID,
            .parameter_value = 0.0,
            .is_driving = 1,
        },
        .{
            .id = 102,
            .type = .Distance,
            .entity1_id = 1,
            .entity2_id = 2,
            .entity3_id = c_abi.CAD_SKETCH_INVALID_ID,
            .entity4_id = c_abi.CAD_SKETCH_INVALID_ID,
            .parameter_value = 8.0,
            .is_driving = 1,
        },
    };

    var status: c_abi.CadSolverStatus = undefined;
    const solve_stat = cad_sketch_solve(
        &points,
        2,
        &lines,
        1,
        null,
        0,
        null,
        0,
        &constraints,
        2,
        50,
        1e-7,
        &status,
    );

    try std.testing.expectEqual(c_abi.CadStatus.Ok, solve_stat);
    try std.testing.expectEqual(c_abi.CadSolveState.Solved, status.solve_state);
    try std.testing.expectEqual(@as(u32, 0), status.degrees_of_freedom);
    try std.testing.expectApproxEqAbs(8.0, points[1].x, 1e-6);
    try std.testing.expectApproxEqAbs(0.0, points[1].y, 1e-6);

    // Verify zero-copy getters
    try std.testing.expectEqual(@as(u32, 4), cad_wasm_sketch_get_coords_len());
    const coords = cad_wasm_sketch_get_coords_ptr().?;
    try std.testing.expectApproxEqAbs(0.0, coords[0], 1e-6);
    try std.testing.expectApproxEqAbs(0.0, coords[1], 1e-6);
    try std.testing.expectApproxEqAbs(8.0, coords[2], 1e-6);
    try std.testing.expectApproxEqAbs(0.0, coords[3], 1e-6);

    // Test get_dof
    var out_dof: u32 = 999;
    const dof_stat = cad_sketch_get_dof(
        2,
        &lines,
        1,
        null,
        0,
        null,
        0,
        &constraints,
        2,
        &out_dof,
    );
    try std.testing.expectEqual(c_abi.CadStatus.Ok, dof_stat);
    try std.testing.expectEqual(@as(u32, 2), out_dof);
}
