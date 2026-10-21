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
const FLAG_START_CAP = topo_naming.FLAG_START_CAP;
const FLAG_END_CAP = topo_naming.FLAG_END_CAP;
const hashNormal = topo_naming.hashNormal;
const hashPoint = topo_naming.hashPoint;
const hashFace = topo_naming.hashFace;

pub const RevolveError = error{
    InvalidAngle,
    InvalidAxis,
    DegeneratePolygon,
    OutOfMemory,
    ManifoldValidationFailed,
};

/// Revolves a 2D profile [radius (x), height (y)] around a 3D axis.
pub fn revolveProfile(
    allocator: Allocator,
    feature_id: u16,
    raw_points: []const [2]f32,
    axis_origin: Vec3,
    axis_direction: Vec3,
    angle_rad: f64,
    segments_opt: ?u32,
) RevolveError!SoASolid {
    if (@abs(angle_rad) <= 1e-6) return error.InvalidAngle;
    if (axis_direction.norm() <= 1e-6) return error.InvalidAxis;
    const n_pts = raw_points.len;
    if (n_pts < 3) return error.DegeneratePolygon;

    const m_segs = segments_opt orelse 16;
    if (m_segs < 3) return error.DegeneratePolygon;

    const z_axis = axis_direction.normalize();

    // Construct orthogonal frame (x_axis, y_axis, z_axis)
    const arb = if (@abs(z_axis.z) < 0.9) Vec3.init(0, 0, 1) else Vec3.init(1, 0, 0);
    const x_axis = z_axis.cross(arb).normalize();
    const y_axis = z_axis.cross(x_axis).normalize();

    const is_full = @abs(@abs(angle_rad) - 2.0 * std.math.pi) < 1e-4;
    const sweep_angle: f32 = @floatCast(angle_rad);
    const num_slices = m_segs;

    var solid = SoASolid.init();
    errdefer solid.deinit(allocator);

    const solid_topo = CadTopoId.init(feature_id, 0, 2, .Shell, 0, 0);
    const solid_id = try solid.addSolid(allocator, solid_topo);
    const shell_id = try solid.addShell(allocator, solid_id, true, solid_topo);

    // Grid of vertices: [num_slices][n_pts]
    // If not full circle, we have (num_slices + 1) angular slices
    const slice_count = if (is_full) num_slices else num_slices + 1;
    const grid_v = try allocator.alloc(VertexId, slice_count * n_pts);
    defer allocator.free(grid_v);

    for (0..slice_count) |s_idx| {
        const theta = @as(f32, @floatFromInt(s_idx)) * (sweep_angle / @as(f32, @floatFromInt(num_slices)));
        const cos_t = @cos(theta);
        const sin_t = @sin(theta);

        for (0..n_pts) |p_idx| {
            const r = raw_points[p_idx][0];
            const h = raw_points[p_idx][1];

            // Point in 3D: origin + x_axis*(r*cos) + y_axis*(r*sin) + z_axis*h
            const radial = (x_axis.scale(r * cos_t)).add(y_axis.scale(r * sin_t));
            const pt = axis_origin.add(radial).add(z_axis.scale(h));

            const topo_flag: u4 = if (s_idx == 0) FLAG_START_CAP else if (s_idx == slice_count - 1 and !is_full) FLAG_END_CAP else FLAG_LATERAL;
            const v_topo = CadTopoId.init(feature_id, @intCast(p_idx), 2, .Vertex, topo_flag, hashPoint(pt));
            grid_v[s_idx * n_pts + p_idx] = try solid.addVertex(allocator, pt, v_topo);
        }
    }

    // Build quad faces for each slice s -> s + 1
    // Quad between profile points p and next_p:
    // v0: grid(s, p), v1: grid(s, next_p), v2: grid(next_s, next_p), v3: grid(next_s, p)
    const num_quad_slices = num_slices;
    for (0..num_quad_slices) |s_idx| {
        const next_s = (s_idx + 1) % slice_count;

        for (0..n_pts) |p_idx| {
            const next_p = (p_idx + 1) % n_pts;

            const v0 = grid_v[s_idx * n_pts + p_idx];
            const v1 = grid_v[s_idx * n_pts + next_p];
            const v2 = grid_v[next_s * n_pts + next_p];
            const v3 = grid_v[next_s * n_pts + p_idx];

            const p0 = solid.vertices.slice().items(.point)[v0];
            const p1 = solid.vertices.slice().items(.point)[v1];
            const p3 = solid.vertices.slice().items(.point)[v3];

            const nrm = (p1.sub(p0)).cross(p3.sub(p0)).normalize();
            const lat_topo = CadTopoId.init(
                feature_id,
                @intCast(p_idx),
                2,
                .Face,
                FLAG_LATERAL,
                hashFace(nrm, FLAG_LATERAL),
            );

            const face_id = try solid.addFace(allocator, shell_id, nrm, .Cylinder, lat_topo);
            const loop_id = try solid.addLoop(allocator, face_id, true, lat_topo);
            solid.faces.slice().items(.outer_loop)[face_id] = loop_id;

            const he0 = try solid.addHalfEdge(allocator, v0, loop_id, lat_topo);
            const he1 = try solid.addHalfEdge(allocator, v1, loop_id, lat_topo);
            const he2 = try solid.addHalfEdge(allocator, v2, loop_id, lat_topo);
            const he3 = try solid.addHalfEdge(allocator, v3, loop_id, lat_topo);

            solid.setNextPrev(he0, he1);
            solid.setNextPrev(he1, he2);
            solid.setNextPrev(he2, he3);
            solid.setNextPrev(he3, he0);

            solid.loops.slice().items(.half_edge)[loop_id] = he0;
        }
    }

    // Connect internal quad twins across the mesh
    // In slice s and quad p:
    // he0 (v0->v1) is along profile edge p at slice s. Its twin is in slice prev_s at quad p, or if not full, closed by caps.
    // he1 (v1->v2) is along rotation step from s to next_s at profile vertex next_p. Its twin is at quad next_p, edge he3 (v2->v1).
    // he2 (v2->v3) is along profile edge at next_s. Its twin is at next_s, quad p, edge he0.
    // he3 (v3->v0) is along rotation step at profile vertex p. Its twin is at quad prev_p, edge he1.
    // Let's index half-edges cleanly:
    // Quad(s, p) has half-edges at indices: (s * n_pts + p) * 4 + [0..3]
    for (0..num_quad_slices) |s_idx| {
        const next_s = (s_idx + 1) % slice_count;

        for (0..n_pts) |p_idx| {
            const next_p = (p_idx + 1) % n_pts;

            const base_he = @as(HalfEdgeId, @intCast((s_idx * n_pts + p_idx) * 4));
            const he1 = base_he + 1; // v1 -> v2 (along rotation at next_p)

            // Twin of he1 is in quad next_p at same slice s: edge he3 (v3 -> v0)
            const next_p_base = @as(HalfEdgeId, @intCast((s_idx * n_pts + next_p) * 4));
            const he3_twin = next_p_base + 3;

            const e_topo1 = CadTopoId.init(feature_id, @intCast(p_idx), 2, .Edge, FLAG_LATERAL, 0);
            const e1 = try solid.addEdge(allocator, he1, e_topo1);
            solid.setTwins(he1, he3_twin, e1);

            // If full circle, connect profile edges between slice s and next_s
            if (is_full or next_s < num_quad_slices) {
                const he2 = base_he + 2; // v2 -> v3 (at next_s, profile edge reversed)
                const next_s_base = @as(HalfEdgeId, @intCast((next_s * n_pts + p_idx) * 4));
                const next_s_he0 = next_s_base + 0; // v0 -> v1 at next_s

                const e_topo2 = CadTopoId.init(feature_id, @intCast(p_idx), 2, .Edge, FLAG_LATERAL, 0);
                const e2 = try solid.addEdge(allocator, next_s_he0, e_topo2);
                solid.setTwins(next_s_he0, he2, e2);
            }
        }
    }

    // If partial revolution, add start cap face at s=0 and end cap face at s=num_slices
    if (!is_full) {
        // Start cap face (s = 0)
        const start_normal = y_axis.scale(-1.0);
        const start_cap_topo = CadTopoId.init(feature_id, 0, 2, .Face, FLAG_START_CAP, hashFace(start_normal, FLAG_START_CAP));
        const start_face = try solid.addFace(allocator, shell_id, start_normal, .Plane, start_cap_topo);
        const start_loop = try solid.addLoop(allocator, start_face, true, start_cap_topo);
        solid.faces.slice().items(.outer_loop)[start_face] = start_loop;

        var prev_he: ?HalfEdgeId = null;
        var first_he: HalfEdgeId = 0;
        for (0..n_pts) |k| {
            const p_idx = (n_pts - k) % n_pts;
            const v = grid_v[0 * n_pts + p_idx];
            const he = try solid.addHalfEdge(allocator, v, start_loop, start_cap_topo);
            if (k == 0) first_he = he;
            if (prev_he) |prv| solid.setNextPrev(prv, he);
            prev_he = he;
        }
        if (prev_he) |prv| solid.setNextPrev(prv, first_he);
        solid.loops.slice().items(.half_edge)[start_loop] = first_he;

        // End cap face (s = slice_count - 1)
        const end_normal = y_axis;
        const end_cap_topo = CadTopoId.init(feature_id, 0, 2, .Face, FLAG_END_CAP, hashFace(end_normal, FLAG_END_CAP));
        const end_face = try solid.addFace(allocator, shell_id, end_normal, .Plane, end_cap_topo);
        const end_loop = try solid.addLoop(allocator, end_face, true, end_cap_topo);
        solid.faces.slice().items(.outer_loop)[end_face] = end_loop;

        prev_he = null;
        var end_first_he: HalfEdgeId = 0;
        for (0..n_pts) |p_idx| {
            const v = grid_v[(slice_count - 1) * n_pts + p_idx];
            const he = try solid.addHalfEdge(allocator, v, end_loop, end_cap_topo);
            if (p_idx == 0) end_first_he = he;
            if (prev_he) |prv| solid.setNextPrev(prv, he);
            prev_he = he;
        }
        if (prev_he) |prv| solid.setNextPrev(prv, end_first_he);
        solid.loops.slice().items(.half_edge)[end_loop] = end_first_he;
    }

    // Update geometry metrics
    solid.updateMetrics();
    return solid;
}

