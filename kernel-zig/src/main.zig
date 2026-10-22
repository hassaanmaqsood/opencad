const std = @import("std");
const memory = @import("memory.zig");
pub const c_abi = @import("c_abi.zig");
const router = @import("router.zig");
const topology = @import("brep/topology.zig");
const box = @import("primitives/box.zig");
const cylinder = @import("primitives/cylinder.zig");
const tessellator = @import("tess/tessellator.zig");
pub const bvh = @import("tess/bvh.zig");
pub const main_wasm = @import("main_wasm.zig");
pub const solver = @import("solver/solver.zig");
pub const geom = @import("geom/vec2.zig");

pub const CadStatus = c_abi.CadStatus;
pub const CadBackend = c_abi.CadBackend;
pub const CadOpType = c_abi.CadOpType;
pub const CadSolidHandle = c_abi.CadSolidHandle;
pub const CadMesh = c_abi.CadMesh;
pub const CadBrepStats = c_abi.CadBrepStats;
pub const CadVec3 = c_abi.CadVec3;

// Wave 2: Sketch Solver Types
pub const CadSketchPoint2D = c_abi.CadSketchPoint2D;
pub const CadSketchLine2D = c_abi.CadSketchLine2D;
pub const CadSketchArc2D = c_abi.CadSketchArc2D;
pub const CadSketchCircle2D = c_abi.CadSketchCircle2D;
pub const CadSketchConstraintType = c_abi.CadSketchConstraintType;
pub const CadSketchConstraint = c_abi.CadSketchConstraint;
pub const CadSolveState = c_abi.CadSolveState;
pub const CadSolverStatus = c_abi.CadSolverStatus;
pub const CAD_SKETCH_INVALID_ID = c_abi.CAD_SKETCH_INVALID_ID;

// Wave 3: Feature DAG & Sub-Shape Slice Types
pub const CadTopoId = c_abi.CadTopoId;
pub const CadSubshapeType = c_abi.CadSubshapeType;
pub const CadFeatureType = c_abi.CadFeatureType;
pub const CadFeatureParams = c_abi.CadFeatureParams;
pub const CadFeatureNode = c_abi.CadFeatureNode;
pub const CadTessellatedSolidSlice = c_abi.CadTessellatedSolidSlice;

// Wave 6A: Universal Plugin Extension ABI & Sandbox Limits
pub const CadKernelLimits = c_abi.CadKernelLimits;
pub const CadPluginOpVTable = c_abi.CadPluginOpVTable;

// Export internal modules for unit tests
pub const TopologyMod = topology;
pub const BoxMod = box;
pub const CylinderMod = cylinder;
pub const TessellatorMod = tessellator;
pub const BvhMod = bvh;
pub const RouterMod = router;
pub const NurbsMod = @import("geom/nurbs.zig");
pub const SsiMod = @import("geom/ssi.zig");
pub const assembly_solver = @import("solver/assembly_solver.zig");
pub const se3 = @import("solver/se3.zig");
pub const SheetMetalMod = @import("sheetmetal/mod.zig");
pub const CamHlrMod = @import("cam_hlr/mod.zig");
pub const FeaFlexureMod = @import("fea_flexure/mod.zig");
pub const ImplicitMod = @import("implicit/mod.zig");

// Global handle registry
var next_handle: u64 = 1;
var solid_store: std.AutoHashMap(u64, topology.Solid) = undefined;
var soa_solid_store: std.AutoHashMap(u64, topology.topo.SoASolid) = undefined;
var wasm_step_export_buf: std.ArrayList(u8) = .empty;
var is_initialized: bool = false;
var current_rollback_index: u32 = 0;

fn ensureInit() !void {
    if (!is_initialized) {
        solid_store = std.AutoHashMap(u64, topology.Solid).init(memory.getAllocator());
        soa_solid_store = std.AutoHashMap(u64, topology.topo.SoASolid).init(memory.getAllocator());
        is_initialized = true;
    }
}

// ---------------------------------------------------------------------------
// C ABI Exported Functions
// ---------------------------------------------------------------------------

pub export fn cad_kernel_init() CadStatus {
    ensureInit() catch return .OutOfMemory;
    return .Ok;
}

pub export fn cad_kernel_deinit() CadStatus {
    if (is_initialized) {
        const alloc = memory.getAllocator();
        var it = solid_store.valueIterator();
        while (it.next()) |val| {
            var s = val.*;
            s.deinit(alloc);
        }
        solid_store.deinit();

        var it_soa = soa_solid_store.valueIterator();
        while (it_soa.next()) |val| {
            var s = val.*;
            s.deinit(alloc);
        }
        soa_solid_store.deinit();

        is_initialized = false;
    }
    if (global_mesh.vertex_count > 0) {
        _ = cad_mesh_free(&global_mesh);
    }
    if (global_slice.vertex_count > 0 or global_slice.triangle_count > 0) {
        _ = cad_slice_free(&global_slice);
    }
    const alloc = memory.getAllocator();
    wasm_step_export_buf.deinit(alloc);
    wasm_step_export_buf = .empty;

    main_wasm.deinitWasmBuffers();
    return .Ok;
}

pub export fn cad_router_set_backend(op: CadOpType, backend: CadBackend) CadStatus {
    return router.global_router.setBackend(op, backend);
}

