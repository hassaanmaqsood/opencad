const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const cad = @import("cad_kernel");
const box = cad.BoxMod;
const cylinder = cad.CylinderMod;
const topo = cad.TopologyMod.topo;
const Vec3 = cad.TopologyMod.Vec3;

pub const CadTopoId = topo.CadTopoId;
pub const CadSubshapeType = topo.CadSubshapeType;
pub const SoASolid = topo.SoASolid;
pub const VertexId = topo.VertexId;
pub const HalfEdgeId = topo.HalfEdgeId;
pub const EdgeId = topo.EdgeId;
pub const LoopId = topo.LoopId;
pub const FaceId = topo.FaceId;
pub const ShellId = topo.ShellId;
pub const SolidId = topo.SolidId;
pub const INVALID_ID = topo.INVALID_ID;

pub const FLAG_TOP_CAP: u4 = 1;
pub const FLAG_BOTTOM_CAP: u4 = 2;
pub const FLAG_LATERAL: u4 = 3;
pub const FLAG_TOP_EDGE: u4 = 1;
pub const FLAG_BOTTOM_EDGE: u4 = 2;
pub const FLAG_PILLAR_EDGE: u4 = 3;

// ===========================================================================
// Invariant & Topological Twin-Loop Closure Validator
// ===========================================================================

pub fn validateManifoldInvariants(solid: *const SoASolid, expected_genus: u32) !void {
    const V = solid.vertices.len;
    const E = solid.edges.len;
    const F = solid.faces.len;
    const L = solid.loops.len;
    const S = solid.shells.len;
    const G = expected_genus;

    try testing.expect(V > 0);
    try testing.expect(E > 0);
    try testing.expect(F > 0);
    try testing.expect(L > 0);
    try testing.expect(S > 0);

    // 1. Generalized Euler-Poincaré formula: V - E + F - (L - F) - 2(S - G) = 0
    const iV: i64 = @intCast(V);
    const iE: i64 = @intCast(E);
    const iF: i64 = @intCast(F);
    const iL: i64 = @intCast(L);
    const iS: i64 = @intCast(S);
    const iG: i64 = @intCast(G);

    const generalized_euler = iV - iE + iF - (iL - iF) - 2 * (iS - iG);
    try testing.expectEqual(@as(i64, 0), generalized_euler);

    // For a closed 2-manifold solid (sphere topology, S=1, G=0, L=F), verifies V - E + F = 2
    if (S == 1 and G == 0 and L == F) {
        const sphere_euler = iV - iE + iF;
        try testing.expectEqual(@as(i64, 2), sphere_euler);
    }

    // 2. Topological closure rule: Every half-edge has a twin: he.twin.twin == he
    const he_slice = solid.half_edges.slice();
    const origins = he_slice.items(.origin);
    const edges = he_slice.items(.edge);
    const twins = he_slice.items(.twin);
    const nexts = he_slice.items(.next);
    const prevs = he_slice.items(.prev);
    const loop_ids = he_slice.items(.loop);

    var i: usize = 0;
    while (i < solid.half_edges.len) : (i += 1) {
        const tw = twins[i];
        try testing.expect(tw != INVALID_ID);
        try testing.expect(tw < solid.half_edges.len);
        try testing.expect(tw != i); // Cannot be twin with itself

        try testing.expectEqual(@as(u32, @intCast(i)), twins[tw]); // he.twin.twin == he
    }

    // 3. Topological closure rule: Loop cycles close: he.next.prev == he and he.prev.next == he
    i = 0;
    while (i < solid.half_edges.len) : (i += 1) {
        const nxt = nexts[i];
        const prv = prevs[i];

        try testing.expect(nxt != INVALID_ID);
        try testing.expect(nxt < solid.half_edges.len);
        try testing.expect(prv != INVALID_ID);
        try testing.expect(prv < solid.half_edges.len);

        try testing.expectEqual(@as(u32, @intCast(i)), prevs[nxt]); // he.next.prev == he
        try testing.expectEqual(@as(u32, @intCast(i)), nexts[prv]); // he.prev.next == he
    }

    // 4. Topological closure rule: Every face loop is oriented and connected
    const l_slice = solid.loops.slice();
    const loop_hes = l_slice.items(.half_edge);

    for (0..solid.loops.len) |l_idx| {
        const start_he = loop_hes[l_idx];
        try testing.expect(start_he != INVALID_ID);
        try testing.expect(start_he < solid.half_edges.len);

        var curr_he = start_he;
        var step_count: usize = 0;
        const max_steps = solid.half_edges.len + 1;

        while (true) {
            try testing.expectEqual(@as(u32, @intCast(l_idx)), loop_ids[curr_he]);

            const nxt = nexts[curr_he];
            // Connectedness: current half-edge target (which is twin's origin) matches next half-edge origin
            const tw = twins[curr_he];
            const curr_target = origins[tw];
            const next_origin = origins[nxt];
            try testing.expectEqual(curr_target, next_origin);

            step_count += 1;
            try testing.expect(step_count <= max_steps);

            curr_he = nxt;
            if (curr_he == start_he) break;
        }

        try testing.expect(step_count >= 3);
    }

    // 5. Topological closure rule: Every edge has 2 distinct half-edges with opposite orientations
    const e_slice = solid.edges.slice();
    const edge_hes = e_slice.items(.half_edge);

    for (0..solid.edges.len) |e_idx| {
        const he1 = edge_hes[e_idx];
        try testing.expect(he1 != INVALID_ID);
        try testing.expect(he1 < solid.half_edges.len);
        try testing.expectEqual(@as(u32, @intCast(e_idx)), edges[he1]);

        const he2 = twins[he1];
        try testing.expect(he2 != INVALID_ID);
        try testing.expect(he2 < solid.half_edges.len);
        try testing.expectEqual(@as(u32, @intCast(e_idx)), edges[he2]);

        try testing.expect(he1 != he2);

        // Opposite orientations along edge:
        // he1 goes origin(he1) -> origin(he2)
        // he2 goes origin(he2) -> origin(he1)
        const orig1 = origins[he1];
        const orig2 = origins[he2];
        try testing.expect(orig1 != orig2);
        try testing.expectEqual(orig1, origins[twins[he2]]);
        try testing.expectEqual(orig2, origins[twins[he1]]);

        // Half-edges must belong to distinct loops / face cycles
        try testing.expect(loop_ids[he1] != loop_ids[he2]);
    }
}

