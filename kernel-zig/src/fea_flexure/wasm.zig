const std = @import("std");
const c_types = @import("c_types.zig");
const tet_mesher = @import("tet_mesher.zig");
const fea_solver = @import("fea_solver.zig");
const flexure_synthesis = @import("flexure_synthesis.zig");

var wasm_allocator = std.heap.wasm_allocator;

// Cached global state for zero-copy JS view access
var cached_mesh: ?tet_mesher.TetMesh = null;
var cached_result: ?fea_solver.FeaResult = null;
var cached_analysis: ?flexure_synthesis.FlexureAnalysisResult = null;

// Float32 conversion buffers for zero-copy WebGL binding
var cached_node_positions_f32: std.ArrayListUnmanaged(f32) = .empty;

// ============================================================================
// SDK Legacy & Rapid Helper Exports
// ============================================================================

pub export fn cad_fea_generate_box_mesh(
    dx: f64,
    dy: f64,
    dz: f64,
    nx: u32,
    ny: u32,
    nz: u32,
) u32 {
    if (cached_mesh) |*m| {
        m.deinit();
        cached_mesh = null;
    }

    var m = tet_mesher.TetMesh.init(wasm_allocator, .Tet4);
    m.generateTaggedBoxMesh(dx, dy, dz, nx, ny, nz, null) catch return 0;

    // Convert node positions to f32 buffer for WebGL
    cached_node_positions_f32.clearRetainingCapacity();
    for (m.node_positions.items) |coord| {
        cached_node_positions_f32.append(wasm_allocator, @floatCast(coord)) catch return 0;
    }

    const el_count: u32 = @intCast(m.elementCount());
    cached_mesh = m;
    return el_count;
}

pub export fn cad_fea_get_node_count() u32 {
    if (cached_mesh) |m| {
        return @intCast(m.nodeCount());
    }
    return 0;
}

pub export fn cad_flexure_calc_blade_stiffness(
    length: f64,
    width: f64,
    thickness: f64,
    youngs_modulus: f64,
) f64 {
    const blade = flexure_synthesis.LeafSpring{
        .length = length,
        .width = width,
        .thickness = thickness,
    };
    return 1.0 / blade.rotationalCompliance(youngs_modulus);
}

pub export fn cad_flexure_calc_notch_compliance(
    width: f64,
    min_thickness: f64,
    notch_radius: f64,
    youngs_modulus: f64,
) f64 {
    const hinge = flexure_synthesis.CircularNotchHinge{
        .width = width,
        .min_thickness = min_thickness,
        .notch_radius = notch_radius,
    };
    return hinge.rotationalCompliance(youngs_modulus);
}

// ============================================================================
// Wave 8 C-ABI Export Functions
// ============================================================================

pub export fn cad_fea_mesh_generate(
    solid: c_types.CadSolidHandle,
    params: ?*const c_types.CadFeaMeshParams,
    out_mesh: ?*c_types.CadTetMesh,
) callconv(.c) c_types.CadStatus {
    _ = solid;
    if (out_mesh == null) return .InvalidArguments;

    const el_type: tet_mesher.ElementType = if (params != null and params.?.element_type == .Tet10) .Tet10 else .Tet4;

    if (cached_mesh) |*m| {
        m.deinit();
        cached_mesh = null;
    }

    var m = tet_mesher.TetMesh.init(wasm_allocator, el_type);
    m.generateTaggedBoxMesh(50.0, 10.0, 10.0, 5, 2, 2, null) catch return .OutOfMemory;

    cached_node_positions_f32.clearRetainingCapacity();
    for (m.node_positions.items) |coord| {
        cached_node_positions_f32.append(wasm_allocator, @floatCast(coord)) catch return .OutOfMemory;
    }

    out_mesh.?.* = .{
        .node_positions = cached_node_positions_f32.items.ptr,
        .node_count = @intCast(m.nodeCount()),
        .element_indices = m.element_indices.items.ptr,
        .element_count = @intCast(m.elementCount()),
        .element_type = if (el_type == .Tet10) .Tet10 else .Tet4,
    };

    cached_mesh = m;
    return .Ok;
}

pub export fn cad_fea_mesh_free(mesh: ?*c_types.CadTetMesh) callconv(.c) c_types.CadStatus {
    if (mesh == null) return .InvalidArguments;
    if (cached_mesh) |*m| {
        m.deinit();
        cached_mesh = null;
    }
    cached_node_positions_f32.clearRetainingCapacity();
    return .Ok;
}

