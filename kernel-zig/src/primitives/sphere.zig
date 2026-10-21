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

pub const SphereError = error{
    InvalidRadius,
    DegenerateMesh,
    OutOfMemory,
    ManifoldValidationFailed,
};

/// Constructs a watertight 2-manifold B-Rep sphere (Euler V - E + F = 2).
pub fn createSphere(
    allocator: Allocator,
    feature_id: u16,
    radius: f32,
    rings_opt: ?u32,
    sectors_opt: ?u32,
) SphereError!SoASolid {
    if (radius <= 1e-6) return error.InvalidRadius;
    const n_rings = rings_opt orelse 8;
    const n_sectors = sectors_opt orelse 16;
    if (n_rings < 3 or n_sectors < 3) return error.DegenerateMesh;

    var solid = SoASolid.init();
    errdefer solid.deinit(allocator);

    const solid_topo = CadTopoId.init(feature_id, 0, 2, .Shell, 0, 0);
    const solid_id = solid.addSolid(allocator, solid_topo) catch return error.OutOfMemory;
    const shell_id = solid.addShell(allocator, solid_id, true, solid_topo) catch return error.OutOfMemory;

    // 1. Vertices:
    // Index 0: South Pole (0, 0, -radius)
    // Index 1: North Pole (0, 0, +radius)
    // Index 2 + (r - 1) * n_sectors + s: Intermediate latitude rings (r in 1..n_rings-1, s in 0..n_sectors-1)
    const p_south = Vec3.init(0, 0, -radius);
    const p_north = Vec3.init(0, 0, radius);

    const south_topo = CadTopoId.init(feature_id, 0, 2, .Vertex, FLAG_CAP_BOTTOM, hashPoint(p_south));
    const north_topo = CadTopoId.init(feature_id, 1, 2, .Vertex, FLAG_CAP_TOP, hashPoint(p_north));

    const v_south = solid.addVertex(allocator, p_south, south_topo) catch return error.OutOfMemory;
    const v_north = solid.addVertex(allocator, p_north, north_topo) catch return error.OutOfMemory;

    const ring_count = n_rings - 1; // rings 1..n_rings-1
    const intermediate_v = try allocator.alloc(VertexId, ring_count * n_sectors);
    defer allocator.free(intermediate_v);

    for (1..n_rings) |r| {
        const phi = -std.math.pi * 0.5 + (@as(f32, @floatFromInt(r)) * (std.math.pi / @as(f32, @floatFromInt(n_rings))));
        const cos_phi = @cos(phi);
        const sin_phi = @sin(phi);

        for (0..n_sectors) |s| {
            const theta = @as(f32, @floatFromInt(s)) * (2.0 * std.math.pi / @as(f32, @floatFromInt(n_sectors)));
            const pt = Vec3.init(
                radius * cos_phi * @cos(theta),
                radius * cos_phi * @sin(theta),
                radius * sin_phi,
            );

            const v_topo = CadTopoId.init(
                feature_id,
                @intCast(2 + (r - 1) * n_sectors + s),
                2,
                .Vertex,
                FLAG_LATERAL,
                hashPoint(pt),
            );
            const vid = solid.addVertex(allocator, pt, v_topo) catch return error.OutOfMemory;
            intermediate_v[(r - 1) * n_sectors + s] = vid;
        }
    }

    // Helper to get vertex at ring r, sector s
    const getRingV = struct {
        fn get(v_arr: []const VertexId, r: usize, s: usize, sec_count: usize) VertexId {
            return v_arr[(r - 1) * sec_count + (s % sec_count)];
        }
    }.get;

    // 2. Faces & Half-Edges:
    // a. South Cap Triangles: v_south -> getRingV(1, s+1) -> getRingV(1, s)
    const south_hes = try allocator.alloc([3]HalfEdgeId, n_sectors);
    defer allocator.free(south_hes);

    for (0..n_sectors) |s| {
        const next_s = (s + 1) % n_sectors;
        const v0 = v_south;
        const v1 = getRingV(intermediate_v, 1, next_s, n_sectors);
        const v2 = getRingV(intermediate_v, 1, s, n_sectors);

        const p1 = solid.vertices.slice().items(.point)[v1];
        const p2 = solid.vertices.slice().items(.point)[v2];
        const nrm = (p1.sub(p_south)).cross(p2.sub(p_south)).normalize();

        const f_topo = CadTopoId.init(feature_id, @intCast(s), 2, .Face, FLAG_CAP_BOTTOM, hashFace(nrm, FLAG_CAP_BOTTOM));
        const f_id = solid.addFace(allocator, shell_id, nrm, .Sphere, f_topo) catch return error.OutOfMemory;
        const l_id = solid.addLoop(allocator, f_id, true, f_topo) catch return error.OutOfMemory;
        solid.faces.slice().items(.outer_loop)[f_id] = l_id;

        const he0 = solid.addHalfEdge(allocator, v0, l_id, f_topo) catch return error.OutOfMemory;
        const he1 = solid.addHalfEdge(allocator, v1, l_id, f_topo) catch return error.OutOfMemory;
        const he2 = solid.addHalfEdge(allocator, v2, l_id, f_topo) catch return error.OutOfMemory;

        solid.setNextPrev(he0, he1);
        solid.setNextPrev(he1, he2);
        solid.setNextPrev(he2, he0);
        solid.loops.slice().items(.half_edge)[l_id] = he0;

        south_hes[s] = .{ he0, he1, he2 };
    }

    // Connect south pole radial edges between adjacent sectors:
    // Sector s, he2 (v2 -> v_south) is twin with Sector prev_s, he0 (v_south -> v1_prev where v1_prev == v2)
    for (0..n_sectors) |s| {
        const prev_s = (s + n_sectors - 1) % n_sectors;
        const he2_curr = south_hes[s][2];
        const he0_prev = south_hes[prev_s][0];

        const e_topo = CadTopoId.init(feature_id, @intCast(s), 2, .Edge, FLAG_CAP_BOTTOM, 0);
        const e_id = solid.addEdge(allocator, he0_prev, e_topo) catch return error.OutOfMemory;
        solid.setTwins(he0_prev, he2_curr, e_id);
    }

    // b. Intermediate Quad Strips: for r in 1..n_rings-2
    // Quad (r, s): getRingV(r, s) -> getRingV(r, s+1) -> getRingV(r+1, s+1) -> getRingV(r+1, s)
    const quad_count = (n_rings - 2) * n_sectors;
    const quad_hes = try allocator.alloc([4]HalfEdgeId, quad_count);
    defer allocator.free(quad_hes);

    for (1..n_rings - 1) |r| {
        for (0..n_sectors) |s| {
            const next_s = (s + 1) % n_sectors;
            const q_idx = (r - 1) * n_sectors + s;

            const v0 = getRingV(intermediate_v, r, s, n_sectors);
            const v1 = getRingV(intermediate_v, r, next_s, n_sectors);
            const v2 = getRingV(intermediate_v, r + 1, next_s, n_sectors);
            const v3 = getRingV(intermediate_v, r + 1, s, n_sectors);

            const p0 = solid.vertices.slice().items(.point)[v0];
            const p1 = solid.vertices.slice().items(.point)[v1];
            const p3 = solid.vertices.slice().items(.point)[v3];
            const nrm = (p1.sub(p0)).cross(p3.sub(p0)).normalize();

            const f_topo = CadTopoId.init(feature_id, @intCast(n_sectors + q_idx), 2, .Face, FLAG_LATERAL, hashFace(nrm, FLAG_LATERAL));
            const f_id = solid.addFace(allocator, shell_id, nrm, .Sphere, f_topo) catch return error.OutOfMemory;
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

    // Connect vertical meridian edges between adjacent quad sectors:
    // Quad (r, s), he1 (v1 -> v2) twins with Quad (r, next_s), he3 (v3 -> v0)
    for (1..n_rings - 1) |r| {
        for (0..n_sectors) |s| {
            const next_s = (s + 1) % n_sectors;
            const q_curr = (r - 1) * n_sectors + s;
            const q_next = (r - 1) * n_sectors + next_s;

            const he1_curr = quad_hes[q_curr][1];
            const he3_next = quad_hes[q_next][3];

            const e_topo = CadTopoId.init(feature_id, @intCast(q_curr), 2, .Edge, FLAG_LATERAL, 0);
            const e_id = solid.addEdge(allocator, he1_curr, e_topo) catch return error.OutOfMemory;
            solid.setTwins(he1_curr, he3_next, e_id);
        }
    }

    // Connect latitude edges between adjacent quad rings:
    // Quad (r, s), he2 (at ring r+1, next_s -> s) twins with Quad (r+1, s), he0 (at ring r+1, s -> next_s)
    if (n_rings > 3) {
        for (1..n_rings - 2) |r| {
            for (0..n_sectors) |s| {
                const q_lower = (r - 1) * n_sectors + s;
                const q_upper = r * n_sectors + s;

                const he2_lower = quad_hes[q_lower][2];
                const he0_upper = quad_hes[q_upper][0];

                const e_topo = CadTopoId.init(feature_id, @intCast(q_lower), 2, .Edge, FLAG_LATERAL, 0);
                const e_id = solid.addEdge(allocator, he0_upper, e_topo) catch return error.OutOfMemory;
                solid.setTwins(he0_upper, he2_lower, e_id);
            }
        }
    }

    // Connect South cap to Quad ring 1:
    // South cap sector s, he1 (ring 1, next_s -> s) twins with Quad ring 1 sector s, he0 (ring 1, s -> next_s)
    for (0..n_sectors) |s| {
        const he1_south = south_hes[s][1];
        const he0_quad1 = quad_hes[s][0];

        const e_topo = CadTopoId.init(feature_id, @intCast(s), 2, .Edge, FLAG_CAP_BOTTOM, 0);
        const e_id = solid.addEdge(allocator, he0_quad1, e_topo) catch return error.OutOfMemory;
        solid.setTwins(he0_quad1, he1_south, e_id);
    }

    // c. North Cap Triangles: getRingV(n_rings-1, s) -> getRingV(n_rings-1, s+1) -> v_north
    const north_hes = try allocator.alloc([3]HalfEdgeId, n_sectors);
    defer allocator.free(north_hes);

    for (0..n_sectors) |s| {
        const next_s = (s + 1) % n_sectors;
        const v0 = getRingV(intermediate_v, n_rings - 1, s, n_sectors);
        const v1 = getRingV(intermediate_v, n_rings - 1, next_s, n_sectors);
        const v2 = v_north;

        const p0 = solid.vertices.slice().items(.point)[v0];
        const p1 = solid.vertices.slice().items(.point)[v1];
        const nrm = (p1.sub(p0)).cross(p_north.sub(p0)).normalize();

        const f_topo = CadTopoId.init(
            feature_id,
            @intCast(n_sectors + quad_count + s),
            2,
            .Face,
            FLAG_CAP_TOP,
            hashFace(nrm, FLAG_CAP_TOP),
        );
        const f_id = solid.addFace(allocator, shell_id, nrm, .Sphere, f_topo) catch return error.OutOfMemory;
        const l_id = solid.addLoop(allocator, f_id, true, f_topo) catch return error.OutOfMemory;
        solid.faces.slice().items(.outer_loop)[f_id] = l_id;

        const he0 = solid.addHalfEdge(allocator, v0, l_id, f_topo) catch return error.OutOfMemory;
        const he1 = solid.addHalfEdge(allocator, v1, l_id, f_topo) catch return error.OutOfMemory;
        const he2 = solid.addHalfEdge(allocator, v2, l_id, f_topo) catch return error.OutOfMemory;

        solid.setNextPrev(he0, he1);
        solid.setNextPrev(he1, he2);
        solid.setNextPrev(he2, he0);
        solid.loops.slice().items(.half_edge)[l_id] = he0;

        north_hes[s] = .{ he0, he1, he2 };
    }

    // Connect north cap radial edges between adjacent sectors:
    // Sector s, he1 (v1 -> v_north) is twin with Sector next_s, he2 (v_north -> v0_next where v0_next == v1)
    for (0..n_sectors) |s| {
        const next_s = (s + 1) % n_sectors;
        const he1_curr = north_hes[s][1];
        const he2_next = north_hes[next_s][2];

        const e_topo = CadTopoId.init(feature_id, @intCast(s), 2, .Edge, FLAG_CAP_TOP, 0);
        const e_id = solid.addEdge(allocator, he1_curr, e_topo) catch return error.OutOfMemory;
        solid.setTwins(he1_curr, he2_next, e_id);
    }

    // Connect Quad top ring (n_rings - 2) to North cap:
    // Quad (n_rings-2, s), he2 (ring n_rings-1, next_s -> s) twins with North cap sector s, he0 (ring n_rings-1, s -> next_s)
    const top_quad_offset = (n_rings - 3) * n_sectors;
    for (0..n_sectors) |s| {
        const he2_top_quad = quad_hes[top_quad_offset + s][2];
        const he0_north = north_hes[s][0];

        const e_topo = CadTopoId.init(feature_id, @intCast(s), 2, .Edge, FLAG_CAP_TOP, 0);
        const e_id = solid.addEdge(allocator, he0_north, e_topo) catch return error.OutOfMemory;
        solid.setTwins(he0_north, he2_top_quad, e_id);
    }

    // Validate 2-manifold invariants (V - E + F = 2)
    solid.validateManifold() catch return error.ManifoldValidationFailed;

    // Set analytical metrics
    solid.volume = (4.0 / 3.0) * std.math.pi * radius * radius * radius;
    solid.surface_area = 4.0 * std.math.pi * radius * radius;

    return solid;
}

pub fn createLegacySphere(
    allocator: Allocator,
    id: u64,
    radius: f32,
    rings_opt: ?u32,
    sectors_opt: ?u32,
) !topology.Solid {
    var soa = try createSphere(allocator, @intCast(id & 0xFFFF), radius, rings_opt, sectors_opt);
    defer soa.deinit(allocator);
    return soa.toLegacySolid(allocator, id);
}

test "Sphere: Watertight 2-manifold B-Rep and analytical metrics" {
    const allocator = std.testing.allocator;
    const r = 5.0;

    var sphere = try createSphere(allocator, 1, r, 6, 12);
    defer sphere.deinit(allocator);

    // Assert Euler-Poincare = 0 (genus 0, V - E + F = 2)
    try std.testing.expectEqual(@as(i32, 0), sphere.calcEulerPoincare(0));
    try sphere.validateManifold();

    // Volume: (4/3) * pi * 125 = 523.59877
    const expected_vol = (4.0 / 3.0) * std.math.pi * 125.0;
    try std.testing.expectApproxEqAbs(expected_vol, sphere.volume, 1e-3);

    // Surface area: 4 * pi * 25 = 314.15926
    const expected_area = 4.0 * std.math.pi * 25.0;
    try std.testing.expectApproxEqAbs(expected_area, sphere.surface_area, 1e-3);

    // Bounding box [-5, +5]
    const bbox = sphere.calcBoundingBox();
    try std.testing.expectApproxEqAbs(-5.0, bbox.min.x, 0.5);
    try std.testing.expectApproxEqAbs(5.0, bbox.max.x, 0.5);
}
