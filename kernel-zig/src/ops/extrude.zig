const std = @import("std");
const Allocator = std.mem.Allocator;
const Vec3 = @import("../math/vec3.zig").Vec3;
const topo = @import("../topo/mod.zig");

const SoASolid = topo.SoASolid;
const CadTopoId = topo.CadTopoId;
const CadSubshapeType = topo.CadSubshapeType;
const VertexId = topo.VertexId;
const HalfEdgeId = topo.HalfEdgeId;
const EdgeId = topo.EdgeId;
const LoopId = topo.LoopId;
const FaceId = topo.FaceId;
const INVALID_ID = topo.INVALID_ID;

const topo_naming = topo.topo_naming;
const FLAG_CAP_BOTTOM = topo_naming.FLAG_CAP_BOTTOM;
const FLAG_CAP_TOP = topo_naming.FLAG_CAP_TOP;
const FLAG_LATERAL = topo_naming.FLAG_LATERAL;
const hashNormal = topo_naming.hashNormal;
const hashPoint = topo_naming.hashPoint;
const hashEdge = topo_naming.hashEdge;
const hashFace = topo_naming.hashFace;

pub const ExtrudeError = error{
    InvalidDistance,
    InvalidDirection,
    DegeneratePolygon,
    OutOfMemory,
    ManifoldValidationFailed,
};