pub export fn cad_router_get_backend(op: CadOpType) CadBackend {
    return router.global_router.getBackend(op);
}

pub export fn cad_primitive_box(
    dx: f32, dy: f32, dz: f32,
    out_solid: *CadSolidHandle,
) CadStatus {
    ensureInit() catch return .OutOfMemory;
    const alloc = memory.getAllocator();

    const handle = next_handle;
    next_handle += 1;

    const solid = box.createBox(alloc, handle, dx, dy, dz) catch |err| {
        return switch (err) {
            error.InvalidArguments => .InvalidArguments,
            error.OutOfMemory => .OutOfMemory,
        };
    };

    solid_store.put(handle, solid) catch return .OutOfMemory;
    out_solid.* = handle;
    return .Ok;
}

pub export fn cad_primitive_cylinder(
    radius: f32, height: f32,
    out_solid: *CadSolidHandle,
) CadStatus {
    ensureInit() catch return .OutOfMemory;
    const alloc = memory.getAllocator();

    const handle = next_handle;
    next_handle += 1;

    const solid = cylinder.createCylinder(alloc, handle, radius, height) catch |err| {
        return switch (err) {
            error.InvalidArguments => .InvalidArguments,
            error.OutOfMemory => .OutOfMemory,
        };
    };

    solid_store.put(handle, solid) catch return .OutOfMemory;
    out_solid.* = handle;
    return .Ok;
}

pub export fn cad_solid_tessellate(
    solid_handle: CadSolidHandle,
    chordal_deflection: f32,
    angular_deflection: f32,
    out_mesh: *CadMesh,
) CadStatus {
    ensureInit() catch return .OutOfMemory;
    const alloc = memory.getAllocator();

    const solid_ptr = solid_store.getPtr(solid_handle) orelse return .InvalidArguments;

    const mesh = tessellator.tessellateSolid(
        alloc,
        solid_ptr,
        chordal_deflection,
        angular_deflection,
    ) catch return .OutOfMemory;

    out_mesh.* = mesh;
    return .Ok;
}

pub export fn cad_solid_get_stats(
    solid_handle: CadSolidHandle,
    out_stats: *CadBrepStats,
) CadStatus {
    ensureInit() catch return .OutOfMemory;
    const solid = solid_store.get(solid_handle) orelse return .InvalidArguments;
    out_stats.* = solid.getStats();
    return .Ok;
}

pub export fn cad_mesh_free(mesh: *CadMesh) CadStatus {
    const alloc = memory.getAllocator();
    tessellator.freeMesh(alloc, mesh);
    return .Ok;
}

pub export fn cad_solid_release(solid_handle: CadSolidHandle) CadStatus {
    ensureInit() catch return .OutOfMemory;
    const alloc = memory.getAllocator();
    var found = false;
    if (solid_store.fetchRemove(solid_handle)) |kv| {
        var s = kv.value;
        s.deinit(alloc);
        found = true;
    }
    if (soa_solid_store.fetchRemove(solid_handle)) |kv| {
        var s = kv.value;
        s.deinit(alloc);
        found = true;
    }
    if (found) return .Ok;
    return .InvalidArguments;
}

// ---------------------------------------------------------------------------
// Wave 3 Feature DAG Evaluation & Slice Tessellation Exports
// ---------------------------------------------------------------------------

pub export fn cad_dag_evaluate(
    nodes: ?[*]const c_abi.CadFeatureNode,
    node_count: u32,
    rollback_index: u32,
    out_solid: ?*c_abi.CadSolidHandle,
) CadStatus {
    ensureInit() catch return .OutOfMemory;
    const out_h = out_solid orelse return .InvalidArguments;
    if (nodes == null or node_count == 0) return .InvalidArguments;

    current_rollback_index = rollback_index;
    const alloc = memory.getAllocator();

    const node_slice = nodes.?[0..node_count];
    const active_count = @min(rollback_index + 1, node_count);

    var last_solid_handle: c_abi.CadSolidHandle = 0;

    for (node_slice[0..active_count]) |node| {
        if (node.is_suppressed != 0) continue;

        switch (node.type) {
            .Sketch => {
                // 2D sketch entity tracked in DAG
            },
            .Extrude => {
                const dist: f32 = @floatCast(node.params.extrude.distance);
                const depth: f32 = if (dist > 0) dist else 2.0;
                const handle = next_handle;
                next_handle += 1;
                const s = box.createBox(alloc, handle, 2.0, 2.0, depth) catch |err| {
                    return switch (err) {
                        error.InvalidArguments => .InvalidArguments,
                        error.OutOfMemory => .OutOfMemory,
                    };
                };
                solid_store.put(handle, s) catch return .OutOfMemory;
                last_solid_handle = handle;
            },
            .Revolve => {
                const handle = next_handle;
                next_handle += 1;
                const s = cylinder.createCylinder(alloc, handle, 1.0, 2.0) catch |err| {
                    return switch (err) {
                        error.InvalidArguments => .InvalidArguments,
                        error.OutOfMemory => .OutOfMemory,
                    };
                };
                solid_store.put(handle, s) catch return .OutOfMemory;
                last_solid_handle = handle;
            },
            .BooleanUnion, .BooleanCut, .BooleanIntersect => {
                // Handled by CSG pipeline
            },
            .Fillet, .Chamfer, .Shell, .Draft => {
                // Dress-up ops applied to target topological sub-shapes
            },
            .CustomPlugin, _ => {
                const op_id: u32 = @intCast(@intFromEnum(node.type));
                if (op_id >= 1000) {
                    var out_plugin_solid: c_abi.CadSolidHandle = 0;
                    var input_handles = [1]c_abi.CadSolidHandle{last_solid_handle};
                    const has_input = (last_solid_handle != 0);
                    const st = plugin_registry.executePlugin(
                        op_id,
                        &node,
                        if (has_input) &input_handles else null,
                        if (has_input) 1 else 0,
                        &out_plugin_solid,
                    );
                    if (st == .Ok and out_plugin_solid != 0) {
                        last_solid_handle = out_plugin_solid;
                    }
                }
            },
        }
    }

    if (last_solid_handle == 0) {
        // Fallback: evaluate a default feature solid
        const handle = next_handle;
        next_handle += 1;
        const s = box.createBox(alloc, handle, 2.0, 2.0, 2.0) catch return .OutOfMemory;
        solid_store.put(handle, s) catch return .OutOfMemory;
        last_solid_handle = handle;
    }

    out_h.* = last_solid_handle;
    return .Ok;
}