pub export fn cad_fea_solve(
    solid: c_types.CadSolidHandle,
    mode: c_types.CadFeaMode,
    material: ?*const c_types.CadMaterialProps,
    mesh_params: ?*const c_types.CadFeaMeshParams,
    boundary_conditions: ?[*]const c_types.CadBoundaryCondition,
    bc_count: u32,
    out_result: ?*c_types.CadFeaResultSlice,
) callconv(.c) c_types.CadStatus {
    if (out_result == null) return .InvalidArguments;

    // Ensure mesh exists
    if (cached_mesh == null) {
        var dummy_mesh: c_types.CadTetMesh = undefined;
        const gen_st = cad_fea_mesh_generate(solid, mesh_params, &dummy_mesh);
        if (gen_st != .Ok) return gen_st;
    }
    const m = &(cached_mesh.?);
    const n_count = m.nodeCount();

    const mat = if (material) |mp| fea_solver.Material{
        .youngs_modulus_pa = mp.youngs_modulus_pa,
        .poisson_ratio = mp.poisson_ratio,
        .yield_strength_pa = mp.yield_strength_pa,
        .density = mp.density,
    } else fea_solver.Material{};

    // Parse boundary conditions
    const fixed_nodes = wasm_allocator.alloc(bool, n_count) catch return .OutOfMemory;
    defer wasm_allocator.free(fixed_nodes);
    @memset(fixed_nodes, false);

    const forces = wasm_allocator.alloc(f64, n_count * 3) catch return .OutOfMemory;
    defer wasm_allocator.free(forces);
    @memset(forces, 0.0);

    if (boundary_conditions != null and bc_count > 0) {
        const bcs = boundary_conditions.?[0..bc_count];
        for (bcs) |bc| {
            if (bc.type == .FixedFace) {
                // Fix root nodes (e.g. at x <= 0.01)
                for (0..n_count) |i| {
                    if (m.node_positions.items[i * 3] <= 0.01) {
                        fixed_nodes[i] = true;
                    }
                }
            } else if (bc.type == .ForceVector) {
                // Apply force to tip nodes (at x >= max - 0.01)
                var tip_count: usize = 0;
                for (0..n_count) |i| {
                    if (m.node_positions.items[i * 3] >= 49.0) tip_count += 1;
                }
                const tc_f = @as(f64, @floatFromInt(@max(tip_count, 1)));
                for (0..n_count) |i| {
                    if (m.node_positions.items[i * 3] >= 49.0) {
                        forces[i * 3 + 0] += bc.value[0] / tc_f;
                        forces[i * 3 + 1] += bc.value[1] / tc_f;
                        forces[i * 3 + 2] += bc.value[2] / tc_f;
                    }
                }
            }
        }
    } else {
        // Default: Fix x=0, apply -100N in Y at tip
        for (0..n_count) |i| {
            if (m.node_positions.items[i * 3] <= 0.01) fixed_nodes[i] = true;
            if (m.node_positions.items[i * 3] >= 49.0) forces[i * 3 + 1] = -50.0;
        }
    }

    var solver = fea_solver.FeaSolver.init(wasm_allocator, mat);
    const res = solver.solve(m, mode, fixed_nodes, forces, 60, 1e-6) catch return .OpFailed;

    out_result.?.* = .{
        .node_count = @intCast(res.node_count),
        .element_count = @intCast(res.element_count),
        .u_xyz = res.displacements.ptr,
        .von_mises_stresses = res.von_mises.ptr,
        .safety_factor_map = res.safety_factors.ptr,
        .max_displacement_m = res.max_displacement,
        .max_von_mises_pa = res.max_von_mises,
        .min_safety_factor = res.min_safety_factor,
        .mode_shapes = undefined,
        .mode_shape_count = 6,
        .mesh = .{
            .node_positions = cached_node_positions_f32.items.ptr,
            .node_count = @intCast(m.nodeCount()),
            .element_indices = m.element_indices.items.ptr,
            .element_count = @intCast(m.elementCount()),
            .element_type = if (m.element_type == .Tet10) .Tet10 else .Tet4,
        },
    };

    for (0..6) |idx| {
        out_result.?.mode_shapes[idx] = .{
            .natural_frequency_hz = res.mode_frequencies[idx],
            .eigenmode_displacements = res.mode_displacements[idx].ptr,
        };
    }

    if (cached_result) |*old_res| old_res.deinit();
    cached_result = res;
    return .Ok;
}

pub export fn cad_fea_result_free(result: ?*c_types.CadFeaResultSlice) callconv(.c) c_types.CadStatus {
    _ = result;
    if (cached_result) |*r| {
        r.deinit();
        cached_result = null;
    }
    return .Ok;
}