/// Revolves an arbitrary 3D closed wire around an arbitrary 3D axis by a given angle (radians).
/// Uses Rodrigues' rotation formula to rotate 3D points.
pub fn revolveWire3D(
    allocator: Allocator,
    feature_id: u16,
    wire_points: []const Vec3,
    axis_origin: Vec3,
    axis_direction: Vec3,
    angle_rad: f64,
    segments_opt: ?u32,
) RevolveError!SoASolid {
    if (@abs(angle_rad) <= 1e-6) return error.InvalidAngle;
    if (axis_direction.norm() <= 1e-6) return error.InvalidAxis;
    const n_pts = wire_points.len;
    if (n_pts < 3) return error.DegeneratePolygon;

    const num_slices = segments_opt orelse 16;
    if (num_slices < 3) return error.DegeneratePolygon;

    const k_axis = axis_direction.normalize();
    const is_full = @abs(@abs(angle_rad) - 2.0 * std.math.pi) < 1e-4;
    const sweep_angle: f32 = @floatCast(angle_rad);

    var solid = SoASolid.init();
    errdefer solid.deinit(allocator);

    const solid_topo = CadTopoId.init(feature_id, 0, 2, .Shell, 0, 0);
    const solid_id = solid.addSolid(allocator, solid_topo) catch return error.OutOfMemory;
    const shell_id = solid.addShell(allocator, solid_id, true, solid_topo) catch return error.OutOfMemory;

    const slice_count = if (is_full) num_slices else num_slices + 1;
    const grid_v = try allocator.alloc(VertexId, slice_count * n_pts);
    defer allocator.free(grid_v);

    for (0..slice_count) |s_idx| {
        const theta = @as(f32, @floatFromInt(s_idx)) * (sweep_angle / @as(f32, @floatFromInt(num_slices)));
        const cos_t = @cos(theta);
        const sin_t = @sin(theta);

        for (0..n_pts) |p_idx| {
            const p = wire_points[p_idx];
            const v = p.sub(axis_origin);

            // Rodrigues' rotation formula:
            // v_rot = v * cos(theta) + (k x v) * sin(theta) + k * (k . v) * (1 - cos(theta))
            const term1 = v.scale(cos_t);
            const term2 = k_axis.cross(v).scale(sin_t);
            const term3 = k_axis.scale(k_axis.dot(v) * (1.0 - cos_t));
            const p_rot = axis_origin.add(term1).add(term2).add(term3);

            const topo_flag: u4 = if (s_idx == 0) FLAG_START_CAP else if (s_idx == slice_count - 1 and !is_full) FLAG_END_CAP else FLAG_LATERAL;
            const v_topo = CadTopoId.init(feature_id, @intCast(p_idx), 2, .Vertex, topo_flag, hashPoint(p_rot));
            grid_v[s_idx * n_pts + p_idx] = solid.addVertex(allocator, p_rot, v_topo) catch return error.OutOfMemory;
        }
    }

    // Quad lateral faces
    const num_quad_slices = num_slices;
    for (0..num_quad_slices) |s_idx| {
        const next_s = (s_idx + 1) % slice_count;

        for (0..n_pts) |p_idx| {
            const next_p = (p_idx + 1) % n_pts;

            const v0 = grid_v[s_idx * n_pts + p_idx];
            const v1 = grid_v[s_idx * n_pts + next_p];
            const v2 = grid_v[next_s * n_pts + next_p];
            const v3 = grid_v[next_s * n_pts + p_idx];

            const p0 = solid.vertices.slice().items(.point)[v0];
            const p1 = solid.vertices.slice().items(.point)[v1];
            const p3 = solid.vertices.slice().items(.point)[v3];

            const nrm = (p1.sub(p0)).cross(p3.sub(p0)).normalize();
            const lat_topo = CadTopoId.init(
                feature_id,
                @intCast(p_idx),
                2,
                .Face,
                FLAG_LATERAL,
                hashFace(nrm, FLAG_LATERAL),
            );

            const face_id = solid.addFace(allocator, shell_id, nrm, .Cylinder, lat_topo) catch return error.OutOfMemory;
            const loop_id = solid.addLoop(allocator, face_id, true, lat_topo) catch return error.OutOfMemory;
            solid.faces.slice().items(.outer_loop)[face_id] = loop_id;

            const he0 = solid.addHalfEdge(allocator, v0, loop_id, lat_topo) catch return error.OutOfMemory;
            const he1 = solid.addHalfEdge(allocator, v1, loop_id, lat_topo) catch return error.OutOfMemory;
            const he2 = solid.addHalfEdge(allocator, v2, loop_id, lat_topo) catch return error.OutOfMemory;
            const he3 = solid.addHalfEdge(allocator, v3, loop_id, lat_topo) catch return error.OutOfMemory;

            solid.setNextPrev(he0, he1);
            solid.setNextPrev(he1, he2);
            solid.setNextPrev(he2, he3);
            solid.setNextPrev(he3, he0);

            solid.loops.slice().items(.half_edge)[loop_id] = he0;
        }
    }

    // Connect internal quad twins
    for (0..num_quad_slices) |s_idx| {
        const next_s = (s_idx + 1) % slice_count;

        for (0..n_pts) |p_idx| {
            const next_p = (p_idx + 1) % n_pts;

            const base_he = @as(HalfEdgeId, @intCast((s_idx * n_pts + p_idx) * 4));
            const he1 = base_he + 1;

            const next_p_base = @as(HalfEdgeId, @intCast((s_idx * n_pts + next_p) * 4));
            const he3_twin = next_p_base + 3;

            const e_topo1 = CadTopoId.init(feature_id, @intCast(p_idx), 2, .Edge, FLAG_LATERAL, 0);
            const e1 = solid.addEdge(allocator, he1, e_topo1) catch return error.OutOfMemory;
            solid.setTwins(he1, he3_twin, e1);

            if (is_full or next_s < num_quad_slices) {
                const he2 = base_he + 2;
                const next_s_base = @as(HalfEdgeId, @intCast((next_s * n_pts + p_idx) * 4));
                const next_s_he0 = next_s_base + 0;

                const e_topo2 = CadTopoId.init(feature_id, @intCast(p_idx), 2, .Edge, FLAG_LATERAL, 0);
                const e2 = solid.addEdge(allocator, next_s_he0, e_topo2) catch return error.OutOfMemory;
                solid.setTwins(next_s_he0, he2, e2);
            }
        }
    }

    // Partial revolution start and end caps
    if (!is_full) {
        // Start cap (s = 0)
        const v_mid0 = wire_points[0].sub(axis_origin);
        const start_normal = k_axis.cross(v_mid0).normalize().scale(-1.0);
        const start_cap_topo = CadTopoId.init(feature_id, 0, 2, .Face, FLAG_START_CAP, hashFace(start_normal, FLAG_START_CAP));
        const start_face = solid.addFace(allocator, shell_id, start_normal, .Plane, start_cap_topo) catch return error.OutOfMemory;
        const start_loop = solid.addLoop(allocator, start_face, true, start_cap_topo) catch return error.OutOfMemory;
        solid.faces.slice().items(.outer_loop)[start_face] = start_loop;

        var prev_he: ?HalfEdgeId = null;
        var first_he: HalfEdgeId = 0;
        for (0..n_pts) |k| {
            const p_idx = (n_pts - k) % n_pts;
            const v = grid_v[0 * n_pts + p_idx];
            const he = solid.addHalfEdge(allocator, v, start_loop, start_cap_topo) catch return error.OutOfMemory;
            if (k == 0) first_he = he;
            if (prev_he) |prv| solid.setNextPrev(prv, he);
            prev_he = he;
        }
        if (prev_he) |prv| solid.setNextPrev(prv, first_he);
        solid.loops.slice().items(.half_edge)[start_loop] = first_he;

        // End cap (s = slice_count - 1)
        const end_normal = start_normal.scale(-1.0);
        const end_cap_topo = CadTopoId.init(feature_id, 0, 2, .Face, FLAG_END_CAP, hashFace(end_normal, FLAG_END_CAP));
        const end_face = solid.addFace(allocator, shell_id, end_normal, .Plane, end_cap_topo) catch return error.OutOfMemory;
        const end_loop = solid.addLoop(allocator, end_face, true, end_cap_topo) catch return error.OutOfMemory;
        solid.faces.slice().items(.outer_loop)[end_face] = end_loop;

        prev_he = null;
        var end_first_he: HalfEdgeId = 0;
        for (0..n_pts) |p_idx| {
            const v = grid_v[(slice_count - 1) * n_pts + p_idx];
            const he = solid.addHalfEdge(allocator, v, end_loop, end_cap_topo) catch return error.OutOfMemory;
            if (p_idx == 0) end_first_he = he;
            if (prev_he) |prv| solid.setNextPrev(prv, he);
            prev_he = he;
        }
        if (prev_he) |prv| solid.setNextPrev(prv, end_first_he);
        solid.loops.slice().items(.half_edge)[end_loop] = end_first_he;
    }

    solid.updateMetrics();
    return solid;
}