// ===========================================================================
// Parametric Solid Builders for B-Rep / Half-Edge Validation
// ===========================================================================

/// Build a 6-face, 12-edge, 8-vertex, 24-half-edge box solid with full topology and CadTopoIds
pub fn buildHalfEdgeBox(allocator: Allocator, dx: f32, dy: f32, dz: f32, feature_id: u16) !SoASolid {
    const pts = [_][2]f32{
        .{ 0, 0 },
        .{ dx, 0 },
        .{ dx, dy },
        .{ 0, dy },
    };
    return try buildHalfEdgeExtrudedPolygon(allocator, &pts, dz, feature_id);
}

/// Build a faceted cylinder solid with N segments, 2N vertices, 3N edges, N+2 faces, and full topology
pub fn buildHalfEdgeCylinder(allocator: Allocator, radius: f32, height: f32, segments: u32, feature_id: u16) !SoASolid {
    try testing.expect(segments >= 3);
    var pts = try allocator.alloc([2]f32, segments);
    defer allocator.free(pts);

    const pi = std.math.pi;
    for (0..segments) |i| {
        const theta = 2.0 * pi * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segments));
        pts[i] = .{ radius * @cos(theta), radius * @sin(theta) };
    }

    return try buildHalfEdgeExtrudedPolygon(allocator, pts, height, feature_id);
}

