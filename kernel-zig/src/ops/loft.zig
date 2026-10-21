const std = @import("std");
const Allocator = std.mem.Allocator;
const Vec3 = @import("../math/vec3.zig").Vec3;
const topo = @import("../topo/mod.zig");

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

pub const LoftError = error{
    InsufficientProfiles,
    DegenerateWire,
    MismatchedVertexCounts,
    OutOfMemory,
    ManifoldValidationFailed,
};

/// Lofts/skins between K closed 3D wire profiles (parallel or non-parallel).
/// Minimizes torsional twist between adjacent profiles and constructs a watertight 2-manifold SoASolid (V - E + F = 2).
pub fn loftProfiles(
    allocator: Allocator,
    feature_id: u16,
    profiles: []const []const Vec3,
) LoftError!SoASolid {
    const k_profiles = profiles.len;
    if (k_profiles < 2) return error.InsufficientProfiles;

    const n_pts = profiles[0].len;
    if (n_pts < 3) return error.DegenerateWire;

    for (profiles[1..]) |prof| {
        if (prof.len != n_pts) return error.MismatchedVertexCounts;
    }

    // 1. Copy profiles and align phase to minimize twist between adjacent cross-sections
    const aligned_pts = try allocator.alloc([]Vec3, k_profiles);
    defer {
        for (aligned_pts) |p_arr| allocator.free(p_arr);
        allocator.free(aligned_pts);
    }

    aligned_pts[0] = try allocator.alloc(Vec3, n_pts);
    @memcpy(aligned_pts[0], profiles[0]);

    for (1..k_profiles) |k| {
        aligned_pts[k] = try allocator.alloc(Vec3, n_pts);
        const prev_prof = aligned_pts[k - 1];
        const curr_prof = profiles[k];

        // Find shift s in 0..n_pts-1 that minimizes sum of squared distances
        var best_shift: usize = 0;
        var min_dist_sq: f32 = std.math.floatMax(f32);

        for (0..n_pts) |s| {
            var dist_sq: f32 = 0.0;
            for (0..n_pts) |i| {
                const shifted_i = (i + s) % n_pts;
                const d = curr_prof[shifted_i].sub(prev_prof[i]);
                dist_sq += d.dot(d);
            }
            if (dist_sq < min_dist_sq) {
                min_dist_sq = dist_sq;
                best_shift = s;
            }
        }

        for (0..n_pts) |i| {
            aligned_pts[k][i] = curr_prof[(i + best_shift) % n_pts];
        }
    }

    var solid = SoASolid.init();
    errdefer solid.deinit(allocator);

    const solid_topo = CadTopoId.init(feature_id, 0, 3, .Shell, 0, 0);
    const solid_id = solid.addSolid(allocator, solid_topo) catch return error.OutOfMemory;
    const shell_id = solid.addShell(allocator, solid_id, true, solid_topo) catch return error.OutOfMemory;

    // 2. Add 3D vertices: [k_profiles][n_pts]
    const grid_v = try allocator.alloc(VertexId, k_profiles * n_pts);
    defer allocator.free(grid_v);

    for (0..k_profiles) |k| {
        for (0..n_pts) |i| {
            const pt = aligned_pts[k][i];
            const flag: u4 = if (k == 0) FLAG_CAP_BOTTOM else if (k == k_profiles - 1) FLAG_CAP_TOP else FLAG_LATERAL;
            const v_topo = CadTopoId.init(feature_id, @intCast(k * n_pts + i), 3, .Vertex, flag, hashPoint(pt));
            grid_v[k * n_pts + i] = solid.addVertex(allocator, pt, v_topo) catch return error.OutOfMemory;
        }
    }

    // 3. Start Cap Face at Profile 0
    // Estimate outward normal pointing away from Profile 1:
    // Centroid of profile 0 and profile 1
    var c0 = Vec3.init(0, 0, 0);
    var c1 = Vec3.init(0, 0, 0);
    for (0..n_pts) |i| {
        c0 = c0.add(aligned_pts[0][i]);
        c1 = c1.add(aligned_pts[1][i]);
    }
    c0 = c0.scale(1.0 / @as(f32, @floatFromInt(n_pts)));
    c1 = c1.scale(1.0 / @as(f32, @floatFromInt(n_pts)));
    const start_axis = c0.sub(c1).normalize();

    // Compute polygon normal via Newell method
    var start_poly_nrm = Vec3.init(0, 0, 0);
    for (0..n_pts) |i| {
        const next_i = (i + 1) % n_pts;
        const p_curr = aligned_pts[0][i];
        const p_next = aligned_pts[0][next_i];
        start_poly_nrm.x += (p_curr.y - p_next.y) * (p_curr.z + p_next.z);
        start_poly_nrm.y += (p_curr.z - p_next.z) * (p_curr.x + p_next.x);
        start_poly_nrm.z += (p_curr.x - p_next.x) * (p_curr.y + p_next.y);
    }
    start_poly_nrm = start_poly_nrm.normalize();
    const start_normal = if (start_poly_nrm.dot(start_axis) > 0.0) start_poly_nrm else start_poly_nrm.scale(-1.0);

    const start_topo = CadTopoId.init(feature_id, 0, 3, .Face, FLAG_CAP_BOTTOM, hashFace(start_normal, FLAG_CAP_BOTTOM));
    const start_face = solid.addFace(allocator, shell_id, start_normal, .Plane, start_topo) catch return error.OutOfMemory;
    const start_loop = solid.addLoop(allocator, start_face, true, start_topo) catch return error.OutOfMemory;
    solid.faces.slice().items(.outer_loop)[start_face] = start_loop;

    const start_hes = try allocator.alloc(HalfEdgeId, n_pts);
    defer allocator.free(start_hes);

    for (0..n_pts) |k| {
        const idx = (n_pts - k) % n_pts;
        const origin = grid_v[0 * n_pts + idx];
        const he_topo = CadTopoId.init(feature_id, @intCast(idx), 3, .Edge, FLAG_CAP_BOTTOM, 0);
        start_hes[k] = solid.addHalfEdge(allocator, origin, start_loop, he_topo) catch return error.OutOfMemory;
    }
    for (0..n_pts) |k| {
        const next_k = (k + 1) % n_pts;
        solid.setNextPrev(start_hes[k], start_hes[next_k]);
    }
    solid.loops.slice().items(.half_edge)[start_loop] = start_hes[0];

    // 4. End Cap Face at Profile K-1
    var c_last = Vec3.init(0, 0, 0);
    var c_prev = Vec3.init(0, 0, 0);
    for (0..n_pts) |i| {
        c_last = c_last.add(aligned_pts[k_profiles - 1][i]);
        c_prev = c_prev.add(aligned_pts[k_profiles - 2][i]);
    }
    c_last = c_last.scale(1.0 / @as(f32, @floatFromInt(n_pts)));
    c_prev = c_prev.scale(1.0 / @as(f32, @floatFromInt(n_pts)));
    const end_axis = c_last.sub(c_prev).normalize();

    var end_poly_nrm = Vec3.init(0, 0, 0);
    for (0..n_pts) |i| {
        const next_i = (i + 1) % n_pts;
        const p_curr = aligned_pts[k_profiles - 1][i];
        const p_next = aligned_pts[k_profiles - 1][next_i];
        end_poly_nrm.x += (p_curr.y - p_next.y) * (p_curr.z + p_next.z);
        end_poly_nrm.y += (p_curr.z - p_next.z) * (p_curr.x + p_next.x);
        end_poly_nrm.z += (p_curr.x - p_next.x) * (p_curr.y + p_next.y);
    }
    end_poly_nrm = end_poly_nrm.normalize();
    const end_normal = if (end_poly_nrm.dot(end_axis) > 0.0) end_poly_nrm else end_poly_nrm.scale(-1.0);

    const end_topo = CadTopoId.init(feature_id, 1, 3, .Face, FLAG_CAP_TOP, hashFace(end_normal, FLAG_CAP_TOP));
    const end_face = solid.addFace(allocator, shell_id, end_normal, .Plane, end_topo) catch return error.OutOfMemory;
    const end_loop = solid.addLoop(allocator, end_face, true, end_topo) catch return error.OutOfMemory;
    solid.faces.slice().items(.outer_loop)[end_face] = end_loop;

    const end_hes = try allocator.alloc(HalfEdgeId, n_pts);
    defer allocator.free(end_hes);

    for (0..n_pts) |k| {
        const origin = grid_v[(k_profiles - 1) * n_pts + k];
        const he_topo = CadTopoId.init(feature_id, @intCast(k), 3, .Edge, FLAG_CAP_TOP, 0);
        end_hes[k] = solid.addHalfEdge(allocator, origin, end_loop, he_topo) catch return error.OutOfMemory;
    }
    for (0..n_pts) |k| {
        const next_k = (k + 1) % n_pts;
        solid.setNextPrev(end_hes[k], end_hes[next_k]);
    }
    solid.loops.slice().items(.half_edge)[end_loop] = end_hes[0];

    // 5. Lateral Quad Faces between Profile k and k+1
    const n_segments = k_profiles - 1;
    const quad_hes = try allocator.alloc([4]HalfEdgeId, n_segments * n_pts);
    defer allocator.free(quad_hes);

    for (0..n_segments) |k| {
        for (0..n_pts) |i| {
            const next_i = (i + 1) % n_pts;
            const q_idx = k * n_pts + i;

            const v0 = grid_v[k * n_pts + i];
            const v1 = grid_v[k * n_pts + next_i];
            const v2 = grid_v[(k + 1) * n_pts + next_i];
            const v3 = grid_v[(k + 1) * n_pts + i];

            const p0 = solid.vertices.slice().items(.point)[v0];
            const p1 = solid.vertices.slice().items(.point)[v1];
            const p3 = solid.vertices.slice().items(.point)[v3];
            const nrm = (p1.sub(p0)).cross(p3.sub(p0)).normalize();

            const lat_topo = CadTopoId.init(
                feature_id,
                @intCast(2 + q_idx),
                3,
                .Face,
                FLAG_LATERAL,
                hashFace(nrm, FLAG_LATERAL),
            );
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

            quad_hes[q_idx] = .{ he0, he1, he2, he3 };
        }
    }

    // 6. Connect Twins:
    // a. Start cap to segment 0 quad bottom edges
    for (0..n_pts) |i| {
        const next_i = (i + 1) % n_pts;
        const start_he_idx = (n_pts - next_i) % n_pts;
        const lat_he0 = quad_hes[i][0];
        const cap_he = start_hes[start_he_idx];

        const e_topo = CadTopoId.init(feature_id, @intCast(i), 3, .Edge, FLAG_CAP_BOTTOM, 0);
        const e_id = solid.addEdge(allocator, lat_he0, e_topo) catch return error.OutOfMemory;
        solid.setTwins(lat_he0, cap_he, e_id);
    }

    // b. End cap to segment n_segments - 1 quad top edges
    const last_seg_offset = (n_segments - 1) * n_pts;
    for (0..n_pts) |i| {
        const lat_he2 = quad_hes[last_seg_offset + i][2];
        const cap_he = end_hes[i];

        const e_topo = CadTopoId.init(feature_id, @intCast(i), 3, .Edge, FLAG_CAP_TOP, 0);
        const e_id = solid.addEdge(allocator, cap_he, e_topo) catch return error.OutOfMemory;
        solid.setTwins(cap_he, lat_he2, e_id);
    }

    // c. Longitudinal edges between adjacent quads
    for (0..n_segments) |k| {
        for (0..n_pts) |i| {
            const prev_i = (i + n_pts - 1) % n_pts;
            const q_curr = k * n_pts + i;
            const q_prev = k * n_pts + prev_i;

            const he3_curr = quad_hes[q_curr][3];
            const he1_prev = quad_hes[q_prev][1];

            const e_topo = CadTopoId.init(feature_id, @intCast(q_curr), 3, .Edge, FLAG_LATERAL, 0);
            const e_id = solid.addEdge(allocator, he1_prev, e_topo) catch return error.OutOfMemory;
            solid.setTwins(he1_prev, he3_curr, e_id);
        }
    }

    // d. Ring edges between profile k and k+1
    if (n_segments > 1) {
        for (0..n_segments - 1) |k| {
            for (0..n_pts) |i| {
                const q_lower = k * n_pts + i;
                const q_upper = (k + 1) * n_pts + i;

                const he2_lower = quad_hes[q_lower][2];
                const he0_upper = quad_hes[q_upper][0];

                const e_topo = CadTopoId.init(feature_id, @intCast(q_lower), 3, .Edge, FLAG_LATERAL, 0);
                const e_id = solid.addEdge(allocator, he0_upper, e_topo) catch return error.OutOfMemory;
                solid.setTwins(he0_upper, he2_lower, e_id);
            }
        }
    }

    // 7. Validate manifold
    solid.validateManifold() catch return error.ManifoldValidationFailed;

    // 8. Update metrics
    solid.updateMetrics();

    return solid;
}

