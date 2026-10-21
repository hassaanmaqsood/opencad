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
const FLAG_LATERAL = topo_naming.FLAG_LATERAL;
const hashNormal = topo_naming.hashNormal;
const hashPoint = topo_naming.hashPoint;
const hashFace = topo_naming.hashFace;

pub const TorusError = error{
    InvalidRadius,
    DegenerateMesh,
    OutOfMemory,
    ManifoldValidationFailed,
};

/// Constructs a watertight 2-manifold B-Rep torus of genus 1 (Euler V - E + F = 0).
pub fn createTorus(
    allocator: Allocator,
    feature_id: u16,
    major_radius: f32,
    minor_radius: f32,
    major_segments_opt: ?u32,
    minor_segments_opt: ?u32,
) TorusError!SoASolid {
    if (major_radius <= 1e-6 or minor_radius <= 1e-6 or minor_radius >= major_radius) {
        return error.InvalidRadius;
    }
    const n_u = major_segments_opt orelse 16;
    const n_v = minor_segments_opt orelse 16;
    if (n_u < 3 or n_v < 3) return error.DegenerateMesh;

    var solid = SoASolid.init();
    errdefer solid.deinit(allocator);

    const solid_topo = CadTopoId.init(feature_id, 0, 4, .Shell, 0, 0);
    const solid_id = solid.addSolid(allocator, solid_topo) catch return error.OutOfMemory;
    const shell_id = solid.addShell(allocator, solid_id, true, solid_topo) catch return error.OutOfMemory;

    // 1. Grid of vertices: [n_u][n_v]
    const total_verts = n_u * n_v;
    const verts = try allocator.alloc(VertexId, total_verts);
    defer allocator.free(verts);

    for (0..n_u) |u| {
        const theta = @as(f32, @floatFromInt(u)) * (2.0 * std.math.pi / @as(f32, @floatFromInt(n_u)));
        const cos_theta = @cos(theta);
        const sin_theta = @sin(theta);

        for (0..n_v) |v| {
            const psi = @as(f32, @floatFromInt(v)) * (2.0 * std.math.pi / @as(f32, @floatFromInt(n_v)));
            const cos_psi = @cos(psi);
            const sin_psi = @sin(psi);

            const r_dist = major_radius + minor_radius * cos_psi;
            const pt = Vec3.init(
                r_dist * cos_theta,
                r_dist * sin_theta,
                minor_radius * sin_psi,
            );

            const v_topo = CadTopoId.init(
                feature_id,
                @intCast(u * n_v + v),
                4,
                .Vertex,
                FLAG_LATERAL,
                hashPoint(pt),
            );
            verts[u * n_v + v] = solid.addVertex(allocator, pt, v_topo) catch return error.OutOfMemory;
        }
    }

    // 2. Quad faces: [n_u][n_v]
    const total_quads = n_u * n_v;
    const quad_hes = try allocator.alloc([4]HalfEdgeId, total_quads);
    defer allocator.free(quad_hes);

    for (0..n_u) |u| {
        const next_u = (u + 1) % n_u;

        for (0..n_v) |v| {
            const next_v = (v + 1) % n_v;
            const q_idx = u * n_v + v;

            const v0 = verts[u * n_v + v];
            const v1 = verts[next_u * n_v + v];
            const v2 = verts[next_u * n_v + next_v];
            const v3 = verts[u * n_v + next_v];

            const p0 = solid.vertices.slice().items(.point)[v0];
            const p1 = solid.vertices.slice().items(.point)[v1];
            const p3 = solid.vertices.slice().items(.point)[v3];

            const nrm = (p1.sub(p0)).cross(p3.sub(p0)).normalize();

            const f_topo = CadTopoId.init(feature_id, @intCast(q_idx), 4, .Face, FLAG_LATERAL, hashFace(nrm, FLAG_LATERAL));
            const f_id = solid.addFace(allocator, shell_id, nrm, .Torus, f_topo) catch return error.OutOfMemory;
            const l_id = solid.addLoop(allocator, f_id, true, f_topo) catch return error.OutOfMemory;
            solid.faces.slice().items(.outer_loop)[f_id] = l_id;

            const he0 = solid.addHalfEdge(allocator, v0, l_id, f_topo) catch return error.OutOfMemory;
            const he1 = solid.addHalfEdge(allocator, v1, l_id, f_topo) catch return error.OutOfMemory;
            const he2 = solid.addHalfEdge(allocator, v2, l_id, f_topo) catch return error.OutOfMemory;
            const he3 = solid.addHalfEdge(allocator, v3, l_id, f_topo) catch return error.OutOfMemory;

            solid.setNextPrev(he0, he1);
            solid.setNextPrev(he1, he2);
            solid.setNextPrev(he2, he3);
            solid.setNextPrev(he3, he0);
            solid.loops.slice().items(.half_edge)[l_id] = he0;

            quad_hes[q_idx] = .{ he0, he1, he2, he3 };
        }
    }

    // 3. Connect Twins across u and v:
    for (0..n_u) |u| {
        const next_u = (u + 1) % n_u;

        for (0..n_v) |v| {
            const next_v = (v + 1) % n_v;
            const q_curr = u * n_v + v;

            // Meridian edge along v: quad(u, v) he1 (v1 -> v2) twins with quad(next_u, v) he3 (v3 -> v0)
            const q_next_u = next_u * n_v + v;
            const he1_curr = quad_hes[q_curr][1];
            const he3_next_u = quad_hes[q_next_u][3];

            const e_topo_v = CadTopoId.init(feature_id, @intCast(q_curr * 2), 4, .Edge, FLAG_LATERAL, 0);
            const e_id_v = solid.addEdge(allocator, he1_curr, e_topo_v) catch return error.OutOfMemory;
            solid.setTwins(he1_curr, he3_next_u, e_id_v);

            // Parallel ring edge along u: quad(u, v) he2 (v2 -> v3) twins with quad(u, next_v) he0 (v0 -> v1)
            const q_next_v = u * n_v + next_v;
            const he2_curr = quad_hes[q_curr][2];
            const he0_next_v = quad_hes[q_next_v][0];

            const e_topo_u = CadTopoId.init(feature_id, @intCast(q_curr * 2 + 1), 4, .Edge, FLAG_LATERAL, 0);
            const e_id_u = solid.addEdge(allocator, he0_next_v, e_topo_u) catch return error.OutOfMemory;
            solid.setTwins(he0_next_v, he2_curr, e_id_u);
        }
    }

    // Validate manifold for genus 1 (Euler-Poincare = 0)
    solid.validateManifoldGenus(1) catch return error.ManifoldValidationFailed;

    // Analytical volume & surface area
    const r_maj = major_radius;
    const r_min = minor_radius;
    solid.volume = 2.0 * std.math.pi * std.math.pi * r_maj * r_min * r_min;
    solid.surface_area = 4.0 * std.math.pi * std.math.pi * r_maj * r_min;

    return solid;
}

