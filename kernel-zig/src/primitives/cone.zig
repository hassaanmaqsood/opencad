const std = @import("std");
const Allocator = std.mem.Allocator;
const Vec3 = @import("../math/vec3.zig").Vec3;
const topo = @import("../topo/mod.zig");
const topology = @import("../brep/topology.zig");

const SoASolid = topo.SoASolid;
const CadTopoId = topo.CadTopoId;
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
const hashFace = topo_naming.hashFace;

pub const ConeError = error{
    InvalidRadius,
    InvalidHeight,
    DegenerateMesh,
    OutOfMemory,
    ManifoldValidationFailed,
};

/// Constructs a watertight 2-manifold B-Rep cone or truncated cone frustum.
/// Supports both r_top > 0 (frustum) and r_top == 0 (sharp apex cone).
pub fn createCone(
    allocator: Allocator,
    feature_id: u16,
    r_base: f32,
    r_top: f32,
    height: f32,
    sectors_opt: ?u32,
) ConeError!SoASolid {
    if (r_base <= 1e-6 or r_top < 0.0) return error.InvalidRadius;
    if (height <= 1e-6) return error.InvalidHeight;
    const n_sectors = sectors_opt orelse 16;
    if (n_sectors < 3) return error.DegenerateMesh;

    var solid = SoASolid.init();
    errdefer solid.deinit(allocator);

    const solid_topo = CadTopoId.init(feature_id, 0, 1, .Shell, 0, 0);
    const solid_id = solid.addSolid(allocator, solid_topo) catch return error.OutOfMemory;
    const shell_id = solid.addShell(allocator, solid_id, true, solid_topo) catch return error.OutOfMemory;

    // 1. Base vertices at z = 0
    const bot_v = try allocator.alloc(VertexId, n_sectors);
    defer allocator.free(bot_v);

    for (0..n_sectors) |s| {
        const theta = @as(f32, @floatFromInt(s)) * (2.0 * std.math.pi / @as(f32, @floatFromInt(n_sectors)));
        const pt = Vec3.init(r_base * @cos(theta), r_base * @sin(theta), 0.0);
        const v_topo = CadTopoId.init(feature_id, @intCast(s), 1, .Vertex, FLAG_CAP_BOTTOM, hashPoint(pt));
        bot_v[s] = solid.addVertex(allocator, pt, v_topo) catch return error.OutOfMemory;
    }

    const has_top_cap = (r_top > 1e-6);

    // 2. Top vertices at z = height
    var top_v_opt: ?[]VertexId = null;
    var apex_v_opt: ?VertexId = null;

    if (has_top_cap) {
        const top_arr = try allocator.alloc(VertexId, n_sectors);
        for (0..n_sectors) |s| {
            const theta = @as(f32, @floatFromInt(s)) * (2.0 * std.math.pi / @as(f32, @floatFromInt(n_sectors)));
            const pt = Vec3.init(r_top * @cos(theta), r_top * @sin(theta), height);
            const v_topo = CadTopoId.init(feature_id, @intCast(n_sectors + s), 1, .Vertex, FLAG_CAP_TOP, hashPoint(pt));
            top_arr[s] = solid.addVertex(allocator, pt, v_topo) catch return error.OutOfMemory;
        }
        top_v_opt = top_arr;
    } else {
        const p_apex = Vec3.init(0.0, 0.0, height);
        const apex_topo = CadTopoId.init(feature_id, @intCast(n_sectors), 1, .Vertex, FLAG_CAP_TOP, hashPoint(p_apex));
        apex_v_opt = solid.addVertex(allocator, p_apex, apex_topo) catch return error.OutOfMemory;
    }
    defer if (top_v_opt) |tv| allocator.free(tv);

    // 3. Bottom Cap Face: (Normal: 0, 0, -1)
    // Winding order: bot_v[0], bot_v[N-1], bot_v[N-2], ...
    const bot_normal = Vec3.init(0, 0, -1);
    const bot_topo = CadTopoId.init(feature_id, 0, 1, .Face, FLAG_CAP_BOTTOM, hashFace(bot_normal, FLAG_CAP_BOTTOM));
    const bot_face = solid.addFace(allocator, shell_id, bot_normal, .Plane, bot_topo) catch return error.OutOfMemory;
    const bot_loop = solid.addLoop(allocator, bot_face, true, bot_topo) catch return error.OutOfMemory;
    solid.faces.slice().items(.outer_loop)[bot_face] = bot_loop;

    const bot_hes = try allocator.alloc(HalfEdgeId, n_sectors);
    defer allocator.free(bot_hes);

    for (0..n_sectors) |k| {
        const s = (n_sectors - k) % n_sectors;
        const origin = bot_v[s];
        const he_topo = CadTopoId.init(feature_id, @intCast(s), 1, .Edge, FLAG_CAP_BOTTOM, 0);
        bot_hes[k] = solid.addHalfEdge(allocator, origin, bot_loop, he_topo) catch return error.OutOfMemory;
    }
    for (0..n_sectors) |k| {
        const next_k = (k + 1) % n_sectors;
        solid.setNextPrev(bot_hes[k], bot_hes[next_k]);
    }
    solid.loops.slice().items(.half_edge)[bot_loop] = bot_hes[0];

    // 4. Top Cap Face (if frustum r_top > 0): (Normal: 0, 0, 1)
    var top_hes_opt: ?[]HalfEdgeId = null;
    if (top_v_opt) |top_v| {
        const top_normal = Vec3.init(0, 0, 1);
        const top_topo = CadTopoId.init(feature_id, 1, 1, .Face, FLAG_CAP_TOP, hashFace(top_normal, FLAG_CAP_TOP));
        const top_face = solid.addFace(allocator, shell_id, top_normal, .Plane, top_topo) catch return error.OutOfMemory;
        const top_loop = solid.addLoop(allocator, top_face, true, top_topo) catch return error.OutOfMemory;
        solid.faces.slice().items(.outer_loop)[top_face] = top_loop;

        const top_hes = try allocator.alloc(HalfEdgeId, n_sectors);
        for (0..n_sectors) |k| {
            const origin = top_v[k];
            const he_topo = CadTopoId.init(feature_id, @intCast(k), 1, .Edge, FLAG_CAP_TOP, 0);
            top_hes[k] = solid.addHalfEdge(allocator, origin, top_loop, he_topo) catch return error.OutOfMemory;
        }
        for (0..n_sectors) |k| {
            const next_k = (k + 1) % n_sectors;
            solid.setNextPrev(top_hes[k], top_hes[next_k]);
        }
        solid.loops.slice().items(.half_edge)[top_loop] = top_hes[0];
        top_hes_opt = top_hes;
    }
    defer if (top_hes_opt) |th| allocator.free(th);

    // 5. Lateral Faces & Slant Edges
    if (top_v_opt) |top_v| {
        // Frustum case: N quad lateral faces
        const lat_hes = try allocator.alloc([4]HalfEdgeId, n_sectors);
        defer allocator.free(lat_hes);

        for (0..n_sectors) |s| {
            const next_s = (s + 1) % n_sectors;
            const v0 = bot_v[s];
            const v1 = bot_v[next_s];
            const v2 = top_v[next_s];
            const v3 = top_v[s];

            const p0 = solid.vertices.slice().items(.point)[v0];
            const p1 = solid.vertices.slice().items(.point)[v1];
            const p3 = solid.vertices.slice().items(.point)[v3];
            const nrm = (p1.sub(p0)).cross(p3.sub(p0)).normalize();

            const lat_topo = CadTopoId.init(feature_id, @intCast(s), 1, .Face, FLAG_LATERAL, hashFace(nrm, FLAG_LATERAL));
            const lat_face = solid.addFace(allocator, shell_id, nrm, .Cone, lat_topo) catch return error.OutOfMemory;
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

            lat_hes[s] = .{ he0, he1, he2, he3 };
        }

        // Connect Bottom Edges & Twins:
        for (0..n_sectors) |s| {
            const next_s = (s + 1) % n_sectors;
            const bot_he_idx = (n_sectors - next_s) % n_sectors;
            const lat_he0 = lat_hes[s][0];
            const bot_he = bot_hes[bot_he_idx];

            const e_topo = CadTopoId.init(feature_id, @intCast(s), 1, .Edge, FLAG_CAP_BOTTOM, 0);
            const e_id = solid.addEdge(allocator, lat_he0, e_topo) catch return error.OutOfMemory;
            solid.setTwins(lat_he0, bot_he, e_id);
        }

        // Connect Top Edges & Twins:
        if (top_hes_opt) |top_hes| {
            for (0..n_sectors) |s| {
                const lat_he2 = lat_hes[s][2];
                const top_he = top_hes[s];

                const e_topo = CadTopoId.init(feature_id, @intCast(s), 1, .Edge, FLAG_CAP_TOP, 0);
                const e_id = solid.addEdge(allocator, top_he, e_topo) catch return error.OutOfMemory;
                solid.setTwins(top_he, lat_he2, e_id);
            }
        }

        // Connect Slant Edges & Twins:
        for (0..n_sectors) |s| {
            const prev_s = (s + n_sectors - 1) % n_sectors;
            const lat_he3 = lat_hes[s][3];
            const prev_he1 = lat_hes[prev_s][1];

            const e_topo = CadTopoId.init(feature_id, @intCast(s), 1, .Edge, FLAG_LATERAL, 0);
            const e_id = solid.addEdge(allocator, prev_he1, e_topo) catch return error.OutOfMemory;
            solid.setTwins(prev_he1, lat_he3, e_id);
        }
    } else {
        // Sharp Apex Cone case: N triangle lateral faces
        const apex = apex_v_opt.?;
        const lat_hes = try allocator.alloc([3]HalfEdgeId, n_sectors);
        defer allocator.free(lat_hes);

        for (0..n_sectors) |s| {
            const next_s = (s + 1) % n_sectors;
            const v0 = bot_v[s];
            const v1 = bot_v[next_s];
            const v2 = apex;

            const p0 = solid.vertices.slice().items(.point)[v0];
            const p1 = solid.vertices.slice().items(.point)[v1];
            const p2 = solid.vertices.slice().items(.point)[v2];
            const nrm = (p1.sub(p0)).cross(p2.sub(p0)).normalize();

            const lat_topo = CadTopoId.init(feature_id, @intCast(s), 1, .Face, FLAG_LATERAL, hashFace(nrm, FLAG_LATERAL));
            const lat_face = solid.addFace(allocator, shell_id, nrm, .Cone, lat_topo) catch return error.OutOfMemory;
            const lat_loop = solid.addLoop(allocator, lat_face, true, lat_topo) catch return error.OutOfMemory;
            solid.faces.slice().items(.outer_loop)[lat_face] = lat_loop;

            const he0 = solid.addHalfEdge(allocator, v0, lat_loop, lat_topo) catch return error.OutOfMemory;
            const he1 = solid.addHalfEdge(allocator, v1, lat_loop, lat_topo) catch return error.OutOfMemory;
            const he2 = solid.addHalfEdge(allocator, v2, lat_loop, lat_topo) catch return error.OutOfMemory;

            solid.setNextPrev(he0, he1);
            solid.setNextPrev(he1, he2);
            solid.setNextPrev(he2, he0);
            solid.loops.slice().items(.half_edge)[lat_loop] = he0;

            lat_hes[s] = .{ he0, he1, he2 };
        }

        // Connect Bottom Edges:
        for (0..n_sectors) |s| {
            const next_s = (s + 1) % n_sectors;
            const bot_he_idx = (n_sectors - next_s) % n_sectors;
            const lat_he0 = lat_hes[s][0];
            const bot_he = bot_hes[bot_he_idx];

            const e_topo = CadTopoId.init(feature_id, @intCast(s), 1, .Edge, FLAG_CAP_BOTTOM, 0);
            const e_id = solid.addEdge(allocator, lat_he0, e_topo) catch return error.OutOfMemory;
            solid.setTwins(lat_he0, bot_he, e_id);
        }

        // Connect Slant Edges (v1 -> apex vs apex -> v0):
        for (0..n_sectors) |s| {
            const next_s = (s + 1) % n_sectors;
            const lat_he1 = lat_hes[s][1]; // v1 -> apex
            const next_he2 = lat_hes[next_s][2]; // apex -> v0_next (which is v1)

            const e_topo = CadTopoId.init(feature_id, @intCast(s), 1, .Edge, FLAG_LATERAL, 0);
            const e_id = solid.addEdge(allocator, lat_he1, e_topo) catch return error.OutOfMemory;
            solid.setTwins(lat_he1, next_he2, e_id);
        }
    }

    // Validate 2-manifold
    solid.validateManifold() catch return error.ManifoldValidationFailed;

    // Set analytical metrics
    solid.volume = (1.0 / 3.0) * std.math.pi * height * (r_base * r_base + r_base * r_top + r_top * r_top);
    const slant = @sqrt((r_base - r_top) * (r_base - r_top) + height * height);
    const lat_area = std.math.pi * (r_base + r_top) * slant;
    const bot_area = std.math.pi * r_base * r_base;
    const top_area = if (has_top_cap) std.math.pi * r_top * r_top else 0.0;
    solid.surface_area = lat_area + bot_area + top_area;

    return solid;
}