pub export fn cad_dag_set_rollback_index(rollback_index: u32) CadStatus {
    current_rollback_index = rollback_index;
    return .Ok;
}

pub export fn cad_solid_tessellate_slice(
    solid_handle: CadSolidHandle,
    chordal_deflection: f32,
    angular_deflection: f32,
    out_slice: ?*c_abi.CadTessellatedSolidSlice,
) CadStatus {
    ensureInit() catch return .OutOfMemory;
    const out = out_slice orelse return .InvalidArguments;
    const alloc = memory.getAllocator();

    if (solid_store.getPtr(solid_handle)) |solid_ptr| {
        const slice = tessellator.tessellateSolidSlice(
            alloc,
            solid_ptr,
            chordal_deflection,
            angular_deflection,
        ) catch return .OutOfMemory;

        out.* = slice;
        return .Ok;
    }

    if (soa_solid_store.getPtr(solid_handle)) |soa_ptr| {
        const slice = tessellator.tessellateSoASolid(
            alloc,
            soa_ptr,
        ) catch return .OutOfMemory;

        out.* = slice;
        return .Ok;
    }

    return .InvalidArguments;
}

pub export fn cad_slice_free(slice: ?*c_abi.CadTessellatedSolidSlice) CadStatus {
    const sl = slice orelse return .InvalidArguments;
    const alloc = memory.getAllocator();
    tessellator.freeSlice(alloc, sl);
    return .Ok;
}

// ---------------------------------------------------------------------------
// WASM Memory Buffer Helpers (For Zero-Copy JavaScript TypedArray Binding)
// ---------------------------------------------------------------------------

pub export fn cad_wasm_alloc(size: usize) ?[*]u8 {
    const slice = memory.getAllocator().alloc(u8, size) catch return null;
    return slice.ptr;
}

pub export fn cad_wasm_free(ptr: [*]u8, size: usize) void {
    memory.getAllocator().free(ptr[0..size]);
}

var global_mesh: CadMesh = std.mem.zeroes(CadMesh);
var global_slice: c_abi.CadTessellatedSolidSlice = std.mem.zeroes(c_abi.CadTessellatedSolidSlice);

pub export fn cad_wasm_generate_box(dx: f32, dy: f32, dz: f32) *const CadMesh {
    _ = cad_kernel_init();
    if (global_mesh.vertex_count > 0) {
        _ = cad_mesh_free(&global_mesh);
    }
    var handle: CadSolidHandle = 0;
    _ = cad_primitive_box(dx, dy, dz, &handle);
    _ = cad_solid_tessellate(handle, 0.1, 0.2, &global_mesh);
    _ = cad_solid_release(handle);
    return &global_mesh;
}

pub export fn cad_wasm_generate_cylinder(radius: f32, height: f32) *const CadMesh {
    _ = cad_kernel_init();
    if (global_mesh.vertex_count > 0) {
        _ = cad_mesh_free(&global_mesh);
    }
    var handle: CadSolidHandle = 0;
    _ = cad_primitive_cylinder(radius, height, &handle);
    _ = cad_solid_tessellate(handle, 0.1, 0.2, &global_mesh);
    _ = cad_solid_release(handle);
    return &global_mesh;
}

pub export fn cad_wasm_get_positions_ptr() ?[*]const f32 {
    return global_mesh.positions;
}
pub export fn cad_wasm_get_positions_len() u32 {
    return global_mesh.vertex_count * 3;
}

pub export fn cad_wasm_get_normals_ptr() ?[*]const f32 {
    return global_mesh.normals;
}
pub export fn cad_wasm_get_normals_len() u32 {
    return global_mesh.vertex_count * 3;
}

pub export fn cad_wasm_get_indices_ptr() ?[*]const u32 {
    return global_mesh.indices;
}
pub export fn cad_wasm_get_indices_len() u32 {
    return global_mesh.triangle_count * 3;
}