/// Build an extruded M-gon solid along +Z by height with full half-edge twin loops and CadTopoIds
pub fn buildHalfEdgeExtrudedPolygon(
    allocator: Allocator,
    profile_points: []const [2]f32,
    height: f32,
    feature_id: u16,
) !SoASolid {
    const M: u32 = @intCast(profile_points.len);
    try testing.expect(M >= 3);

    var solid = SoASolid.init();
    errdefer solid.deinit(allocator);

    const solid_id = try solid.addSolid(allocator, CadTopoId.init(feature_id, 0, 3, .Shell, 0, 0));
    const shell_id = try solid.addShell(allocator, solid_id, true, CadTopoId.init(feature_id, 0, 3, .Shell, 0, 0));
    solid.solids.slice().items(.shell)[solid_id] = shell_id;

    // 1. Add Vertices: M bottom (0..M-1) and M top (M..2M-1)
    for (profile_points, 0..) |pt, i| {
        const v_topo = CadTopoId.init(feature_id, @intCast(i + 1), 3, .Vertex, FLAG_BOTTOM_CAP, 0);
        _ = try solid.addVertex(allocator, Vec3.init(pt[0], pt[1], 0.0), v_topo);
    }
    for (profile_points, 0..) |pt, i| {
        const v_topo = CadTopoId.init(feature_id, @intCast(i + 1), 3, .Vertex, FLAG_TOP_CAP, 0);
        _ = try solid.addVertex(allocator, Vec3.init(pt[0], pt[1], height), v_topo);
    }

    // 2. Add Edges:
    // Bottom edges (0..M-1): connects bottom vertices i and (i+1)%M
    for (0..M) |i| {
        const e_topo = CadTopoId.init(feature_id, @intCast(i + 1), 3, .Edge, FLAG_BOTTOM_EDGE, 0);
        _ = try solid.addEdge(allocator, INVALID_ID, e_topo);
    }
    // Top edges (M..2M-1): connects top vertices M+i and M+(i+1)%M
    for (0..M) |i| {
        const e_topo = CadTopoId.init(feature_id, @intCast(i + 1), 3, .Edge, FLAG_TOP_EDGE, 0);
        _ = try solid.addEdge(allocator, INVALID_ID, e_topo);
    }
    // Lateral vertical edges (2M..3M-1): connects bottom i and top M+i
    for (0..M) |i| {
        const e_topo = CadTopoId.init(feature_id, @intCast(i + 1), 3, .Edge, FLAG_PILLAR_EDGE, 0);
        _ = try solid.addEdge(allocator, INVALID_ID, e_topo);
    }

    // 3. Add Faces:
    // Face 0: Bottom face (normal: 0, 0, -1)
    const bot_face_id = try solid.addFace(
        allocator,
        shell_id,
        Vec3.init(0, 0, -1),
        .Plane,
        CadTopoId.init(feature_id, 0, 3, .Face, FLAG_BOTTOM_CAP, 0),
    );
    const bot_loop_id = try solid.addLoop(
        allocator,
        bot_face_id,
        true,
        CadTopoId.init(feature_id, 0, 3, .Face, FLAG_BOTTOM_CAP, 0),
    );
    solid.faces.slice().items(.outer_loop)[bot_face_id] = bot_loop_id;

    // Face 1: Top face (normal: 0, 0, 1)
    const top_face_id = try solid.addFace(
        allocator,
        shell_id,
        Vec3.init(0, 0, 1),
        .Plane,
        CadTopoId.init(feature_id, 0, 3, .Face, FLAG_TOP_CAP, 0),
    );
    const top_loop_id = try solid.addLoop(
        allocator,
        top_face_id,
        true,
        CadTopoId.init(feature_id, 0, 3, .Face, FLAG_TOP_CAP, 0),
    );
    solid.faces.slice().items(.outer_loop)[top_face_id] = top_loop_id;

    // Lateral Faces (2 .. M+1)
    var lat_face_ids = try allocator.alloc(FaceId, M);
    defer allocator.free(lat_face_ids);
    var lat_loop_ids = try allocator.alloc(LoopId, M);
    defer allocator.free(lat_loop_ids);

    for (0..M) |i| {
        const p0 = profile_points[i];
        const p1 = profile_points[(i + 1) % M];
        const dx = p1[0] - p0[0];
        const dy = p1[1] - p0[1];
        const lat_normal = Vec3.init(dy, -dx, 0).normalize();

        const lat_f_topo = CadTopoId.init(feature_id, @intCast(i + 1), 3, .Face, FLAG_LATERAL, 0);
        const fid = try solid.addFace(allocator, shell_id, lat_normal, .Plane, lat_f_topo);
        const lid = try solid.addLoop(allocator, fid, true, lat_f_topo);
        solid.faces.slice().items(.outer_loop)[fid] = lid;
        lat_face_ids[i] = fid;
        lat_loop_ids[i] = lid;
    }

    // 4. Create Half-Edges:
    // A) Bottom face loop half-edges: directs (i+1)%M -> i (clockwise viewed from above)
    var bot_hes = try allocator.alloc(HalfEdgeId, M);
    defer allocator.free(bot_hes);
    for (0..M) |i| {
        const orig: VertexId = @intCast((i + 1) % M);
        const he_id = try solid.addHalfEdge(
            allocator,
            orig,
            bot_loop_id,
            CadTopoId.init(feature_id, @intCast(i + 1), 3, .Edge, FLAG_BOTTOM_EDGE, 0),
        );
        bot_hes[i] = he_id;
    }
    solid.loops.slice().items(.half_edge)[bot_loop_id] = bot_hes[0];
    for (0..M) |i| {
        // In clockwise order, after edge i (from i+1 to i), next is edge (i - 1 + M) % M (from i to i-1)
        const next_idx = (i + M - 1) % M;
        solid.setNextPrev(bot_hes[i], bot_hes[next_idx]);
    }

    // B) Top face loop half-edges: directs M+i -> M+(i+1)%M (counter-clockwise)
    var top_hes = try allocator.alloc(HalfEdgeId, M);
    defer allocator.free(top_hes);
    for (0..M) |i| {
        const orig: VertexId = @intCast(M + i);
        const he_id = try solid.addHalfEdge(
            allocator,
            orig,
            top_loop_id,
            CadTopoId.init(feature_id, @intCast(i + 1), 3, .Edge, FLAG_TOP_EDGE, 0),
        );
        top_hes[i] = he_id;
    }
    solid.loops.slice().items(.half_edge)[top_loop_id] = top_hes[0];
    for (0..M) |i| {
        const next_idx = (i + 1) % M;
        solid.setNextPrev(top_hes[i], top_hes[next_idx]);
    }

    // C) Lateral quad faces half-edges:
    // For lateral face i:
    // he_lat_bot: i -> (i+1)%M (twin of bot_hes[i])
    // he_lat_right: (i+1)%M -> M+(i+1)%M (vertical pillar (i+1)%M)
    // he_lat_top: M+(i+1)%M -> M+i (twin of top_hes[i])
    // he_lat_left: M+i -> i (vertical pillar i)
    var lat_bot_hes = try allocator.alloc(HalfEdgeId, M);
    defer allocator.free(lat_bot_hes);
    var lat_top_hes = try allocator.alloc(HalfEdgeId, M);
    defer allocator.free(lat_top_hes);
    var lat_right_hes = try allocator.alloc(HalfEdgeId, M);
    defer allocator.free(lat_right_hes);
    var lat_left_hes = try allocator.alloc(HalfEdgeId, M);
    defer allocator.free(lat_left_hes);

    for (0..M) |i| {
        const lid = lat_loop_ids[i];
        const v_bot_start: VertexId = @intCast(i);
        const v_bot_end: VertexId = @intCast((i + 1) % M);
        const v_top_end: VertexId = @intCast(M + (i + 1) % M);
        const v_top_start: VertexId = @intCast(M + i);

        const h_bot = try solid.addHalfEdge(
            allocator,
            v_bot_start,
            lid,
            CadTopoId.init(feature_id, @intCast(i + 1), 3, .Edge, FLAG_BOTTOM_EDGE, 0),
        );
        const h_right = try solid.addHalfEdge(
            allocator,
            v_bot_end,
            lid,
            CadTopoId.init(feature_id, @intCast((i + 1) % M + 1), 3, .Edge, FLAG_PILLAR_EDGE, 0),
        );
        const h_top = try solid.addHalfEdge(
            allocator,
            v_top_end,
            lid,
            CadTopoId.init(feature_id, @intCast(i + 1), 3, .Edge, FLAG_TOP_EDGE, 0),
        );
        const h_left = try solid.addHalfEdge(
            allocator,
            v_top_start,
            lid,
            CadTopoId.init(feature_id, @intCast(i + 1), 3, .Edge, FLAG_PILLAR_EDGE, 0),
        );

        lat_bot_hes[i] = h_bot;
        lat_right_hes[i] = h_right;
        lat_top_hes[i] = h_top;
        lat_left_hes[i] = h_left;

        solid.loops.slice().items(.half_edge)[lid] = h_bot;
        solid.setNextPrev(h_bot, h_right);
        solid.setNextPrev(h_right, h_top);
        solid.setNextPrev(h_top, h_left);
        solid.setNextPrev(h_left, h_bot);
    }

    // 5. Connect Twins and assign Edge IDs:
    for (0..M) |i| {
        // Bottom edge i: twins are bot_hes[i] and lat_bot_hes[i]
        const e_bot: EdgeId = @intCast(i);
        solid.setTwins(bot_hes[i], lat_bot_hes[i], e_bot);

        // Top edge i: twins are top_hes[i] and lat_top_hes[i]
        const e_top: EdgeId = @intCast(M + i);
        solid.setTwins(top_hes[i], lat_top_hes[i], e_top);

        // Vertical pillar edge i:
        // left half-edge of face i (going M+i -> i) and right half-edge of face (i-1+M)%M (going i -> M+i)
        const e_pillar: EdgeId = @intCast(2 * M + i);
        const prev_face_idx = (i + M - 1) % M;
        solid.setTwins(lat_left_hes[i], lat_right_hes[prev_face_idx], e_pillar);
    }

    solid.updateMetrics();
    return solid;
}