test "Loft between 3 non-parallel closed profiles" {
    const allocator = std.testing.allocator;

    // Profile 0: Square at z = 0, size 10x10
    const prof0 = [_]Vec3{
        Vec3.init(-5, -5, 0),
        Vec3.init(5, -5, 0),
        Vec3.init(5, 5, 0),
        Vec3.init(-5, 5, 0),
    };

    // Profile 1: Rotated & scaled square at z = 10, size 8x8
    const prof1 = [_]Vec3{
        Vec3.init(-3, -5, 10),
        Vec3.init(5, -3, 10),
        Vec3.init(3, 5, 10),
        Vec3.init(-5, 3, 10),
    };

    // Profile 2: Square at z = 20, size 4x4
    const prof2 = [_]Vec3{
        Vec3.init(-2, -2, 20),
        Vec3.init(2, -2, 20),
        Vec3.init(2, 2, 20),
        Vec3.init(-2, 2, 20),
    };

    const loft_profiles = [_][]const Vec3{ &prof0, &prof1, &prof2 };

    var lofted = try loftProfiles(allocator, 1, &loft_profiles);
    defer lofted.deinit(allocator);

    // 3 profiles * 4 points = 12 vertices
    // 2 segments * 4 quads + 2 caps = 10 faces
    // 12 - E + 10 = 2 => E = 20 edges
    try std.testing.expectEqual(@as(usize, 12), lofted.vertices.len);
    try std.testing.expectEqual(@as(usize, 20), lofted.edges.len);
    try std.testing.expectEqual(@as(usize, 10), lofted.faces.len);

    try std.testing.expectEqual(@as(i32, 0), lofted.calcEulerPoincare(0));
    try lofted.validateManifold();

    try std.testing.expect(lofted.volume > 200.0);
    try std.testing.expect(lofted.surface_area > 100.0);
}