/// Extrudes a 2D closed polygon wire along a 3D direction vector by a given distance.
/// Constructs a watertight 2-manifold SoASolid with persistent CadTopoId tags.
pub fn extrudePolygon(
    allocator: Allocator,
    feature_id: u16,
    raw_points: []const [2]f32,
    distance: f32,
    direction: Vec3,
    symmetric: bool,
) ExtrudeError!SoASolid {
    if (distance <= 1e-6) return error.InvalidDistance;
    if (direction.norm() <= 1e-6) return error.InvalidDirection;
    const n_pts = raw_points.len;
    if (n_pts < 3) return error.DegeneratePolygon;

    const dir = direction.normalize();

    // 1. Calculate 2D signed area to ensure counter-clockwise (CCW) orientation
    var signed_area: f32 = 0.0;
    var i: usize = 0;
    while (i < n_pts) : (i += 1) {
        const next_i = (i + 1) % n_pts;
        signed_area += (raw_points[i][0] * raw_points[next_i][1] - raw_points[next_i][0] * raw_points[i][1]);
    }
    signed_area *= 0.5;
    if (@abs(signed_area) < 1e-7) return error.DegeneratePolygon;

    // Buffer for ordered 2D vertices (CCW)
    const pts = try allocator.alloc([2]f32, n_pts);
    defer allocator.free(pts);

    if (signed_area < 0.0) {
        // Reverse clockwise to CCW
        for (0..n_pts) |idx| {
            pts[idx] = raw_points[n_pts - 1 - idx];
        }
    } else {
        @memcpy(pts, raw_points);
    }

    const start_offset = if (symmetric) dir.scale(-distance * 0.5) else Vec3.init(0, 0, 0);
    const end_offset = if (symmetric) dir.scale(distance * 0.5) else dir.scale(distance);

    var solid = SoASolid.init();
    errdefer solid.deinit(allocator);

    const solid_topo = CadTopoId.init(feature_id, 0, 3, .Shell, 0, 0);
    const solid_id = try solid.addSolid(allocator, solid_topo);
    const shell_id = try solid.addShell(allocator, solid_id, true, solid_topo);

    // 2. Create 2 * N vertices: Bottom [0..N-1] and Top [N..2N-1]
    const bottom_v = try allocator.alloc(VertexId, n_pts);
    defer allocator.free(bottom_v);

    const top_v = try allocator.alloc(VertexId, n_pts);
    defer allocator.free(top_v);

    for (0..n_pts) |idx| {
        const base_pt = Vec3.init(pts[idx][0], pts[idx][1], 0.0);
        const p_bot = base_pt.add(start_offset);
        const p_top = base_pt.add(end_offset);

        const bot_topo = CadTopoId.init(
            feature_id,
            @intCast(idx),
            3,
            .Vertex,
            FLAG_CAP_BOTTOM,
            hashPoint(p_bot),
        );
        bottom_v[idx] = try solid.addVertex(allocator, p_bot, bot_topo);

        const top_topo = CadTopoId.init(
            feature_id,
            @intCast(idx),
            3,
            .Vertex,
            FLAG_CAP_TOP,
            hashPoint(p_top),
        );
        top_v[idx] = try solid.addVertex(allocator, p_top, top_topo);
    }

    // 3. Bottom Cap Face (Normal: -dir)
    const bot_normal = dir.scale(-1.0);
    const bot_face_topo = CadTopoId.init(
        feature_id,
        0,
        3,
        .Face,
        FLAG_CAP_BOTTOM,
        hashFace(bot_normal, FLAG_CAP_BOTTOM),
    );
    const bot_face = try solid.addFace(allocator, shell_id, bot_normal, .Plane, bot_face_topo);
    const bot_loop = try solid.addLoop(allocator, bot_face, true, bot_face_topo);
    solid.faces.slice().items(.outer_loop)[bot_face] = bot_loop;

    // In bottom cap, winding must be CW when viewed from +Z so outward normal is -Z
    // Order: bottom_v[0], bottom_v[N-1], bottom_v[N-2], ...
    const bot_hes = try allocator.alloc(HalfEdgeId, n_pts);
    defer allocator.free(bot_hes);

    for (0..n_pts) |k| {
        const v_idx = (n_pts - k) % n_pts;
        const origin = bottom_v[v_idx];
        const he_topo = CadTopoId.init(feature_id, @intCast(v_idx), 3, .Edge, FLAG_CAP_BOTTOM, 0);
        bot_hes[k] = try solid.addHalfEdge(allocator, origin, bot_loop, he_topo);
    }
    for (0..n_pts) |k| {
        const next_k = (k + 1) % n_pts;
        solid.setNextPrev(bot_hes[k], bot_hes[next_k]);
    }
    solid.loops.slice().items(.half_edge)[bot_loop] = bot_hes[0];

    // 4. Top Cap Face (Normal: +dir)
    const top_normal = dir;
    const top_face_topo = CadTopoId.init(
        feature_id,
        0,
        3,
        .Face,
        FLAG_CAP_TOP,
        hashFace(top_normal, FLAG_CAP_TOP),
    );
    const top_face = try solid.addFace(allocator, shell_id, top_normal, .Plane, top_face_topo);
    const top_loop = try solid.addLoop(allocator, top_face, true, top_face_topo);
    solid.faces.slice().items(.outer_loop)[top_face] = top_loop;

    // Top cap winding is CCW: top_v[0], top_v[1], ...
    const top_hes = try allocator.alloc(HalfEdgeId, n_pts);
    defer allocator.free(top_hes);

    for (0..n_pts) |k| {
        const origin = top_v[k];
        const he_topo = CadTopoId.init(feature_id, @intCast(k), 3, .Edge, FLAG_CAP_TOP, 0);
        top_hes[k] = try solid.addHalfEdge(allocator, origin, top_loop, he_topo);
    }
    for (0..n_pts) |k| {
        const next_k = (k + 1) % n_pts;
        solid.setNextPrev(top_hes[k], top_hes[next_k]);
    }
    solid.loops.slice().items(.half_edge)[top_loop] = top_hes[0];

    // 5. N Lateral Quad Faces
    // Quad k: bottom_v[k] -> bottom_v[next_k] -> top_v[next_k] -> top_v[k]
    const lateral_hes = try allocator.alloc([4]HalfEdgeId, n_pts);
    defer allocator.free(lateral_hes);

    for (0..n_pts) |k| {
        const next_k = (k + 1) % n_pts;
        const v0 = bottom_v[k];
        const v1 = bottom_v[next_k];
        const v2 = top_v[next_k];
        const v3 = top_v[k];

        const p0 = solid.vertices.slice().items(.point)[v0];
        const p1 = solid.vertices.slice().items(.point)[v1];
        const p3 = solid.vertices.slice().items(.point)[v3];

        const edge_vec = p1.sub(p0);
        const up_vec = p3.sub(p0);
        const lat_normal = edge_vec.cross(up_vec).normalize();

        const lat_face_topo = CadTopoId.init(
            feature_id,
            @intCast(k),
            3,
            .Face,
            FLAG_LATERAL,
            hashFace(lat_normal, FLAG_LATERAL),
        );
        const lat_face = try solid.addFace(allocator, shell_id, lat_normal, .Plane, lat_face_topo);
        const lat_loop = try solid.addLoop(allocator, lat_face, true, lat_face_topo);
        solid.faces.slice().items(.outer_loop)[lat_face] = lat_loop;

        const he0 = try solid.addHalfEdge(allocator, v0, lat_loop, lat_face_topo);
        const he1 = try solid.addHalfEdge(allocator, v1, lat_loop, lat_face_topo);
        const he2 = try solid.addHalfEdge(allocator, v2, lat_loop, lat_face_topo);
        const he3 = try solid.addHalfEdge(allocator, v3, lat_loop, lat_face_topo);

        solid.setNextPrev(he0, he1);
        solid.setNextPrev(he1, he2);
        solid.setNextPrev(he2, he3);
        solid.setNextPrev(he3, he0);

        solid.loops.slice().items(.half_edge)[lat_loop] = he0;
        lateral_hes[k] = .{ he0, he1, he2, he3 };
    }

    // 6. Connect Twins and instantiate Edges (3 * N edges total)
    // a. Bottom horizontal edges: lateral_hes[k][0] (v[k] -> v[next_k]) twins with bot_hes
    for (0..n_pts) |k| {
        const next_k = (k + 1) % n_pts;
        // In bot_hes, find the half-edge starting at v[next_k]
        // bot_hes was built with origin = bottom_v[(N - idx) % N]
        // so origin is v[next_k] when (N - idx) % N == next_k => idx = (N - next_k) % N
        const bot_he_idx = (n_pts - next_k) % n_pts;
        const lat_he0 = lateral_hes[k][0];
        const bot_he = bot_hes[bot_he_idx];

        const edge_topo = CadTopoId.init(feature_id, @intCast(k), 3, .Edge, FLAG_CAP_BOTTOM, 0);
        const edge_id = try solid.addEdge(allocator, lat_he0, edge_topo);
        solid.setTwins(lat_he0, bot_he, edge_id);
    }

    // b. Top horizontal edges: lateral_hes[k][2] (top[next_k] -> top[k]) twins with top_hes[k] (top[k] -> top[next_k])
    for (0..n_pts) |k| {
        const lat_he2 = lateral_hes[k][2];
        const top_he = top_hes[k];

        const edge_topo = CadTopoId.init(feature_id, @intCast(k), 3, .Edge, FLAG_CAP_TOP, 0);
        const edge_id = try solid.addEdge(allocator, top_he, edge_topo);
        solid.setTwins(top_he, lat_he2, edge_id);
    }

    // c. Vertical pillar edges: lateral_hes[k][3] (top[k] -> bot[k]) twins with lateral_hes[prev_k][1] (bot[k] -> top[k])
    for (0..n_pts) |k| {
        const prev_k = (k + n_pts - 1) % n_pts;
        const lat_he3 = lateral_hes[k][3];
        const prev_he1 = lateral_hes[prev_k][1];

        const edge_topo = CadTopoId.init(feature_id, @intCast(k), 3, .Edge, FLAG_LATERAL, 0);
        const edge_id = try solid.addEdge(allocator, prev_he1, edge_topo);
        solid.setTwins(prev_he1, lat_he3, edge_id);
    }

    // 7. Validate 2-manifold integrity
    solid.validateManifold() catch return error.ManifoldValidationFailed;

    // 8. Update volume and surface area metrics
    solid.updateMetrics();

    return solid;
}