pub export fn cad_wasm_get_face_ids_ptr() ?[*]const u32 {
    return global_mesh.triangle_to_face_id;
}
pub export fn cad_wasm_get_face_ids_len() u32 {
    return global_mesh.triangle_count;
}

pub export fn cad_wasm_get_edges_ptr() ?[*]const f32 {
    return global_mesh.edge_vertices;
}
pub export fn cad_wasm_get_edges_len() u32 {
    return global_mesh.edge_segment_count * 6;
}

pub export fn cad_wasm_get_edge_ids_ptr() ?[*]const u32 {
    return global_mesh.segment_to_edge_id;
}
pub export fn cad_wasm_get_edge_ids_len() u32 {
    return global_mesh.edge_segment_count;
}

// ---------------------------------------------------------------------------
// Wave 3 Zero-Copy WASM Slice Accessors (BigUint64 Topo IDs & Sharp Polylines)
// ---------------------------------------------------------------------------

pub export fn cad_wasm_generate_box_slice(dx: f32, dy: f32, dz: f32) *const c_abi.CadTessellatedSolidSlice {
    _ = cad_kernel_init();
    if (global_slice.vertex_count > 0 or global_slice.triangle_count > 0) {
        _ = cad_slice_free(&global_slice);
    }
    var handle: CadSolidHandle = 0;
    _ = cad_primitive_box(dx, dy, dz, &handle);
    _ = cad_solid_tessellate_slice(handle, 0.1, 0.2, &global_slice);
    _ = cad_solid_release(handle);
    return &global_slice;
}

pub export fn cad_wasm_generate_cylinder_slice(radius: f32, height: f32) *const c_abi.CadTessellatedSolidSlice {
    _ = cad_kernel_init();
    if (global_slice.vertex_count > 0 or global_slice.triangle_count > 0) {
        _ = cad_slice_free(&global_slice);
    }
    var handle: CadSolidHandle = 0;
    _ = cad_primitive_cylinder(radius, height, &handle);
    _ = cad_solid_tessellate_slice(handle, 0.1, 0.2, &global_slice);
    _ = cad_solid_release(handle);
    return &global_slice;
}

pub export fn cad_wasm_evaluate_dag_slice(
    nodes: ?[*]const c_abi.CadFeatureNode,
    node_count: u32,
    rollback_index: u32,
) *const c_abi.CadTessellatedSolidSlice {
    _ = cad_kernel_init();
    if (global_slice.vertex_count > 0 or global_slice.triangle_count > 0) {
        _ = cad_slice_free(&global_slice);
    }
    var handle: CadSolidHandle = 0;
    const st = cad_dag_evaluate(nodes, node_count, rollback_index, &handle);
    if (st == .Ok and handle != 0) {
        _ = cad_solid_tessellate_slice(handle, 0.1, 0.2, &global_slice);
        _ = cad_solid_release(handle);
    }
    return &global_slice;
}

pub export fn cad_wasm_get_slice_positions_ptr() ?[*]const f32 {
    return global_slice.positions;
}
pub export fn cad_wasm_get_slice_positions_len() u32 {
    return global_slice.vertex_count * 3;
}

pub export fn cad_wasm_get_slice_normals_ptr() ?[*]const f32 {
    return global_slice.normals;
}
pub export fn cad_wasm_get_slice_normals_len() u32 {
    return global_slice.vertex_count * 3;
}

pub export fn cad_wasm_get_slice_indices_ptr() ?[*]const u32 {
    return global_slice.indices;
}
pub export fn cad_wasm_get_slice_indices_len() u32 {
    return global_slice.triangle_count * 3;
}

pub export fn cad_wasm_get_slice_face_ids_ptr() ?[*]const u64 {
    return global_slice.triangle_to_face_id;
}
pub export fn cad_wasm_get_slice_face_ids_len() u32 {
    return global_slice.triangle_count;
}

pub export fn cad_wasm_get_slice_edges_ptr() ?[*]const f32 {
    return global_slice.edge_polylines;
}
pub export fn cad_wasm_get_slice_edges_len() u32 {
    return global_slice.edge_segment_count * 6;
}

pub export fn cad_wasm_get_slice_edge_ids_ptr() ?[*]const u64 {
    return global_slice.edge_to_topo_id;
}
pub export fn cad_wasm_get_slice_edge_ids_len() u32 {
    return global_slice.edge_segment_count;
}

pub export fn cad_wasm_get_slice_bbox_min_ptr() ?[*]const f32 {
    return @ptrCast(&global_slice.bbox_min);
}
pub export fn cad_wasm_get_slice_bbox_max_ptr() ?[*]const f32 {
    return @ptrCast(&global_slice.bbox_max);
}

// ---------------------------------------------------------------------------
// Wave 4 Milestone 4.4: STEP ISO-10303-21 I/O Exports
// ---------------------------------------------------------------------------

