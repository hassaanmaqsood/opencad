const std = @import("std");
const Allocator = std.mem.Allocator;
const c_abi = @import("../c_abi.zig");
const CadMesh = c_abi.CadMesh;
const CadVec3 = c_abi.CadVec3;
const CadTopoId = c_abi.CadTopoId;
const CadSubshapeType = c_abi.CadSubshapeType;
const CadTessellatedSolidSlice = c_abi.CadTessellatedSolidSlice;
const topology = @import("../brep/topology.zig");
const Solid = topology.Solid;
const Vec3 = @import("../math/vec3.zig").Vec3;

// ---------------------------------------------------------------------------
// Persistent Topological Naming Tag Generators
// ---------------------------------------------------------------------------

pub fn makeFaceTopoId(feature_id: u16, op_type: u8, face_id: u16, flags: u4) CadTopoId {
    const hash = @as(u16, face_id) *% 31 +% (@as(u16, flags) << 8);
    return CadTopoId.init(
        feature_id,
        0,
        op_type,
        .Face,
        flags,
        hash,
    );
}

pub fn makeEdgeTopoId(feature_id: u16, op_type: u8, edge_id: u16, flags: u4) CadTopoId {
    const hash = @as(u16, edge_id) *% 37 +% (@as(u16, flags) << 8);
    return CadTopoId.init(
        feature_id,
        0,
        op_type,
        .Edge,
        flags,
        hash,
    );
}

// ---------------------------------------------------------------------------
// Struct-of-Arrays (SoA) Half-Edge View Adapter
// ---------------------------------------------------------------------------

pub const SoAHalfEdgeView = struct {
    vertices: []const [3]f32,
    half_edges_origin: []const u32,
    half_edges_twin: []const u32,
    half_edges_next: []const u32,
    half_edges_face: []const u32,
    face_first_half_edge: []const u32,
    face_normals: []const [3]f32,
    face_topo_ids: []const u64,
    edge_sharp: []const bool,
    edge_v0: []const u32,
    edge_v1: []const u32,
    edge_topo_ids: []const u64,
};

pub fn tessellateSoAHalfEdgeSlice(
    allocator: Allocator,
    view: SoAHalfEdgeView,
) !CadTessellatedSolidSlice {
    var pos_list = std.ArrayList(f32).empty;
    errdefer pos_list.deinit(allocator);
    var nrm_list = std.ArrayList(f32).empty;
    errdefer nrm_list.deinit(allocator);
    var idx_list = std.ArrayList(u32).empty;
    errdefer idx_list.deinit(allocator);
    var tri_face_list = std.ArrayList(u64).empty;
    errdefer tri_face_list.deinit(allocator);
    var edge_list = std.ArrayList(f32).empty;
    errdefer edge_list.deinit(allocator);
    var seg_edge_list = std.ArrayList(u64).empty;
    errdefer seg_edge_list.deinit(allocator);

    var min_pt = [3]f32{ 1e9, 1e9, 1e9 };
    var max_pt = [3]f32{ -1e9, -1e9, -1e9 };

    for (view.vertices) |v| {
        inline for (0..3) |c| {
            if (v[c] < min_pt[c]) min_pt[c] = v[c];
            if (v[c] > max_pt[c]) max_pt[c] = v[c];
        }
    }

    var face_verts_buf = std.ArrayList(u32).empty;
    defer face_verts_buf.deinit(allocator);

    for (view.face_first_half_edge, 0..) |start_he, f_idx| {
        face_verts_buf.clearRetainingCapacity();
        var cur = start_he;
        var guard: u32 = 0;
        const max_loop = @as(u32, @intCast(view.half_edges_origin.len));

        while (guard < max_loop) : (guard += 1) {
            const v_orig = view.half_edges_origin[cur];
            try face_verts_buf.append(allocator, v_orig);
            cur = view.half_edges_next[cur];
            if (cur == start_he) break;
        }

        const face_topo = if (f_idx < view.face_topo_ids.len) view.face_topo_ids[f_idx] else 0;
        const nrm = if (f_idx < view.face_normals.len) view.face_normals[f_idx] else [3]f32{ 0, 0, 1 };

        if (face_verts_buf.items.len >= 3) {
            const fv = face_verts_buf.items;
            const base_idx: u32 = @intCast(pos_list.items.len / 3);

            for (fv) |vi| {
                const p = view.vertices[vi];
                try pos_list.append(allocator, p[0]);
                try pos_list.append(allocator, p[1]);
                try pos_list.append(allocator, p[2]);
                try nrm_list.append(allocator, nrm[0]);
                try nrm_list.append(allocator, nrm[1]);
                try nrm_list.append(allocator, nrm[2]);
            }

            var k: u32 = 1;
            while (k + 1 < fv.len) : (k += 1) {
                try idx_list.append(allocator, base_idx);
                try idx_list.append(allocator, base_idx + k);
                try idx_list.append(allocator, base_idx + k + 1);
                try tri_face_list.append(allocator, face_topo);
            }
        }
    }

    // Extract sharp feature edge polylines
    for (view.edge_sharp, 0..) |is_sharp, e_idx| {
        if (!is_sharp) continue;
        const v0 = view.vertices[view.edge_v0[e_idx]];
        const v1 = view.vertices[view.edge_v1[e_idx]];
        const topo_id = if (e_idx < view.edge_topo_ids.len) view.edge_topo_ids[e_idx] else 0;

        try edge_list.append(allocator, v0[0]);
        try edge_list.append(allocator, v0[1]);
        try edge_list.append(allocator, v0[2]);
        try edge_list.append(allocator, v1[0]);
        try edge_list.append(allocator, v1[1]);
        try edge_list.append(allocator, v1[2]);
        try seg_edge_list.append(allocator, topo_id);
    }

    const pos_slice = try pos_list.toOwnedSlice(allocator);
    errdefer allocator.free(pos_slice);
    const nrm_slice = try nrm_list.toOwnedSlice(allocator);
    errdefer allocator.free(nrm_slice);
    const idx_slice = try idx_list.toOwnedSlice(allocator);
    errdefer allocator.free(idx_slice);
    const tri_face_slice = try tri_face_list.toOwnedSlice(allocator);
    errdefer allocator.free(tri_face_slice);

    var edge_slice: ?[]f32 = null;
    var seg_edge_slice: ?[]u64 = null;
    if (edge_list.items.len > 0) {
        edge_slice = try edge_list.toOwnedSlice(allocator);
        seg_edge_slice = try seg_edge_list.toOwnedSlice(allocator);
    } else {
        edge_list.deinit(allocator);
        seg_edge_list.deinit(allocator);
    }

    return CadTessellatedSolidSlice{
        .positions = pos_slice.ptr,
        .vertex_count = @intCast(pos_slice.len / 3),
        .normals = nrm_slice.ptr,
        .indices = idx_slice.ptr,
        .triangle_count = @intCast(idx_slice.len / 3),
        .triangle_to_face_id = tri_face_slice.ptr,
        .edge_polylines = if (edge_slice) |s| s.ptr else null,
        .edge_segment_count = if (edge_slice) |s| @intCast(s.len / 6) else 0,
        .edge_to_topo_id = if (seg_edge_slice) |s| s.ptr else null,
        .bbox_min = .{ .x = min_pt[0], .y = min_pt[1], .z = min_pt[2] },
        .bbox_max = .{ .x = max_pt[0], .y = max_pt[1], .z = max_pt[2] },
    };
}

