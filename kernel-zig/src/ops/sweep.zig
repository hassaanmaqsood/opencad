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

pub const SweepError = error{
    DegenerateProfile,
    DegenerateGuide,
    OutOfMemory,
    ManifoldValidationFailed,
};

/// Sweeps a 2D closed polygon wire along a 3D guide curve/polyline using
/// a Rotation-Minimizing Frame (Bishop frame / Double Reflection method).
/// Constructs a watertight 2-manifold SoASolid (V - E + F = 2).
pub fn sweepProfile(
    allocator: Allocator,
    feature_id: u16,
    raw_profile: []const [2]f32,
    guide_curve: []const Vec3,
) SweepError!SoASolid {
    const n_pts = raw_profile.len;
    if (n_pts < 3) return error.DegenerateProfile;
    const m_stations = guide_curve.len;
    if (m_stations < 2) return error.DegenerateGuide;

    // 1. Ensure profile is oriented Counter-Clockwise (CCW)
    var signed_area: f32 = 0.0;
    for (0..n_pts) |i| {
        const next_i = (i + 1) % n_pts;
        signed_area += (raw_profile[i][0] * raw_profile[next_i][1] - raw_profile[next_i][0] * raw_profile[i][1]);
    }
    signed_area *= 0.5;
    if (@abs(signed_area) < 1e-7) return error.DegenerateProfile;

    const profile = try allocator.alloc([2]f32, n_pts);
    defer allocator.free(profile);

    if (signed_area < 0.0) {
        for (0..n_pts) |idx| {
            profile[idx] = raw_profile[n_pts - 1 - idx];
        }
    } else {
        @memcpy(profile, raw_profile);
    }

    // 2. Compute Rotation-Minimizing Frames (RMF / Bishop frame) along guide curve
    const Frame = struct {
        r: Vec3,
        s: Vec3,
        t: Vec3,
    };

    const frames = try allocator.alloc(Frame, m_stations);
    defer allocator.free(frames);

    // Initial frame at station 0
    const t0 = guide_curve[1].sub(guide_curve[0]).normalize();
    const arb = if (@abs(t0.z) < 0.9) Vec3.init(0, 0, 1) else Vec3.init(1, 0, 0);
    const r0 = t0.cross(arb).normalize();
    const s0 = t0.cross(r0).normalize();
    frames[0] = .{ .r = r0, .s = s0, .t = t0 };

    // Propagate frame via Double Reflection Method (Wang et al. 2008)
    for (0..m_stations - 1) |k| {
        const x_k = guide_curve[k];
        const x_next = guide_curve[k + 1];
        const t_k = frames[k].t;
        const r_k = frames[k].r;

        // Tangent at k+1
        const t_next = if (k + 2 < m_stations)
            guide_curve[k + 2].sub(x_k).normalize()
        else
            x_next.sub(x_k).normalize();

        const v1 = x_next.sub(x_k);
        const c1 = v1.dot(v1);

        if (c1 > 1e-12) {
            // First reflection
            const r_k_l = r_k.sub(v1.scale(2.0 * v1.dot(r_k) / c1));
            const t_k_l = t_k.sub(v1.scale(2.0 * v1.dot(t_k) / c1));

            // Second reflection
            const v2 = t_next.sub(t_k_l);
            const c2 = v2.dot(v2);

            var r_next = if (c2 > 1e-10)
                r_k_l.sub(v2.scale(2.0 * v2.dot(r_k_l) / c2))
            else
                r_k_l;

            r_next = r_next.normalize();
            const s_next = t_next.cross(r_next).normalize();
            frames[k + 1] = .{ .r = r_next, .s = s_next, .t = t_next };
        } else {
            frames[k + 1] = frames[k];
        }
    }

    var solid = SoASolid.init();
    errdefer solid.deinit(allocator);

    const solid_topo = CadTopoId.init(feature_id, 0, 3, .Shell, 0, 0);
    const solid_id = solid.addSolid(allocator, solid_topo) catch return error.OutOfMemory;
    const shell_id = solid.addShell(allocator, solid_id, true, solid_topo) catch return error.OutOfMemory;

    // 3. Compute 3D vertices: [m_stations][n_pts]
    const grid_v = try allocator.alloc(VertexId, m_stations * n_pts);
    defer allocator.free(grid_v);

    for (0..m_stations) |k| {
        const c_k = guide_curve[k];
        const f_k = frames[k];

        for (0..n_pts) |i| {
            const u = profile[i][0];
            const v = profile[i][1];

            // 3D position = C_k + R_k * u + S_k * v
            const pt = c_k.add(f_k.r.scale(u)).add(f_k.s.scale(v));
            const flag: u4 = if (k == 0) FLAG_CAP_BOTTOM else if (k == m_stations - 1) FLAG_CAP_TOP else FLAG_LATERAL;
            const v_topo = CadTopoId.init(feature_id, @intCast(k * n_pts + i), 3, .Vertex, flag, hashPoint(pt));
            grid_v[k * n_pts + i] = solid.addVertex(allocator, pt, v_topo) catch return error.OutOfMemory;
        }
    }

    // 4. Start Cap Face at station 0 (Normal: -t0)
    const start_normal = frames[0].t.scale(-1.0);
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

    // 5. End Cap Face at station m_stations - 1 (Normal: +t_last)
    const end_normal = frames[m_stations - 1].t;
    const end_topo = CadTopoId.init(feature_id, 1, 3, .Face, FLAG_CAP_TOP, hashFace(end_normal, FLAG_CAP_TOP));
    const end_face = solid.addFace(allocator, shell_id, end_normal, .Plane, end_topo) catch return error.OutOfMemory;
    const end_loop = solid.addLoop(allocator, end_face, true, end_topo) catch return error.OutOfMemory;
    solid.faces.slice().items(.outer_loop)[end_face] = end_loop;

    const end_hes = try allocator.alloc(HalfEdgeId, n_pts);
    defer allocator.free(end_hes);

    for (0..n_pts) |k| {
        const origin = grid_v[(m_stations - 1) * n_pts + k];
        const he_topo = CadTopoId.init(feature_id, @intCast(k), 3, .Edge, FLAG_CAP_TOP, 0);
        end_hes[k] = solid.addHalfEdge(allocator, origin, end_loop, he_topo) catch return error.OutOfMemory;
    }
    for (0..n_pts) |k| {
        const next_k = (k + 1) % n_pts;
        solid.setNextPrev(end_hes[k], end_hes[next_k]);
    }
    solid.loops.slice().items(.half_edge)[end_loop] = end_hes[0];

    // 6. Lateral Quad Faces between station k and k+1
    const n_segments = m_stations - 1;
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

    // 7. Connect Twins:
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

    // c. Longitudinal edges between adjacent quads along profile
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

    // d. Ring edges between station k and k+1
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

    // 8. Validate 2-manifold
    solid.validateManifold() catch return error.ManifoldValidationFailed;

    // 9. Update metrics
    solid.updateMetrics();

    return solid;
}