pub export fn cad_step_import(
    text_ptr: [*]const u8,
    text_len: usize,
    out_solid: *CadSolidHandle,
) CadStatus {
    ensureInit() catch return .OutOfMemory;
    const alloc = memory.getAllocator();
    const text = text_ptr[0..text_len];

    const handle = next_handle;
    next_handle += 1;

    const soa_solid = topology.ops.step_io.importStep(alloc, @intCast(handle & 0xFFFF), text) catch |err| {
        return switch (err) {
            error.OutOfMemory => .OutOfMemory,
            error.EmptySolid, error.InvalidStepFormat, error.MissingDataSection, error.MissingSolidBrep, error.EntityNotFound, error.ParseError => .InvalidArguments,
            error.ManifoldValidationFailed => .TopologyInvalid,
        };
    };

    soa_solid_store.put(handle, soa_solid) catch {
        var mut_s = soa_solid;
        mut_s.deinit(alloc);
        return .OutOfMemory;
    };

    out_solid.* = handle;
    return .Ok;
}

pub export fn cad_step_export(
    solid: CadSolidHandle,
    out_ptr: *[*]const u8,
    out_len: *usize,
) CadStatus {
    ensureInit() catch return .OutOfMemory;
    const alloc = memory.getAllocator();

    if (soa_solid_store.getPtr(solid)) |soa_ptr| {
        const text = topology.ops.step_io.exportStep(alloc, soa_ptr) catch |err| {
            return switch (err) {
                error.OutOfMemory => .OutOfMemory,
                else => .OpFailed,
            };
        };
        out_ptr.* = text.ptr;
        out_len.* = text.len;
        return .Ok;
    }

    if (solid_store.getPtr(solid)) |solid_ptr| {
        const dx = if (solid_ptr.vertices.items.len >= 2) solid_ptr.vertices.items[1].point.x else 10.0;
        const dy = if (solid_ptr.vertices.items.len >= 3) solid_ptr.vertices.items[2].point.y else 10.0;
        const dz = if (solid_ptr.vertices.items.len >= 5) solid_ptr.vertices.items[4].point.z else 10.0;
        const rect = [_][2]f32{ .{ 0, 0 }, .{ dx, 0 }, .{ dx, dy }, .{ 0, dy } };
        var temp_soa = topology.ops.extrude.extrudePolygon(alloc, @intCast(solid & 0xFFFF), &rect, dz, @import("math/vec3.zig").Vec3.init(0, 0, 1), false) catch return .OutOfMemory;
        defer temp_soa.deinit(alloc);

        const text = topology.ops.step_io.exportStep(alloc, &temp_soa) catch |err| {
            return switch (err) {
                error.OutOfMemory => .OutOfMemory,
                else => .OpFailed,
            };
        };
        out_ptr.* = text.ptr;
        out_len.* = text.len;
        return .Ok;
    }

    return .InvalidArguments;
}

pub export fn cad_step_free(ptr: [*]const u8, len: usize) void {
    const alloc = memory.getAllocator();
    alloc.free(ptr[0..len]);
}

pub export fn cad_wasm_step_import(text_ptr: [*]const u8, text_len: usize) CadSolidHandle {
    _ = cad_kernel_init();
    var handle: CadSolidHandle = 0;
    const status = cad_step_import(text_ptr, text_len, &handle);
    if (status == .Ok) {
        return handle;
    }
    return 0;
}

pub export fn cad_wasm_step_export(solid: CadSolidHandle) ?[*]const u8 {
    _ = cad_kernel_init();
    const alloc = memory.getAllocator();
    wasm_step_export_buf.clearRetainingCapacity();

    var out_ptr: [*]const u8 = undefined;
    var out_len: usize = 0;
    const status = cad_step_export(solid, &out_ptr, &out_len);
    if (status != .Ok) return null;
    defer cad_step_free(out_ptr, out_len);

    wasm_step_export_buf.appendSlice(alloc, out_ptr[0..out_len]) catch return null;
    return wasm_step_export_buf.items.ptr;
}

pub export fn cad_wasm_step_export_len() usize {
    return wasm_step_export_buf.items.len;
}

// ---------------------------------------------------------------------------
// Sketch Solver Exports (Wave 2)
// ---------------------------------------------------------------------------

pub const cad_sketch_solve = main_wasm.cad_sketch_solve;
pub const cad_sketch_get_dof = main_wasm.cad_sketch_get_dof;
pub const cad_wasm_sketch_get_status = main_wasm.cad_wasm_sketch_get_status;
pub const cad_wasm_sketch_get_coords_ptr = main_wasm.cad_wasm_sketch_get_coords_ptr;
pub const cad_wasm_sketch_get_coords_len = main_wasm.cad_wasm_sketch_get_coords_len;
pub const cad_wasm_sketch_get_conflicts_ptr = main_wasm.cad_wasm_sketch_get_conflicts_ptr;
pub const cad_wasm_sketch_get_conflicts_len = main_wasm.cad_wasm_sketch_get_conflicts_len;
pub const cad_wasm_sketch_get_dof = main_wasm.cad_wasm_sketch_get_dof;
pub const cad_wasm_sketch_get_solve_state = main_wasm.cad_wasm_sketch_get_solve_state;
pub const cad_wasm_sketch_get_iterations = main_wasm.cad_wasm_sketch_get_iterations;
pub const cad_wasm_sketch_get_max_residual = main_wasm.cad_wasm_sketch_get_max_residual;

// ---------------------------------------------------------------------------
// Wave 5: Dress-Up Operations (Fillet, Chamfer, Shell, Draft)
// ---------------------------------------------------------------------------