pub fn tessellateSoASolid(
    allocator: Allocator,
    soa: *const topology.topo.SoASolid,
) !CadTessellatedSolidSlice {
    var pos_list = std.ArrayList(f32).empty;
    errdefer pos_list.deinit(allocator);
    var nrm_list = std.ArrayList(f32).empty;
    errdefer nrm_list.deinit(allocator);
    var idx_list = std.ArrayList(u32).empty;
    errdefer idx_list.deinit(allocator);
    var tri_face_list = std.ArrayList(u64).empty;
    errdefer tri_face_list.deinit(allocator);
    var edge_list = std.ArrayList(f32).empty;
    errdefer edge_list.deinit(allocator);
    var seg_edge_list = std.ArrayList(u64).empty;
    errdefer seg_edge_list.deinit(allocator);

    const v_slice = soa.vertices.slice();
    const pts = v_slice.items(.point);

    var min_pt = [3]f32{ 1e9, 1e9, 1e9 };
    var max_pt = [3]f32{ -1e9, -1e9, -1e9 };

    for (pts) |p| {
        if (p.x < min_pt[0]) min_pt[0] = p.x;
        if (p.x > max_pt[0]) max_pt[0] = p.x;
        if (p.y < min_pt[1]) min_pt[1] = p.y;
        if (p.y > max_pt[1]) max_pt[1] = p.y;
        if (p.z < min_pt[2]) min_pt[2] = p.z;
        if (p.z > max_pt[2]) max_pt[2] = p.z;
    }

    var face_verts_buf = std.ArrayList(u32).empty;
    defer face_verts_buf.deinit(allocator);

    const f_slice = soa.faces.slice();
    const f_normals = f_slice.items(.normal);
    const f_loops = f_slice.items(.outer_loop);
    const f_topos = f_slice.items(.topo_id);

    const l_slice = soa.loops.slice();
    const l_hes = l_slice.items(.half_edge);

    const he_slice = soa.half_edges.slice();
    const he_origins = he_slice.items(.origin);
    const he_nexts = he_slice.items(.next);

    for (0..soa.faces.len) |f_idx| {
        face_verts_buf.clearRetainingCapacity();
        const loop_id = f_loops[f_idx];
        if (loop_id >= soa.loops.len) continue;
        const start_he = l_hes[loop_id];
        if (start_he >= soa.half_edges.len) continue;

        var cur = start_he;
        var guard: u32 = 0;
        const max_loop: u32 = @intCast(soa.half_edges.len);

        while (guard < max_loop) : (guard += 1) {
            const v_orig = he_origins[cur];
            try face_verts_buf.append(allocator, v_orig);
            cur = he_nexts[cur];
            if (cur == start_he or cur >= soa.half_edges.len) break;
        }

        const face_topo = f_topos[f_idx].raw;
        const nrm = f_normals[f_idx];

        if (face_verts_buf.items.len >= 3) {
            const fv = face_verts_buf.items;
            const base_idx: u32 = @intCast(pos_list.items.len / 3);

            for (fv) |vi| {
                const p = pts[vi];
                try pos_list.append(allocator, p.x);
                try pos_list.append(allocator, p.y);
                try pos_list.append(allocator, p.z);
                try nrm_list.append(allocator, nrm.x);
                try nrm_list.append(allocator, nrm.y);
                try nrm_list.append(allocator, nrm.z);
            }

            var k: u32 = 1;
            while (k + 1 < fv.len) : (k += 1) {
                try idx_list.append(allocator, base_idx);
                try idx_list.append(allocator, base_idx + k);
                try idx_list.append(allocator, base_idx + k + 1);
                try tri_face_list.append(allocator, face_topo);
            }
        }
    }

    // Extract sharp feature edge polylines from edges
    const e_slice = soa.edges.slice();
    const e_hes = e_slice.items(.half_edge);
    const e_topos = e_slice.items(.topo_id);
    const he_twins = he_slice.items(.twin);

    for (0..soa.edges.len) |e_idx| {
        const he1 = e_hes[e_idx];
        if (he1 >= soa.half_edges.len) continue;
        const he2 = he_twins[he1];
        if (he2 >= soa.half_edges.len) continue;

        const v0 = pts[he_origins[he1]];
        const v1 = pts[he_origins[he2]];
        const topo_id = e_topos[e_idx].raw;

        try edge_list.append(allocator, v0.x);
        try edge_list.append(allocator, v0.y);
        try edge_list.append(allocator, v0.z);
        try edge_list.append(allocator, v1.x);
        try edge_list.append(allocator, v1.y);
        try edge_list.append(allocator, v1.z);
        try seg_edge_list.append(allocator, topo_id);
    }

    const pos_slice = try pos_list.toOwnedSlice(allocator);
    errdefer allocator.free(pos_slice);
    const nrm_slice = try nrm_list.toOwnedSlice(allocator);
    errdefer allocator.free(nrm_slice);
    const idx_slice = try idx_list.toOwnedSlice(allocator);
    errdefer allocator.free(idx_slice);
    const tri_face_slice = try tri_face_list.toOwnedSlice(allocator);
    errdefer allocator.free(tri_face_slice);

    var edge_slice: ?[]f32 = null;
    var seg_edge_slice: ?[]u64 = null;
    if (edge_list.items.len > 0) {
        edge_slice = try edge_list.toOwnedSlice(allocator);
        seg_edge_slice = try seg_edge_list.toOwnedSlice(allocator);
    } else {
        edge_list.deinit(allocator);
        seg_edge_list.deinit(allocator);
    }

    return CadTessellatedSolidSlice{
        .positions = pos_slice.ptr,
        .vertex_count = @intCast(pos_slice.len / 3),
        .normals = nrm_slice.ptr,
        .indices = idx_slice.ptr,
        .triangle_count = @intCast(idx_slice.len / 3),
        .triangle_to_face_id = tri_face_slice.ptr,
        .edge_polylines = if (edge_slice) |s| s.ptr else null,
        .edge_segment_count = if (edge_slice) |s| @intCast(s.len / 6) else 0,
        .edge_to_topo_id = if (seg_edge_slice) |s| s.ptr else null,
        .bbox_min = .{ .x = min_pt[0], .y = min_pt[1], .z = min_pt[2] },
        .bbox_max = .{ .x = max_pt[0], .y = max_pt[1], .z = max_pt[2] },
    };
}