/// Build a hollow extruded solid (outer M1 polygon, inner M2 polygon through-hole)
/// Genus G = 1, Shells S = 1, Loops L = M1 + M2 + 4, Faces F = M1 + M2 + 2
/// Tests generalized formula: V - E + F - (L - F) - 2(S - G) = 0
pub fn buildHalfEdgeHollowExtrusion(
    allocator: Allocator,
    outer_poly: []const [2]f32,
    inner_poly: []const [2]f32,
    height: f32,
    feature_id: u16,
) !SoASolid {
    const M1: u32 = @intCast(outer_poly.len);
    const M2: u32 = @intCast(inner_poly.len);
    try testing.expect(M1 >= 3 and M2 >= 3);

    var solid = SoASolid.init();
    errdefer solid.deinit(allocator);

    const solid_id = try solid.addSolid(allocator, CadTopoId.init(feature_id, 0, 3, .Shell, 0, 0));
    const shell_id = try solid.addShell(allocator, solid_id, true, CadTopoId.init(feature_id, 0, 3, .Shell, 0, 0));
    solid.solids.slice().items(.shell)[solid_id] = shell_id;

    // Outer vertices: 0..M1-1 (bottom), M1..2M1-1 (top)
    // Inner vertices: 2M1..2M1+M2-1 (bottom), 2M1+M2..2M1+2M2-1 (top)
    for (outer_poly, 0..) |pt, i| {
        _ = try solid.addVertex(allocator, Vec3.init(pt[0], pt[1], 0.0), CadTopoId.init(feature_id, @intCast(i + 1), 3, .Vertex, 0, 0));
    }
    for (outer_poly, 0..) |pt, i| {
        _ = try solid.addVertex(allocator, Vec3.init(pt[0], pt[1], height), CadTopoId.init(feature_id, @intCast(i + 1), 3, .Vertex, 0, 0));
    }
    for (inner_poly, 0..) |pt, i| {
        _ = try solid.addVertex(allocator, Vec3.init(pt[0], pt[1], 0.0), CadTopoId.init(feature_id, @intCast(100 + i + 1), 3, .Vertex, 0, 0));
    }
    for (inner_poly, 0..) |pt, i| {
        _ = try solid.addVertex(allocator, Vec3.init(pt[0], pt[1], height), CadTopoId.init(feature_id, @intCast(100 + i + 1), 3, .Vertex, 0, 0));
    }

    // Edges: 3 * (M1 + M2) edges
    for (0..3 * (M1 + M2)) |i| {
        _ = try solid.addEdge(allocator, INVALID_ID, CadTopoId.init(feature_id, @intCast(i + 1), 3, .Edge, 0, 0));
    }

    // Faces:
    // Face 0: Bottom face with 2 loops (outer + inner hole)
    const bot_fid = try solid.addFace(allocator, shell_id, Vec3.init(0, 0, -1), .Plane, CadTopoId.init(feature_id, 0, 3, .Face, FLAG_BOTTOM_CAP, 0));
    const bot_loop_outer = try solid.addLoop(allocator, bot_fid, true, CadTopoId.init(feature_id, 0, 3, .Face, FLAG_BOTTOM_CAP, 0));
    const bot_loop_inner = try solid.addLoop(allocator, bot_fid, false, CadTopoId.init(feature_id, 0, 3, .Face, FLAG_BOTTOM_CAP, 0));
    solid.faces.slice().items(.outer_loop)[bot_fid] = bot_loop_outer;

    // Face 1: Top face with 2 loops (outer + inner hole)
    const top_fid = try solid.addFace(allocator, shell_id, Vec3.init(0, 0, 1), .Plane, CadTopoId.init(feature_id, 0, 3, .Face, FLAG_TOP_CAP, 0));
    const top_loop_outer = try solid.addLoop(allocator, top_fid, true, CadTopoId.init(feature_id, 0, 3, .Face, FLAG_TOP_CAP, 0));
    const top_loop_inner = try solid.addLoop(allocator, top_fid, false, CadTopoId.init(feature_id, 0, 3, .Face, FLAG_TOP_CAP, 0));
    solid.faces.slice().items(.outer_loop)[top_fid] = top_loop_outer;

    // M1 outer lateral faces + M2 inner lateral faces
    var lat_fids = try allocator.alloc(FaceId, M1 + M2);
    defer allocator.free(lat_fids);
    var lat_lids = try allocator.alloc(LoopId, M1 + M2);
    defer allocator.free(lat_lids);

    for (0..(M1 + M2)) |i| {
        const fid = try solid.addFace(allocator, shell_id, Vec3.init(1, 0, 0), .Plane, CadTopoId.init(feature_id, @intCast(i + 1), 3, .Face, FLAG_LATERAL, 0));
        const lid = try solid.addLoop(allocator, fid, true, CadTopoId.init(feature_id, @intCast(i + 1), 3, .Face, FLAG_LATERAL, 0));
        solid.faces.slice().items(.outer_loop)[fid] = lid;
        lat_fids[i] = fid;
        lat_lids[i] = lid;
    }

    // Outer Bottom Loop (Clockwise)
    var out_bot_hes = try allocator.alloc(HalfEdgeId, M1);
    defer allocator.free(out_bot_hes);
    for (0..M1) |i| {
        out_bot_hes[i] = try solid.addHalfEdge(allocator, @intCast((i + 1) % M1), bot_loop_outer, CadTopoId.INVALID);
    }
    solid.loops.slice().items(.half_edge)[bot_loop_outer] = out_bot_hes[0];
    for (0..M1) |i| {
        solid.setNextPrev(out_bot_hes[i], out_bot_hes[(i + M1 - 1) % M1]);
    }

    // Outer Top Loop (CCW)
    var out_top_hes = try allocator.alloc(HalfEdgeId, M1);
    defer allocator.free(out_top_hes);
    for (0..M1) |i| {
        out_top_hes[i] = try solid.addHalfEdge(allocator, @intCast(M1 + i), top_loop_outer, CadTopoId.INVALID);
    }
    solid.loops.slice().items(.half_edge)[top_loop_outer] = out_top_hes[0];
    for (0..M1) |i| {
        solid.setNextPrev(out_top_hes[i], out_top_hes[(i + 1) % M1]);
    }

    // Inner Hole Bottom Loop (CCW for interior hole)
    const in_v_bot_offset = 2 * M1;
    var in_bot_hes = try allocator.alloc(HalfEdgeId, M2);
    defer allocator.free(in_bot_hes);
    for (0..M2) |i| {
        in_bot_hes[i] = try solid.addHalfEdge(allocator, @intCast(in_v_bot_offset + i), bot_loop_inner, CadTopoId.INVALID);
    }
    solid.loops.slice().items(.half_edge)[bot_loop_inner] = in_bot_hes[0];
    for (0..M2) |i| {
        solid.setNextPrev(in_bot_hes[i], in_bot_hes[(i + 1) % M2]);
    }

    // Inner Hole Top Loop (Clockwise for interior hole)
    const in_v_top_offset = 2 * M1 + M2;
    var in_top_hes = try allocator.alloc(HalfEdgeId, M2);
    defer allocator.free(in_top_hes);
    for (0..M2) |i| {
        in_top_hes[i] = try solid.addHalfEdge(allocator, @intCast(in_v_top_offset + (i + 1) % M2), top_loop_inner, CadTopoId.INVALID);
    }
    solid.loops.slice().items(.half_edge)[top_loop_inner] = in_top_hes[0];
    for (0..M2) |i| {
        solid.setNextPrev(in_top_hes[i], in_top_hes[(i + M2 - 1) % M2]);
    }

    // Outer lateral quads
    for (0..M1) |i| {
        const lid = lat_lids[i];
        const v_b0: VertexId = @intCast(i);
        const v_b1: VertexId = @intCast((i + 1) % M1);
        const v_t1: VertexId = @intCast(M1 + (i + 1) % M1);
        const v_t0: VertexId = @intCast(M1 + i);

        const h_bot = try solid.addHalfEdge(allocator, v_b0, lid, CadTopoId.INVALID);
        const h_right = try solid.addHalfEdge(allocator, v_b1, lid, CadTopoId.INVALID);
        const h_top = try solid.addHalfEdge(allocator, v_t1, lid, CadTopoId.INVALID);
        const h_left = try solid.addHalfEdge(allocator, v_t0, lid, CadTopoId.INVALID);

        solid.loops.slice().items(.half_edge)[lid] = h_bot;
        solid.setNextPrev(h_bot, h_right);
        solid.setNextPrev(h_right, h_top);
        solid.setNextPrev(h_top, h_left);
        solid.setNextPrev(h_left, h_bot);

        // Twins
        solid.setTwins(out_bot_hes[i], h_bot, @intCast(i));
        solid.setTwins(out_top_hes[i], h_top, @intCast(M1 + i));
    }
    // Outer pillars
    for (0..M1) |i| {
        const next_face = (i + 1) % M1;
        // right of face i is twin of left of face (i+1)%M1
        const h_right = solid.half_edges.slice().items(.next)[solid.loops.slice().items(.half_edge)[lat_lids[i]]];
        const h_next_left = solid.half_edges.slice().items(.prev)[solid.loops.slice().items(.half_edge)[lat_lids[next_face]]];
        solid.setTwins(h_right, h_next_left, @intCast(2 * M1 + (i + 1) % M1));
    }

    // Inner lateral quads
    const in_e_bot_offset = 3 * M1;
    const in_e_top_offset = 3 * M1 + M2;
    const in_e_pillar_offset = 3 * M1 + 2 * M2;
    for (0..M2) |i| {
        const lid = lat_lids[M1 + i];
        const v_b0: VertexId = @intCast(in_v_bot_offset + (i + 1) % M2);
        const v_b1: VertexId = @intCast(in_v_bot_offset + i);
        const v_t1: VertexId = @intCast(in_v_top_offset + i);
        const v_t0: VertexId = @intCast(in_v_top_offset + (i + 1) % M2);

        const h_bot = try solid.addHalfEdge(allocator, v_b0, lid, CadTopoId.INVALID);
        const h_right = try solid.addHalfEdge(allocator, v_b1, lid, CadTopoId.INVALID);
        const h_top = try solid.addHalfEdge(allocator, v_t1, lid, CadTopoId.INVALID);
        const h_left = try solid.addHalfEdge(allocator, v_t0, lid, CadTopoId.INVALID);

        solid.loops.slice().items(.half_edge)[lid] = h_bot;
        solid.setNextPrev(h_bot, h_right);
        solid.setNextPrev(h_right, h_top);
        solid.setNextPrev(h_top, h_left);
        solid.setNextPrev(h_left, h_bot);

        // Twins
        solid.setTwins(in_bot_hes[i], h_bot, @intCast(in_e_bot_offset + i));
        solid.setTwins(in_top_hes[i], h_top, @intCast(in_e_top_offset + i));
    }
    // Inner pillars
    for (0..M2) |i| {
        const curr_lid = lat_lids[M1 + i];
        const next_lid = lat_lids[M1 + (i + M2 - 1) % M2];
        const h_right = solid.half_edges.slice().items(.next)[solid.loops.slice().items(.half_edge)[curr_lid]];
        const h_next_left = solid.half_edges.slice().items(.prev)[solid.loops.slice().items(.half_edge)[next_lid]];
        solid.setTwins(h_right, h_next_left, @intCast(in_e_pillar_offset + i));
    }

    return solid;
}