test "Sweep square along curved 3D guide curve (Bishop frame)" {
    const allocator = std.testing.allocator;

    const sq_profile = [_][2]f32{
        .{ -1.0, -1.0 },
        .{ 1.0, -1.0 },
        .{ 1.0, 1.0 },
        .{ -1.0, 1.0 },
    };

    // Helical / curved guide curve with 5 stations
    const guide = [_]Vec3{
        Vec3.init(0, 0, 0),
        Vec3.init(5, 2, 5),
        Vec3.init(10, 6, 10),
        Vec3.init(15, 8, 15),
        Vec3.init(20, 10, 20),
    };

    var swept = try sweepProfile(allocator, 1, &sq_profile, &guide);
    defer swept.deinit(allocator);

    // 5 stations * 4 profile points = 20 vertices
    // 4 segments * 4 quads + 2 caps = 18 faces
    // 20 - E + 18 = 2 => E = 36 edges
    try std.testing.expectEqual(@as(usize, 20), swept.vertices.len);
    try std.testing.expectEqual(@as(usize, 36), swept.edges.len);
    try std.testing.expectEqual(@as(usize, 18), swept.faces.len);

    try std.testing.expectEqual(@as(i32, 0), swept.calcEulerPoincare(0));
    try swept.validateManifold();

    try std.testing.expect(swept.volume > 50.0);
    try std.testing.expect(swept.surface_area > 50.0);
}