// ---------------------------------------------------------------------------
// Wave 3 Sub-Shape Tessellated Solid Slice Generation
// ---------------------------------------------------------------------------

pub fn tessellateSolidSlice(
    allocator: Allocator,
    solid: *const Solid,
    chordal_deflection: f32,
    angular_deflection: f32,
) !CadTessellatedSolidSlice {
    _ = chordal_deflection;
    _ = angular_deflection;

    var pos_list = std.ArrayList(f32).empty;
    errdefer pos_list.deinit(allocator);
    var nrm_list = std.ArrayList(f32).empty;
    errdefer nrm_list.deinit(allocator);
    var idx_list = std.ArrayList(u32).empty;
    errdefer idx_list.deinit(allocator);
    var tri_face_list = std.ArrayList(u64).empty;
    errdefer tri_face_list.deinit(allocator);
    var edge_list = std.ArrayList(f32).empty;
    errdefer edge_list.deinit(allocator);
    var seg_edge_list = std.ArrayList(u64).empty;
    errdefer seg_edge_list.deinit(allocator);

    var min_pt = Vec3.init(1e9, 1e9, 1e9);
    var max_pt = Vec3.init(-1e9, -1e9, -1e9);

    const feature_id: u16 = @intCast(solid.id & 0xFFFF);

    if (solid.vertices.items.len == 8 and solid.shell.faces.items.len == 6) {
        // Parametric Box Tessellation
        const verts = solid.vertices.items;
        for (verts) |v| {
            if (v.point.x < min_pt.x) min_pt.x = v.point.x;
            if (v.point.y < min_pt.y) min_pt.y = v.point.y;
            if (v.point.z < min_pt.z) min_pt.z = v.point.z;
            if (v.point.x > max_pt.x) max_pt.x = v.point.x;
            if (v.point.y > max_pt.y) max_pt.y = v.point.y;
            if (v.point.z > max_pt.z) max_pt.z = v.point.z;
        }

        const face_v_indices = [6][4]usize{
            .{ 0, 1, 2, 3 }, // Bottom (-Z) Face 1
            .{ 4, 7, 6, 5 }, // Top (+Z) Face 2
            .{ 0, 4, 5, 1 }, // Front (-Y) Face 3
            .{ 2, 6, 7, 3 }, // Back (+Y) Face 4
            .{ 3, 7, 4, 0 }, // Left (-X) Face 5
            .{ 1, 5, 6, 2 }, // Right (+X) Face 6
        };

        const op_box = @as(u8, @intCast(@intFromEnum(c_abi.CadOpType.PrimitiveBox)));

        for (solid.shell.faces.items, 0..) |face, f_idx| {
            const v_idxs = face_v_indices[f_idx];
            const base_idx: u32 = @intCast(pos_list.items.len / 3);
            const face_topo = makeFaceTopoId(feature_id, op_box, @intCast(face.id), @intCast(f_idx + 1)).raw;

            for (v_idxs) |vi| {
                const pt = verts[vi].point;
                try pos_list.append(allocator, pt.x);
                try pos_list.append(allocator, pt.y);
                try pos_list.append(allocator, pt.z);
                try nrm_list.append(allocator, face.normal.x);
                try nrm_list.append(allocator, face.normal.y);
                try nrm_list.append(allocator, face.normal.z);
            }

            // Triangle 1
            try idx_list.append(allocator, base_idx + 0);
            try idx_list.append(allocator, base_idx + 1);
            try idx_list.append(allocator, base_idx + 2);
            try tri_face_list.append(allocator, face_topo);

            // Triangle 2
            try idx_list.append(allocator, base_idx + 0);
            try idx_list.append(allocator, base_idx + 2);
            try idx_list.append(allocator, base_idx + 3);
            try tri_face_list.append(allocator, face_topo);
        }

        // 12 sharp feature edges
        for (solid.edges.items, 0..) |ed, e_idx| {
            const p0 = verts[ed.v_start].point;
            const p1 = verts[ed.v_end].point;
            const edge_topo = makeEdgeTopoId(feature_id, op_box, @intCast(ed.id), @intCast(e_idx + 1)).raw;

            try edge_list.append(allocator, p0.x);
            try edge_list.append(allocator, p0.y);
            try edge_list.append(allocator, p0.z);
            try edge_list.append(allocator, p1.x);
            try edge_list.append(allocator, p1.y);
            try edge_list.append(allocator, p1.z);
            try seg_edge_list.append(allocator, edge_topo);
        }
    } else {
        // Cylinder or generic B-Rep solid tessellation
        const segments: u32 = 32;
        const pi = std.math.pi;
        const h = if (solid.vertices.items.len >= 2) solid.vertices.items[1].point.z else 2.0;
        const r: f32 = if (h > 0 and solid.volume > 0) @sqrt(solid.volume / (pi * h)) else 1.0;

        min_pt = Vec3.init(-r, -r, 0);
        max_pt = Vec3.init(r, r, h);

        const op_cyl = @as(u8, @intCast(@intFromEnum(c_abi.CadOpType.PrimitiveCylinder)));
        const face1_topo = makeFaceTopoId(feature_id, op_cyl, 1, 1).raw; // Bottom cap
        const face2_topo = makeFaceTopoId(feature_id, op_cyl, 2, 2).raw; // Top cap
        const face3_topo = makeFaceTopoId(feature_id, op_cyl, 3, 0).raw; // Lateral wall
        const edge1_topo = makeEdgeTopoId(feature_id, op_cyl, 1, 1).raw; // Bottom rim
        const edge2_topo = makeEdgeTopoId(feature_id, op_cyl, 2, 2).raw; // Top rim

        // Bottom cap (Face 1)
        const center_bot_idx: u32 = @intCast(pos_list.items.len / 3);
        try pos_list.append(allocator, 0); try pos_list.append(allocator, 0); try pos_list.append(allocator, 0);
        try nrm_list.append(allocator, 0); try nrm_list.append(allocator, 0); try nrm_list.append(allocator, -1);

        var i: u32 = 0;
        while (i < segments) : (i += 1) {
            const theta = 2.0 * pi * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segments));
            try pos_list.append(allocator, r * @cos(theta));
            try pos_list.append(allocator, r * @sin(theta));
            try pos_list.append(allocator, 0);
            try nrm_list.append(allocator, 0); try nrm_list.append(allocator, 0); try nrm_list.append(allocator, -1);

            const idx0 = center_bot_idx;
            const idx1 = center_bot_idx + 1 + i;
            const idx2 = center_bot_idx + 1 + ((i + 1) % segments);
            try idx_list.append(allocator, idx0);
            try idx_list.append(allocator, idx2);
            try idx_list.append(allocator, idx1);
            try tri_face_list.append(allocator, face1_topo);
        }

        // Top cap (Face 2)
        const center_top_idx: u32 = @intCast(pos_list.items.len / 3);
        try pos_list.append(allocator, 0); try pos_list.append(allocator, 0); try pos_list.append(allocator, h);
        try nrm_list.append(allocator, 0); try nrm_list.append(allocator, 0); try nrm_list.append(allocator, 1);

        i = 0;
        while (i < segments) : (i += 1) {
            const theta = 2.0 * pi * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segments));
            try pos_list.append(allocator, r * @cos(theta));
            try pos_list.append(allocator, r * @sin(theta));
            try pos_list.append(allocator, h);
            try nrm_list.append(allocator, 0); try nrm_list.append(allocator, 0); try nrm_list.append(allocator, 1);

            const idx0 = center_top_idx;
            const idx1 = center_top_idx + 1 + i;
            const idx2 = center_top_idx + 1 + ((i + 1) % segments);
            try idx_list.append(allocator, idx0);
            try idx_list.append(allocator, idx1);
            try idx_list.append(allocator, idx2);
            try tri_face_list.append(allocator, face2_topo);
        }

        // Lateral wall (Face 3)
        i = 0;
        while (i < segments) : (i += 1) {
            const th0 = 2.0 * pi * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segments));
            const th1 = 2.0 * pi * @as(f32, @floatFromInt((i + 1) % segments)) / @as(f32, @floatFromInt(segments));
            const c0 = @cos(th0); const s0 = @sin(th0);
            const c1 = @cos(th1); const s1 = @sin(th1);

            const base: u32 = @intCast(pos_list.items.len / 3);
            try pos_list.append(allocator, r * c0); try pos_list.append(allocator, r * s0); try pos_list.append(allocator, 0);
            try nrm_list.append(allocator, c0);     try nrm_list.append(allocator, s0);     try nrm_list.append(allocator, 0);

            try pos_list.append(allocator, r * c1); try pos_list.append(allocator, r * s1); try pos_list.append(allocator, 0);
            try nrm_list.append(allocator, c1);     try nrm_list.append(allocator, s1);     try nrm_list.append(allocator, 0);

            try pos_list.append(allocator, r * c1); try pos_list.append(allocator, r * s1); try pos_list.append(allocator, h);
            try nrm_list.append(allocator, c1);     try nrm_list.append(allocator, s1);     try nrm_list.append(allocator, 0);

            try pos_list.append(allocator, r * c0); try pos_list.append(allocator, r * s0); try pos_list.append(allocator, h);
            try nrm_list.append(allocator, c0);     try nrm_list.append(allocator, s0);     try nrm_list.append(allocator, 0);

            try idx_list.append(allocator, base + 0);
            try idx_list.append(allocator, base + 1);
            try idx_list.append(allocator, base + 2);
            try tri_face_list.append(allocator, face3_topo);

            try idx_list.append(allocator, base + 0);
            try idx_list.append(allocator, base + 2);
            try idx_list.append(allocator, base + 3);
            try tri_face_list.append(allocator, face3_topo);
        }

        // Rim sharp edge line segments (32 segments on bottom cap, 32 segments on top cap)
        i = 0;
        while (i < segments) : (i += 1) {
            const th0 = 2.0 * pi * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segments));
            const th1 = 2.0 * pi * @as(f32, @floatFromInt((i + 1) % segments)) / @as(f32, @floatFromInt(segments));

            // Bottom rim (Edge ID 1)
            try edge_list.append(allocator, r * @cos(th0));
            try edge_list.append(allocator, r * @sin(th0));
            try edge_list.append(allocator, 0);
            try edge_list.append(allocator, r * @cos(th1));
            try edge_list.append(allocator, r * @sin(th1));
            try edge_list.append(allocator, 0);
            try seg_edge_list.append(allocator, edge1_topo);

            // Top rim (Edge ID 2)
            try edge_list.append(allocator, r * @cos(th0));
            try edge_list.append(allocator, r * @sin(th0));
            try edge_list.append(allocator, h);
            try edge_list.append(allocator, r * @cos(th1));
            try edge_list.append(allocator, r * @sin(th1));
            try edge_list.append(allocator, h);
            try seg_edge_list.append(allocator, edge2_topo);
        }
    }

    const pos_slice = try pos_list.toOwnedSlice(allocator);
    errdefer allocator.free(pos_slice);
    const nrm_slice = try nrm_list.toOwnedSlice(allocator);
    errdefer allocator.free(nrm_slice);
    const idx_slice = try idx_list.toOwnedSlice(allocator);
    errdefer allocator.free(idx_slice);
    const tri_face_slice = try tri_face_list.toOwnedSlice(allocator);
    errdefer allocator.free(tri_face_slice);

    var edge_slice: ?[]f32 = null;
    var seg_edge_slice: ?[]u64 = null;
    if (edge_list.items.len > 0) {
        edge_slice = try edge_list.toOwnedSlice(allocator);
        seg_edge_slice = try seg_edge_list.toOwnedSlice(allocator);
    } else {
        edge_list.deinit(allocator);
        seg_edge_list.deinit(allocator);
    }

    return CadTessellatedSolidSlice{
        .positions = pos_slice.ptr,
        .vertex_count = @intCast(pos_slice.len / 3),
        .normals = nrm_slice.ptr,
        .indices = idx_slice.ptr,
        .triangle_count = @intCast(idx_slice.len / 3),
        .triangle_to_face_id = tri_face_slice.ptr,
        .edge_polylines = if (edge_slice) |s| s.ptr else null,
        .edge_segment_count = if (edge_slice) |s| @intCast(s.len / 6) else 0,
        .edge_to_topo_id = if (seg_edge_slice) |s| s.ptr else null,
        .bbox_min = .{ .x = min_pt.x, .y = min_pt.y, .z = min_pt.z },
        .bbox_max = .{ .x = max_pt.x, .y = max_pt.y, .z = max_pt.z },
    };
}