// ===========================================================================
// Persistent Topological Naming (TNP) Resolver
// ===========================================================================

pub const CadTopoResolver = struct {
    pub fn findEdge(solid: *const SoASolid, target: CadTopoId) ?EdgeId {
        const e_slice = solid.edges.slice();
        const topos = e_slice.items(.topo_id);

        for (topos, 0..) |t, idx| {
            if (t.fields.origin_feature_id == target.fields.origin_feature_id and
                t.fields.source_sketch_entity_id == target.fields.source_sketch_entity_id and
                t.fields.subshape_type == target.fields.subshape_type and
                t.fields.flags == target.fields.flags)
            {
                return @intCast(idx);
            }
        }
        return null;
    }

    pub fn findFace(solid: *const SoASolid, target: CadTopoId) ?FaceId {
        const f_slice = solid.faces.slice();
        const topos = f_slice.items(.topo_id);

        for (topos, 0..) |t, idx| {
            if (t.fields.origin_feature_id == target.fields.origin_feature_id and
                t.fields.source_sketch_entity_id == target.fields.source_sketch_entity_id and
                t.fields.subshape_type == target.fields.subshape_type and
                t.fields.flags == target.fields.flags)
            {
                return @intCast(idx);
            }
        }
        return null;
    }

    pub fn getEdgeEndpoints(solid: *const SoASolid, edge_id: EdgeId) struct { p0: Vec3, p1: Vec3 } {
        const he1 = solid.edges.slice().items(.half_edge)[edge_id];
        const he2 = solid.half_edges.slice().items(.twin)[he1];
        const v0 = solid.half_edges.slice().items(.origin)[he1];
        const v1 = solid.half_edges.slice().items(.origin)[he2];
        const pts = solid.vertices.slice().items(.point);
        return .{ .p0 = pts[v0], .p1 = pts[v1] };
    }
};