pub fn createLegacyTorus(
    allocator: Allocator,
    id: u64,
    major_radius: f32,
    minor_radius: f32,
    major_segments_opt: ?u32,
    minor_segments_opt: ?u32,
) !topology.Solid {
    var soa = try createTorus(allocator, @intCast(id & 0xFFFF), major_radius, minor_radius, major_segments_opt, minor_segments_opt);
    defer soa.deinit(allocator);
    return soa.toLegacySolid(allocator, id);
}

test "Torus: Genus 1 B-Rep manifold invariants and volume" {
    const allocator = std.testing.allocator;

    const R = 10.0;
    const r = 3.0;
    var torus = try createTorus(allocator, 1, R, r, 12, 12);
    defer torus.deinit(allocator);

    // V = 144, E = 288, F = 144 -> V - E + F = 0
    try std.testing.expectEqual(@as(usize, 144), torus.vertices.len);
    try std.testing.expectEqual(@as(usize, 288), torus.edges.len);
    try std.testing.expectEqual(@as(usize, 144), torus.faces.len);

    try std.testing.expectEqual(@as(i32, 0), torus.calcEulerPoincare(1));
    try torus.validateManifoldGenus(1);

    // Volume: 2 * pi^2 * 10 * 9 = 180 * pi^2 = 1776.52879
    const expected_vol = 2.0 * std.math.pi * std.math.pi * R * r * r;
    try std.testing.expectApproxEqAbs(expected_vol, torus.volume, 1e-2);

    // Surface area: 4 * pi^2 * 10 * 3 = 120 * pi^2 = 1184.3525
    const expected_area = 4.0 * std.math.pi * std.math.pi * R * r;
    try std.testing.expectApproxEqAbs(expected_area, torus.surface_area, 1e-2);
}