/// Extrudes a 2D polygon with arbitrary inner hole loops along direction vector.
/// Satisfies generalized Euler-Poincare invariant: V - E + F - (L - F) - 2*(S - G) = 0.
pub fn extrudePolygonWithHoles(
    allocator: Allocator,
    feature_id: u16,
    raw_outer: []const [2]f32,
    raw_holes: []const []const [2]f32,
    distance: f32,
    direction: Vec3,
    symmetric: bool,
) ExtrudeError!SoASolid {
    if (raw_holes.len == 0) {
        return extrudePolygon(allocator, feature_id, raw_outer, distance, direction, symmetric);
    }

    if (distance <= 1e-6) return error.InvalidDistance;
    if (direction.norm() <= 1e-6) return error.InvalidDirection;
    if (raw_outer.len < 3) return error.DegeneratePolygon;

    const dir = direction.normalize();
    const start_offset = if (symmetric) dir.scale(-distance * 0.5) else Vec3.init(0, 0, 0);
    const end_offset = if (symmetric) dir.scale(distance * 0.5) else dir.scale(distance);

    var solid = SoASolid.init();
    errdefer solid.deinit(allocator);

    const num_holes: u32 = @intCast(raw_holes.len);
    const solid_topo = CadTopoId.init(feature_id, 0, 3, .Shell, 0, 0);
    const solid_id = solid.addSolid(allocator, solid_topo) catch return error.OutOfMemory;
    const shell_id = solid.addShell(allocator, solid_id, true, solid_topo) catch return error.OutOfMemory;

    // Bottom Cap Face (Normal: -dir)
    const bot_normal = dir.scale(-1.0);
    const bot_topo = CadTopoId.init(feature_id, 0, 3, .Face, FLAG_CAP_BOTTOM, hashFace(bot_normal, FLAG_CAP_BOTTOM));
    const bot_face = solid.addFace(allocator, shell_id, bot_normal, .Plane, bot_topo) catch return error.OutOfMemory;

    // Top Cap Face (Normal: +dir)
    const top_normal = dir;
    const top_topo = CadTopoId.init(feature_id, 1, 3, .Face, FLAG_CAP_TOP, hashFace(top_normal, FLAG_CAP_TOP));
    const top_face = solid.addFace(allocator, shell_id, top_normal, .Plane, top_topo) catch return error.OutOfMemory;

    // Extrude outer boundary wire
    try extrudeWireLoop(
        &solid,
        allocator,
        feature_id,
        raw_outer,
        shell_id,
        bot_face,
        top_face,
        start_offset,
        end_offset,
        true, // is_outer
        true, // ccw
    );

    // Extrude each hole wire
    for (raw_holes, 0..) |hole_pts, h_idx| {
        if (hole_pts.len < 3) return error.DegeneratePolygon;
        try extrudeWireLoop(
            &solid,
            allocator,
            feature_id + @as(u16, @intCast(h_idx + 1)),
            hole_pts,
            shell_id,
            bot_face,
            top_face,
            start_offset,
            end_offset,
            false, // is_outer (hole)
            false, // cw orientation for holes
        );
    }

    // Calculate exact analytical volume and surface area
    var outer_area: f32 = 0.0;
    var outer_perim: f32 = 0.0;
    for (0..raw_outer.len) |i| {
        const next_i = (i + 1) % raw_outer.len;
        outer_area += (raw_outer[i][0] * raw_outer[next_i][1] - raw_outer[next_i][0] * raw_outer[i][1]);
        const dx = raw_outer[next_i][0] - raw_outer[i][0];
        const dy = raw_outer[next_i][1] - raw_outer[i][1];
        outer_perim += @sqrt(dx * dx + dy * dy);
    }
    outer_area = @abs(outer_area) * 0.5;

    var net_area = outer_area;
    var total_perim = outer_perim;
    for (raw_holes) |hole_pts| {
        var h_area: f32 = 0.0;
        var h_perim: f32 = 0.0;
        for (0..hole_pts.len) |i| {
            const next_i = (i + 1) % hole_pts.len;
            h_area += (hole_pts[i][0] * hole_pts[next_i][1] - hole_pts[next_i][0] * hole_pts[i][1]);
            const dx = hole_pts[next_i][0] - hole_pts[i][0];
            const dy = hole_pts[next_i][1] - hole_pts[i][1];
            h_perim += @sqrt(dx * dx + dy * dy);
        }
        net_area -= @abs(h_area) * 0.5;
        total_perim += h_perim;
    }

    // Validate manifold invariants for genus = num_holes
    solid.validateManifoldGenus(num_holes) catch return error.ManifoldValidationFailed;

    solid.volume = net_area * distance;
    solid.surface_area = 2.0 * net_area + total_perim * distance;
    return solid;
}