// ===========================================================================
// Unit Tests: Euler-Poincaré Manifold & Closure Validator
// ===========================================================================

test "Topological Invariant: Box solid Euler-Poincare and closure rules" {
    const allocator = testing.allocator;

    var b = try buildHalfEdgeBox(allocator, 15.0, 25.0, 35.0, 101);
    defer b.deinit(allocator);

    // V=8, E=12, F=6, L=6, S=1, G=0
    try testing.expectEqual(@as(usize, 8), b.vertices.len);
    try testing.expectEqual(@as(usize, 12), b.edges.len);
    try testing.expectEqual(@as(usize, 6), b.faces.len);
    try testing.expectEqual(@as(usize, 6), b.loops.len);
    try testing.expectEqual(@as(usize, 24), b.half_edges.len);

    // Validates V - E + F = 2 and all 4 closure rules
    try validateManifoldInvariants(&b, 0);

    // Volume check: 15 * 25 * 35 = 13125.0
    try testing.expectApproxEqAbs(@as(f32, 13125.0), b.volume, 1e-2);
}

test "Topological Invariant: Cylinder solid Euler-Poincare and closure rules" {
    const allocator = testing.allocator;

    // Faceted cylinder with 32 segments
    const segments: u32 = 32;
    var cyl = try buildHalfEdgeCylinder(allocator, 5.0, 20.0, segments, 102);
    defer cyl.deinit(allocator);

    // V=64, E=96, F=34, L=34, S=1, G=0
    try testing.expectEqual(@as(usize, 2 * segments), cyl.vertices.len);
    try testing.expectEqual(@as(usize, 3 * segments), cyl.edges.len);
    try testing.expectEqual(@as(usize, segments + 2), cyl.faces.len);
    try testing.expectEqual(@as(usize, 6 * segments), cyl.half_edges.len);

    // V - E + F = 64 - 96 + 34 = 2
    try validateManifoldInvariants(&cyl, 0);

    // Cross-validate analytical cylinder from primitive module satisfies Euler invariant
    var occ_cyl = try cylinder.createCylinder(allocator, 1, 5.0, 20.0);
    defer occ_cyl.deinit(allocator);
    const stats = occ_cyl.getStats();
    try testing.expectEqual(@as(i32, 2), stats.euler_characteristic);
}

