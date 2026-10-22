const std = @import("std");
const Allocator = std.mem.Allocator;
const Vec3 = @import("../math/vec3.zig").Vec3;
const topo = @import("../topo/mod.zig");
const c_abi = @import("../c_abi.zig");

const SoASolid = topo.SoASolid;
const CadTopoId = topo.CadTopoId;
const VertexId = topo.VertexId;
const HalfEdgeId = topo.HalfEdgeId;
const EdgeId = topo.EdgeId;
const LoopId = topo.LoopId;
const FaceId = topo.FaceId;
const ShellId = topo.ShellId;
const INVALID_ID = topo.INVALID_ID;

pub const ShellOp = struct {
    thickness: f64 = 1.0,
    is_inward: bool = true,
    open_face_count: u32 = 0,
    open_face_ids: [16]CadTopoId = @splat(.{ .raw = 0 }),
};

pub const ShellError = error{
    EmptySolid,
    InvalidThickness,
    FaceNotFound,
    OutOfMemory,
    OperationFailed,
};

const Tri = struct {
    p: [3]Vec3,
    normal: Vec3,
    topo_id: CadTopoId,
};

const QuantizedVec3 = struct {
    x: i32,
    y: i32,
    z: i32,
};

fn quantizePoint(p: Vec3, scale: f32) QuantizedVec3 {
    return .{
        .x = @as(i32, @intFromFloat(@round(p.x * scale))),
        .y = @as(i32, @intFromFloat(@round(p.y * scale))),
        .z = @as(i32, @intFromFloat(@round(p.z * scale))),
    };
}

const EdgeKey = struct {
    min_v: VertexId,
    max_v: VertexId,
};

fn makeEdgeKey(v1: VertexId, v2: VertexId) EdgeKey {
    return if (v1 < v2) .{ .min_v = v1, .max_v = v2 } else .{ .min_v = v2, .max_v = v1 };
}

