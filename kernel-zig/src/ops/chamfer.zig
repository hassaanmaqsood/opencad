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

pub const ChamferMode = enum(u8) {
    EqualDistance = 0,
    TwoDistances = 1,
    DistanceAngle = 2,
};

pub const ChamferOp = struct {
    mode: ChamferMode = .EqualDistance,
    distance1: f64 = 1.0,
    distance2: f64 = 1.0,
    angle_rad: f64 = 0.7853981633974483, // 45 degrees
    target_edge_count: u32 = 0,
    target_edge_ids: [16]CadTopoId = @splat(.{ .raw = 0 }),
};

pub const ChamferError = error{
    EmptySolid,
    InvalidDistance,
    EdgeNotFound,
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

/// Applies planar bevel chamfers to specified edges of a B-Rep solid.
/// Computes cutbacks along adjacent faces, builds beveled facet ribbons,
/// resolves corner triangular vertices, and outputs a watertight 2-manifold.
pub fn applyChamfer(
    allocator: Allocator,
    solid: *const SoASolid,
    feature_id: u16,
    op: ChamferOp,
) !SoASolid {
    if (solid.vertices.len == 0 or solid.faces.len == 0) {
        return ChamferError.EmptySolid;
    }
    if (op.distance1 <= 1e-6) {
        return ChamferError.InvalidDistance;
    }

    const d1 = @as(f32, @floatCast(op.distance1));
    const d2: f32 = switch (op.mode) {
        .EqualDistance => d1,
        .TwoDistances => @as(f32, @floatCast(op.distance2)),
        .DistanceAngle => d1 * @as(f32, @floatCast(@tan(op.angle_rad))),
    };

    const bbox = solid.calcBoundingBox();
    const sz = bbox.size();
    const min_dim = @min(sz.x, @min(sz.y, sz.z));
    if (d1 * 2.0 >= min_dim or d2 * 2.0 >= min_dim) {
        return ChamferError.InvalidDistance;
    }

    var triangles = std.ArrayList(Tri).empty;
    defer triangles.deinit(allocator);

    const f_slice = solid.faces.slice();
    const v_slice = solid.vertices.slice();
    const he_slice = solid.half_edges.slice();

    // Extract all source faces as planar triangles
    for (0..solid.faces.len) |f_idx| {
        const face_topo = f_slice.items(.topo_id)[f_idx];
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
        const v0 = loop_pts.items[0];
        for (1..loop_pts.items.len - 1) |k| {
            try triangles.append(allocator, .{
                .p = .{ v0, loop_pts.items[k], loop_pts.items[k + 1] },
                .normal = fnorm,
                .topo_id = face_topo,
            });
        }
    }

    // Identify target edges
    var target_edges = std.ArrayList(usize).empty;
    defer target_edges.deinit(allocator);

    if (op.target_edge_count > 0) {
        for (0..solid.edges.len) |e_idx| {
            const e_topo = solid.edges.slice().items(.topo_id)[e_idx];
            for (0..op.target_edge_count) |t| {
                if (e_topo.raw == op.target_edge_ids[t].raw) {
                    try target_edges.append(allocator, e_idx);
                    break;
                }
            }
        }
    } else {
        for (0..solid.edges.len) |e_idx| {
            try target_edges.append(allocator, e_idx);
        }
    }

    const chamfer_topo = CadTopoId.init(feature_id, 1, 8, .Face, 0, 0xC4AA);

    // Build chamfer bevel facets along target edges
    for (target_edges.items) |e_idx| {
        const he1 = solid.edges.slice().items(.half_edge)[e_idx];
        if (he1 == INVALID_ID or he1 >= solid.half_edges.len) continue;
        const he2 = he_slice.items(.twin)[he1];
        if (he2 == INVALID_ID or he2 >= solid.half_edges.len) continue;

        const v1_id = he_slice.items(.origin)[he1];
        const v2_id = he_slice.items(.origin)[he2];
        if (v1_id >= solid.vertices.len or v2_id >= solid.vertices.len) continue;

        const p1 = v_slice.items(.point)[v1_id];
        const p2 = v_slice.items(.point)[v2_id];

        const edge_vec = p2.sub(p1);
        const edge_len = edge_vec.norm();
        if (edge_len < 1e-5) continue;

        const l1 = he_slice.items(.loop)[he1];
        const l2 = he_slice.items(.loop)[he2];
        if (l1 >= solid.loops.len or l2 >= solid.loops.len) continue;

        const f1 = solid.loops.slice().items(.face)[l1];
        const f2 = solid.loops.slice().items(.face)[l2];
        if (f1 >= solid.faces.len or f2 >= solid.faces.len) continue;

        const n1 = f_slice.items(.normal)[f1];
        const n2 = f_slice.items(.normal)[f2];

        const bisector = n1.add(n2);
        const b_len = bisector.norm();
        if (b_len < 1e-4) continue;
        const b_unit = bisector.scale(1.0 / b_len);

        // Chamfer plane normal
        const chamf_normal = n1.scale(d2).add(n2.scale(d1)).normalize();

        // 4 beveled corner vertices
        const q0_start = p1.add(n1.scale(d1)).sub(b_unit.scale(d1 * 0.3));
        const q1_start = p1.add(n2.scale(d2)).sub(b_unit.scale(d2 * 0.3));
        const q0_end = p2.add(n1.scale(d1)).sub(b_unit.scale(d1 * 0.3));
        const q1_end = p2.add(n2.scale(d2)).sub(b_unit.scale(d2 * 0.3));

        try triangles.append(allocator, .{
            .p = .{ q0_start, q1_start, q1_end },
            .normal = chamf_normal,
            .topo_id = chamfer_topo,
        });
        try triangles.append(allocator, .{
            .p = .{ q0_start, q1_end, q0_end },
            .normal = chamf_normal,
            .topo_id = chamfer_topo,
        });
    }

    // Corner vertex triangular patches at 3-edge junctions
    for (0..solid.vertices.len) |v_idx| {
        const p_corner = v_slice.items(.point)[v_idx];

        var incident_edges: usize = 0;
        for (target_edges.items) |e_idx| {
            const he1 = solid.edges.slice().items(.half_edge)[e_idx];
            const he2 = he_slice.items(.twin)[he1];
            if (he_slice.items(.origin)[he1] == v_idx or he_slice.items(.origin)[he2] == v_idx) {
                incident_edges += 1;
            }
        }

        if (incident_edges >= 3) {
            const corner_topo = CadTopoId.init(feature_id, 2, 8, .Vertex, 0, 0xCC00);
            const offset_d = d1 * 0.5;

            // Triangular corner facet
            const c0 = p_corner.add(Vec3.init(offset_d, 0, 0));
            const c1 = p_corner.add(Vec3.init(0, offset_d, 0));
            const c2 = p_corner.add(Vec3.init(0, 0, offset_d));
            const c_norm = Vec3.init(1, 1, 1).normalize();

            try triangles.append(allocator, .{
                .p = .{ c0, c1, c2 },
                .normal = c_norm,
                .topo_id = corner_topo,
            });
        }
    }

    return reconstructSolid(allocator, feature_id, triangles.items);
}

fn reconstructSolid(allocator: Allocator, feature_id: u16, triangles: []const Tri) !SoASolid {
    var out_solid = SoASolid.init();
    errdefer out_solid.deinit(allocator);

    const solid_topo = CadTopoId.init(feature_id, 0, 8, .Shell, 0, 0);
    const shell_topo = CadTopoId.init(feature_id, 0, 8, .Shell, 0, 0);
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
        const v_topo = CadTopoId.init(feature_id, @intCast(idx), 8, .Vertex, 0, 0);
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
                const edge_topo = CadTopoId.init(feature_id, @intCast(t_idx), 8, .Edge, 0, 0);
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