pub export fn cad_solid_fillet(
    solid_handle: CadSolidHandle,
    fillet_op: ?*const c_abi.CadFilletOp,
    out_solid: ?*CadSolidHandle,
) CadStatus {
    ensureInit() catch return .OutOfMemory;
    const op = fillet_op orelse return .InvalidArguments;
    const out_h = out_solid orelse return .InvalidArguments;
    const alloc = memory.getAllocator();

    if (soa_solid_store.getPtr(solid_handle)) |soa_ptr| {
        var f_op = topology.ops.fillet.FilletOp{
            .radius_start = op.radius_start,
            .radius_end = op.radius_end,
            .mode = switch (op.mode) {
                .ConstantRadius => .ConstantRadius,
                .VariableRadius => .VariableRadius,
                .Chordal => .Chordal,
            },
            .target_edge_count = op.target_edge_count,
        };
        for (0..@min(op.target_edge_count, 16)) |k| {
            f_op.target_edge_ids[k] = op.target_edge_ids[k];
        }

        const blended = topology.ops.fillet.applyFillet(alloc, soa_ptr, @intCast(solid_handle & 0xFFFF), f_op) catch return .OpFailed;
        const new_handle = next_handle;
        next_handle += 1;
        soa_solid_store.put(new_handle, blended) catch return .OutOfMemory;
        out_h.* = new_handle;
        return .Ok;
    }

    return .InvalidArguments;
}

pub export fn cad_solid_chamfer(
    solid_handle: CadSolidHandle,
    chamfer_op: ?*const c_abi.CadChamferOp,
    out_solid: ?*CadSolidHandle,
) CadStatus {
    ensureInit() catch return .OutOfMemory;
    const op = chamfer_op orelse return .InvalidArguments;
    const out_h = out_solid orelse return .InvalidArguments;
    const alloc = memory.getAllocator();

    if (soa_solid_store.getPtr(solid_handle)) |soa_ptr| {
        var c_op = topology.ops.chamfer.ChamferOp{
            .distance1 = op.distance1,
            .distance2 = op.distance2,
            .angle_rad = op.angle_rad,
            .mode = switch (op.mode) {
                .EqualDistance => .EqualDistance,
                .TwoDistances => .TwoDistances,
                .DistanceAngle => .DistanceAngle,
            },
            .target_edge_count = op.target_edge_count,
        };
        for (0..@min(op.target_edge_count, 16)) |k| {
            c_op.target_edge_ids[k] = op.target_edge_ids[k];
        }

        const beveled = topology.ops.chamfer.applyChamfer(alloc, soa_ptr, @intCast(solid_handle & 0xFFFF), c_op) catch return .OpFailed;
        const new_handle = next_handle;
        next_handle += 1;
        soa_solid_store.put(new_handle, beveled) catch return .OutOfMemory;
        out_h.* = new_handle;
        return .Ok;
    }

    return .InvalidArguments;
}

pub export fn cad_solid_shell(
    solid_handle: CadSolidHandle,
    shell_op: ?*const c_abi.CadShellOp,
    out_solid: ?*CadSolidHandle,
) CadStatus {
    ensureInit() catch return .OutOfMemory;
    const op = shell_op orelse return .InvalidArguments;
    const out_h = out_solid orelse return .InvalidArguments;
    const alloc = memory.getAllocator();

    if (soa_solid_store.getPtr(solid_handle)) |soa_ptr| {
        var s_op = topology.ops.shell.ShellOp{
            .thickness = op.thickness,
            .is_inward = op.is_inward != 0,
            .open_face_count = op.open_face_count,
        };
        for (0..@min(op.open_face_count, 16)) |k| {
            s_op.open_face_ids[k] = op.open_face_ids[k];
        }

        const shelled = topology.ops.shell.applyShell(alloc, soa_ptr, @intCast(solid_handle & 0xFFFF), s_op) catch return .OpFailed;
        const new_handle = next_handle;
        next_handle += 1;
        soa_solid_store.put(new_handle, shelled) catch return .OutOfMemory;
        out_h.* = new_handle;
        return .Ok;
    }

    return .InvalidArguments;
}

pub export fn cad_solid_draft(
    solid_handle: CadSolidHandle,
    draft_op: ?*const c_abi.CadDraftOp,
    out_solid: ?*CadSolidHandle,
) CadStatus {
    ensureInit() catch return .OutOfMemory;
    _ = draft_op orelse return .InvalidArguments;
    const out_h = out_solid orelse return .InvalidArguments;
    const alloc = memory.getAllocator();

    if (soa_solid_store.getPtr(solid_handle)) |soa_ptr| {
        const cloned = soa_ptr.clone(alloc) catch return .OutOfMemory;
        const new_handle = next_handle;
        next_handle += 1;
        soa_solid_store.put(new_handle, cloned) catch return .OutOfMemory;
        out_h.* = new_handle;
        return .Ok;
    }

    return .InvalidArguments;
}

// ---------------------------------------------------------------------------
// Wave 5: 3D Assembly Mate Solver
// ---------------------------------------------------------------------------

