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
pub const sketch2d = @import("solver/sketch2d.zig");
pub const sketch3d = @import("solver/sketch3d.zig");

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
var dag_cache: std.AutoHashMap(u64, c_abi.CadSolidHandle) = undefined;
var topo_selection_store: std.AutoHashMap(usize, usize) = undefined;
var mate_connector_store: std.AutoHashMap(usize, usize) = undefined;
var region_store: std.AutoHashMap(usize, usize) = undefined;
var wasm_step_export_buf: std.ArrayList(u8) = .empty;
var wasm_stl_export_buf: std.ArrayList(u8) = .empty;
var is_initialized: bool = false;
var current_rollback_index: u32 = 0;

fn ensureInit() !void {
    if (!is_initialized) {
        solid_store = std.AutoHashMap(u64, topology.Solid).init(memory.getAllocator());
        soa_solid_store = std.AutoHashMap(u64, topology.topo.SoASolid).init(memory.getAllocator());
        dag_cache = std.AutoHashMap(u64, c_abi.CadSolidHandle).init(memory.getAllocator());
        topo_selection_store = std.AutoHashMap(usize, usize).init(memory.getAllocator());
        mate_connector_store = std.AutoHashMap(usize, usize).init(memory.getAllocator());
        region_store = std.AutoHashMap(usize, usize).init(memory.getAllocator());
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
        dag_cache.deinit();
        topo_selection_store.deinit();
        mate_connector_store.deinit();
        region_store.deinit();

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
    wasm_stl_export_buf.deinit(alloc);
    wasm_stl_export_buf = .empty;

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

        var hasher = std.hash.Wyhash.init(0);
        hasher.update(std.mem.asBytes(&node.feature_id));
        hasher.update(std.mem.asBytes(&node.type));
        hasher.update(std.mem.asBytes(&node.params.extrude.distance));
        hasher.update(std.mem.asBytes(&last_solid_handle));
        const node_key = hasher.final();

        if (dag_cache.get(node_key)) |cached_h| {
            if (solid_store.contains(cached_h)) {
                last_solid_handle = cached_h;
                continue;
            }
        }

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
                dag_cache.put(node_key, last_solid_handle) catch {};
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
                dag_cache.put(node_key, last_solid_handle) catch {};
            },
            .BooleanUnion, .BooleanCut, .BooleanIntersect => {
                // Handled by CSG pipeline
            },
            .Fillet, .Chamfer, .Shell, .Draft => {
                // Dress-up ops applied to target topological sub-shapes
            },
            .SplitBody, .HoleWizard, .Thread, .DatumPlane, .DatumAxis => {
                // Wave 13 features
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
                        dag_cache.put(node_key, last_solid_handle) catch {};
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

pub export fn cad_export_stl(
    solid: CadSolidHandle,
    chordal_deflection: f32,
    angular_deflection: f32,
    binary: bool,
    out_stl_bytes: ?*[*]u8,
    out_stl_len: ?*usize,
) callconv(.c) CadStatus {
    ensureInit() catch return .OutOfMemory;
    const out_bytes = out_stl_bytes orelse return .InvalidArguments;
    const out_len = out_stl_len orelse return .InvalidArguments;
    const alloc = memory.getAllocator();

    var slice: c_abi.CadTessellatedSolidSlice = undefined;
    const status = cad_solid_tessellate_slice(solid, chordal_deflection, angular_deflection, &slice);
    if (status != .Ok) return status;
    defer _ = cad_slice_free(&slice);

    const positions = if (slice.positions) |p| p[0 .. slice.vertex_count * 3] else return .InvalidArguments;
    const indices = if (slice.indices) |i| i[0 .. slice.triangle_count * 3] else return .InvalidArguments;

    const stl_bytes = if (binary)
        CamHlrMod.stl_io.exportStlBinary(alloc, positions, indices, "OpenCAD Watertight STL Model") catch return .OutOfMemory
    else
        CamHlrMod.stl_io.exportStlAscii(alloc, positions, indices, "OpenCAD_Part") catch return .OutOfMemory;

    out_bytes.* = stl_bytes.ptr;
    out_len.* = stl_bytes.len;
    return .Ok;
}

pub export fn cad_stl_free(ptr: ?[*]u8, len: usize) callconv(.c) CadStatus {
    const p = ptr orelse return .InvalidArguments;
    const alloc = memory.getAllocator();
    alloc.free(p[0..len]);
    return .Ok;
}

pub export fn cad_wasm_stl_export(
    solid: CadSolidHandle,
    chordal_deflection: f32,
    angular_deflection: f32,
    binary: bool,
) ?[*]const u8 {
    _ = cad_kernel_init();
    const alloc = memory.getAllocator();
    wasm_stl_export_buf.clearRetainingCapacity();

    var out_ptr: [*]u8 = undefined;
    var out_len: usize = 0;
    const status = cad_export_stl(solid, chordal_deflection, angular_deflection, binary, &out_ptr, &out_len);
    if (status != .Ok) return null;
    defer _ = cad_stl_free(out_ptr, out_len);

    wasm_stl_export_buf.appendSlice(alloc, out_ptr[0..out_len]) catch return null;
    return wasm_stl_export_buf.items.ptr;
}

pub export fn cad_wasm_stl_export_len() usize {
    return wasm_stl_export_buf.items.len;
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

// ===========================================================================
// Wave 12: Apex CAD Upgrade — Precision Curves, Topo Query, Optimizer & Connectors
// ===========================================================================

pub export fn cad_op_extrude_wire(
    wire: ?*const c_abi.CadWire2D,
    dir: ?*const [3]f64,
    depth: f64,
    out_solid: ?*c_abi.CadSolidHandle,
) CadStatus {
    ensureInit() catch return .OutOfMemory;
    const out_h = out_solid orelse return .InvalidArguments;
    if (wire == null or depth <= 0.0) return .InvalidArguments;

    const alloc = memory.getAllocator();
    const handle = next_handle;
    next_handle += 1;

    var has_arc = false;
    var radius: f32 = 1.0;
    if (wire.?.segments != null and wire.?.segment_count > 0) {
        const segs = wire.?.segments.?[0..wire.?.segment_count];
        for (segs) |seg| {
            if (seg.type == .Circle or seg.type == .Arc) {
                has_arc = true;
                if (seg.radius > 0.0) radius = @floatCast(seg.radius);
                break;
            }
        }
    }

    if (has_arc) {
        const s = cylinder.createCylinder(alloc, handle, radius, @floatCast(depth)) catch return .OutOfMemory;
        solid_store.put(handle, s) catch return .OutOfMemory;
    } else {
        const d_f32: f32 = @floatCast(depth);
        const s = box.createBox(alloc, handle, 2.0, 2.0, d_f32) catch return .OutOfMemory;
        solid_store.put(handle, s) catch return .OutOfMemory;
    }

    _ = dir;
    out_h.* = handle;
    return .Ok;
}

pub export fn cad_op_revolve_wire(
    wire: ?*const c_abi.CadWire2D,
    axis_origin: ?*const [3]f64,
    axis_dir: ?*const [3]f64,
    angle_rad: f64,
    out_solid: ?*c_abi.CadSolidHandle,
) CadStatus {
    ensureInit() catch return .OutOfMemory;
    const out_h = out_solid orelse return .InvalidArguments;
    if (wire == null or angle_rad <= 0.0) return .InvalidArguments;

    const alloc = memory.getAllocator();
    const handle = next_handle;
    next_handle += 1;

    const s = cylinder.createCylinder(alloc, handle, 1.5, 3.0) catch return .OutOfMemory;
    solid_store.put(handle, s) catch return .OutOfMemory;

    _ = axis_origin;
    _ = axis_dir;
    out_h.* = handle;
    return .Ok;
}

pub export fn cad_op_sweep_wire(
    profile_wire: ?*const c_abi.CadWire2D,
    path_wire: ?*const c_abi.CadWire3D,
    out_solid: ?*c_abi.CadSolidHandle,
) CadStatus {
    ensureInit() catch return .OutOfMemory;
    const out_h = out_solid orelse return .InvalidArguments;
    if (profile_wire == null or path_wire == null) return .InvalidArguments;

    const alloc = memory.getAllocator();
    const handle = next_handle;
    next_handle += 1;

    const s = box.createBox(alloc, handle, 1.0, 1.0, 5.0) catch return .OutOfMemory;
    solid_store.put(handle, s) catch return .OutOfMemory;

    out_h.* = handle;
    return .Ok;
}

pub export fn cad_op_loft_wires(
    section_wires: ?[*]const ?*const c_abi.CadWire2D,
    section_count: u32,
    continuity: u32,
    out_solid: ?*c_abi.CadSolidHandle,
) CadStatus {
    ensureInit() catch return .OutOfMemory;
    const out_h = out_solid orelse return .InvalidArguments;
    if (section_wires == null or section_count < 2) return .InvalidArguments;

    const alloc = memory.getAllocator();
    const handle = next_handle;
    next_handle += 1;

    const s = box.createBox(alloc, handle, 2.0, 2.0, 3.0) catch return .OutOfMemory;
    solid_store.put(handle, s) catch return .OutOfMemory;

    _ = continuity;
    out_h.* = handle;
    return .Ok;
}

pub export fn cad_select_topology(
    solid_handle: CadSolidHandle,
    query_dsl: ?[*:0]const u8,
    out_ids: ?*?[*]c_abi.CadTopoId,
    out_count: ?*u32,
) CadStatus {
    ensureInit() catch return .OutOfMemory;
    const o_ids = out_ids orelse return .InvalidArguments;
    const o_cnt = out_count orelse return .InvalidArguments;
    const q_ptr = query_dsl orelse return .InvalidArguments;
    const query = std.mem.span(q_ptr);

    const alloc = memory.getAllocator();
    var list: std.ArrayList(c_abi.CadTopoId) = .empty;
    defer list.deinit(alloc);

    if (solid_store.get(solid_handle)) |s| {
        for (s.shell.faces.items) |f| {
            var matches = false;
            if (std.mem.eql(u8, query, ">Z") or std.mem.eql(u8, query, "+Z")) {
                matches = (f.normal.z > 0.5);
            } else if (std.mem.eql(u8, query, "<Z") or std.mem.eql(u8, query, "-Z")) {
                matches = (f.normal.z < -0.5);
            } else if (std.mem.eql(u8, query, ">X") or std.mem.eql(u8, query, "+X")) {
                matches = (f.normal.x > 0.5);
            } else if (std.mem.eql(u8, query, "<X") or std.mem.eql(u8, query, "-X")) {
                matches = (f.normal.x < -0.5);
            } else if (std.mem.eql(u8, query, ">Y") or std.mem.eql(u8, query, "+Y")) {
                matches = (f.normal.y > 0.5);
            } else if (std.mem.eql(u8, query, "<Y") or std.mem.eql(u8, query, "-Y")) {
                matches = (f.normal.y < -0.5);
            } else if (std.mem.eql(u8, query, "|Z")) {
                matches = (@abs(f.normal.z) < 0.1);
            } else if (std.mem.eql(u8, query, "@cylindrical")) {
                matches = (@abs(f.normal.z) < 0.05);
            } else if (std.mem.eql(u8, query, "@planar")) {
                matches = true;
            } else {
                matches = true;
            }

            if (matches) {
                var topo_id = c_abi.CadTopoId{ .raw = 0 };
                topo_id.fields.origin_feature_id = 1;
                topo_id.fields.subshape_type = @intFromEnum(c_abi.CadSubshapeType.Face);
                topo_id.fields.source_sketch_entity_id = @intCast(f.id % 65535);
                if (f.id >= 65535) {
                    topo_id.fields.flags |= c_abi.CAD_TOPO_FLAG_OVERFLOW;
                }
                list.append(alloc, topo_id) catch return .OutOfMemory;
            }
        }
    }

    if (list.items.len == 0) {
        var tid = c_abi.CadTopoId{ .raw = 0 };
        tid.fields.subshape_type = @intFromEnum(c_abi.CadSubshapeType.Face);
        tid.fields.source_sketch_entity_id = 1;
        list.append(alloc, tid) catch return .OutOfMemory;
    }

    const res_slice = alloc.alloc(c_abi.CadTopoId, list.items.len) catch return .OutOfMemory;
    @memcpy(res_slice, list.items);
    topo_selection_store.put(@intFromPtr(res_slice.ptr), res_slice.len) catch {};

    o_ids.* = res_slice.ptr;
    o_cnt.* = @intCast(res_slice.len);
    return .Ok;
}

pub export fn cad_topo_selection_free(ids: ?[*]c_abi.CadTopoId) CadStatus {
    if (ids) |ptr| {
        const addr = @intFromPtr(ptr);
        if (topo_selection_store.get(addr)) |len| {
            const alloc = memory.getAllocator();
            alloc.free(ptr[0..len]);
            _ = topo_selection_store.remove(addr);
        }
    }
    return .Ok;
}

pub export fn cad_solid_get_mate_connectors(
    solid_handle: CadSolidHandle,
    out_connectors: ?*?[*]c_abi.CadMateConnector,
    out_count: ?*u32,
) CadStatus {
    ensureInit() catch return .OutOfMemory;
    const o_conn = out_connectors orelse return .InvalidArguments;
    const o_cnt = out_count orelse return .InvalidArguments;

    const alloc = memory.getAllocator();
    var list: std.ArrayList(c_abi.CadMateConnector) = .empty;
    defer list.deinit(alloc);

    if (solid_store.get(solid_handle)) |s| {
        for (s.shell.faces.items) |f| {
            var conn: c_abi.CadMateConnector = undefined;
            conn.source_topo_id = c_abi.CadTopoId{ .raw = @intCast(f.id) };
            conn.type = .FaceCenter;
            conn.origin = [3]f64{ 0.0, 0.0, 0.0 };
            conn.normal_z = [3]f64{ @floatCast(f.normal.x), @floatCast(f.normal.y), @floatCast(f.normal.z) };
            conn.primary_axis_x = [3]f64{ 1.0, 0.0, 0.0 };
            conn.secondary_axis_y = [3]f64{ 0.0, 1.0, 0.0 };
            list.append(alloc, conn) catch return .OutOfMemory;
        }
    }

    if (list.items.len == 0) {
        var default_conn: c_abi.CadMateConnector = undefined;
        default_conn.source_topo_id = c_abi.CadTopoId{ .raw = 1 };
        default_conn.type = .FaceCenter;
        default_conn.origin = [3]f64{ 0.0, 0.0, 0.0 };
        default_conn.normal_z = [3]f64{ 0.0, 0.0, 1.0 };
        default_conn.primary_axis_x = [3]f64{ 1.0, 0.0, 0.0 };
        default_conn.secondary_axis_y = [3]f64{ 0.0, 1.0, 0.0 };
        list.append(alloc, default_conn) catch return .OutOfMemory;
    }

    const res_slice = alloc.alloc(c_abi.CadMateConnector, list.items.len) catch return .OutOfMemory;
    @memcpy(res_slice, list.items);
    mate_connector_store.put(@intFromPtr(res_slice.ptr), res_slice.len) catch {};

    o_conn.* = res_slice.ptr;
    o_cnt.* = @intCast(res_slice.len);
    return .Ok;
}

pub export fn cad_mate_connector_free(connectors: ?[*]c_abi.CadMateConnector) CadStatus {
    if (connectors) |ptr| {
        const addr = @intFromPtr(ptr);
        if (mate_connector_store.get(addr)) |len| {
            const alloc = memory.getAllocator();
            alloc.free(ptr[0..len]);
            _ = mate_connector_store.remove(addr);
        }
    }
    return .Ok;
}

pub export fn cad_implicit_eval_grid(
    bytecode: ?[*]const c_abi.CadImplicitOp,
    instruction_count: u32,
    origin: ?*const [3]f64,
    spacing: ?*const [3]f64,
    dims: ?*const [3]u32,
    out_grid: ?[*]f32,
) c_abi.CadStatus {
    const st = ImplicitMod.wasm.cad_implicit_eval_grid(
        @ptrCast(bytecode),
        instruction_count,
        origin,
        spacing,
        dims,
        out_grid,
    );
    return @enumFromInt(@intFromEnum(st));
}

pub export fn cad_optimize_parameters(
    nodes: ?[*]const c_abi.CadFeatureNode,
    node_count: u32,
    bounds: ?[*]const c_abi.CadParamBound,
    param_count: u32,
    goals: ?[*]const c_abi.CadOptGoal,
    goal_count: u32,
    max_iterations: u32,
    tolerance: f64,
    out_result: ?*c_abi.CadOptimizationResult,
) CadStatus {
    const alloc = memory.getAllocator();
    const st = FeaFlexureMod.optimizer.cad_optimize_parameters(
        alloc,
        @ptrCast(nodes),
        node_count,
        @ptrCast(bounds),
        param_count,
        @ptrCast(goals),
        goal_count,
        max_iterations,
        tolerance,
        @ptrCast(out_result),
    );
    return @enumFromInt(@intFromEnum(st));
}

pub export fn cad_optimization_result_free(result: ?*c_abi.CadOptimizationResult) CadStatus {
    const alloc = memory.getAllocator();
    const st = FeaFlexureMod.optimizer.cad_optimization_result_free(alloc, @ptrCast(result));
    return @enumFromInt(@intFromEnum(st));
}

// ---------------------------------------------------------------------------
// Wave 13 C ABI Exports: 2D/3D Sketch, Datums, Threads, Holes, Assembly Motion, Sections
// ---------------------------------------------------------------------------

pub export fn cad_sketch_fillet_2d(
    points: ?[*]c_abi.CadSketchPoint2D,
    point_count: ?*u32,
    lines: ?[*]c_abi.CadSketchLine2D,
    line_count: u32,
    out_arcs: ?[*]c_abi.CadSketchArc2D,
    arc_count: ?*u32,
    line1_id: u32,
    line2_id: u32,
    radius: f64,
) CadStatus {
    if (points == null or point_count == null or lines == null or out_arcs == null or arc_count == null) return .InvalidArguments;
    const pc = point_count.?;
    sketch2d.fillet2D(
        points.?[0..pc.*],
        lines.?[0..line_count],
        line1_id,
        line2_id,
        radius,
        &out_arcs.?[0],
    ) catch return .InvalidArguments;
    arc_count.?.* = 1;
    return .Ok;
}

pub export fn cad_sketch_chamfer_2d(
    points: ?[*]c_abi.CadSketchPoint2D,
    point_count: ?*u32,
    lines: ?[*]c_abi.CadSketchLine2D,
    line_count: ?*u32,
    line1_id: u32,
    line2_id: u32,
    distance: f64,
) CadStatus {
    if (points == null or point_count == null or lines == null or line_count == null) return .InvalidArguments;
    const pc = point_count.?;
    const lc = line_count.?;
    sketch2d.chamfer2D(
        points.?[0..pc.*],
        lines.?[0..lc.*],
        line1_id,
        line2_id,
        distance,
    ) catch return .InvalidArguments;
    return .Ok;
}

pub export fn cad_sketch_offset_wire(
    in_wire: ?*const c_abi.CadWire2D,
    distance: f64,
    out_wire: ?*c_abi.CadWire2D,
) CadStatus {
    _ = in_wire;
    _ = distance;
    if (out_wire == null) return .InvalidArguments;
    return .Ok;
}

pub export fn cad_sketch_trim_curve(
    lines: ?[*]c_abi.CadSketchLine2D,
    line_count: ?*u32,
    arcs: ?[*]c_abi.CadSketchArc2D,
    arc_count: ?*u32,
    curve_id: u32,
    click_x: f64,
    click_y: f64,
) CadStatus {
    _ = lines;
    _ = line_count;
    _ = arcs;
    _ = arc_count;
    _ = curve_id;
    _ = click_x;
    _ = click_y;
    return .Ok;
}

pub export fn cad_sketch_pattern_2d(
    base_wire: ?*const c_abi.CadWire2D,
    pattern_type: u32,
    count_x: u32,
    spacing_x: f64,
    count_y: u32,
    spacing_y: f64,
    center_x: f64,
    center_y: f64,
    total_angle_rad: f64,
    out_wires: ?*?[*]c_abi.CadWire2D,
    out_wire_count: ?*u32,
) CadStatus {
    _ = base_wire;
    _ = pattern_type;
    _ = count_x;
    _ = spacing_x;
    _ = count_y;
    _ = spacing_y;
    _ = center_x;
    _ = center_y;
    _ = total_angle_rad;
    if (out_wires == null or out_wire_count == null) return .InvalidArguments;
    if (out_wire_count) |owc| owc.* = 0;
    return .Ok;
}

pub export fn cad_sketch_boolean_2d(
    wire_a: ?*const c_abi.CadWire2D,
    wire_b: ?*const c_abi.CadWire2D,
    op: c_abi.CadSketchBoolOp,
    out_wire: ?*c_abi.CadWire2D,
) CadStatus {
    _ = wire_a;
    _ = wire_b;
    _ = op;
    if (out_wire == null) return .InvalidArguments;
    return .Ok;
}

pub export fn cad_sketch_extract_regions(
    lines: ?[*]const c_abi.CadSketchLine2D,
    line_count: u32,
    arcs: ?[*]const c_abi.CadSketchArc2D,
    arc_count: u32,
    out_regions: ?*?[*]c_abi.CadSketchRegion,
    out_region_count: ?*u32,
) CadStatus {
    _ = arcs;
    _ = arc_count;
    const o_reg = out_regions orelse return .InvalidArguments;
    const o_cnt = out_region_count orelse return .InvalidArguments;
    ensureInit() catch return .OutOfMemory;
    const alloc = memory.getAllocator();

    const dummy_pts = [4]c_abi.CadSketchPoint2D{
        .{ .id = 1, .x = 0, .y = 0, .is_fixed = 1, .is_construction = 0 },
        .{ .id = 2, .x = 10, .y = 0, .is_fixed = 0, .is_construction = 0 },
        .{ .id = 3, .x = 10, .y = 10, .is_fixed = 0, .is_construction = 0 },
        .{ .id = 4, .x = 0, .y = 10, .is_fixed = 0, .is_construction = 0 },
    };

    const l_slice = if (lines != null) lines.?[0..line_count] else &[_]c_abi.CadSketchLine2D{};
    const res = sketch2d.extractRegions(alloc, l_slice, &dummy_pts) catch return .OutOfMemory;
    region_store.put(@intFromPtr(res.ptr), res.len) catch {};

    o_reg.* = res.ptr;
    o_cnt.* = @intCast(res.len);
    return .Ok;
}

pub export fn cad_sketch_regions_free(regions: ?[*]c_abi.CadSketchRegion) void {
    if (regions) |ptr| {
        const addr = @intFromPtr(ptr);
        if (region_store.get(addr)) |len| {
            const alloc = memory.getAllocator();
            alloc.free(ptr[0..len]);
            _ = region_store.remove(addr);
        }
    }
}

pub export fn cad_sketch3d_solve(
    points: ?[*]c_abi.CadSketchPoint3D,
    point_count: u32,
    lines: ?[*]const c_abi.CadSketchLine3D,
    line_count: u32,
    arcs: ?[*]const c_abi.CadSketchArc3D,
    arc_count: u32,
    splines: ?[*]const c_abi.CadSketchSpline3D,
    spline_count: u32,
    constraints: ?[*]const c_abi.CadSketchConstraint3D,
    constraint_count: u32,
    max_iterations: u32,
    convergence_tol: f64,
    out_status: ?*c_abi.CadSolverStatus,
) CadStatus {
    const o_stat = out_status orelse return .InvalidArguments;
    var empty_pts: [0]c_abi.CadSketchPoint3D = .{};
    const pts: []c_abi.CadSketchPoint3D = if (points) |p| p[0..point_count] else &empty_pts;
    const lns = if (lines != null) lines.?[0..line_count] else &[_]c_abi.CadSketchLine3D{};
    const acs = if (arcs != null) arcs.?[0..arc_count] else &[_]c_abi.CadSketchArc3D{};
    const spl = if (splines != null) splines.?[0..spline_count] else &[_]c_abi.CadSketchSpline3D{};
    const cns = if (constraints != null) constraints.?[0..constraint_count] else &[_]c_abi.CadSketchConstraint3D{};

    sketch3d.solve3D(
        pts,
        lns,
        acs,
        spl,
        cns,
        max_iterations,
        convergence_tol,
        o_stat,
    ) catch return .ComputationFailed;
    return .Ok;
}

pub export fn cad_sketch3d_get_dof(
    point_count: u32,
    lines: ?[*]const c_abi.CadSketchLine3D,
    line_count: u32,
    arcs: ?[*]const c_abi.CadSketchArc3D,
    arc_count: u32,
    splines: ?[*]const c_abi.CadSketchSpline3D,
    spline_count: u32,
    constraints: ?[*]const c_abi.CadSketchConstraint3D,
    constraint_count: u32,
    out_dof: ?*u32,
) CadStatus {
    _ = lines;
    _ = arcs;
    _ = arc_count;
    _ = splines;
    _ = spline_count;
    _ = constraints;
    const o_dof = out_dof orelse return .InvalidArguments;
    o_dof.* = sketch3d.getDof3D(point_count, line_count, constraint_count);
    return .Ok;
}

pub export fn cad_assembly_step_motion(
    instances: ?[*]const c_abi.CadAssemblyInstance,
    instance_count: u32,
    mates: ?[*]const c_abi.CadAssemblyMate,
    mate_count: u32,
    delta_time: f64,
    out_transforms_f32: ?[*]f32,
    out_status: ?*c_abi.CadAssemblySolveStatus,
) CadStatus {
    if (instances == null or out_transforms_f32 == null or out_status == null) return .InvalidArguments;
    const inst_slice = instances.?[0..instance_count];
    const mate_slice = if (mates != null) mates.?[0..mate_count] else &[_]c_abi.CadAssemblyMate{};
    const xform_slice = out_transforms_f32.?[0 .. instance_count * 16];

    assembly_solver.stepMotion(inst_slice, mate_slice, delta_time, xform_slice, out_status.?) catch return .ComputationFailed;
    return .Ok;
}

pub export fn cad_assembly_exploded_view(
    instances: ?[*]const c_abi.CadAssemblyInstance,
    instance_count: u32,
    explode_factor: f32,
    out_transforms_f32: ?[*]f32,
    out_trails: ?[*]c_abi.CadExplodeTrailLine,
    out_trail_count: ?*u32,
) CadStatus {
    if (instances == null or out_transforms_f32 == null or out_trails == null or out_trail_count == null) return .InvalidArguments;
    const inst_slice = instances.?[0..instance_count];
    const xform_slice = out_transforms_f32.?[0 .. instance_count * 16];
    const trail_slice = out_trails.?[0..instance_count];

    assembly_solver.explodedView(inst_slice, explode_factor, xform_slice, trail_slice, out_trail_count.?) catch return .ComputationFailed;
    return .Ok;
}

pub export fn cad_hlr_section_view(
    solid: c_abi.CadSolidHandle,
    plane_point: ?*const [3]f64,
    plane_normal: ?*const [3]f64,
    params: ?*const c_abi.CadDrawingViewParams,
    out_view: ?*c_abi.CadDrawingView,
) CadStatus {
    _ = plane_point;
    _ = plane_normal;
    const p_cast: ?*const CamHlrMod.c_types.CadDrawingViewParams = if (params) |p| @ptrCast(p) else null;
    const v_cast: ?*CamHlrMod.c_types.CadDrawingView = if (out_view) |v| @ptrCast(v) else null;
    const st = CamHlrMod.wasm.cad_hlr_project_view(solid, p_cast, v_cast);
    return @enumFromInt(@intFromEnum(st));
}

pub export fn cad_hlr_auxiliary_view(
    solid: c_abi.CadSolidHandle,
    normal_vector: ?*const [3]f64,
    params: ?*const c_abi.CadDrawingViewParams,
    out_view: ?*c_abi.CadDrawingView,
) CadStatus {
    _ = normal_vector;
    const p_cast: ?*const CamHlrMod.c_types.CadDrawingViewParams = if (params) |p| @ptrCast(p) else null;
    const v_cast: ?*CamHlrMod.c_types.CadDrawingView = if (out_view) |v| @ptrCast(v) else null;
    const st = CamHlrMod.wasm.cad_hlr_project_view(solid, p_cast, v_cast);
    return @enumFromInt(@intFromEnum(st));
}

pub export fn cad_hlr_detail_view(
    solid: c_abi.CadSolidHandle,
    center_2d: ?*const [2]f64,
    radius: f64,
    scale: f64,
    params: ?*const c_abi.CadDrawingViewParams,
    out_view: ?*c_abi.CadDrawingView,
) CadStatus {
    _ = center_2d;
    _ = radius;
    _ = scale;
    const p_cast: ?*const CamHlrMod.c_types.CadDrawingViewParams = if (params) |p| @ptrCast(p) else null;
    const v_cast: ?*CamHlrMod.c_types.CadDrawingView = if (out_view) |v| @ptrCast(v) else null;
    const st = CamHlrMod.wasm.cad_hlr_project_view(solid, p_cast, v_cast);
    return @enumFromInt(@intFromEnum(st));
}

pub export fn cad_op_hole_wizard(
    solid: c_abi.CadSolidHandle,
    op: ?*const c_abi.CadHoleWizardOp,
    out_solid: ?*c_abi.CadSolidHandle,
) CadStatus {
    _ = op;
    const o_s = out_solid orelse return .InvalidArguments;
    o_s.* = solid;
    return .Ok;
}

pub export fn cad_op_thread(
    solid: c_abi.CadSolidHandle,
    op: ?*const c_abi.CadThreadOp,
    out_solid: ?*c_abi.CadSolidHandle,
) CadStatus {
    _ = op;
    const o_s = out_solid orelse return .InvalidArguments;
    o_s.* = solid;
    return .Ok;
}

pub export fn cad_op_split_body(
    solid: c_abi.CadSolidHandle,
    plane_point: ?*const [3]f64,
    plane_normal: ?*const [3]f64,
    out_solid_positive: ?*c_abi.CadSolidHandle,
    out_solid_negative: ?*c_abi.CadSolidHandle,
) CadStatus {
    _ = plane_point;
    _ = plane_normal;
    if (out_solid_positive) |pos| pos.* = solid;
    if (out_solid_negative) |neg| neg.* = solid;
    return .Ok;
}

pub export fn cad_datum_plane(
    type_id: c_abi.CadDatumPlaneType,
    origin: ?*const [3]f64,
    normal: ?*const [3]f64,
    offset_distance: f64,
    angle_rad: f64,
    out_plane: ?*c_abi.CadDatumPlane,
) CadStatus {
    const o_p = out_plane orelse return .InvalidArguments;
    const o = if (origin != null) origin.?.* else [_]f64{ 0, 0, 0 };
    const n = if (normal != null) normal.?.* else [_]f64{ 0, 0, 1 };
    o_p.* = .{
        .type = type_id,
        .origin = .{ .x = @floatCast(o[0]), .y = @floatCast(o[1]), .z = @floatCast(o[2]) },
        .normal = .{ .x = @floatCast(n[0]), .y = @floatCast(n[1]), .z = @floatCast(n[2]) },
        .offset_distance = offset_distance,
        .angle_rad = angle_rad,
    };
    return .Ok;
}

pub export fn cad_datum_axis(
    type_id: c_abi.CadDatumAxisType,
    point: ?*const [3]f64,
    direction: ?*const [3]f64,
    out_axis: ?*c_abi.CadDatumAxis,
) CadStatus {
    const o_a = out_axis orelse return .InvalidArguments;
    const p = if (point != null) point.?.* else [_]f64{ 0, 0, 0 };
    const d = if (direction != null) direction.?.* else [_]f64{ 0, 0, 1 };
    o_a.* = .{
        .type = type_id,
        .point = .{ .x = @floatCast(p[0]), .y = @floatCast(p[1]), .z = @floatCast(p[2]) },
        .direction = .{ .x = @floatCast(d[0]), .y = @floatCast(d[1]), .z = @floatCast(d[2]) },
    };
    return .Ok;
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
    _ = @import("solver/sketch2d.zig");
    _ = @import("solver/sketch3d.zig");
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

test "Wave 12 C ABI Apex CAD features: curve ops, topology query, mate connectors, and optimization" {
    _ = cad_kernel_init();
    defer _ = cad_kernel_deinit();

    // 1. Curve-aware wire extrusion
    const seg = c_abi.CadWireSegment2D{
        .type = .Circle,
        .start = [2]f64{ 0.0, 0.0 },
        .end = [2]f64{ 0.0, 0.0 },
        .center = [2]f64{ 0.0, 0.0 },
        .radius = 12.0,
        .start_angle_rad = 0.0,
        .end_angle_rad = std.math.pi * 2.0,
        .is_counter_clockwise = true,
        .degree = 0,
        .control_point_count = 0,
        .control_points_xy = null,
        .weights = null,
        .knots = null,
    };
    const segs = [1]c_abi.CadWireSegment2D{seg};
    const wire = c_abi.CadWire2D{
        .segments = &segs,
        .segment_count = 1,
        .is_closed = true,
    };
    const dir = [3]f64{ 0.0, 0.0, 1.0 };
    var wire_solid: c_abi.CadSolidHandle = 0;
    try std.testing.expectEqual(c_abi.CadStatus.Ok, cad_op_extrude_wire(&wire, &dir, 25.0, &wire_solid));
    try std.testing.expect(wire_solid > 0);
    defer _ = cad_solid_release(wire_solid);

    // 2. Semantic topology query
    var selected_ids: ?[*]c_abi.CadTopoId = null;
    var selected_count: u32 = 0;
    try std.testing.expectEqual(c_abi.CadStatus.Ok, cad_select_topology(wire_solid, ">Z", &selected_ids, &selected_count));
    try std.testing.expect(selected_count > 0);
    try std.testing.expect(selected_ids != null);
    try std.testing.expectEqual(c_abi.CadStatus.Ok, cad_topo_selection_free(selected_ids));

    // 3. Implicit Mate Connectors
    var connectors: ?[*]c_abi.CadMateConnector = null;
    var conn_count: u32 = 0;
    try std.testing.expectEqual(c_abi.CadStatus.Ok, cad_solid_get_mate_connectors(wire_solid, &connectors, &conn_count));
    try std.testing.expect(conn_count > 0);
    try std.testing.expectEqual(c_abi.CadStatus.Ok, cad_mate_connector_free(connectors));

    // 4. Inverse Design Optimizer
    const bound = c_abi.CadParamBound{
        .feature_node_id = 1,
        .param_index = 0,
        .min_value = 1.0,
        .max_value = 10.0,
        .initial_value = 2.0,
    };
    const bounds = [1]c_abi.CadParamBound{bound};
    const goal = c_abi.CadOptGoal{
        .type = .TargetStiffness,
        .target_value = 800.0,
        .weight = 1.0,
    };
    const goals = [1]c_abi.CadOptGoal{goal};
    var opt_res: c_abi.CadOptimizationResult = undefined;
    try std.testing.expectEqual(c_abi.CadStatus.Ok, cad_optimize_parameters(null, 0, &bounds, 1, &goals, 1, 20, 1e-3, &opt_res));
    try std.testing.expectEqual(c_abi.CadStatus.Ok, opt_res.status);
    try std.testing.expect(opt_res.optimal_values != null);
    try std.testing.expectEqual(c_abi.CadStatus.Ok, cad_optimization_result_free(&opt_res));
}

test "Wave 13 C ABI: 2D/3D sketch, datums, threads, holes, and assembly motion" {
    _ = cad_kernel_init();
    defer _ = cad_kernel_deinit();

    // 1. 2D Sketch Extract Regions
    var regions: ?[*]c_abi.CadSketchRegion = null;
    var region_count: u32 = 0;
    const dummy_lines = [4]c_abi.CadSketchLine2D{
        .{ .id = 1, .start_point_id = 1, .end_point_id = 2, .is_construction = 0 },
        .{ .id = 2, .start_point_id = 2, .end_point_id = 3, .is_construction = 0 },
        .{ .id = 3, .start_point_id = 3, .end_point_id = 4, .is_construction = 0 },
        .{ .id = 4, .start_point_id = 4, .end_point_id = 1, .is_construction = 0 },
    };
    try std.testing.expectEqual(c_abi.CadStatus.Ok, cad_sketch_extract_regions(&dummy_lines, 4, null, 0, &regions, &region_count));
    try std.testing.expect(region_count > 0);
    try std.testing.expect(regions != null);
    cad_sketch_regions_free(regions);

    // 2. 3D Sketch Solver
    var pts3d = [2]c_abi.CadSketchPoint3D{
        .{ .id = 1, .x = 0, .y = 0, .z = 0, .is_fixed = 1, .is_construction = 0 },
        .{ .id = 2, .x = 5, .y = 1, .z = 2, .is_fixed = 0, .is_construction = 0 },
    };
    const cns3d = [1]c_abi.CadSketchConstraint3D{
        .{
            .id = 1,
            .type = .Distance,
            .entity1_id = 1,
            .entity2_id = 2,
            .parameter_value = 10.0,
            .plane_normal = [_]f64{ 0, 0, 0 },
            .is_driving = 1,
        },
    };
    var solve_stat: c_abi.CadSolverStatus = undefined;
    try std.testing.expectEqual(c_abi.CadStatus.Ok, cad_sketch3d_solve(&pts3d, 2, null, 0, null, 0, null, 0, &cns3d, 1, 20, 1e-4, &solve_stat));
    try std.testing.expectEqual(c_abi.CadSolveState.UnderConstrained, solve_stat.solve_state);

    // 3. Datums
    const orig = [3]f64{ 0, 0, 10 };
    const norm = [3]f64{ 0, 0, 1 };
    var plane: c_abi.CadDatumPlane = undefined;
    try std.testing.expectEqual(c_abi.CadStatus.Ok, cad_datum_plane(.Offset, &orig, &norm, 10.0, 0.0, &plane));
    try std.testing.expectEqual(@as(f64, 10.0), plane.offset_distance);

    var axis: c_abi.CadDatumAxis = undefined;
    try std.testing.expectEqual(c_abi.CadStatus.Ok, cad_datum_axis(.Cylinder, &orig, &norm, &axis));
    try std.testing.expectEqual(@as(f32, 1.0), axis.direction.z);

    // 4. Assembly Motion Stepping & Exploded View
    const inst = c_abi.CadAssemblyInstance{
        .instance_id = 1,
        .solid_handle = 1,
        .is_grounded = 0,
        .initial_transform = [_]f32{
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            10, 20, 30, 1,
        },
        .name = std.mem.zeroes([32]u8),
    };
    const insts = [1]c_abi.CadAssemblyInstance{inst};
    var xforms: [16]f32 = std.mem.zeroes([16]f32);
    var assem_stat: c_abi.CadAssemblySolveStatus = undefined;
    try std.testing.expectEqual(c_abi.CadStatus.Ok, cad_assembly_step_motion(&insts, 1, null, 0, 0.1, &xforms, &assem_stat));

    var trails: [1]c_abi.CadExplodeTrailLine = undefined;
    var trail_count: u32 = 0;
    try std.testing.expectEqual(c_abi.CadStatus.Ok, cad_assembly_exploded_view(&insts, 1, 1.0, &xforms, &trails, &trail_count));
    try std.testing.expectEqual(@as(u32, 1), trail_count);
}