pub fn createLegacyCone(
    allocator: Allocator,
    id: u64,
    r_base: f32,
    r_top: f32,
    height: f32,
    sectors_opt: ?u32,
) !topology.Solid {
    var soa = try createCone(allocator, @intCast(id & 0xFFFF), r_base, r_top, height, sectors_opt);
    defer soa.deinit(allocator);
    return soa.toLegacySolid(allocator, id);
}

test "Cone: Sharp apex cone manifold validation and volume" {
    const allocator = std.testing.allocator;

    var cone = try createCone(allocator, 1, 6.0, 0.0, 9.0, 16);
    defer cone.deinit(allocator);

    // V = 17, E = 32, F = 17 -> V - E + F = 2
    try std.testing.expectEqual(@as(usize, 17), cone.vertices.len);
    try std.testing.expectEqual(@as(usize, 32), cone.edges.len);
    try std.testing.expectEqual(@as(usize, 17), cone.faces.len);

    try std.testing.expectEqual(@as(i32, 0), cone.calcEulerPoincare(0));
    try cone.validateManifold();

    // Volume: (1/3) * pi * 9 * 36 = 339.292
    const expected_vol = (1.0 / 3.0) * std.math.pi * 9.0 * 36.0;
    try std.testing.expectApproxEqAbs(expected_vol, cone.volume, 1e-2);
}

test "Cone: Truncated frustum manifold validation and volume" {
    const allocator = std.testing.allocator;

    var frustum = try createCone(allocator, 2, 8.0, 4.0, 10.0, 12);
    defer frustum.deinit(allocator);

    // V = 24, E = 36, F = 14 -> V - E + F = 2
    try std.testing.expectEqual(@as(usize, 24), frustum.vertices.len);
    try std.testing.expectEqual(@as(usize, 36), frustum.edges.len);
    try std.testing.expectEqual(@as(usize, 14), frustum.faces.len);

    try std.testing.expectEqual(@as(i32, 0), frustum.calcEulerPoincare(0));
    try frustum.validateManifold();

    // Volume = (1/3) * pi * 10 * (64 + 32 + 16) = (1/3) * pi * 10 * 112 = 1172.86
    const expected_vol = (1.0 / 3.0) * std.math.pi * 10.0 * 112.0;
    try std.testing.expectApproxEqAbs(expected_vol, frustum.volume, 1e-2);
}