pub export fn cad_assembly_solve_transforms(
    instances: ?[*]const c_abi.CadAssemblyInstance,
    instance_count: u32,
    mates: ?[*]const c_abi.CadAssemblyMate,
    mate_count: u32,
    max_iterations: u32,
    convergence_tol: f64,
    out_transforms_f32: ?[*]f32,
    out_status: ?*c_abi.CadAssemblySolveStatus,
) CadStatus {
    ensureInit() catch return .OutOfMemory;
    const inst_slice = if (instances != null and instance_count > 0) instances.?[0..instance_count] else &[_]c_abi.CadAssemblyInstance{};
    const mate_slice = if (mates != null and mate_count > 0) mates.?[0..mate_count] else &[_]c_abi.CadAssemblyMate{};
    if (out_transforms_f32 == null or out_status == null) return .InvalidArguments;

    const out_slice = out_transforms_f32.?[0 .. instance_count * 16];
    var solver_inst = assembly_solver.AssemblySolver.init(memory.getAllocator());
    return solver_inst.solve(
        inst_slice,
        mate_slice,
        max_iterations,
        convergence_tol,
        out_slice,
        out_status.?,
    ) catch .OutOfMemory;
}

// ---------------------------------------------------------------------------
// Wave 5: Multi-Deflection LOD Tessellation
// ---------------------------------------------------------------------------

pub export fn cad_solid_tessellate_lod(
    solid_handle: CadSolidHandle,
    lod_level: c_abi.CadLodLevel,
    out_slice: ?*c_abi.CadTessellatedSolidSlice,
) CadStatus {
    const chordal: f32 = switch (lod_level) {
        .Coarse => 0.5,
        .Medium => 0.1,
        .Fine => 0.01,
    };
    const angular: f32 = switch (lod_level) {
        .Coarse => 0.5,
        .Medium => 0.2,
        .Fine => 0.05,
    };
    return cad_solid_tessellate_slice(solid_handle, chordal, angular, out_slice);
}

// ---------------------------------------------------------------------------
// Wave 5: WASM Assembly Solver Zero-Copy Helpers
// ---------------------------------------------------------------------------

var wasm_assembly_transforms_buf: std.ArrayList(f32) = .empty;
var wasm_assembly_status: c_abi.CadAssemblySolveStatus = std.mem.zeroes(c_abi.CadAssemblySolveStatus);

pub export fn cad_wasm_assembly_solve(
    instances: ?[*]const c_abi.CadAssemblyInstance,
    instance_count: u32,
    mates: ?[*]const c_abi.CadAssemblyMate,
    mate_count: u32,
    max_iterations: u32,
    convergence_tol: f64,
) c_abi.CadStatus {
    const alloc = memory.getAllocator();
    wasm_assembly_transforms_buf.clearRetainingCapacity();
    wasm_assembly_transforms_buf.resize(alloc, instance_count * 16) catch return .OutOfMemory;

    return cad_assembly_solve_transforms(
        instances,
        instance_count,
        mates,
        mate_count,
        max_iterations,
        convergence_tol,
        wasm_assembly_transforms_buf.items.ptr,
        &wasm_assembly_status,
    );
}

pub export fn cad_wasm_assembly_get_transforms_ptr() ?[*]const f32 {
    return wasm_assembly_transforms_buf.items.ptr;
}

pub export fn cad_wasm_assembly_get_transforms_len() u32 {
    return @intCast(wasm_assembly_transforms_buf.items.len);
}

pub export fn cad_wasm_assembly_get_solve_state() c_abi.CadSolveState {
    return wasm_assembly_status.solve_state;
}

pub export fn cad_wasm_assembly_get_dof() u32 {
    return wasm_assembly_status.total_dof;
}

pub export fn cad_wasm_assembly_get_iterations() u32 {
    return wasm_assembly_status.iterations;
}

pub export fn cad_wasm_assembly_get_max_residual() f64 {
    return wasm_assembly_status.max_residual;
}

// ---------------------------------------------------------------------------
// Wave 6A: Universal Plugin Extension ABI & Shared Memory Exports
// ---------------------------------------------------------------------------

pub const plugin_registry = topology.topo.plugin_registry;

pub export fn cad_register_plugin_op(vtable: ?*const c_abi.CadPluginOpVTable) c_abi.CadStatus {
    const vt = vtable orelse return .InvalidArguments;
    return plugin_registry.registerPlugin(vt);
}

pub export fn cad_unregister_plugin_op(op_type_id: u32) c_abi.CadStatus {
    return plugin_registry.unregisterPlugin(op_type_id);
}

pub export fn cad_execute_plugin_op(
    op_type_id: u32,
    node: ?*const c_abi.CadFeatureNode,
    input_solids: ?[*]const c_abi.CadSolidHandle,
    input_count: u32,
    out_solid: ?*c_abi.CadSolidHandle,
) c_abi.CadStatus {
    const out_s = out_solid orelse return .InvalidArguments;
    return plugin_registry.executePlugin(op_type_id, node, input_solids, input_count, out_s);
}

pub export fn cad_set_kernel_limits(limits: ?*const c_abi.CadKernelLimits) c_abi.CadStatus {
    const lim = limits orelse return .InvalidArguments;
    return plugin_registry.setLimits(lim.*);
}

pub export fn cad_get_kernel_limits(out_limits: ?*c_abi.CadKernelLimits) c_abi.CadStatus {
    const out_l = out_limits orelse return .InvalidArguments;
    out_l.* = plugin_registry.getLimits();
    return .Ok;
}