fn extrudeWireLoop(
    solid: *SoASolid,
    allocator: Allocator,
    feature_id: u16,
    pts: []const [2]f32,
    shell_id: u32,
    bot_face: u32,
    top_face: u32,
    start_offset: Vec3,
    end_offset: Vec3,
    is_outer: bool,
    force_ccw: bool,
) ExtrudeError!void {
    const n_pts = pts.len;

    // Calculate signed area
    var area: f32 = 0.0;
    for (0..n_pts) |i| {
        const next_i = (i + 1) % n_pts;
        area += (pts[i][0] * pts[next_i][1] - pts[next_i][0] * pts[i][1]);
    }
    area *= 0.5;

    const ordered_pts = try allocator.alloc([2]f32, n_pts);
    defer allocator.free(ordered_pts);

    const is_ccw = area > 0.0;
    if (force_ccw != is_ccw) {
        for (0..n_pts) |i| ordered_pts[i] = pts[n_pts - 1 - i];
    } else {
        @memcpy(ordered_pts, pts);
    }

    // Create 2 * N vertices
    const bot_v = try allocator.alloc(VertexId, n_pts);
    defer allocator.free(bot_v);
    const top_v = try allocator.alloc(VertexId, n_pts);
    defer allocator.free(top_v);

    for (0..n_pts) |i| {
        const base_pt = Vec3.init(ordered_pts[i][0], ordered_pts[i][1], 0.0);
        const p_bot = base_pt.add(start_offset);
        const p_top = base_pt.add(end_offset);

        const flag: u4 = if (is_outer) FLAG_CAP_BOTTOM else topo_naming.FLAG_INTERIOR;
        const bot_t = CadTopoId.init(feature_id, @intCast(i), 3, .Vertex, flag, hashPoint(p_bot));
        bot_v[i] = solid.addVertex(allocator, p_bot, bot_t) catch return error.OutOfMemory;

        const top_t = CadTopoId.init(feature_id, @intCast(i), 3, .Vertex, flag, hashPoint(p_top));
        top_v[i] = solid.addVertex(allocator, p_top, top_t) catch return error.OutOfMemory;
    }

    // Bottom loop
    const bot_loop_topo = CadTopoId.init(feature_id, 0, 3, .Face, FLAG_CAP_BOTTOM, 0);
    const bot_loop = solid.addLoop(allocator, bot_face, is_outer, bot_loop_topo) catch return error.OutOfMemory;
    if (is_outer) {
        solid.faces.slice().items(.outer_loop)[bot_face] = bot_loop;
    }

    const bot_hes = try allocator.alloc(HalfEdgeId, n_pts);
    defer allocator.free(bot_hes);

    for (0..n_pts) |k| {
        const v_idx = (n_pts - k) % n_pts;
        const origin = bot_v[v_idx];
        const he_topo = CadTopoId.init(feature_id, @intCast(v_idx), 3, .Edge, FLAG_CAP_BOTTOM, 0);
        bot_hes[k] = solid.addHalfEdge(allocator, origin, bot_loop, he_topo) catch return error.OutOfMemory;
    }
    for (0..n_pts) |k| {
        const next_k = (k + 1) % n_pts;
        solid.setNextPrev(bot_hes[k], bot_hes[next_k]);
    }
    solid.loops.slice().items(.half_edge)[bot_loop] = bot_hes[0];

    // Top loop
    const top_loop_topo = CadTopoId.init(feature_id, 1, 3, .Face, FLAG_CAP_TOP, 0);
    const top_loop = solid.addLoop(allocator, top_face, is_outer, top_loop_topo) catch return error.OutOfMemory;
    if (is_outer) {
        solid.faces.slice().items(.outer_loop)[top_face] = top_loop;
    }

    const top_hes = try allocator.alloc(HalfEdgeId, n_pts);
    defer allocator.free(top_hes);

    for (0..n_pts) |k| {
        const origin = top_v[k];
        const he_topo = CadTopoId.init(feature_id, @intCast(k), 3, .Edge, FLAG_CAP_TOP, 0);
        top_hes[k] = solid.addHalfEdge(allocator, origin, top_loop, he_topo) catch return error.OutOfMemory;
    }
    for (0..n_pts) |k| {
        const next_k = (k + 1) % n_pts;
        solid.setNextPrev(top_hes[k], top_hes[next_k]);
    }
    solid.loops.slice().items(.half_edge)[top_loop] = top_hes[0];

    // Lateral Quads
    const lat_hes = try allocator.alloc([4]HalfEdgeId, n_pts);
    defer allocator.free(lat_hes);

    for (0..n_pts) |k| {
        const next_k = (k + 1) % n_pts;
        const v0 = bot_v[k];
        const v1 = bot_v[next_k];
        const v2 = top_v[next_k];
        const v3 = top_v[k];

        const p0 = solid.vertices.slice().items(.point)[v0];
        const p1 = solid.vertices.slice().items(.point)[v1];
        const p3 = solid.vertices.slice().items(.point)[v3];
        const nrm = (p1.sub(p0)).cross(p3.sub(p0)).normalize();

        const lat_topo = CadTopoId.init(feature_id, @intCast(k), 3, .Face, FLAG_LATERAL, hashFace(nrm, FLAG_LATERAL));
        const lat_face = solid.addFace(allocator, shell_id, nrm, .Plane, lat_topo) catch return error.OutOfMemory;
        const lat_loop = solid.addLoop(allocator, lat_face, true, lat_topo) catch return error.OutOfMemory;
        solid.faces.slice().items(.outer_loop)[lat_face] = lat_loop;

        const he0 = solid.addHalfEdge(allocator, v0, lat_loop, lat_topo) catch return error.OutOfMemory;
        const he1 = solid.addHalfEdge(allocator, v1, lat_loop, lat_topo) catch return error.OutOfMemory;
        const he2 = solid.addHalfEdge(allocator, v2, lat_loop, lat_topo) catch return error.OutOfMemory;
        const he3 = solid.addHalfEdge(allocator, v3, lat_loop, lat_topo) catch return error.OutOfMemory;

        solid.setNextPrev(he0, he1);
        solid.setNextPrev(he1, he2);
        solid.setNextPrev(he2, he3);
        solid.setNextPrev(he3, he0);
        solid.loops.slice().items(.half_edge)[lat_loop] = he0;

        lat_hes[k] = .{ he0, he1, he2, he3 };
    }

    // Connect Twins
    for (0..n_pts) |k| {
        const next_k = (k + 1) % n_pts;
        const bot_he_idx = (n_pts - next_k) % n_pts;
        const lat_he0 = lat_hes[k][0];
        const bot_he = bot_hes[bot_he_idx];

        const e_topo = CadTopoId.init(feature_id, @intCast(k), 3, .Edge, FLAG_CAP_BOTTOM, 0);
        const e_id = solid.addEdge(allocator, lat_he0, e_topo) catch return error.OutOfMemory;
        solid.setTwins(lat_he0, bot_he, e_id);
    }

    for (0..n_pts) |k| {
        const lat_he2 = lat_hes[k][2];
        const top_he = top_hes[k];

        const e_topo = CadTopoId.init(feature_id, @intCast(k), 3, .Edge, FLAG_CAP_TOP, 0);
        const e_id = solid.addEdge(allocator, top_he, e_topo) catch return error.OutOfMemory;
        solid.setTwins(top_he, lat_he2, e_id);
    }

    for (0..n_pts) |k| {
        const prev_k = (k + n_pts - 1) % n_pts;
        const lat_he3 = lat_hes[k][3];
        const prev_he1 = lat_hes[prev_k][1];

        const e_topo = CadTopoId.init(feature_id, @intCast(k), 3, .Edge, FLAG_LATERAL, 0);
        const e_id = solid.addEdge(allocator, prev_he1, e_topo) catch return error.OutOfMemory;
        solid.setTwins(prev_he1, lat_he3, e_id);
    }
}