test "Topological Invariant: Extruded polygonal solid Euler-Poincare and closure rules" {
    const allocator = testing.allocator;

    // 5-point non-regular polygon profile
    const profile = [_][2]f32{
        .{ 0.0, 0.0 },
        .{ 12.0, 2.0 },
        .{ 18.0, 15.0 },
        .{ 8.0, 22.0 },
        .{ -2.0, 10.0 },
    };

    var ext = try buildHalfEdgeExtrudedPolygon(allocator, &profile, 30.0, 103);
    defer ext.deinit(allocator);

    // V=10, E=15, F=7, L=7, S=1, G=0
    try testing.expectEqual(@as(usize, 10), ext.vertices.len);
    try testing.expectEqual(@as(usize, 15), ext.edges.len);
    try testing.expectEqual(@as(usize, 7), ext.faces.len);

    try validateManifoldInvariants(&ext, 0);
}

test "Topological Invariant: Hollow Extruded solid Generalized Euler-Poincare with holes (G=1)" {
    const allocator = testing.allocator;

    // Outer square: 40 x 40
    const outer = [_][2]f32{
        .{ -20.0, -20.0 },
        .{ 20.0, -20.0 },
        .{ 20.0, 20.0 },
        .{ -20.0, 20.0 },
    };
    // Inner square hole: 16 x 16
    const inner = [_][2]f32{
        .{ -8.0, -8.0 },
        .{ 8.0, -8.0 },
        .{ 8.0, 8.0 },
        .{ -8.0, 8.0 },
    };

    var hollow = try buildHalfEdgeHollowExtrusion(allocator, &outer, &inner, 25.0, 104);
    defer hollow.deinit(allocator);

    // V = 2*(4+4) = 16
    // E = 3*(4+4) = 24
    // F = 4+4+2 = 10
    // L = 4+4+4 = 12 (Bottom has 2 loops, Top has 2 loops, 8 lateral faces)
    // S = 1, G = 1 (through-hole torus topology)
    try testing.expectEqual(@as(usize, 16), hollow.vertices.len);
    try testing.expectEqual(@as(usize, 24), hollow.edges.len);
    try testing.expectEqual(@as(usize, 10), hollow.faces.len);
    try testing.expectEqual(@as(usize, 12), hollow.loops.len);

    // Generalized formula: V - E + F - (L - F) - 2(S - G) = 16 - 24 + 10 - 2 - 0 = 0!
    try validateManifoldInvariants(&hollow, 1);
}

// ===========================================================================
// Unit Tests: Topological Naming Persistence (TNP) & Stress Fuzzing
// ===========================================================================

test "Topological Naming Persistence: Parametric sketch modification & resolver stability" {
    const allocator = testing.allocator;
    const extrude_feature_id: u16 = 200;

    // Step 1: Initial 2D rectangular sketch (4 vertices, 4 lines)
    // Line 1: (0,0) -> (40,0)
    // Line 2: (40,0) -> (40,20)  <-- Target line
    // Line 3: (40,20) -> (0,20)
    // Line 4: (0,20) -> (0,0)
    var sketch_v1 = std.ArrayList([2]f32).empty;
    defer sketch_v1.deinit(allocator);
    try sketch_v1.append(allocator, .{ 0.0, 0.0 });
    try sketch_v1.append(allocator, .{ 40.0, 0.0 });
    try sketch_v1.append(allocator, .{ 40.0, 20.0 });
    try sketch_v1.append(allocator, .{ 0.0, 20.0 });

    // Step 2: Extrude to solid (height = 15)
    var solid_v1 = try buildHalfEdgeExtrudedPolygon(allocator, sketch_v1.items, 15.0, extrude_feature_id);
    defer solid_v1.deinit(allocator);

    // Step 3: Identify target top edge CadTopoId (edge between TopFace and LateralFace 2)
    // In our indexing, Line 2 is sketch entity ID = 2
    const target_edge_topo = CadTopoId.init(extrude_feature_id, 2, 3, .Edge, FLAG_TOP_EDGE, 0);

    const edge_idx_v1 = CadTopoResolver.findEdge(&solid_v1, target_edge_topo);
    try testing.expect(edge_idx_v1 != null);
    const endpoints_v1 = CadTopoResolver.getEdgeEndpoints(&solid_v1, edge_idx_v1.?);
    try testing.expectApproxEqAbs(@as(f32, 40.0), endpoints_v1.p0.x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0.0), endpoints_v1.p0.y, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 15.0), endpoints_v1.p0.z, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 40.0), endpoints_v1.p1.x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 20.0), endpoints_v1.p1.y, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 15.0), endpoints_v1.p1.z, 1e-4);

    // Step 4: Upstream mutation A: Move vertex 3 from (0,20) to (-10, 25)
    var sketch_v2 = std.ArrayList([2]f32).empty;
    defer sketch_v2.deinit(allocator);
    try sketch_v2.append(allocator, .{ 0.0, 0.0 });
    try sketch_v2.append(allocator, .{ 40.0, 0.0 });
    try sketch_v2.append(allocator, .{ 40.0, 20.0 });
    try sketch_v2.append(allocator, .{ -10.0, 25.0 });

    // Step 5: Re-evaluate DAG
    var solid_v2 = try buildHalfEdgeExtrudedPolygon(allocator, sketch_v2.items, 15.0, extrude_feature_id);
    defer solid_v2.deinit(allocator);

    // Step 6: Verify persistent resolver maps target edge reliably
    const edge_idx_v2 = CadTopoResolver.findEdge(&solid_v2, target_edge_topo);
    try testing.expect(edge_idx_v2 != null);
    const endpoints_v2 = CadTopoResolver.getEdgeEndpoints(&solid_v2, edge_idx_v2.?);
    // Line 2 endpoints did not change, even though upstream vertex 3 moved!
    try testing.expectApproxEqAbs(@as(f32, 40.0), endpoints_v2.p0.x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 20.0), endpoints_v2.p1.y, 1e-4);
    try validateManifoldInvariants(&solid_v2, 0);

    // Step 7: Upstream mutation B: Insert an intermediate vertex on Line 4 (splitting into 5-gon)
    var sketch_v3 = std.ArrayList([2]f32).empty;
    defer sketch_v3.deinit(allocator);
    try sketch_v3.append(allocator, .{ 0.0, 0.0 });
    try sketch_v3.append(allocator, .{ 40.0, 0.0 });
    try sketch_v3.append(allocator, .{ 40.0, 20.0 });
    try sketch_v3.append(allocator, .{ -10.0, 25.0 });
    try sketch_v3.append(allocator, .{ -5.0, 8.0 }); // Intermediate vertex inserted

    var solid_v3 = try buildHalfEdgeExtrudedPolygon(allocator, sketch_v3.items, 15.0, extrude_feature_id);
    defer solid_v3.deinit(allocator);

    // Solid now has 5 lateral faces, 7 faces, 15 edges, 10 vertices
    try testing.expectEqual(@as(usize, 10), solid_v3.vertices.len);
    try testing.expectEqual(@as(usize, 15), solid_v3.edges.len);
    try testing.expectEqual(@as(usize, 7), solid_v3.faces.len);

    // Target edge CadTopoId still resolves reliably without broken downstream naming!
    const edge_idx_v3 = CadTopoResolver.findEdge(&solid_v3, target_edge_topo);
    try testing.expect(edge_idx_v3 != null);
    try validateManifoldInvariants(&solid_v3, 0);
}