test "Revolve square into torus B-Rep" {
    const allocator = std.testing.allocator;

    // Small square offset from axis by radius 10
    const profile = [_][2]f32{
        .{ 8.0, -1.0 },
        .{ 12.0, -1.0 },
        .{ 12.0, 1.0 },
        .{ 8.0, 1.0 },
    };

    var solid = try revolveProfile(
        allocator,
        1,
        &profile,
        Vec3.init(0, 0, 0),
        Vec3.init(0, 0, 1),
        2.0 * std.math.pi,
        8, // 8 slices
    );
    defer solid.deinit(allocator);

    // 4 points * 8 slices = 32 vertices
    try std.testing.expectEqual(@as(usize, 32), solid.vertices.len);
    // 4 * 8 = 32 quad faces
    try std.testing.expectEqual(@as(usize, 32), solid.faces.len);
    // For torus: genus G = 1, so Euler-Poincaré = 0
    try std.testing.expectEqual(@as(i32, 0), solid.calcEulerPoincare(1));

    try std.testing.expect(solid.volume > 0.0);
    try std.testing.expect(solid.surface_area > 0.0);
}

test "Revolve wire in 3D: 180-degree partial revolution" {
    const allocator = std.testing.allocator;

    const wire = [_]Vec3{
        Vec3.init(5, 0, -2),
        Vec3.init(7, 0, -2),
        Vec3.init(7, 0, 2),
        Vec3.init(5, 0, 2),
    };

    var solid = try revolveWire3D(
        allocator,
        10,
        &wire,
        Vec3.init(0, 0, 0),
        Vec3.init(0, 0, 1),
        std.math.pi, // 180 degrees
        8,
    );
    defer solid.deinit(allocator);

    // 4 points * 9 slices = 36 vertices
    // 8 quad slices * 4 quads + 2 caps = 34 faces
    try std.testing.expectEqual(@as(usize, 36), solid.vertices.len);
    try std.testing.expectEqual(@as(usize, 34), solid.faces.len);

    try std.testing.expect(solid.volume > 0.0);
    try std.testing.expect(solid.surface_area > 0.0);
}