test "Extrude rectangle to watertight 2-manifold solid" {
    const allocator = std.testing.allocator;

    const rect_pts = [_][2]f32{
        .{ 0.0, 0.0 },
        .{ 10.0, 0.0 },
        .{ 10.0, 5.0 },
        .{ 0.0, 5.0 },
    };

    var solid = try extrudePolygon(
        allocator,
        1,
        &rect_pts,
        20.0,
        Vec3.init(0, 0, 1),
        false,
    );
    defer solid.deinit(allocator);

    // 8 vertices, 12 edges, 6 faces
    try std.testing.expectEqual(@as(usize, 8), solid.vertices.len);
    try std.testing.expectEqual(@as(usize, 12), solid.edges.len);
    try std.testing.expectEqual(@as(usize, 6), solid.faces.len);
    try std.testing.expectEqual(@as(usize, 24), solid.half_edges.len);

    // Euler characteristic = 0
    try std.testing.expectEqual(@as(i32, 0), solid.calcEulerPoincare(0));

    // Volume = 10 * 5 * 20 = 1000
    try std.testing.expectApproxEqAbs(@as(f32, 1000.0), solid.volume, 1e-2);

    // Surface area = 2 * (10*5) + 2 * (10*20) + 2 * (5*20) = 100 + 400 + 200 = 700
    try std.testing.expectApproxEqAbs(@as(f32, 700.0), solid.surface_area, 1e-2);
}

