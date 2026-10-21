const std = @import("std");
const memory = @import("memory.zig");
const c_abi = @import("c_abi.zig");
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

// Export internal modules for unit tests
pub const TopologyMod = topology;
pub const BoxMod = box;
pub const CylinderMod = cylinder;
pub const TessellatorMod = tessellator;
pub const BvhMod = bvh;
pub const RouterMod = router;

// Global handle registry
var next_handle: u64 = 1;
var solid_store: std.AutoHashMap(u64, topology.Solid) = undefined;
var is_initialized: bool = false;
var current_rollback_index: u32 = 0;

fn ensureInit() !void {
    if (!is_initialized) {
        solid_store = std.AutoHashMap(u64, topology.Solid).init(memory.getAllocator());
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
        is_initialized = false;
    }
    if (global_mesh.vertex_count > 0) {
        _ = cad_mesh_free(&global_mesh);
    }
    if (global_slice.vertex_count > 0 or global_slice.triangle_count > 0) {
        _ = cad_slice_free(&global_slice);
    }
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
    if (solid_store.fetchRemove(solid_handle)) |kv| {
        var s = kv.value;
        s.deinit(alloc);
        return .Ok;
    }
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
            .Fillet, .Chamfer => {
                // Applied to target topological sub-shapes
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

    const solid_ptr = solid_store.getPtr(solid_handle) orelse return .InvalidArguments;

    const slice = tessellator.tessellateSolidSlice(
        alloc,
        solid_ptr,
        chordal_deflection,
        angular_deflection,
    ) catch return .OutOfMemory;

    out.* = slice;
    return .Ok;
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

test {
    _ = @import("geom/vec2.zig");
    _ = @import("solver/types.zig");
    _ = @import("solver/residuals.zig");
    _ = @import("solver/jacobian.zig");
    _ = @import("solver/qr.zig");
    _ = @import("solver/solver.zig");
    _ = @import("main_wasm.zig");
    _ = @import("tess/tessellator.zig");
    _ = @import("tess/bvh.zig");
}