test "Topological Naming Persistence: 20-step sequential parametric history fuzzing test" {
    const allocator = testing.allocator;
    const feat_id: u16 = 300;
    const target_edge_topo = CadTopoId.init(feat_id, 2, 3, .Edge, FLAG_TOP_EDGE, 0);

    var rng = std.Random.DefaultPrng.init(0xCAFEBABE);
    const rand = rng.random();

    // Base sketch profile points
    var base_points = std.ArrayList([2]f32).empty;
    defer base_points.deinit(allocator);
    try base_points.append(allocator, .{ 0.0, 0.0 });
    try base_points.append(allocator, .{ 30.0, 0.0 });
    try base_points.append(allocator, .{ 30.0, 15.0 });
    try base_points.append(allocator, .{ 0.0, 15.0 });

    const total_steps: usize = 20;
    var step: usize = 0;

    while (step < total_steps) : (step += 1) {
        var current_points = std.ArrayList([2]f32).empty;
        defer current_points.deinit(allocator);

        // Copy base points
        for (base_points.items) |p| {
            try current_points.append(allocator, p);
        }

        // Apply mutation based on step
        const mut_kind = step % 4;
        var ext_height: f32 = 10.0 + @as(f32, @floatFromInt(step)) * 1.5;

        if (mut_kind == 0) {
            // Translate / wiggle non-target vertices (vertices 0 and 3)
            const dx = (rand.float(f32) - 0.5) * 4.0;
            const dy = (rand.float(f32) - 0.5) * 4.0;
            current_points.items[3][0] += dx;
            current_points.items[3][1] += dy;
        } else if (mut_kind == 1) {
            // Scale geometry along X and Y
            const scale_x = 1.0 + rand.float(f32) * 0.5;
            const scale_y = 1.0 + rand.float(f32) * 0.5;
            for (current_points.items) |*p| {
                p[0] *= scale_x;
                p[1] *= scale_y;
            }
        } else if (mut_kind == 2) {
            // Insert intermediate vertex on edge 4
            const p3 = current_points.items[3];
            const p0 = current_points.items[0];
            const mid_x = (p3[0] + p0[0]) * 0.5 - 5.0;
            const mid_y = (p3[1] + p0[1]) * 0.5;
            try current_points.append(allocator, .{ mid_x, mid_y });
        } else {
            // Vary extrusion height drastically
            ext_height = 5.0 + rand.float(f32) * 40.0;
        }

        // Re-evaluate DAG solid
        var solid = try buildHalfEdgeExtrudedPolygon(allocator, current_points.items, ext_height, feat_id);
        defer solid.deinit(allocator);

        // 1. Target topological naming resolver MUST find target edge unambiguously
        const resolved_idx = CadTopoResolver.findEdge(&solid, target_edge_topo);
        try testing.expect(resolved_idx != null);

        // 2. Verified edge endpoints must correspond to Line 2 (endpoints p0 and p1 at z = ext_height)
        const endpoints = CadTopoResolver.getEdgeEndpoints(&solid, resolved_idx.?);
        try testing.expectApproxEqAbs(ext_height, endpoints.p0.z, 1e-4);
        try testing.expectApproxEqAbs(ext_height, endpoints.p1.z, 1e-4);

        // 3. Manifold invariant must strictly hold across all mutations: V - E + F = 2
        try validateManifoldInvariants(&solid, 0);

        // 4. Volume must be strictly positive
        try testing.expect(solid.volume > 0.0);
    }
}