/// Creates a hollow thin-walled shell solid by offsetting wall faces
/// and bridging open face boundaries with boundary ribbon faces.
pub fn applyShell(
    allocator: Allocator,
    solid: *const SoASolid,
    feature_id: u16,
    op: ShellOp,
) !SoASolid {
    if (solid.vertices.len == 0 or solid.faces.len == 0) {
        return ShellError.EmptySolid;
    }
    if (op.thickness <= 1e-6) {
        return ShellError.InvalidThickness;
    }

    const t = @as(f32, @floatCast(op.thickness));
    const bbox = solid.calcBoundingBox();
    const sz = bbox.size();
    const min_dim = @min(sz.x, @min(sz.y, sz.z));
    if (t * 2.0 >= min_dim) {
        return ShellError.InvalidThickness;
    }

    const f_slice = solid.faces.slice();
    const v_slice = solid.vertices.slice();
    const he_slice = solid.half_edges.slice();

    // Determine which faces are open
    var is_face_open = try allocator.alloc(bool, solid.faces.len);
    defer allocator.free(is_face_open);
    @memset(is_face_open, false);

    if (op.open_face_count > 0) {
        for (0..solid.faces.len) |f_idx| {
            const ft = f_slice.items(.topo_id)[f_idx];
            for (0..op.open_face_count) |k| {
                if (ft.raw == op.open_face_ids[k].raw) {
                    is_face_open[f_idx] = true;
                    break;
                }
            }
        }
    } else {
        // Default: face with maximum Z normal is opened (e.g. top of box)
        var max_z_idx: usize = 0;
        var max_z_val: f32 = -1e9;
        for (0..solid.faces.len) |f_idx| {
            const nz = f_slice.items(.normal)[f_idx].z;
            if (nz > max_z_val) {
                max_z_val = nz;
                max_z_idx = f_idx;
            }
        }
        is_face_open[max_z_idx] = true;
    }

    var triangles = std.ArrayList(Tri).empty;
    defer triangles.deinit(allocator);

    const inner_topo = CadTopoId.init(feature_id, 1, 9, .Face, 0, 0x511E);
    const wall_topo = CadTopoId.init(feature_id, 2, 9, .Face, 0, 0x511A);

    // 1. Retain all non-open outer faces
    for (0..solid.faces.len) |f_idx| {
        if (is_face_open[f_idx]) continue;

        const loop_id = f_slice.items(.outer_loop)[f_idx];
        if (loop_id == INVALID_ID or loop_id >= solid.loops.len) continue;
        const start_he = solid.loops.slice().items(.half_edge)[loop_id];
        if (start_he == INVALID_ID) continue;

        var loop_pts = std.ArrayList(Vec3).empty;
        defer loop_pts.deinit(allocator);

        var cur_he = start_he;
        var safe_counter: usize = 0;
        while (safe_counter < 100) : (safe_counter += 1) {
            const v_orig = he_slice.items(.origin)[cur_he];
            if (v_orig < solid.vertices.len) {
                try loop_pts.append(allocator, v_slice.items(.point)[v_orig]);
            }
            cur_he = he_slice.items(.next)[cur_he];
            if (cur_he == start_he or cur_he == INVALID_ID) break;
        }

        if (loop_pts.items.len < 3) continue;

        const fnorm = f_slice.items(.normal)[f_idx];
        const ftopo = f_slice.items(.topo_id)[f_idx];
        const v0 = loop_pts.items[0];

        for (1..loop_pts.items.len - 1) |k| {
            try triangles.append(allocator, .{
                .p = .{ v0, loop_pts.items[k], loop_pts.items[k + 1] },
                .normal = fnorm,
                .topo_id = ftopo,
            });
        }
    }

    // 2. Compute inner offset cavity for non-open faces
    for (0..solid.faces.len) |f_idx| {
        if (is_face_open[f_idx]) continue;

        const loop_id = f_slice.items(.outer_loop)[f_idx];
        if (loop_id == INVALID_ID or loop_id >= solid.loops.len) continue;
        const start_he = solid.loops.slice().items(.half_edge)[loop_id];
        if (start_he == INVALID_ID) continue;

        var loop_pts = std.ArrayList(Vec3).empty;
        defer loop_pts.deinit(allocator);

        var cur_he = start_he;
        var safe_counter: usize = 0;
        while (safe_counter < 100) : (safe_counter += 1) {
            const v_orig = he_slice.items(.origin)[cur_he];
            if (v_orig < solid.vertices.len) {
                // Inward offset along face normal
                const pt = v_slice.items(.point)[v_orig];
                const fnorm = f_slice.items(.normal)[f_idx];
                const offset_pt = pt.sub(fnorm.scale(t));
                try loop_pts.append(allocator, offset_pt);
            }
            cur_he = he_slice.items(.next)[cur_he];
            if (cur_he == start_he or cur_he == INVALID_ID) break;
        }

        if (loop_pts.items.len < 3) continue;

        // Inverted normal for inner cavity
        const fnorm_inv = f_slice.items(.normal)[f_idx].negate();
        const v0 = loop_pts.items[0];

        // Reverse winding for inner shell
        for (1..loop_pts.items.len - 1) |k| {
            try triangles.append(allocator, .{
                .p = .{ v0, loop_pts.items[k + 1], loop_pts.items[k] },
                .normal = fnorm_inv,
                .topo_id = inner_topo,
            });
        }
    }

    // 3. Connect open face rims to inner shell with wall ribbon faces
    for (0..solid.faces.len) |f_idx| {
        if (!is_face_open[f_idx]) continue;

        const loop_id = f_slice.items(.outer_loop)[f_idx];
        if (loop_id == INVALID_ID or loop_id >= solid.loops.len) continue;
        const start_he = solid.loops.slice().items(.half_edge)[loop_id];
        if (start_he == INVALID_ID) continue;

        var rim_pts = std.ArrayList(Vec3).empty;
        defer rim_pts.deinit(allocator);

        var cur_he = start_he;
        var safe_counter: usize = 0;
        while (safe_counter < 100) : (safe_counter += 1) {
            const v_orig = he_slice.items(.origin)[cur_he];
            if (v_orig < solid.vertices.len) {
                try rim_pts.append(allocator, v_slice.items(.point)[v_orig]);
            }
            cur_he = he_slice.items(.next)[cur_he];
            if (cur_he == start_he or cur_he == INVALID_ID) break;
        }

        const count = rim_pts.items.len;
        if (count < 3) continue;

        const fnorm = f_slice.items(.normal)[f_idx];

        for (0..count) |i| {
            const p0_outer = rim_pts.items[i];
            const p1_outer = rim_pts.items[(i + 1) % count];

            const p0_inner = p0_outer.sub(fnorm.scale(t));
            const p1_inner = p1_outer.sub(fnorm.scale(t));

            const edge_d = p1_outer.sub(p0_outer).normalize();
            const wall_norm = edge_d.cross(fnorm.negate()).normalize();

            // Quad ribbon: 2 triangles
            try triangles.append(allocator, .{
                .p = .{ p0_outer, p1_outer, p1_inner },
                .normal = wall_norm,
                .topo_id = wall_topo,
            });
            try triangles.append(allocator, .{
                .p = .{ p0_outer, p1_inner, p0_inner },
                .normal = wall_norm,
                .topo_id = wall_topo,
            });
        }
    }

    return reconstructSolid(allocator, feature_id, triangles.items);
}