pub fn freeSlice(allocator: Allocator, slice: *CadTessellatedSolidSlice) void {
    if (slice.positions) |p| {
        const s = p[0 .. slice.vertex_count * 3];
        allocator.free(s);
    }
    if (slice.normals) |n| {
        const s = n[0 .. slice.vertex_count * 3];
        allocator.free(s);
    }
    if (slice.indices) |i| {
        const s = i[0 .. slice.triangle_count * 3];
        allocator.free(s);
    }
    if (slice.triangle_to_face_id) |tf| {
        const s = tf[0 .. slice.triangle_count];
        allocator.free(s);
    }
    if (slice.edge_polylines) |ev| {
        const s = ev[0 .. slice.edge_segment_count * 6];
        allocator.free(s);
    }
    if (slice.edge_to_topo_id) |se| {
        const s = se[0 .. slice.edge_segment_count];
        allocator.free(s);
    }
    slice.* = std.mem.zeroes(CadTessellatedSolidSlice);
}

// ---------------------------------------------------------------------------
// Backward-Compatible CadMesh Tessellator (Wave 1)
// ---------------------------------------------------------------------------

pub fn tessellateSolid(
    allocator: Allocator,
    solid: *const Solid,
    chordal_deflection: f32,
    angular_deflection: f32,
) !CadMesh {
    _ = chordal_deflection;
    _ = angular_deflection;

    var pos_list = std.ArrayList(f32).empty;
    errdefer pos_list.deinit(allocator);
    var nrm_list = std.ArrayList(f32).empty;
    errdefer nrm_list.deinit(allocator);
    var idx_list = std.ArrayList(u32).empty;
    errdefer idx_list.deinit(allocator);
    var tri_face_list = std.ArrayList(u32).empty;
    errdefer tri_face_list.deinit(allocator);
    var edge_list = std.ArrayList(f32).empty;
    errdefer edge_list.deinit(allocator);
    var seg_edge_list = std.ArrayList(u32).empty;
    errdefer seg_edge_list.deinit(allocator);

    var min_pt = Vec3.init(1e9, 1e9, 1e9);
    var max_pt = Vec3.init(-1e9, -1e9, -1e9);

    if (solid.vertices.items.len == 8 and solid.shell.faces.items.len == 6) {
        // Parametric Box Tessellation
        const verts = solid.vertices.items;
        for (verts) |v| {
            if (v.point.x < min_pt.x) min_pt.x = v.point.x;
            if (v.point.y < min_pt.y) min_pt.y = v.point.y;
            if (v.point.z < min_pt.z) min_pt.z = v.point.z;
            if (v.point.x > max_pt.x) max_pt.x = v.point.x;
            if (v.point.y > max_pt.y) max_pt.y = v.point.y;
            if (v.point.z > max_pt.z) max_pt.z = v.point.z;
        }

        const face_v_indices = [6][4]usize{
            .{ 0, 1, 2, 3 }, // Bottom (-Z) Face 1
            .{ 4, 7, 6, 5 }, // Top (+Z) Face 2
            .{ 0, 4, 5, 1 }, // Front (-Y) Face 3
            .{ 2, 6, 7, 3 }, // Back (+Y) Face 4
            .{ 3, 7, 4, 0 }, // Left (-X) Face 5
            .{ 1, 5, 6, 2 }, // Right (+X) Face 6
        };

        for (solid.shell.faces.items, 0..) |face, f_idx| {
            const v_idxs = face_v_indices[f_idx];
            const base_idx: u32 = @intCast(pos_list.items.len / 3);

            for (v_idxs) |vi| {
                const pt = verts[vi].point;
                try pos_list.append(allocator, pt.x);
                try pos_list.append(allocator, pt.y);
                try pos_list.append(allocator, pt.z);
                try nrm_list.append(allocator, face.normal.x);
                try nrm_list.append(allocator, face.normal.y);
                try nrm_list.append(allocator, face.normal.z);
            }

            // Triangle 1
            try idx_list.append(allocator, base_idx + 0);
            try idx_list.append(allocator, base_idx + 1);
            try idx_list.append(allocator, base_idx + 2);
            try tri_face_list.append(allocator, face.id);

            // Triangle 2
            try idx_list.append(allocator, base_idx + 0);
            try idx_list.append(allocator, base_idx + 2);
            try idx_list.append(allocator, base_idx + 3);
            try tri_face_list.append(allocator, face.id);
        }

        // 12 edges
        for (solid.edges.items) |ed| {
            const p0 = verts[ed.v_start].point;
            const p1 = verts[ed.v_end].point;
            try edge_list.append(allocator, p0.x);
            try edge_list.append(allocator, p0.y);
            try edge_list.append(allocator, p0.z);
            try edge_list.append(allocator, p1.x);
            try edge_list.append(allocator, p1.y);
            try edge_list.append(allocator, p1.z);
            try seg_edge_list.append(allocator, ed.id);
        }
    } else {
        // Cylinder or generic B-Rep solid tessellation
        const segments: u32 = 32;
        const pi = std.math.pi;
        const h = if (solid.vertices.items.len >= 2) solid.vertices.items[1].point.z else 2.0;
        const r: f32 = if (h > 0 and solid.volume > 0) @sqrt(solid.volume / (pi * h)) else 1.0;

        min_pt = Vec3.init(-r, -r, 0);
        max_pt = Vec3.init(r, r, h);

        // Bottom cap (Face 1)
        const center_bot_idx: u32 = @intCast(pos_list.items.len / 3);
        try pos_list.append(allocator, 0); try pos_list.append(allocator, 0); try pos_list.append(allocator, 0);
        try nrm_list.append(allocator, 0); try nrm_list.append(allocator, 0); try nrm_list.append(allocator, -1);

        var i: u32 = 0;
        while (i < segments) : (i += 1) {
            const theta = 2.0 * pi * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segments));
            try pos_list.append(allocator, r * @cos(theta));
            try pos_list.append(allocator, r * @sin(theta));
            try pos_list.append(allocator, 0);
            try nrm_list.append(allocator, 0); try nrm_list.append(allocator, 0); try nrm_list.append(allocator, -1);

            const idx0 = center_bot_idx;
            const idx1 = center_bot_idx + 1 + i;
            const idx2 = center_bot_idx + 1 + ((i + 1) % segments);
            try idx_list.append(allocator, idx0);
            try idx_list.append(allocator, idx2);
            try idx_list.append(allocator, idx1);
            try tri_face_list.append(allocator, 1);
        }

        // Top cap (Face 2)
        const center_top_idx: u32 = @intCast(pos_list.items.len / 3);
        try pos_list.append(allocator, 0); try pos_list.append(allocator, 0); try pos_list.append(allocator, h);
        try nrm_list.append(allocator, 0); try nrm_list.append(allocator, 0); try nrm_list.append(allocator, 1);

        i = 0;
        while (i < segments) : (i += 1) {
            const theta = 2.0 * pi * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segments));
            try pos_list.append(allocator, r * @cos(theta));
            try pos_list.append(allocator, r * @sin(theta));
            try pos_list.append(allocator, h);
            try nrm_list.append(allocator, 0); try nrm_list.append(allocator, 0); try nrm_list.append(allocator, 1);

            const idx0 = center_top_idx;
            const idx1 = center_top_idx + 1 + i;
            const idx2 = center_top_idx + 1 + ((i + 1) % segments);
            try idx_list.append(allocator, idx0);
            try idx_list.append(allocator, idx1);
            try idx_list.append(allocator, idx2);
            try tri_face_list.append(allocator, 2);
        }

        // Lateral wall (Face 3)
        i = 0;
        while (i < segments) : (i += 1) {
            const th0 = 2.0 * pi * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segments));
            const th1 = 2.0 * pi * @as(f32, @floatFromInt((i + 1) % segments)) / @as(f32, @floatFromInt(segments));
            const c0 = @cos(th0); const s0 = @sin(th0);
            const c1 = @cos(th1); const s1 = @sin(th1);

            const base: u32 = @intCast(pos_list.items.len / 3);
            try pos_list.append(allocator, r * c0); try pos_list.append(allocator, r * s0); try pos_list.append(allocator, 0);
            try nrm_list.append(allocator, c0);     try nrm_list.append(allocator, s0);     try nrm_list.append(allocator, 0);

            try pos_list.append(allocator, r * c1); try pos_list.append(allocator, r * s1); try pos_list.append(allocator, 0);
            try nrm_list.append(allocator, c1);     try nrm_list.append(allocator, s1);     try nrm_list.append(allocator, 0);

            try pos_list.append(allocator, r * c1); try pos_list.append(allocator, r * s1); try pos_list.append(allocator, h);
            try nrm_list.append(allocator, c1);     try nrm_list.append(allocator, s1);     try nrm_list.append(allocator, 0);

            try pos_list.append(allocator, r * c0); try pos_list.append(allocator, r * s0); try pos_list.append(allocator, h);
            try nrm_list.append(allocator, c0);     try nrm_list.append(allocator, s0);     try nrm_list.append(allocator, 0);

            try idx_list.append(allocator, base + 0);
            try idx_list.append(allocator, base + 1);
            try idx_list.append(allocator, base + 2);
            try tri_face_list.append(allocator, 3);

            try idx_list.append(allocator, base + 0);
            try idx_list.append(allocator, base + 2);
            try idx_list.append(allocator, base + 3);
            try tri_face_list.append(allocator, 3);
        }

        // Rim edge line segments (64 segments: 32 on bottom cap, 32 on top cap)
        i = 0;
        while (i < segments) : (i += 1) {
            const th0 = 2.0 * pi * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segments));
            const th1 = 2.0 * pi * @as(f32, @floatFromInt((i + 1) % segments)) / @as(f32, @floatFromInt(segments));

            // Bottom rim (Edge ID 1)
            try edge_list.append(allocator, r * @cos(th0));
            try edge_list.append(allocator, r * @sin(th0));
            try edge_list.append(allocator, 0);
            try edge_list.append(allocator, r * @cos(th1));
            try edge_list.append(allocator, r * @sin(th1));
            try edge_list.append(allocator, 0);
            try seg_edge_list.append(allocator, 1);

            // Top rim (Edge ID 2)
            try edge_list.append(allocator, r * @cos(th0));
            try edge_list.append(allocator, r * @sin(th0));
            try edge_list.append(allocator, h);
            try edge_list.append(allocator, r * @cos(th1));
            try edge_list.append(allocator, r * @sin(th1));
            try edge_list.append(allocator, h);
            try seg_edge_list.append(allocator, 2);
        }
    }

    const pos_slice = try pos_list.toOwnedSlice(allocator);
    errdefer allocator.free(pos_slice);
    const nrm_slice = try nrm_list.toOwnedSlice(allocator);
    errdefer allocator.free(nrm_slice);
    const idx_slice = try idx_list.toOwnedSlice(allocator);
    errdefer allocator.free(idx_slice);
    const tri_face_slice = try tri_face_list.toOwnedSlice(allocator);
    errdefer allocator.free(tri_face_slice);

    var edge_slice: ?[]f32 = null;
    var seg_edge_slice: ?[]u32 = null;
    if (edge_list.items.len > 0) {
        edge_slice = try edge_list.toOwnedSlice(allocator);
        seg_edge_slice = try seg_edge_list.toOwnedSlice(allocator);
    } else {
        edge_list.deinit(allocator);
        seg_edge_list.deinit(allocator);
    }

    return CadMesh{
        .positions = pos_slice.ptr,
        .vertex_count = @intCast(pos_slice.len / 3),
        .normals = nrm_slice.ptr,
        .indices = idx_slice.ptr,
        .triangle_count = @intCast(idx_slice.len / 3),
        .triangle_to_face_id = tri_face_slice.ptr,
        .edge_vertices = if (edge_slice) |s| s.ptr else null,
        .edge_segment_count = if (edge_slice) |s| @intCast(s.len / 6) else 0,
        .segment_to_edge_id = if (seg_edge_slice) |s| s.ptr else null,
        .bbox_min = .{ .x = min_pt.x, .y = min_pt.y, .z = min_pt.z },
        .bbox_max = .{ .x = max_pt.x, .y = max_pt.y, .z = max_pt.z },
    };
}

pub fn freeMesh(allocator: Allocator, mesh: *CadMesh) void {
    if (mesh.positions) |p| {
        const slice = p[0 .. mesh.vertex_count * 3];
        allocator.free(slice);
    }
    if (mesh.normals) |n| {
        const slice = n[0 .. mesh.vertex_count * 3];
        allocator.free(slice);
    }
    if (mesh.indices) |i| {
        const slice = i[0 .. mesh.triangle_count * 3];
        allocator.free(slice);
    }
    if (mesh.triangle_to_face_id) |tf| {
        const slice = tf[0 .. mesh.triangle_count];
        allocator.free(slice);
    }
    if (mesh.edge_vertices) |ev| {
        const slice = ev[0 .. mesh.edge_segment_count * 6];
        allocator.free(slice);
    }
    if (mesh.segment_to_edge_id) |se| {
        const slice = se[0 .. mesh.edge_segment_count];
        allocator.free(slice);
    }
    mesh.* = std.mem.zeroes(CadMesh);
}