test "Extrude L-shape (non-convex polygon)" {
    const allocator = std.testing.allocator;

    const l_pts = [_][2]f32{
        .{ 0.0, 0.0 },
        .{ 6.0, 0.0 },
        .{ 6.0, 2.0 },
        .{ 2.0, 2.0 },
        .{ 2.0, 6.0 },
        .{ 0.0, 6.0 },
    };

    var solid = try extrudePolygon(
        allocator,
        2,
        &l_pts,
        10.0,
        Vec3.init(0, 0, 1),
        false,
    );
    defer solid.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 12), solid.vertices.len);
    try std.testing.expectEqual(@as(usize, 18), solid.edges.len);
    try std.testing.expectEqual(@as(usize, 8), solid.faces.len);
    try std.testing.expectEqual(@as(i32, 0), solid.calcEulerPoincare(0));

    // L-shape 2D area = 6*2 + 2*4 = 12 + 8 = 20. Volume = 20 * 10 = 200
    try std.testing.expectApproxEqAbs(@as(f32, 200.0), solid.volume, 1e-2);
}

test "Extrude polygon with hole (genus 1 hollow prism)" {
    const allocator = std.testing.allocator;

    // Outer 20x20 square
    const outer = [_][2]f32{
        .{ 0, 0 },
        .{ 20, 0 },
        .{ 20, 20 },
        .{ 0, 20 },
    };

    // Inner 10x10 hole
    const hole = [_][2]f32{
        .{ 5, 5 },
        .{ 15, 5 },
        .{ 15, 15 },
        .{ 5, 15 },
    };

    const holes = [_][]const [2]f32{&hole};

    var hollow_prism = try extrudePolygonWithHoles(
        allocator,
        1,
        &outer,
        &holes,
        10.0,
        Vec3.init(0, 0, 1),
        false,
    );
    defer hollow_prism.deinit(allocator);

    // V = 2 * (4 + 4) = 16
    // E = 3 * (4 + 4) = 24
    // F = 2 + (4 + 4) = 10
    // L = 2 + 2 + 8 = 12
    // Genus G = 1, Shells S = 1
    // V - E + F - (L - F) - 2(S - G) = 16 - 24 + 10 - (12 - 10) - 2(1 - 1) = 2 - 2 - 0 = 0
    try std.testing.expectEqual(@as(usize, 16), hollow_prism.vertices.len);
    try std.testing.expectEqual(@as(usize, 24), hollow_prism.edges.len);
    try std.testing.expectEqual(@as(usize, 10), hollow_prism.faces.len);

    try std.testing.expectEqual(@as(i32, 0), hollow_prism.calcEulerPoincare(1));
    try hollow_prism.validateManifoldGenus(1);
}