fn reconstructSolid(allocator: Allocator, feature_id: u16, triangles: []const Tri) !SoASolid {
    var out_solid = SoASolid.init();
    errdefer out_solid.deinit(allocator);

    const solid_topo = CadTopoId.init(feature_id, 0, 9, .Shell, 0, 0);
    const shell_topo = CadTopoId.init(feature_id, 0, 9, .Shell, 0, 0);
    const solid_id = try out_solid.addSolid(allocator, solid_topo);
    const shell_id = try out_solid.addShell(allocator, solid_id, true, shell_topo);

    var vertex_map = std.AutoHashMap(QuantizedVec3, VertexId).init(allocator);
    defer vertex_map.deinit();

    var unique_pts = std.ArrayList(Vec3).empty;
    defer unique_pts.deinit(allocator);

    const scale: f32 = 1000.0;

    for (triangles) |tri| {
        for (tri.p) |p| {
            const key = quantizePoint(p, scale);
            if (!vertex_map.contains(key)) {
                const vid: VertexId = @intCast(unique_pts.items.len);
                try unique_pts.append(allocator, p);
                try vertex_map.put(key, vid);
            }
        }
    }

    for (unique_pts.items, 0..) |p, idx| {
        const v_topo = CadTopoId.init(feature_id, @intCast(idx), 9, .Vertex, 0, 0);
        _ = try out_solid.addVertex(allocator, p, v_topo);
    }

    var edge_map = std.AutoHashMap(EdgeKey, HalfEdgeId).init(allocator);
    defer edge_map.deinit();

    var net_vol: f64 = 0.0;
    var net_area: f64 = 0.0;

    for (triangles, 0..) |tri, t_idx| {
        const v0 = vertex_map.get(quantizePoint(tri.p[0], scale)).?;
        const v1 = vertex_map.get(quantizePoint(tri.p[1], scale)).?;
        const v2 = vertex_map.get(quantizePoint(tri.p[2], scale)).?;

        if (v0 == v1 or v1 == v2 or v2 == v0) continue;

        const face_topo = tri.topo_id;
        const face_id = try out_solid.addFace(allocator, shell_id, tri.normal, .Plane, face_topo);
        const loop_id = try out_solid.addLoop(allocator, face_id, true, face_topo);

        const he0 = try out_solid.addHalfEdge(allocator, v0, loop_id, face_topo);
        const he1 = try out_solid.addHalfEdge(allocator, v1, loop_id, face_topo);
        const he2 = try out_solid.addHalfEdge(allocator, v2, loop_id, face_topo);

        out_solid.half_edges.slice().items(.next)[he0] = he1;
        out_solid.half_edges.slice().items(.prev)[he0] = he2;
        out_solid.half_edges.slice().items(.next)[he1] = he2;
        out_solid.half_edges.slice().items(.prev)[he1] = he0;
        out_solid.half_edges.slice().items(.next)[he2] = he0;
        out_solid.half_edges.slice().items(.prev)[he2] = he1;

        out_solid.loops.slice().items(.half_edge)[loop_id] = he0;
        out_solid.faces.slice().items(.outer_loop)[face_id] = loop_id;

        const edges_triple = [3]struct { vA: VertexId, vB: VertexId, he: HalfEdgeId }{
            .{ .vA = v0, .vB = v1, .he = he0 },
            .{ .vA = v1, .vB = v2, .he = he1 },
            .{ .vA = v2, .vB = v0, .he = he2 },
        };

        for (edges_triple) |e_pair| {
            const e_key = makeEdgeKey(e_pair.vA, e_pair.vB);
            if (edge_map.get(e_key)) |twin_he| {
                out_solid.half_edges.slice().items(.twin)[e_pair.he] = twin_he;
                out_solid.half_edges.slice().items(.twin)[twin_he] = e_pair.he;

                const edge_id = out_solid.half_edges.slice().items(.edge)[twin_he];
                out_solid.half_edges.slice().items(.edge)[e_pair.he] = edge_id;
            } else {
                const edge_topo = CadTopoId.init(feature_id, @intCast(t_idx), 9, .Edge, 0, 0);
                const edge_id = try out_solid.addEdge(allocator, e_pair.he, edge_topo);
                out_solid.half_edges.slice().items(.edge)[e_pair.he] = edge_id;
                try edge_map.put(e_key, e_pair.he);
            }
        }

        const cross = (tri.p[1].sub(tri.p[0])).cross(tri.p[2].sub(tri.p[0]));
        net_vol += @as(f64, @floatCast(tri.p[0].dot(tri.p[1].cross(tri.p[2])))) / 6.0;
        net_area += @as(f64, @floatCast(cross.norm())) * 0.5;
    }

    out_solid.volume = @floatCast(@abs(net_vol));
    out_solid.surface_area = @floatCast(net_area);

    return out_solid;
}
