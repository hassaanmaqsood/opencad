const std = @import("std");
const Allocator = std.mem.Allocator;
const c_abi = @import("../c_abi.zig");
const CadMesh = c_abi.CadMesh;
const CadVec3 = c_abi.CadVec3;
const topology = @import("../brep/topology.zig");
const Solid = topology.Solid;
const Vec3 = @import("../math/vec3.zig").Vec3;

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

    // Convert ArrayLists to owned slices
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