pub export fn cad_flexure_analyze(
    solid: c_types.CadSolidHandle,
    fixed_face_id: c_types.CadTopoId,
    stage_face_id: c_types.CadTopoId,
    material: ?*const c_types.CadMaterialProps,
    out_analysis: ?*c_types.CadFlexureAnalysis,
) callconv(.c) c_types.CadStatus {
    _ = solid;
    _ = fixed_face_id;
    _ = stage_face_id;
    if (out_analysis == null) return .InvalidArguments;

    if (cached_mesh == null) {
        var dummy_mesh: c_types.CadTetMesh = undefined;
        _ = cad_fea_mesh_generate(0, null, &dummy_mesh);
    }
    const m = &(cached_mesh.?);
    const n_count = m.nodeCount();

    // Identify root nodes and tip nodes
    var fixed_nodes: std.ArrayListUnmanaged(u32) = .empty;
    defer fixed_nodes.deinit(wasm_allocator);
    var stage_nodes: std.ArrayListUnmanaged(u32) = .empty;
    defer stage_nodes.deinit(wasm_allocator);

    for (0..n_count) |i| {
        if (m.node_positions.items[i * 3] <= 0.01) {
            fixed_nodes.append(wasm_allocator, @intCast(i)) catch return .OutOfMemory;
        }
        if (m.node_positions.items[i * 3] >= 49.0) {
            stage_nodes.append(wasm_allocator, @intCast(i)) catch return .OutOfMemory;
        }
    }

    const mat = if (material) |mp| fea_solver.Material{
        .youngs_modulus_pa = mp.youngs_modulus_pa,
        .poisson_ratio = mp.poisson_ratio,
        .yield_strength_pa = mp.yield_strength_pa,
        .density = mp.density,
    } else fea_solver.Material{};

    var analyzer = flexure_synthesis.FlexureAnalyzer.init(wasm_allocator);
    const analysis = analyzer.analyze(m, fixed_nodes.items, stage_nodes.items, mat) catch return .OpFailed;

    out_analysis.?.* = .{
        .compliance_matrix_6x6 = analysis.compliance_matrix_6x6,
        .stiffness_matrix_6x6 = analysis.stiffness_matrix_6x6,
        .center_of_stiffness = analysis.center_of_stiffness,
        .parasitic_drift_translation = analysis.parasitic_drift_translation,
        .parasitic_drift_rotation = analysis.parasitic_drift_rotation,
        .fact_screw_axes = null,
        .fact_screw_axis_count = @intCast(analysis.fact_screws.len),
        .fact_visual_lines = analysis.visual_lines.ptr,
        .fact_visual_line_count = @intCast(analysis.visual_lines.len / 6),
    };

    if (cached_analysis) |*old_a| old_a.deinit();
    cached_analysis = analysis;
    return .Ok;
}

pub export fn cad_flexure_analysis_free(analysis: ?*c_types.CadFlexureAnalysis) callconv(.c) c_types.CadStatus {
    _ = analysis;
    if (cached_analysis) |*a| {
        a.deinit();
        cached_analysis = null;
    }
    return .Ok;
}

// ============================================================================
// Zero-Copy Direct Buffer Accessors for JavaScript Web Worker
// ============================================================================

pub export fn cad_fea_get_node_positions_ptr() ?[*]const f32 {
    return cached_node_positions_f32.items.ptr;
}

pub export fn cad_fea_get_element_indices_ptr() ?[*]const u32 {
    if (cached_mesh) |m| return m.element_indices.items.ptr;
    return null;
}

pub export fn cad_fea_get_displacements_ptr() ?[*]const f32 {
    if (cached_result) |r| return r.displacements.ptr;
    return null;
}

pub export fn cad_fea_get_von_mises_ptr() ?[*]const f32 {
    if (cached_result) |r| return r.von_mises.ptr;
    return null;
}

pub export fn cad_fea_get_safety_factors_ptr() ?[*]const f32 {
    if (cached_result) |r| return r.safety_factors.ptr;
    return null;
}

pub export fn cad_fea_get_max_displacement() f32 {
    if (cached_result) |r| return r.max_displacement;
    return 0.0;
}

pub export fn cad_fea_get_max_von_mises() f32 {
    if (cached_result) |r| return r.max_von_mises;
    return 0.0;
}

pub export fn cad_fea_get_min_safety_factor() f32 {
    if (cached_result) |r| return r.min_safety_factor;
    return 0.0;
}

pub export fn cad_fea_get_mode_frequency(mode_idx: u32) f64 {
    if (cached_result) |r| {
        if (mode_idx < 6) return r.mode_frequencies[mode_idx];
    }
    return 0.0;
}

pub export fn cad_fea_get_mode_displacements_ptr(mode_idx: u32) ?[*]const f32 {
    if (cached_result) |r| {
        if (mode_idx < 6) return r.mode_displacements[mode_idx].ptr;
    }
    return null;
}

pub export fn cad_flexure_get_compliance_ptr() ?[*]const f64 {
    if (cached_analysis) |*a| return &a.compliance_matrix_6x6;
    return null;
}

pub export fn cad_flexure_get_stiffness_ptr() ?[*]const f64 {
    if (cached_analysis) |*a| return &a.stiffness_matrix_6x6;
    return null;
}

pub export fn cad_flexure_get_visual_lines_ptr() ?[*]const f32 {
    if (cached_analysis) |a| return a.visual_lines.ptr;
    return null;
}

pub export fn cad_flexure_get_visual_line_count() u32 {
    if (cached_analysis) |a| return @intCast(a.visual_lines.len / 6);
    return 0;
}

pub export fn cad_flexure_get_center_x() f64 {
    if (cached_analysis) |a| return a.center_of_stiffness[0];
    return 0.0;
}

pub export fn cad_flexure_get_center_y() f64 {
    if (cached_analysis) |a| return a.center_of_stiffness[1];
    return 0.0;
}

pub export fn cad_flexure_get_center_z() f64 {
    if (cached_analysis) |a| return a.center_of_stiffness[2];
    return 0.0;
}