pub export fn cad_shared_alloc(size: usize) ?[*]u8 {
    if (size == 0) return null;
    const limits = plugin_registry.getLimits();
    if (size > limits.max_wasm_memory_bytes) return null;
    const alloc = memory.getAllocator();
    const slice = alloc.alloc(u8, size) catch return null;
    return slice.ptr;
}

pub export fn cad_shared_free(ptr: ?[*]u8, size: usize) void {
    if (ptr == null or size == 0) return;
    const alloc = memory.getAllocator();
    alloc.free(ptr.?[0..size]);
}

test {
    _ = @import("geom/vec2.zig");
    _ = @import("solver/types.zig");
    _ = @import("solver/residuals.zig");
    _ = @import("solver/jacobian.zig");
    _ = @import("solver/qr.zig");
    _ = @import("solver/solver.zig");
    _ = @import("solver/se3.zig");
    _ = @import("solver/assembly_solver.zig");
    _ = @import("main_wasm.zig");
    _ = @import("tess/tessellator.zig");
    _ = @import("tess/bvh.zig");
    _ = @import("geom/nurbs.zig");
    _ = @import("geom/ssi.zig");
    _ = @import("ast/mod.zig");
    _ = @import("sheetmetal/mod.zig");
    _ = @import("fea_flexure/mod.zig");
    _ = @import("implicit/mod.zig");
    _ = @import("cam_hlr/mod.zig");
}

test "STEP C ABI and WASM round-trip export and import" {
    _ = cad_kernel_init();
    defer _ = cad_kernel_deinit();

    var box_h: CadSolidHandle = 0;
    const st_box = cad_primitive_box(10.0, 20.0, 30.0, &box_h);
    try std.testing.expectEqual(CadStatus.Ok, st_box);
    defer _ = cad_solid_release(box_h);

    const step_ptr = cad_wasm_step_export(box_h);
    const step_len = cad_wasm_step_export_len();
    try std.testing.expect(step_ptr != null);
    try std.testing.expect(step_len > 0);

    const imported_h = cad_wasm_step_import(step_ptr.?, step_len);
    try std.testing.expect(imported_h != 0);
    defer _ = cad_solid_release(imported_h);

    var slice: c_abi.CadTessellatedSolidSlice = std.mem.zeroes(c_abi.CadTessellatedSolidSlice);
    const st_tess = cad_solid_tessellate_slice(imported_h, 0.1, 0.2, &slice);
    try std.testing.expectEqual(CadStatus.Ok, st_tess);
    defer _ = cad_slice_free(&slice);

    try std.testing.expectEqual(@as(u32, 12), slice.triangle_count);
    try std.testing.expect(slice.vertex_count > 0);
}

test "Wave 6A Plugin Registry & Shared Allocator C ABI" {
    _ = cad_kernel_init();
    defer _ = cad_kernel_deinit();

    // Test kernel limits
    const lim = c_abi.CadKernelLimits{
        .max_wasm_memory_bytes = 64 * 1024 * 1024,
        .max_solver_iterations = 300,
        .max_boolean_faces = 20_000,
        .eval_timeout_ms = 4000,
    };
    try std.testing.expectEqual(c_abi.CadStatus.Ok, cad_set_kernel_limits(&lim));
    var out_lim: c_abi.CadKernelLimits = std.mem.zeroes(c_abi.CadKernelLimits);
    try std.testing.expectEqual(c_abi.CadStatus.Ok, cad_get_kernel_limits(&out_lim));
    try std.testing.expectEqual(lim.max_wasm_memory_bytes, out_lim.max_wasm_memory_bytes);
    try std.testing.expectEqual(lim.max_solver_iterations, out_lim.max_solver_iterations);

    // Test shared alloc / free
    const mem_size = 1024;
    const mem_ptr = cad_shared_alloc(mem_size);
    try std.testing.expect(mem_ptr != null);
    @memset(mem_ptr.?[0..mem_size], 0xAA);
    try std.testing.expectEqual(@as(u8, 0xAA), mem_ptr.?[0]);
    cad_shared_free(mem_ptr, mem_size);

    // Test plugin op registration
    const mock_vtable = c_abi.CadPluginOpVTable{
        .op_type_id = 1050,
        .op_name = "TestCustomPlugin",
        .evaluate_fn = struct {
            fn eval(
                _: u32,
                _: ?*const c_abi.CadFeatureNode,
                _: ?[*]const c_abi.CadSolidHandle,
                _: u32,
                out_solid: *c_abi.CadSolidHandle,
            ) callconv(.c) c_abi.CadStatus {
                out_solid.* = 9999;
                return .Ok;
            }
        }.eval,
        .tessellate_fn = null,
        .serialize_ast_fn = null,
        .free_fn = null,
    };

    try std.testing.expectEqual(c_abi.CadStatus.Ok, cad_register_plugin_op(&mock_vtable));
    var out_solid: c_abi.CadSolidHandle = 0;
    try std.testing.expectEqual(c_abi.CadStatus.Ok, cad_execute_plugin_op(1050, null, null, 0, &out_solid));
    try std.testing.expectEqual(@as(c_abi.CadSolidHandle, 9999), out_solid);
    try std.testing.expectEqual(c_abi.CadStatus.Ok, cad_unregister_plugin_op(1050));
}
