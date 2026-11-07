const std = @import("std");
const memory = @import("memory.zig");
const nurbs = @import("geom/nurbs.zig");
const curve_wire = @import("curve_wire.zig");
const topo_id = @import("topo/topo_id.zig");
const autodiff = @import("autodiff.zig");
const implicit_field = @import("implicit_field.zig");

pub const Vec3d = nurbs.Vec3d;
pub const TopoId = topo_id.TopoId;
pub const TopoFlags = topo_id.TopoFlags;
pub const h64 = topo_id.h64;

pub const SUBSHAPE_VERTEX: u8 = 1;
pub const SUBSHAPE_EDGE: u8 = 2;
pub const SUBSHAPE_WIRE: u8 = 3;
pub const SUBSHAPE_FACE: u8 = 4;
pub const SUBSHAPE_SHELL: u8 = 5;
pub const SUBSHAPE_SOLID: u8 = 6;

pub const ERR_SWEEP_SELF_INTERSECT: u32 = 0x0401;
pub const ERR_FILLET_RADIUS_COLLAPSE: u32 = 0x0402;
pub const ERR_SSI_CONVERGENCE: u32 = 0x0403;
pub const ERR_EULER_POINCARE: u32 = 0x0404;
pub const ERR_NON_MANIFOLD_EDGE: u32 = 0x0405;
pub const ERR_REGION_UNBOUNDED: u32 = 0x0406;
pub const ERR_TOPOID_OVERFLOW: u32 = 0x0407;

pub var last_brep_status: u32 = 0;

pub fn makeTopoId(solid_id: u32, subshape_type: u8, local_idx: u32) TopoId {
    const f_hash = (@as(u64, solid_id) << 32) | @as(u64, local_idx);
    return TopoId.init(f_hash, 0, subshape_type, TopoFlags.ANALYTIC, 0);
}

pub fn makeNamedTopoId(feature_id: []const u8, branch_id: []const u8, subshape_type: u8, flags: u8, split_gen: u32) TopoId {
    const fh = if (feature_id.len > 0) h64(feature_id) else 1;
    const bh = if (branch_id.len > 0) h64(branch_id) else 0;
    return TopoId.init(fh, bh, subshape_type, flags, split_gen);
}

// ============================================================================
// Analytic Curvature Metadata per Face / Triangle (CDML §10.2)
// ============================================================================

pub const FaceCurvature = struct {
    k_min: f64 = 0.0,
    k_max: f64 = 0.0,
    k_gauss: f64 = 0.0,
    k_mean: f64 = 0.0,
};

// ============================================================================
// B-Rep Solid Mesh & Topology Data Structure
// ============================================================================

pub const BRepSolid = struct {
    solid_id: u32,
    feature_hash: u64 = 0,
    vertices: std.ArrayList(Vec3d) = .empty,
    normals: std.ArrayList(Vec3d) = .empty,
    indices: std.ArrayList(u32) = .empty,
    triangle_to_topo_id: std.ArrayList(TopoId) = .empty,
    triangle_curvatures: std.ArrayList(FaceCurvature) = .empty,
    genus: usize = 0,
    shells: usize = 1,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, solid_id: u32) BRepSolid {
        return .{
            .solid_id = solid_id,
            .feature_hash = (@as(u64, solid_id) << 32) | 1,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *BRepSolid) void {
        self.vertices.deinit(self.allocator);
        self.normals.deinit(self.allocator);
        self.indices.deinit(self.allocator);
        self.triangle_to_topo_id.deinit(self.allocator);
        self.triangle_curvatures.deinit(self.allocator);
    }

    pub fn clone(self: *const BRepSolid, allocator: std.mem.Allocator, new_id: u32) !BRepSolid {
        var copy = BRepSolid.init(allocator, new_id);
        copy.feature_hash = self.feature_hash;
        copy.genus = self.genus;
        copy.shells = self.shells;
        try copy.vertices.appendSlice(allocator, self.vertices.items);
        try copy.normals.appendSlice(allocator, self.normals.items);
        try copy.indices.appendSlice(allocator, self.indices.items);
        try copy.triangle_to_topo_id.appendSlice(allocator, self.triangle_to_topo_id.items);
        try copy.triangle_curvatures.appendSlice(allocator, self.triangle_curvatures.items);
        return copy;
    }

    pub fn addTriangle(
        self: *BRepSolid,
        idx0: u32,
        idx1: u32,
        idx2: u32,
        tid: TopoId,
        curv: FaceCurvature,
    ) !void {
        try self.indices.appendSlice(self.allocator, &[_]u32{ idx0, idx1, idx2 });
        try self.triangle_to_topo_id.append(self.allocator, tid);
        try self.triangle_curvatures.append(self.allocator, curv);
    }

    pub fn getCurvature(self: *const BRepSolid, tri_idx: usize) FaceCurvature {
        if (tri_idx < self.triangle_curvatures.items.len) {
            return self.triangle_curvatures.items[tri_idx];
        }
        return .{};
    }

    /// Computes exact enclosed volume via the discrete Divergence Theorem:
    /// V = | (1/6) * sum_t p0_t . (p1_t x p2_t) |
    pub fn computeEnclosedVolume(self: *const BRepSolid) f64 {
        const tri_count = self.indices.items.len / 3;
        var sum6: f64 = 0.0;
        for (0..tri_count) |t| {
            const idx0 = self.indices.items[t * 3];
            const idx1 = self.indices.items[t * 3 + 1];
            const idx2 = self.indices.items[t * 3 + 2];
            if (idx0 >= self.vertices.items.len or idx1 >= self.vertices.items.len or idx2 >= self.vertices.items.len) continue;
            const p0 = self.vertices.items[idx0];
            const p1 = self.vertices.items[idx1];
            const p2 = self.vertices.items[idx2];
            sum6 += p0.dot(p1.cross(p2));
        }
        return @abs(sum6) / 6.0;
    }

    /// Verifies 2-manifold edge incidence (every undirected edge shared by exactly 2 triangles) (§10.3)
    pub fn verifyTwoManifoldEdges(self: *const BRepSolid) bool {
        const tri_count = self.indices.items.len / 3;
        if (tri_count < 4) return false;

        var edge_counts = std.AutoHashMap(u64, u32).init(self.allocator);
        defer edge_counts.deinit();

        for (0..tri_count) |t| {
            const idx0 = self.indices.items[t * 3];
            const idx1 = self.indices.items[t * 3 + 1];
            const idx2 = self.indices.items[t * 3 + 2];

            const e1 = makeEdgeKey(idx0, idx1);
            const e2 = makeEdgeKey(idx1, idx2);
            const e3 = makeEdgeKey(idx2, idx0);

            edge_counts.put(e1, (edge_counts.get(e1) orelse 0) + 1) catch {};
            edge_counts.put(e2, (edge_counts.get(e2) orelse 0) + 1) catch {};
            edge_counts.put(e3, (edge_counts.get(e3) orelse 0) + 1) catch {};
        }

        var it = edge_counts.valueIterator();
        while (it.next()) |cnt| {
            if (cnt.* != 2) return false;
        }
        return true;
    }

    /// Verifies the Euler–Poincaré formula: V - E + F = 2(S - G)
    pub fn verifyEulerPoincare(self: *const BRepSolid) bool {
        const V = self.vertices.items.len;
        const tri_count = self.indices.items.len / 3;
        if (V < 4 or tri_count < 4) return false;

        var edge_set = std.AutoHashMap(u64, void).init(self.allocator);
        defer edge_set.deinit();

        for (0..tri_count) |t| {
            const idx0 = self.indices.items[t * 3];
            const idx1 = self.indices.items[t * 3 + 1];
            const idx2 = self.indices.items[t * 3 + 2];

            const e1 = makeEdgeKey(idx0, idx1);
            const e2 = makeEdgeKey(idx1, idx2);
            const e3 = makeEdgeKey(idx2, idx0);

            edge_set.put(e1, {}) catch {};
            edge_set.put(e2, {}) catch {};
            edge_set.put(e3, {}) catch {};
        }

        const E = edge_set.count();
        const F = tri_count;
        const S: usize = @max(1, self.shells);
        const G = self.genus;

        const lhs = @as(i64, @intCast(V)) - @as(i64, @intCast(E)) + @as(i64, @intCast(F));
        const rhs = 2 * (@as(i64, @intCast(S)) - @as(i64, @intCast(G)));

        return lhs == rhs;
    }
};

pub fn makeEdgeKey(v0: u32, v1: u32) u64 {
    const min_v = @min(v0, v1);
    const max_v = @max(v0, v1);
    return (@as(u64, min_v) << 32) | @as(u64, max_v);
}

// ============================================================================
// Sampled 2D Wire Profile Loop (Outer or Hole) for Sweeps (§6.3, §7.1)
// ============================================================================

pub const ProfileEdgeSample2D = struct {
    u: f64,
    v: f64,
    curve_hash: u64,
    curvature_2d: f64 = 0.0,
};

pub const ProfileLoop2D = struct {
    wire_id: []const u8,
    is_hole: bool,
    points: []const ProfileEdgeSample2D, // ordered counter-clockwise for outer, clockwise or CCW for hole
};

pub const TrajectoryStep = struct {
    v: f64,
    translation: Vec3d,
    axis: Vec3d = Vec3d.init(0.0, 0.0, 1.0),
    angle_rad: f64 = 0.0,
};

/// Rodrigues / Lie algebra exponential map rotation R(v) = exp(theta * [omega]_x)
pub fn rotateRodrigues(pt: Vec3d, axis: Vec3d, angle_rad: f64) Vec3d {
    if (@abs(angle_rad) < 1e-15) return pt;
    const k = axis.normalize();
    const cos_a = @cos(angle_rad);
    const sin_a = @sin(angle_rad);
    const k_cross_p = k.cross(pt);
    const k_dot_p = k.dot(pt);
    return pt.scale(cos_a).add(k_cross_p.scale(sin_a)).add(k.scale(k_dot_p * (1.0 - cos_a)));
}

pub fn evalTrajectoryPoint(
    local_u: f64,
    local_v: f64,
    frame_p0: Vec3d,
    frame_e1: Vec3d,
    frame_e2: Vec3d,
    step: TrajectoryStep,
) Vec3d {
    const c_u = frame_p0.add(frame_e1.scale(local_u)).add(frame_e2.scale(local_v));
    const rotated = rotateRodrigues(c_u, step.axis, step.angle_rad);
    return rotated.add(step.translation);
}

// ============================================================================
// 2D Constrained Ear-Clipping Triangulator with Hole Bridge Merging (§6.3, §7.1)
// ============================================================================

const PolyVert2D = struct {
    u: f64,
    v: f64,
    orig_idx: u32,
};

fn signedArea2D(pts: []const PolyVert2D) f64 {
    if (pts.len < 3) return 0.0;
    var area2: f64 = 0.0;
    for (0..pts.len) |i| {
        const p0 = pts[i];
        const p1 = pts[(i + 1) % pts.len];
        area2 += p0.u * p1.v - p1.u * p0.v;
    }
    return 0.5 * area2;
}

fn cross2D(ax: f64, ay: f64, bx: f64, by: f64, cx: f64, cy: f64) f64 {
    return (bx - ax) * (cy - ay) - (by - ay) * (cx - ax);
}

fn pointInTriangle2D(px: f64, py: f64, ax: f64, ay: f64, bx: f64, by: f64, cx: f64, cy: f64) bool {
    const c1 = cross2D(ax, ay, bx, by, px, py);
    const c2 = cross2D(bx, by, cx, cy, px, py);
    const c3 = cross2D(cx, cy, ax, ay, px, py);
    return (c1 >= -1e-11 and c2 >= -1e-11 and c3 >= -1e-11);
}

fn segmentsIntersectStrict2D(ax: f64, ay: f64, bx: f64, by: f64, cx: f64, cy: f64, dx: f64, dy: f64) bool {
    const d1 = cross2D(cx, cy, dx, dy, ax, ay);
    const d2 = cross2D(cx, cy, dx, dy, bx, by);
    const d3 = cross2D(ax, ay, bx, by, cx, cy);
    const d4 = cross2D(ax, ay, bx, by, dx, dy);
    if (((d1 > 1e-10 and d2 < -1e-10) or (d1 < -1e-10 and d2 > 1e-10)) and
        ((d3 > 1e-10 and d4 < -1e-10) or (d3 < -1e-10 and d4 > 1e-10)))
    {
        return true;
    }
    return false;
}

/// Triangulates an outer 2D polygon with 0 or more interior holes into CCW triangles of `orig_idx`
pub fn triangulatePolygonWithHoles2D(
    allocator: std.mem.Allocator,
    outer_pts: []const PolyVert2D,
    holes: []const []const PolyVert2D,
    out_tris: *std.ArrayList([3]u32),
) !void {
    var poly: std.ArrayList(PolyVert2D) = .empty;
    defer poly.deinit(allocator);

    try poly.appendSlice(allocator, outer_pts);
    // Ensure outer polygon is CCW (positive signed area)
    if (signedArea2D(poly.items) < 0.0) {
        std.mem.reverse(PolyVert2D, poly.items);
    }

    // Splice each hole into `poly` via rightmost-vertex visibility bridge (Eberly hole-merging)
    var hole_flags = try allocator.alloc(bool, holes.len);
    defer allocator.free(hole_flags);
    @memset(hole_flags, false);

    for (0..holes.len) |_| {
        // Pick unprocessed hole with maximum u coordinate
        var best_h: ?usize = null;
        var best_right_u: f64 = -1e30;
        var best_h_v_idx: usize = 0;

        for (holes, 0..) |h_slice, h_idx| {
            if (hole_flags[h_idx] or h_slice.len < 3) continue;
            for (h_slice, 0..) |hv, vi| {
                if (hv.u > best_right_u) {
                    best_right_u = hv.u;
                    best_h = h_idx;
                    best_h_v_idx = vi;
                }
            }
        }

        const h_idx = best_h orelse break;
        hole_flags[h_idx] = true;

        const h_loop = try allocator.dupe(PolyVert2D, holes[h_idx]);
        defer allocator.free(h_loop);

        // Ensure hole is CW (negative signed area)
        if (signedArea2D(h_loop) > 0.0) {
            std.mem.reverse(PolyVert2D, h_loop);
        }

        // Re-find rightmost vertex index in CW hole
        var rm_idx: usize = 0;
        for (h_loop, 0..) |hv, vi| {
            if (hv.u > h_loop[rm_idx].u) {
                rm_idx = vi;
            }
        }
        const M = h_loop[rm_idx];

        // Find mutually visible vertex on current outer polygon `poly`
        // Simplest robust choice: pick outer vertex P maximizing visibility or closest in distance without crossing edges
        var best_outer_idx: usize = 0;
        var best_dist_sq: f64 = 1e30;
        for (poly.items, 0..) |pv, pi| {
            const du = pv.u - M.u;
            const dv = pv.v - M.v;
            const dsq = du * du + dv * dv;
            var crosses = false;
            for (0..poly.items.len) |ei| {
                const e_next = (ei + 1) % poly.items.len;
                if (ei == pi or e_next == pi) continue;
                const a = poly.items[ei];
                const b = poly.items[e_next];
                if (segmentsIntersectStrict2D(M.u, M.v, pv.u, pv.v, a.u, a.v, b.u, b.v)) {
                    crosses = true;
                    break;
                }
            }
            if (!crosses and dsq < best_dist_sq) {
                best_dist_sq = dsq;
                best_outer_idx = pi;
            }
        }

        // Splice: poly[0..best_outer_idx] + M..h_loop..M + poly[best_outer_idx..]
        var merged: std.ArrayList(PolyVert2D) = .empty;
        for (0..best_outer_idx + 1) |k| {
            try merged.append(allocator, poly.items[k]);
        }
        for (0..h_loop.len) |k| {
            try merged.append(allocator, h_loop[(rm_idx + k) % h_loop.len]);
        }
        try merged.append(allocator, M);
        for (best_outer_idx..poly.items.len) |k| {
            try merged.append(allocator, poly.items[k]);
        }
        poly.deinit(allocator);
        poly = merged;
    }

    // Ear clipping on merged simple polygon `poly`
    var guard: usize = 0;
    const max_guard = poly.items.len * poly.items.len + 64;
    while (poly.items.len >= 3 and guard < max_guard) : (guard += 1) {
        const n = poly.items.len;
        if (n == 3) {
            const p0 = poly.items[0];
            const p1 = poly.items[1];
            const p2 = poly.items[2];
            if (p0.orig_idx != p1.orig_idx and p1.orig_idx != p2.orig_idx and p2.orig_idx != p0.orig_idx) {
                try out_tris.append(allocator, .{ p0.orig_idx, p1.orig_idx, p2.orig_idx });
            }
            break;
        }

        var ear_found = false;
        // Pass 1: strict convex ear with no interior vertices
        for (0..n) |i| {
            const prev = poly.items[(i + n - 1) % n];
            const curr = poly.items[i];
            const next = poly.items[(i + 1) % n];

            const cr = cross2D(prev.u, prev.v, curr.u, curr.v, next.u, next.v);
            if (cr <= 1e-11) continue;

            var contains_other = false;
            for (0..n) |j| {
                if (j == (i + n - 1) % n or j == i or j == (i + 1) % n) continue;
                const p = poly.items[j];
                if (p.orig_idx == prev.orig_idx or p.orig_idx == curr.orig_idx or p.orig_idx == next.orig_idx) continue;
                if (pointInTriangle2D(p.u, p.v, prev.u, prev.v, curr.u, curr.v, next.u, next.v)) {
                    contains_other = true;
                    break;
                }
            }

            if (!contains_other) {
                if (prev.orig_idx != curr.orig_idx and curr.orig_idx != next.orig_idx and next.orig_idx != prev.orig_idx) {
                    try out_tris.append(allocator, .{ prev.orig_idx, curr.orig_idx, next.orig_idx });
                }
                _ = poly.orderedRemove(i);
                ear_found = true;
                break;
            }
        }

        if (!ear_found) {
            // Fallback: clip best convex (or least-reflex) vertex to guarantee termination on degenerate bridge slits
            var best_i: usize = 0;
            var best_cr: f64 = -1e30;
            for (0..n) |i| {
                const prev = poly.items[(i + n - 1) % n];
                const curr = poly.items[i];
                const next = poly.items[(i + 1) % n];
                const cr = cross2D(prev.u, prev.v, curr.u, curr.v, next.u, next.v);
                if (cr > best_cr) {
                    best_cr = cr;
                    best_i = i;
                }
            }
            const prev = poly.items[(best_i + n - 1) % n];
            const curr = poly.items[best_i];
            const next = poly.items[(best_i + 1) % n];
            if (prev.orig_idx != curr.orig_idx and curr.orig_idx != next.orig_idx and next.orig_idx != prev.orig_idx and best_cr > -1e-9) {
                try out_tris.append(allocator, .{ prev.orig_idx, curr.orig_idx, next.orig_idx });
            }
            _ = poly.orderedRemove(best_i);
        }
    }
}

// ============================================================================
// Multi-Wire SE(3) Sweep with Outer + Hole Loops & SHA-256 TopoId (§7.1, §10.1)
// ============================================================================

pub fn sweepProfileLoopsSE3(
    allocator: std.mem.Allocator,
    feature_hash: u64,
    sweep_branch_hash: u64,
    frame_p0: Vec3d,
    frame_e1: Vec3d,
    frame_e2: Vec3d,
    outer_loop: ProfileLoop2D,
    hole_loops: []const ProfileLoop2D,
    traj_steps: []const TrajectoryStep,
    cap_ends: bool,
) !u64 {
    last_brep_status = 0;
    if (outer_loop.points.len < 3 or traj_steps.len < 2) {
        last_brep_status = ERR_SWEEP_SELF_INTERSECT;
        return error.SweepSelfIntersect;
    }

    const solid_id = next_solid_id;
    next_solid_id += 1;

    var solid = BRepSolid.init(allocator, solid_id);
    errdefer solid.deinit();
    solid.feature_hash = feature_hash;
    solid.genus = hole_loops.len;

    const frame_normal = frame_e1.cross(frame_e2).normalize();
    const K = traj_steps.len; // number of trajectory stations v_0 .. v_{K-1}

    // Track vertex index offsets for each loop at each station k in 0..K
    // Loop 0 = outer_loop, Loop 1..H = hole_loops
    const total_loops = 1 + hole_loops.len;
    var loop_offsets = try allocator.alloc(u32, total_loops * K);
    defer allocator.free(loop_offsets);

    // 1. Emit vertices for all loops across all K trajectory stations
    for (0..K) |k| {
        const step = traj_steps[k];
        const station_nrm = rotateRodrigues(frame_normal, step.axis, step.angle_rad).normalize();

        // Outer loop at station k
        loop_offsets[0 * K + k] = @intCast(solid.vertices.items.len);
        for (outer_loop.points) |pt| {
            const wp = evalTrajectoryPoint(pt.u, pt.v, frame_p0, frame_e1, frame_e2, step);
            try solid.vertices.append(allocator, wp);
            try solid.normals.append(allocator, station_nrm);
        }

        // Hole loops at station k
        for (hole_loops, 0..) |hl, h_idx| {
            loop_offsets[(1 + h_idx) * K + k] = @intCast(solid.vertices.items.len);
            for (hl.points) |pt| {
                const wp = evalTrajectoryPoint(pt.u, pt.v, frame_p0, frame_e1, frame_e2, step);
                try solid.vertices.append(allocator, wp);
                try solid.normals.append(allocator, station_nrm);
            }
        }
    }

    // 2. Check sweep Jacobian ||dS/du x dS/dv|| > 0 and emit lateral faces for outer and hole loops
    for (0..total_loops) |l_idx| {
        const loop = if (l_idx == 0) outer_loop else hole_loops[l_idx - 1];
        const M = loop.points.len;
        const is_hole = loop.is_hole;

        for (0..K - 1) |k| {
            for (0..M) |i| {
                const next_i = (i + 1) % M;
                const b0 = loop_offsets[l_idx * K + k] + @as(u32, @intCast(i));
                const b1 = loop_offsets[l_idx * K + k] + @as(u32, @intCast(next_i));
                const t0 = loop_offsets[l_idx * K + (k + 1)] + @as(u32, @intCast(i));
                const t1 = loop_offsets[l_idx * K + (k + 1)] + @as(u32, @intCast(next_i));

                const p_b0 = solid.vertices.items[b0];
                const p_b1 = solid.vertices.items[b1];
                const p_t0 = solid.vertices.items[t0];

                const ds_du = p_b1.sub(p_b0);
                const ds_dv = p_t0.sub(p_b0);
                const cross_uv = ds_du.cross(ds_dv);
                if (cross_uv.length() < 1e-10) {
                    last_brep_status = ERR_SWEEP_SELF_INTERSECT;
                    return error.SweepSelfIntersect;
                }

                // Update vertex normals for lateral wall vertices
                const out_n = if (!is_hole) cross_uv.normalize() else cross_uv.normalize().scale(-1.0);
                solid.normals.items[b0] = out_n;
                solid.normals.items[t0] = out_n;

                const c_hash = if (loop.points[i].curve_hash != 0) loop.points[i].curve_hash else sweep_branch_hash;
                const tid = TopoId.init(feature_hash, c_hash, SUBSHAPE_FACE, TopoFlags.ANALYTIC | TopoFlags.PRESERVE, 0);

                // Curvature along lateral face:
                // For straight extrusion of a curve with planar curvature kappa_2d:
                // k_min = 0, k_max = kappa_2d, k_gauss = 0, k_mean = 0.5 * kappa_2d
                const k2d = loop.points[i].curvature_2d;
                const curv = FaceCurvature{
                    .k_min = 0.0,
                    .k_max = k2d,
                    .k_gauss = 0.0,
                    .k_mean = 0.5 * k2d,
                };

                if (!is_hole) {
                    // Outer wall: outward normal
                    try solid.addTriangle(b0, b1, t1, tid, curv);
                    try solid.addTriangle(b0, t1, t0, tid, curv);
                } else {
                    // Inner hole wall: points inward toward hole center!
                    // Wait: if hole loop points are sampled CCW (like cos(2*pi*t), sin(2*pi*t)),
                    // then b0 -> b1 -> t1 has normal pointing OUTWARD from the cylinder (which is into the solid material!).
                    // The outward normal of the solid on a hole wall points INWARD toward the hole axis!
                    // Let's check signed area of the hole loop:
                    var area2: f64 = 0.0;
                    for (0..M) |mi| {
                        const p_curr = loop.points[mi];
                        const p_next = loop.points[(mi + 1) % M];
                        area2 += p_curr.u * p_next.v - p_next.u * p_curr.v;
                    }
                    if (area2 > 0.0) {
                        // Loop is CCW in (u,v), so reverse winding for hole wall so normal points toward hole center
                        try solid.addTriangle(b0, t1, b1, tid, curv);
                        try solid.addTriangle(b0, t0, t1, tid, curv);
                    } else {
                        // Loop is already CW in (u,v)
                        try solid.addTriangle(b0, b1, t1, tid, curv);
                        try solid.addTriangle(b0, t1, t0, tid, curv);
                    }
                }
            }
        }
    }

    // 3. Triangulate bottom (k = 0) and top (k = K - 1) planar caps with holes
    if (cap_ends) {
        var outer_poly = try allocator.alloc(PolyVert2D, outer_loop.points.len);
        defer allocator.free(outer_poly);
        for (outer_loop.points, 0..) |pt, i| {
            outer_poly[i] = .{ .u = pt.u, .v = pt.v, .orig_idx = @intCast(i) };
        }

        var hole_polys = try allocator.alloc([]PolyVert2D, hole_loops.len);
        defer {
            for (hole_polys) |hp| allocator.free(hp);
            allocator.free(hole_polys);
        }

        var cum_offset: u32 = @intCast(outer_loop.points.len);
        for (hole_loops, 0..) |hl, h_idx| {
            hole_polys[h_idx] = try allocator.alloc(PolyVert2D, hl.points.len);
            for (hl.points, 0..) |pt, i| {
                hole_polys[h_idx][i] = .{
                    .u = pt.u,
                    .v = pt.v,
                    .orig_idx = cum_offset + @as(u32, @intCast(i)),
                };
            }
            cum_offset += @intCast(hl.points.len);
        }

        var cap_tris: std.ArrayList([3]u32) = .empty;
        defer cap_tris.deinit(allocator);
        try triangulatePolygonWithHoles2D(allocator, outer_poly, hole_polys, &cap_tris);

        const mapLocalIdx = struct {
            fn map(local_idx: u32, station_k: usize, num_k: usize, outer_len: usize, holes_slice: []const ProfileLoop2D, offsets: []const u32) u32 {
                if (local_idx < outer_len) {
                    return offsets[0 * num_k + station_k] + local_idx;
                }
                var rem = local_idx - @as(u32, @intCast(outer_len));
                for (holes_slice, 0..) |hl, hi| {
                    const hlen: u32 = @intCast(hl.points.len);
                    if (rem < hlen) {
                        return offsets[(1 + hi) * num_k + station_k] + rem;
                    }
                    rem -= hlen;
                }
                return offsets[station_k];
            }
        }.map;

        const bot_tid = TopoId.init(feature_hash, sweep_branch_hash, SUBSHAPE_FACE, TopoFlags.ANALYTIC | TopoFlags.BOUNDARY, 0);
        const top_tid = TopoId.init(feature_hash, sweep_branch_hash, SUBSHAPE_FACE, TopoFlags.ANALYTIC | TopoFlags.BOUNDARY, 0);
        const flat_curv = FaceCurvature{ .k_min = 0.0, .k_max = 0.0, .k_gauss = 0.0, .k_mean = 0.0 };

        // Bottom cap (k = 0): reverse winding so normal points along -frame_normal
        for (cap_tris.items) |tri| {
            const v0 = mapLocalIdx(tri[0], 0, K, outer_loop.points.len, hole_loops, loop_offsets);
            const v1 = mapLocalIdx(tri[2], 0, K, outer_loop.points.len, hole_loops, loop_offsets);
            const v2 = mapLocalIdx(tri[1], 0, K, outer_loop.points.len, hole_loops, loop_offsets);
            try solid.addTriangle(v0, v1, v2, bot_tid, flat_curv);
        }

        // Top cap (k = K - 1): forward CCW winding so normal points along +frame_normal
        for (cap_tris.items) |tri| {
            const v0 = mapLocalIdx(tri[0], K - 1, K, outer_loop.points.len, hole_loops, loop_offsets);
            const v1 = mapLocalIdx(tri[1], K - 1, K, outer_loop.points.len, hole_loops, loop_offsets);
            const v2 = mapLocalIdx(tri[2], K - 1, K, outer_loop.points.len, hole_loops, loop_offsets);
            try solid.addTriangle(v0, v1, v2, top_tid, flat_curv);
        }
    }

    const handle: u64 = (@as(u64, 0b00) << 62) | @as(u64, solid_id);
    try solid_brep_store.put(handle, solid);
    recordSweepSource(handle, feature_hash, sweep_branch_hash, frame_p0, frame_e1, frame_e2, outer_loop, hole_loops, traj_steps, cap_ends) catch {};
    return handle;
}

// ============================================================================
// Multi-Wire SE(3) Revolution Solid with Watertight Closure
// ============================================================================

pub fn revolveProfileLoops(
    allocator: std.mem.Allocator,
    feature_hash: u64,
    revolve_branch_hash: u64,
    frame_p0: Vec3d,
    frame_e1: Vec3d,
    frame_e2: Vec3d,
    outer_loop: ProfileLoop2D,
    axis_origin: Vec3d,
    axis_direction: Vec3d,
    angle_rad: f64,
    n_slices_opt: ?usize,
) !u64 {
    last_brep_status = 0;
    const M = outer_loop.points.len;
    if (M < 3) {
        last_brep_status = ERR_SWEEP_SELF_INTERSECT;
        return error.SweepSelfIntersect;
    }

    const axis_norm = axis_direction.normalize();
    if (axis_norm.length() < 1e-9) {
        last_brep_status = ERR_SWEEP_SELF_INTERSECT;
        return error.SweepSelfIntersect;
    }

    const N = n_slices_opt orelse 32;
    if (N < 3) {
        last_brep_status = ERR_SWEEP_SELF_INTERSECT;
        return error.SweepSelfIntersect;
    }

    // Check signed area to ensure CCW polygon orientation
    var area2: f64 = 0.0;
    for (0..M) |i| {
        const curr = outer_loop.points[i];
        const next = outer_loop.points[(i + 1) % M];
        area2 += curr.u * next.v - next.u * curr.v;
    }
    const is_ccw = (area2 >= 0.0);

    // Create oriented points slice
    var poly_pts = try allocator.alloc(ProfileEdgeSample2D, M);
    defer allocator.free(poly_pts);
    for (0..M) |i| {
        if (is_ccw) {
            poly_pts[i] = outer_loop.points[i];
        } else {
            poly_pts[i] = outer_loop.points[M - 1 - i];
        }
    }

    const solid_id = next_solid_id;
    next_solid_id += 1;

    var solid = BRepSolid.init(allocator, solid_id);
    errdefer solid.deinit();
    solid.feature_hash = feature_hash;

    // Check if any vertex touches the axis (determines genus)
    var touches_axis = false;
    for (0..M) |i| {
        const p_3d = frame_p0.add(frame_e1.scale(poly_pts[i].u)).add(frame_e2.scale(poly_pts[i].v));
        const w = p_3d.sub(axis_origin);
        const w_proj = axis_norm.scale(axis_norm.dot(w));
        const w_perp = w.sub(w_proj);
        if (w_perp.length() < 1e-5) {
            touches_axis = true;
            break;
        }
    }
    solid.genus = if (touches_axis) 0 else 1;

    // Allocate vertex index mapping: [M][N]
    var vert_indices = try allocator.alloc(u32, M * N);
    defer allocator.free(vert_indices);

    // Emit vertices
    for (0..M) |i| {
        const p_3d = frame_p0.add(frame_e1.scale(poly_pts[i].u)).add(frame_e2.scale(poly_pts[i].v));
        const w = p_3d.sub(axis_origin);
        const w_proj = axis_norm.scale(axis_norm.dot(w));
        const w_perp = w.sub(w_proj);
        const r_axis = w_perp.length();

        if (r_axis < 1e-5) {
            // Apex vertex on axis: single shared vertex for all k
            const apex_pt = axis_origin.add(w_proj);
            const v_idx: u32 = @intCast(solid.vertices.items.len);
            try solid.vertices.append(allocator, apex_pt);
            try solid.normals.append(allocator, Vec3d.init(0.0, 0.0, 0.0));
            for (0..N) |k| {
                vert_indices[i * N + k] = v_idx;
            }
        } else {
            // Off axis: N vertices rotated around the axis
            const inv_n: f64 = 1.0 / @as(f64, @floatFromInt(N));
            for (0..N) |k| {
                const theta = @as(f64, @floatFromInt(k)) * inv_n * angle_rad;
                const pt_k = axis_origin.add(rotateRodrigues(w, axis_norm, theta));
                const v_idx: u32 = @intCast(solid.vertices.items.len);
                try solid.vertices.append(allocator, pt_k);
                try solid.normals.append(allocator, Vec3d.init(0.0, 0.0, 0.0));
                vert_indices[i * N + k] = v_idx;
            }
        }
    }

    // Emit triangles
    for (0..M) |i| {
        const next_i = (i + 1) % M;
        const p0_3d = frame_p0.add(frame_e1.scale(poly_pts[i].u)).add(frame_e2.scale(poly_pts[i].v));
        const p1_3d = frame_p0.add(frame_e1.scale(poly_pts[next_i].u)).add(frame_e2.scale(poly_pts[next_i].v));
        const w0 = p0_3d.sub(axis_origin);
        const w1 = p1_3d.sub(axis_origin);
        const r0 = w0.sub(axis_norm.scale(axis_norm.dot(w0))).length();
        const r1 = w1.sub(axis_norm.scale(axis_norm.dot(w1))).length();

        if (r0 < 1e-5 and r1 < 1e-5) {
            // Both vertices on axis -> segment lies along the rotation axis, sweeps zero area
            continue;
        }

        const c_hash = if (poly_pts[i].curve_hash != 0) poly_pts[i].curve_hash else revolve_branch_hash;
        const tid = TopoId.init(feature_hash, c_hash, SUBSHAPE_FACE, TopoFlags.ANALYTIC | TopoFlags.PRESERVE, 0);
        const curv = FaceCurvature{};

        for (0..N) |k| {
            const next_k = (k + 1) % N;
            const v00 = vert_indices[i * N + k];
            const v01 = vert_indices[i * N + next_k];
            const v10 = vert_indices[next_i * N + k];
            const v11 = vert_indices[next_i * N + next_k];

            if (r0 < 1e-5) {
                // v00 == v01 (apex)
                try solid.addTriangle(v10, v00, v11, tid, curv);
            } else if (r1 < 1e-5) {
                // v10 == v11 (apex)
                try solid.addTriangle(v00, v01, v10, tid, curv);
            } else {
                try solid.addTriangle(v00, v01, v10, tid, curv);
                try solid.addTriangle(v10, v01, v11, tid, curv);
            }
        }
    }

    // Compute smooth vertex normals by accumulating triangle face normals
    const num_tris = solid.indices.items.len / 3;
    for (0..num_tris) |t| {
        const idx0 = solid.indices.items[t * 3 + 0];
        const idx1 = solid.indices.items[t * 3 + 1];
        const idx2 = solid.indices.items[t * 3 + 2];
        const p0 = solid.vertices.items[idx0];
        const p1 = solid.vertices.items[idx1];
        const p2 = solid.vertices.items[idx2];
        const fn_vec = p1.sub(p0).cross(p2.sub(p0));
        solid.normals.items[idx0] = solid.normals.items[idx0].add(fn_vec);
        solid.normals.items[idx1] = solid.normals.items[idx1].add(fn_vec);
        solid.normals.items[idx2] = solid.normals.items[idx2].add(fn_vec);
    }

    for (solid.normals.items) |*n| {
        const len = n.length();
        if (len > 1e-9) {
            n.* = n.scale(1.0 / len);
        } else {
            n.* = Vec3d.init(0.0, 0.0, 1.0);
        }
    }

    const handle: u64 = (@as(u64, 0b00) << 62) | @as(u64, solid_id);
    try solid_brep_store.put(handle, solid);
    return handle;
}

// ============================================================================
// Analytic Region B-Rep Builder (<brep region="..."/>, CDML §4.4–§4.5)
// ============================================================================

pub const RegionIneqTerm = struct {
    id: []const u8,
    branch_hash: u64,
    expr_str: []const u8, // f_i(x,y,z) >= 0 inside the region
};

/// Evaluates an analytic conjunction of inequalities `<brep region="..."/>`.
/// Supports cylinder/prism/box half-space intersections, tags every face with its `<ineq id>`'s `h64`,
/// and verifies 2-manifold closure and Euler–Poincaré.
pub fn constructAnalyticRegionBrep(
    allocator: std.mem.Allocator,
    feature_hash: u64,
    terms: []const RegionIneqTerm,
    var_indices: *const std.StringHashMap(u32),
    var_values: []const f64,
) !u64 {
    last_brep_status = 0;
    if (terms.len < 2) {
        last_brep_status = ERR_REGION_UNBOUNDED;
        return error.RegionUnbounded;
    }

    // Compile each inequality f_i(x,y,z) >= 0 in field context with x,y,z mapped to vars 0,1,2
    var map_with_xyz = std.StringHashMap(u32).init(allocator);
    defer map_with_xyz.deinit();

    var it = var_indices.iterator();
    while (it.next()) |entry| {
        try map_with_xyz.put(entry.key_ptr.*, entry.value_ptr.* + 3);
    }
    try map_with_xyz.put("x", 0);
    try map_with_xyz.put("y", 1);
    try map_with_xyz.put("z", 2);

    var compiled = try allocator.alloc(autodiff.Expression, terms.len);
    var compiled_count: usize = 0;
    defer {
        for (0..compiled_count) |i| compiled[i].deinit();
        allocator.free(compiled);
    }

    for (terms, 0..) |t, i| {
        compiled[i] = try autodiff.compileExpressionWithContext(allocator, t.expr_str, .field, &map_with_xyz);
        compiled_count += 1;
    }

    var eval_vars = try allocator.alloc(f64, 3 + var_values.len);
    defer allocator.free(eval_vars);
    for (var_values, 0..) |vv, i| {
        eval_vars[3 + i] = vv;
    }

    const evalTermAt = struct {
        fn call(expr: *const autodiff.Expression, ev_slice: []f64, x: f64, y: f64, z: f64) f64 {
            ev_slice[0] = x;
            ev_slice[1] = y;
            ev_slice[2] = z;
            return expr.evalScalar(ev_slice);
        }
    }.call;

    // 1. Check boundedness along +/-X, +/-Y, +/-Z at distance 1e6
    const far: f64 = 1e6;
    const dirs = [6][3]f64{
        .{ far, 0, 0 }, .{ -far, 0, 0 },
        .{ 0, far, 0 }, .{ 0, -far, 0 },
        .{ 0, 0, far }, .{ 0, 0, -far },
    };
    for (dirs) |d| {
        var all_pos = true;
        for (compiled) |*c| {
            if (evalTermAt(c, eval_vars, d[0], d[1], d[2]) < 0.0) {
                all_pos = false;
                break;
            }
        }
        if (all_pos) {
            last_brep_status = ERR_REGION_UNBOUNDED;
            return error.RegionUnbounded;
        }
    }

    // 2. Locate an interior seed point (seed_x, seed_y, seed_z) and find z_min, z_max, and XY bounds.
    var seed_x: f64 = 0.0;
    var seed_y: f64 = 0.0;
    var seed_z: f64 = 0.0;
    var z_lo: f64 = -500.0;
    var z_hi: f64 = 500.0;
    var z_mid: f64 = 1.0;

    // Fast path: check along (0, 0, z)
    var found_seed = false;
    var scan_z: f64 = -200.0;
    while (scan_z <= 200.0) : (scan_z += 0.5) {
        var inside = true;
        for (compiled) |*c| {
            if (evalTermAt(c, eval_vars, 0.0, 0.0, scan_z) < -1e-7) {
                inside = false;
                break;
            }
        }
        if (inside) {
            if (!found_seed) {
                z_lo = scan_z;
                found_seed = true;
            }
            z_hi = scan_z;
        }
    }

    if (found_seed) {
        seed_z = 0.5 * (z_lo + z_hi);
    } else {
        // General off-axis path: 3D Interval Arithmetic octree subdivision over [-500, 500]^3
        var eval_ivs = try allocator.alloc(autodiff.Interval, 3 + var_values.len);
        defer allocator.free(eval_ivs);
        for (var_values, 0..) |vv, i| {
            eval_ivs[3 + i] = autodiff.Interval.point(vv);
        }

        const SeedSearchCtx = struct {
            exprs: []const autodiff.Expression,
            ev_vars: []f64,
            ev_ivs: []autodiff.Interval,
            sum_x: f64 = 0.0,
            sum_y: f64 = 0.0,
            sum_z: f64 = 0.0,
            count: usize = 0,

            fn search(self: *@This(), depth: u5, x0: f64, x1: f64, y0: f64, y1: f64, z0: f64, z1: f64) void {
                if (self.count >= 64) return;
                self.ev_ivs[0] = autodiff.Interval.init(x0, x1);
                self.ev_ivs[1] = autodiff.Interval.init(y0, y1);
                self.ev_ivs[2] = autodiff.Interval.init(z0, z1);
                for (self.exprs) |*c| {
                    const iv = c.evalInterval(self.ev_ivs);
                    if (iv.max < -1e-7) return; // Pruned by Interval Arithmetic!
                }

                const xc = 0.5 * (x0 + x1);
                const yc = 0.5 * (y0 + y1);
                const zc = 0.5 * (z0 + z1);
                var center_in = true;
                self.ev_vars[0] = xc;
                self.ev_vars[1] = yc;
                self.ev_vars[2] = zc;
                for (self.exprs) |*c| {
                    if (c.evalScalar(self.ev_vars) < -1e-7) {
                        center_in = false;
                        break;
                    }
                }
                if (center_in) {
                    self.sum_x += xc;
                    self.sum_y += yc;
                    self.sum_z += zc;
                    self.count += 1;
                }
                if (depth >= 6) return;
                const next_d = depth + 1;
                self.search(next_d, x0, xc, y0, yc, z0, zc);
                self.search(next_d, xc, x1, y0, yc, z0, zc);
                self.search(next_d, x0, xc, yc, y1, z0, zc);
                self.search(next_d, xc, x1, yc, y1, z0, zc);
                self.search(next_d, x0, xc, y0, yc, zc, z1);
                self.search(next_d, xc, x1, y0, yc, zc, z1);
                self.search(next_d, x0, xc, yc, y1, zc, z1);
                self.search(next_d, xc, x1, yc, y1, zc, z1);
            }
        };

        var sctx = SeedSearchCtx{
            .exprs = compiled,
            .ev_vars = eval_vars,
            .ev_ivs = eval_ivs,
        };
        sctx.search(0, -500.0, 500.0, -500.0, 500.0, -500.0, 500.0);
        if (sctx.count == 0) {
            last_brep_status = ERR_REGION_UNBOUNDED;
            return error.RegionUnbounded;
        }
        const inv_c = 1.0 / @as(f64, @floatFromInt(sctx.count));
        seed_x = sctx.sum_x * inv_c;
        seed_y = sctx.sum_y * inv_c;
        seed_z = sctx.sum_z * inv_c;
        found_seed = true;

        // Center (seed_x, seed_y) via X and Y chord bisection at seed_z
        var x_in_pos = seed_x;
        var x_out_pos = seed_x + 500.0;
        for (0..40) |_| {
            const xm = 0.5 * (x_in_pos + x_out_pos);
            var inside = true;
            for (compiled) |*c| {
                if (evalTermAt(c, eval_vars, xm, seed_y, seed_z) < 0.0) {
                    inside = false;
                    break;
                }
            }
            if (inside) x_in_pos = xm else x_out_pos = xm;
        }
        var x_in_neg = seed_x;
        var x_out_neg = seed_x - 500.0;
        for (0..40) |_| {
            const xm = 0.5 * (x_in_neg + x_out_neg);
            var inside = true;
            for (compiled) |*c| {
                if (evalTermAt(c, eval_vars, xm, seed_y, seed_z) < 0.0) {
                    inside = false;
                    break;
                }
            }
            if (inside) x_in_neg = xm else x_out_neg = xm;
        }
        seed_x = 0.5 * (x_in_pos + x_in_neg);

        var y_in_pos = seed_y;
        var y_out_pos = seed_y + 500.0;
        for (0..40) |_| {
            const ym = 0.5 * (y_in_pos + y_out_pos);
            var inside = true;
            for (compiled) |*c| {
                if (evalTermAt(c, eval_vars, seed_x, ym, seed_z) < 0.0) {
                    inside = false;
                    break;
                }
            }
            if (inside) y_in_pos = ym else y_out_pos = ym;
        }
        var y_in_neg = seed_y;
        var y_out_neg = seed_y - 500.0;
        for (0..40) |_| {
            const ym = 0.5 * (y_in_neg + y_out_neg);
            var inside = true;
            for (compiled) |*c| {
                if (evalTermAt(c, eval_vars, seed_x, ym, seed_z) < 0.0) {
                    inside = false;
                    break;
                }
            }
            if (inside) y_in_neg = ym else y_out_neg = ym;
        }
        seed_y = 0.5 * (y_in_pos + y_in_neg);
        z_lo = seed_z;
        z_hi = seed_z;
    }

    // Refine exact z_lo and z_hi via bisection along (seed_x, seed_y, z)
    var a_lo: f64 = -500.0;
    var b_lo: f64 = seed_z;
    var bot_term_idx: usize = 0;
    for (0..45) |_| {
        const mid = 0.5 * (a_lo + b_lo);
        var inside = true;
        for (compiled, 0..) |*c, idx| {
            if (evalTermAt(c, eval_vars, seed_x, seed_y, mid) < 0.0) {
                inside = false;
                bot_term_idx = idx;
                break;
            }
        }
        if (inside) b_lo = mid else a_lo = mid;
    }
    z_lo = 0.5 * (a_lo + b_lo);

    var a_hi: f64 = seed_z;
    var b_hi: f64 = 500.0;
    var top_term_idx: usize = 0;
    for (0..45) |_| {
        const mid = 0.5 * (a_hi + b_hi);
        var inside = true;
        for (compiled, 0..) |*c, idx| {
            if (evalTermAt(c, eval_vars, seed_x, seed_y, mid) < 0.0) {
                inside = false;
                top_term_idx = idx;
                break;
            }
        }
        if (inside) a_hi = mid else b_hi = mid;
    }
    z_hi = 0.5 * (a_hi + b_hi);
    z_mid = 0.5 * (z_lo + z_hi);

    // 3. Sample radial boundary r(theta) in the XY plane around (seed_x, seed_y) at z_mid for N_theta = 128 angular stations
    const N_theta: usize = 128;
    var r_profile: [N_theta]f64 = undefined;
    var wall_term_indices: [N_theta]usize = undefined;

    for (0..N_theta) |ti| {
        const theta = (2.0 * std.math.pi * @as(f64, @floatFromInt(ti))) / @as(f64, @floatFromInt(N_theta));
        const ct = @cos(theta);
        const st = @sin(theta);

        var r_in: f64 = 0.0;
        var r_out: f64 = 500.0;
        var active_wall_idx: usize = 0;
        for (0..45) |_| {
            const r_m = 0.5 * (r_in + r_out);
            var inside = true;
            for (compiled, 0..) |*c, idx| {
                if (evalTermAt(c, eval_vars, seed_x + r_m * ct, seed_y + r_m * st, z_mid) < 0.0) {
                    inside = false;
                    active_wall_idx = idx;
                    break;
                }
            }
            if (inside) r_in = r_m else r_out = r_m;
        }
        r_profile[ti] = 0.5 * (r_in + r_out);
        wall_term_indices[ti] = active_wall_idx;
    }

    const solid_id = next_solid_id;
    next_solid_id += 1;

    var solid = BRepSolid.init(allocator, solid_id);
    errdefer solid.deinit();
    solid.feature_hash = feature_hash;

    // Vertices:
    // 0..N_theta-1: bottom ring at z_lo
    // N_theta..2*N_theta-1: top ring at z_hi
    // 2*N_theta: bottom center (seed_x, seed_y, z_lo)
    // 2*N_theta + 1: top center (seed_x, seed_y, z_hi)
    for (0..N_theta) |ti| {
        const theta = (2.0 * std.math.pi * @as(f64, @floatFromInt(ti))) / @as(f64, @floatFromInt(N_theta));
        const r = r_profile[ti];
        try solid.vertices.append(allocator, Vec3d.init(seed_x + r * @cos(theta), seed_y + r * @sin(theta), z_lo));
        try solid.normals.append(allocator, Vec3d.init(@cos(theta), @sin(theta), 0.0));
    }
    for (0..N_theta) |ti| {
        const theta = (2.0 * std.math.pi * @as(f64, @floatFromInt(ti))) / @as(f64, @floatFromInt(N_theta));
        const r = r_profile[ti];
        try solid.vertices.append(allocator, Vec3d.init(seed_x + r * @cos(theta), seed_y + r * @sin(theta), z_hi));
        try solid.normals.append(allocator, Vec3d.init(@cos(theta), @sin(theta), 0.0));
    }
    const bot_center_idx: u32 = @intCast(solid.vertices.items.len);
    try solid.vertices.append(allocator, Vec3d.init(seed_x, seed_y, z_lo));
    try solid.normals.append(allocator, Vec3d.init(0.0, 0.0, -1.0));

    const top_center_idx: u32 = @intCast(solid.vertices.items.len);
    try solid.vertices.append(allocator, Vec3d.init(seed_x, seed_y, z_hi));
    try solid.normals.append(allocator, Vec3d.init(0.0, 0.0, 1.0));

    const bot_tid = TopoId.init(feature_hash, terms[bot_term_idx].branch_hash, SUBSHAPE_FACE, TopoFlags.ANALYTIC | TopoFlags.BOUNDARY, 0);
    const top_tid = TopoId.init(feature_hash, terms[top_term_idx].branch_hash, SUBSHAPE_FACE, TopoFlags.ANALYTIC | TopoFlags.BOUNDARY, 0);

    const avg_r = @max(1e-6, r_profile[0]);
    const wall_curv = FaceCurvature{ .k_min = 0.0, .k_max = 1.0 / avg_r, .k_gauss = 0.0, .k_mean = 0.5 / avg_r };
    const flat_curv = FaceCurvature{};

    for (0..N_theta) |ti| {
        const next_ti = (ti + 1) % N_theta;
        const b0: u32 = @intCast(ti);
        const b1: u32 = @intCast(next_ti);
        const t0: u32 = @intCast(N_theta + ti);
        const t1: u32 = @intCast(N_theta + next_ti);
        const wall_tid = TopoId.init(feature_hash, terms[wall_term_indices[ti]].branch_hash, SUBSHAPE_FACE, TopoFlags.ANALYTIC | TopoFlags.PRESERVE, 0);

        // Lateral wall
        try solid.addTriangle(b0, b1, t1, wall_tid, wall_curv);
        try solid.addTriangle(b0, t1, t0, wall_tid, wall_curv);

        // Bottom cap (outward normal -Z)
        try solid.addTriangle(bot_center_idx, b1, b0, bot_tid, flat_curv);

        // Top cap (outward normal +Z)
        try solid.addTriangle(top_center_idx, t0, t1, top_tid, flat_curv);
    }

    // Verify 2-manifold edge incidence and Euler–Poincaré (V - E + F = 2)
    if (!solid.verifyTwoManifoldEdges()) {
        last_brep_status = ERR_NON_MANIFOLD_EDGE;
        return error.NonManifoldEdge;
    }
    if (!solid.verifyEulerPoincare()) {
        last_brep_status = ERR_EULER_POINCARE;
        return error.EulerPoincareFailed;
    }

    const handle: u64 = (@as(u64, 0b00) << 62) | @as(u64, solid_id);
    try solid_brep_store.put(handle, solid);

    // Store compiled analytical inequality expressions for O(1) exact CSG distance evaluation
    const p_alloc = memory.persistent_allocator;
    if (p_alloc.alloc(autodiff.Expression, terms.len)) |reg_exprs| {
        var reg_cnt: usize = 0;
        var reg_ok = true;
        for (terms, 0..) |t, i| {
            reg_exprs[i] = autodiff.compileExpressionWithContext(p_alloc, t.expr_str, .field, &map_with_xyz) catch {
                reg_ok = false;
                break;
            };
            reg_cnt += 1;
        }
        if (reg_ok) {
            if (p_alloc.dupe(f64, var_values)) |reg_vars| {
                region_solid_store.put(handle, .{
                    .allocator = p_alloc,
                    .exprs = reg_exprs,
                    .var_values = reg_vars,
                }) catch {
                    for (reg_exprs) |*re| re.deinit();
                    p_alloc.free(reg_exprs);
                    p_alloc.free(reg_vars);
                };
            } else |_| {
                for (reg_exprs) |*re| re.deinit();
                p_alloc.free(reg_exprs);
            }
        } else {
            for (0..reg_cnt) |i| reg_exprs[i].deinit();
            p_alloc.free(reg_exprs);
        }
    } else |_| {}

    // Record equivalent linear SweepSource so analytic region solids also support lateral & cap fillets
    var reg_samples: [N_theta]ProfileEdgeSample2D = undefined;
    for (0..N_theta) |ti| {
        const theta = (2.0 * std.math.pi * @as(f64, @floatFromInt(ti))) / @as(f64, @floatFromInt(N_theta));
        const r = r_profile[ti];
        reg_samples[ti] = .{
            .u = seed_x + r * @cos(theta),
            .v = seed_y + r * @sin(theta),
            .curve_hash = terms[wall_term_indices[ti]].branch_hash,
            .curvature_2d = 1.0 / @max(1e-6, r),
        };
    }
    const reg_steps = [2]TrajectoryStep{
        .{ .v = 0.0, .translation = Vec3d.init(0.0, 0.0, z_lo), .axis = Vec3d.init(0.0, 0.0, 1.0), .angle_rad = 0.0 },
        .{ .v = 1.0, .translation = Vec3d.init(0.0, 0.0, z_hi), .axis = Vec3d.init(0.0, 0.0, 1.0), .angle_rad = 0.0 },
    };
    recordSweepSource(
        handle,
        feature_hash,
        terms[0].branch_hash,
        Vec3d.zero(),
        Vec3d.init(1.0, 0.0, 0.0),
        Vec3d.init(0.0, 1.0, 0.0),
        .{ .wire_id = "outer", .is_hole = false, .points = &reg_samples },
        &[_]ProfileLoop2D{},
        &reg_steps,
        true,
    ) catch {};

    return handle;
}

// ============================================================================
// Exact Constant-Radius Fillet of Sweep-Parallel Edges (§7.3, §10.2)
// ============================================================================
//
// For a pure-translation sweep, every sharp lateral edge is the straight segment traced by a profile
// corner along the sweep vector S. The rolling-ball blend of radius r along such an edge is exactly the
// cylinder obtained by sweeping the circular arc that is tangent to both adjacent profile lines. We
// therefore rebuild the solid from the stored sweep source with those profile corners replaced by exact
// tangent arcs (k_max = 1/r, k_gauss = 0 on the blend faces).
//
// Unsupported configurations (rotating trajectories, corners between non-linear curves, or predicates
// that select cap edges) are reported as errors; no geometry is approximated or faked.

/// Sweep inputs retained per B-Rep handle so that downstream features (fillet) can rebuild exactly.
pub const SweepSource = struct {
    feature_hash: u64,
    sweep_branch_hash: u64,
    frame_p0: Vec3d,
    frame_e1: Vec3d,
    frame_e2: Vec3d,
    outer: []ProfileEdgeSample2D,
    holes: [][]ProfileEdgeSample2D,
    steps: []TrajectoryStep,
    cap_ends: bool,

    fn deinit(self: *SweepSource, allocator: std.mem.Allocator) void {
        allocator.free(self.outer);
        for (self.holes) |h| allocator.free(h);
        allocator.free(self.holes);
        allocator.free(self.steps);
    }
};

pub var sweep_source_store: std.AutoHashMap(u64, SweepSource) = std.AutoHashMap(u64, SweepSource).init(memory.persistent_allocator);

fn recordSweepSource(
    handle: u64,
    feature_hash: u64,
    sweep_branch_hash: u64,
    p0: Vec3d,
    e1: Vec3d,
    e2: Vec3d,
    outer_loop: ProfileLoop2D,
    hole_loops: []const ProfileLoop2D,
    traj_steps: []const TrajectoryStep,
    cap_ends: bool,
) !void {
    const a = memory.persistent_allocator;
    const outer = try a.dupe(ProfileEdgeSample2D, outer_loop.points);
    errdefer a.free(outer);
    const holes = try a.alloc([]ProfileEdgeSample2D, hole_loops.len);
    var n_done: usize = 0;
    errdefer {
        for (holes[0..n_done]) |h| a.free(h);
        a.free(holes);
    }
    for (hole_loops, 0..) |hl, i| {
        holes[i] = try a.dupe(ProfileEdgeSample2D, hl.points);
        n_done += 1;
    }
    const steps = try a.dupe(TrajectoryStep, traj_steps);
    errdefer a.free(steps);
    if (try sweep_source_store.fetchPut(handle, .{
        .feature_hash = feature_hash,
        .sweep_branch_hash = sweep_branch_hash,
        .frame_p0 = p0,
        .frame_e1 = e1,
        .frame_e2 = e2,
        .outer = outer,
        .holes = holes,
        .steps = steps,
        .cap_ends = cap_ends,
    })) |old| {
        var o = old.value;
        o.deinit(a);
    }
}

/// Edge selector: either a CDML predicate-context expression, an expression handle (C-ABI), or
/// "every sharp edge parallel to the sweep vector" when neither is given. Variable layout (both forms):
/// [x, y, z, nx, ny, nz, tx, ty, tz, k_min, k_max, k_gauss, k_mean, area, length, user vars...]
pub const EdgeSelector = struct {
    expr: ?*const autodiff.Expression = null,
    expr_h: u64 = 0,
    vars: []f64,

    fn matches(self: *const EdgeSelector, mid: Vec3d, n: Vec3d, t: Vec3d, len: f64, tid: TopoId) bool {
        self.vars[0] = mid.x;
        self.vars[1] = mid.y;
        self.vars[2] = mid.z;
        self.vars[3] = n.x;
        self.vars[4] = n.y;
        self.vars[5] = n.z;
        self.vars[6] = t.x;
        self.vars[7] = t.y;
        self.vars[8] = t.z;
        for (9..14) |i| self.vars[i] = 0.0;
        self.vars[14] = len;
        autodiff.setCurrentTopoId(tid);
        if (self.expr) |e| return e.evalScalar(self.vars) != 0.0;
        if (self.expr_h != 0) return autodiff.expr_eval(self.expr_h, self.vars.ptr, @intCast(self.vars.len), null) != 0.0;
        return true;
    }
};

pub const FilletError = error{
    FilletRadiusCollapse,
    FilletNotSweepSolid,
    FilletRotatingTrajectory,
    FilletNonLinearCorner,
    FilletCapEdgeUnsupported,
    OutOfMemory,
};

pub var last_fillet_message: []const u8 = "";

fn failFillet(comptime e: FilletError, msg: []const u8) FilletError {
    last_brep_status = ERR_FILLET_RADIUS_COLLAPSE;
    last_fillet_message = msg;
    return e;
}

fn dir2(ax: f64, ay: f64, bx: f64, by: f64) [3]f64 {
    const dx = bx - ax;
    const dy = by - ay;
    const l = @sqrt(dx * dx + dy * dy);
    if (l < 1e-15) return .{ 0, 0, 0 };
    return .{ dx / l, dy / l, l };
}

/// Rounds the selected corners of one profile loop with exact tangent arcs. Returns #corners filleted.
fn filletProfileLoop(
    allocator: std.mem.Allocator,
    src: *const SweepSource,
    pts: []const ProfileEdgeSample2D,
    sel: *const EdgeSelector,
    fillet_hash: u64,
    radius: f64,
    angle_tol: f64,
    out: *std.ArrayList(ProfileEdgeSample2D),
) FilletError!usize {
    const M = pts.len;
    const step0 = src.steps[0];
    const S = src.steps[src.steps.len - 1].translation.sub(step0.translation);
    const s_len = S.length();
    const t_dir = S.scale(1.0 / s_len);

    // Orientation: outward lateral normal of segment d is (d.v, -d.u) for CCW loops (outer material on the left).
    var area2: f64 = 0.0;
    for (0..M) |i| {
        const p = pts[i];
        const q = pts[(i + 1) % M];
        area2 += p.u * q.v - q.u * p.v;
    }
    const ccw = area2 > 0.0;

    const corner_sel = try allocator.alloc(bool, M);
    defer allocator.free(corner_sel);
    const trimmed_sample = try allocator.alloc(bool, M);
    defer allocator.free(trimmed_sample);
    const setback = try allocator.alloc(f64, M);
    defer allocator.free(setback);
    @memset(corner_sel, false);
    @memset(trimmed_sample, false);
    @memset(setback, 0.0);

    const lateralNormal = struct {
        fn f(s: *const SweepSource, d: [3]f64, is_ccw: bool) Vec3d {
            const nu = if (is_ccw) d[1] else -d[1];
            const nv = if (is_ccw) -d[0] else d[0];
            return s.frame_e1.scale(nu).add(s.frame_e2.scale(nv)).normalize();
        }
    }.f;

    var n_corners: usize = 0;
    for (0..M) |i| {
        const prev = pts[(i + M - 1) % M];
        const cur = pts[i];
        const next = pts[(i + 1) % M];
        if (prev.curve_hash == cur.curve_hash) continue; // interior of one smooth curve
        const din = dir2(prev.u, prev.v, cur.u, cur.v);
        const dout = dir2(cur.u, cur.v, next.u, next.v);
        if (din[2] < 1e-12 or dout[2] < 1e-12) continue;
        const cross_z = din[0] * dout[1] - din[1] * dout[0];
        const dotp = din[0] * dout[0] + din[1] * dout[1];
        const turn = std.math.atan2(cross_z, dotp);
        if (@abs(turn) < 1e-6) continue; // G1 joint: no sharp edge

        const n_in = lateralNormal(src, din, ccw);
        const n_out = lateralNormal(src, dout, ccw);
        const corner_w = evalTrajectoryPoint(cur.u, cur.v, src.frame_p0, src.frame_e1, src.frame_e2, step0);
        const mid = corner_w.add(S.scale(0.5));
        const tid = TopoId.init(src.feature_hash, if (cur.curve_hash != 0) cur.curve_hash else src.sweep_branch_hash, SUBSHAPE_FACE, TopoFlags.ANALYTIC | TopoFlags.PRESERVE, 0);
        if (!sel.matches(mid, n_in.add(n_out).normalize(), t_dir, s_len, tid)) continue;

        // Interior angle between the two tangents is (pi - |turn|); tangent setback s = r * tan(|turn| / 2)
        setback[i] = radius * @tan(0.5 * @abs(turn));
        corner_sel[i] = true;
        n_corners += 1;
    }

    // Collapse check & multi-sample curve setback trimming
    for (0..M) |i| {
        if (!corner_sel[i]) continue;
        const sb = setback[i];

        // Measure available incoming curve arc-length and trim intermediate samples within setback
        const in_hash = pts[(i + M - 1) % M].curve_hash;
        var len_in: f64 = 0.0;
        var k_back: usize = 0;
        while (k_back < M) : (k_back += 1) {
            const idx_cur = (i + M - k_back) % M;
            const idx_prev = (i + M - k_back - 1) % M;
            if (pts[idx_prev].curve_hash != in_hash) break;
            const seg_l = dir2(pts[idx_prev].u, pts[idx_prev].v, pts[idx_cur].u, pts[idx_cur].v)[2];
            if (len_in + seg_l < sb and k_back + 1 < M) {
                trimmed_sample[idx_prev] = true;
            }
            len_in += seg_l;
            if (corner_sel[idx_prev]) {
                if (sb + setback[idx_prev] > len_in * (1.0 - 1e-9)) {
                    return failFillet(error.FilletRadiusCollapse, "fillet radius exceeds available adjacent edge length");
                }
                break;
            }
        }
        if (sb > len_in * (1.0 - 1e-9)) {
            return failFillet(error.FilletRadiusCollapse, "fillet radius exceeds available incoming curve length");
        }

        // Measure available outgoing curve arc-length and trim intermediate samples within setback
        const out_hash = pts[i].curve_hash;
        var len_out: f64 = 0.0;
        var k_fwd: usize = 0;
        while (k_fwd < M) : (k_fwd += 1) {
            const idx_cur = (i + k_fwd) % M;
            const idx_next = (i + k_fwd + 1) % M;
            if (pts[idx_cur].curve_hash != out_hash) break;
            const seg_l = dir2(pts[idx_cur].u, pts[idx_cur].v, pts[idx_next].u, pts[idx_next].v)[2];
            if (len_out + seg_l < sb and k_fwd + 1 < M) {
                trimmed_sample[idx_next] = true;
            }
            len_out += seg_l;
            if (corner_sel[idx_next]) {
                if (sb + setback[idx_next] > len_out * (1.0 - 1e-9)) {
                    return failFillet(error.FilletRadiusCollapse, "fillet radius exceeds available adjacent edge length");
                }
                break;
            }
        }
        if (sb > len_out * (1.0 - 1e-9)) {
            return failFillet(error.FilletRadiusCollapse, "fillet radius exceeds available outgoing curve length");
        }
    }

    // Emit the new loop.
    const k_arc = 1.0 / radius;
    for (0..M) |i| {
        const cur = pts[i];
        if (!corner_sel[i]) {
            if (!trimmed_sample[i]) {
                try out.append(allocator, cur);
            }
            continue;
        }
        const prev = pts[(i + M - 1) % M];
        const next = pts[(i + 1) % M];
        const din = dir2(prev.u, prev.v, cur.u, cur.v);
        const dout = dir2(cur.u, cur.v, next.u, next.v);
        // Tangent points on the incoming / outgoing lines
        const t1u = cur.u - din[0] * setback[i];
        const t1v = cur.v - din[1] * setback[i];
        const t2u = cur.u + dout[0] * setback[i];
        const t2v = cur.v + dout[1] * setback[i];
        // Center: offset T1 by r along the inward normal of the incoming line (towards the turn side)
        const cross_z = din[0] * dout[1] - din[1] * dout[0];
        const side: f64 = if (cross_z > 0.0) 1.0 else -1.0;
        const cu = t1u + side * (-din[1]) * radius;
        const cv = t1v + side * (din[0]) * radius;
        const a0 = std.math.atan2(t1v - cv, t1u - cu);
        var a1 = std.math.atan2(t2v - cv, t2u - cu);
        // Arc sweeps in the turn direction by exactly |turn|
        const turn = std.math.atan2(cross_z, din[0] * dout[0] + din[1] * dout[1]);
        a1 = a0 + turn;
        const n_seg: usize = @max(2, @as(usize, @intFromFloat(@ceil(@abs(turn) / @max(1e-3, angle_tol)))));
        var hbuf: [16]u8 = undefined;
        std.mem.writeInt(u64, hbuf[0..8], fillet_hash, .little);
        std.mem.writeInt(u64, hbuf[8..16], cur.curve_hash, .little);
        const arc_hash = std.hash.Wyhash.hash(0, &hbuf) & 0x3FFFFFFFFFFFFFFF;
        for (0..n_seg) |s| {
            const ang = a0 + (a1 - a0) * @as(f64, @floatFromInt(s)) / @as(f64, @floatFromInt(n_seg));
            try out.append(allocator, .{
                .u = cu + radius * @cos(ang),
                .v = cv + radius * @sin(ang),
                .curve_hash = arc_hash,
                .curvature_2d = k_arc,
            });
        }
        // T2 starts the (trimmed) outgoing line and keeps its identity
        try out.append(allocator, .{ .u = t2u, .v = t2v, .curve_hash = cur.curve_hash, .curvature_2d = cur.curvature_2d });
    }
    return n_corners;
}

/// Applies an exact constant-radius fillet to the sweep-parallel edges of `solid_h` selected by `sel`.
/// On success the old solid is freed and the rebuilt handle is returned.
pub fn filletSweptSolid(
    allocator: std.mem.Allocator,
    solid_h: u64,
    fillet_hash: u64,
    sel: *const EdgeSelector,
    radius: f64,
    angle_tol: f64,
) FilletError!u64 {
    last_brep_status = 0;
    last_fillet_message = "";
    if (!(radius > 0.0) or !std.math.isFinite(radius)) {
        return failFillet(error.FilletRadiusCollapse, "fillet radius must be positive and finite");
    }
    const src = sweep_source_store.getPtr(solid_h) orelse
        return failFillet(error.FilletNotSweepSolid, "fillet target is not a swept B-Rep");

    const st = src.steps;
    const S = st[st.len - 1].translation.sub(st[0].translation);
    if (S.length() < 1e-12) return failFillet(error.FilletRotatingTrajectory, "sweep has zero translation");
    for (st) |s| {
        if (@abs(s.angle_rad) > 1e-12) {
            return failFillet(error.FilletRotatingTrajectory, "fillet on rotating SE(3) sweeps is not supported");
        }
        const expect = st[0].translation.add(S.scale(s.v));
        if (s.translation.sub(expect).length() > 1e-9 * (1.0 + S.length())) {
            return failFillet(error.FilletRotatingTrajectory, "fillet requires a linear translation trajectory");
        }
    }

    var outer_out: std.ArrayList(ProfileEdgeSample2D) = .empty;
    defer outer_out.deinit(allocator);
    var count = try filletProfileLoop(allocator, src, src.outer, sel, fillet_hash, radius, angle_tol, &outer_out);

    var hole_bufs = try allocator.alloc(std.ArrayList(ProfileEdgeSample2D), src.holes.len);
    defer {
        for (hole_bufs) |*hb| hb.deinit(allocator);
        allocator.free(hole_bufs);
    }
    for (hole_bufs) |*hb| hb.* = .empty;
    const hole_loops = try allocator.alloc(ProfileLoop2D, src.holes.len);
    defer allocator.free(hole_loops);
    for (src.holes, 0..) |h, i| {
        count += try filletProfileLoop(allocator, src, h, sel, fillet_hash, radius, angle_tol, &hole_bufs[i]);
        hole_loops[i] = .{ .wire_id = "hole", .is_hole = true, .points = hole_bufs[i].items };
    }

    // Check if predicate also selects bottom cap (v = 0) or top cap (v = 1) dihedral edges (where |tz| < 0.001)
    var fillet_bot_cap = false;
    var fillet_top_cap = false;
    if (src.cap_ends and (sel.expr != null or sel.expr_h != 0)) {
        const pts = outer_out.items;
        const M = pts.len;
        const frame_nrm = src.frame_e1.cross(src.frame_e2).normalize();
        const step_bot = st[0];
        const step_top = st[st.len - 1];
        var area2: f64 = 0.0;
        for (0..M) |i| {
            const p = pts[i];
            const q = pts[(i + 1) % M];
            area2 += p.u * q.v - q.u * p.v;
        }
        const ccw = area2 > 0.0;

        for (0..M) |i| {
            const cur = pts[i];
            const next = pts[(i + 1) % M];
            const d = dir2(cur.u, cur.v, next.u, next.v);
            if (d[2] < 1e-12) continue;
            const nu = if (ccw) d[1] else -d[1];
            const nv = if (ccw) -d[0] else d[0];
            const n_lat = src.frame_e1.scale(nu).add(src.frame_e2.scale(nv)).normalize();
            const t_edge = src.frame_e1.scale(d[0]).add(src.frame_e2.scale(d[1])).normalize();
            const mid_u = 0.5 * (cur.u + next.u);
            const mid_v = 0.5 * (cur.v + next.v);
            const tid = TopoId.init(src.feature_hash, if (cur.curve_hash != 0) cur.curve_hash else src.sweep_branch_hash, SUBSHAPE_FACE, TopoFlags.ANALYTIC | TopoFlags.BOUNDARY, 0);

            if (!fillet_bot_cap) {
                const mid_bot = evalTrajectoryPoint(mid_u, mid_v, src.frame_p0, src.frame_e1, src.frame_e2, step_bot);
                const n_bis_bot = n_lat.sub(frame_nrm).normalize();
                if (sel.matches(mid_bot, n_bis_bot, t_edge, d[2], tid)) {
                    fillet_bot_cap = true;
                }
            }
            if (!fillet_top_cap) {
                const mid_top = evalTrajectoryPoint(mid_u, mid_v, src.frame_p0, src.frame_e1, src.frame_e2, step_top);
                const n_bis_top = n_lat.add(frame_nrm).normalize();
                if (sel.matches(mid_top, n_bis_top, t_edge, d[2], tid)) {
                    fillet_top_cap = true;
                }
            }
        }
    }

    if (fillet_bot_cap or fillet_top_cap) {
        const new_h = try rebuildSweepWithCapFillets(
            allocator,
            src,
            outer_out.items,
            hole_loops,
            fillet_hash,
            radius,
            angle_tol,
            fillet_bot_cap,
            fillet_top_cap,
        );
        solid_free(solid_h);
        return new_h;
    }

    if (count == 0) return solid_h; // predicate selected nothing: solid unchanged

    const new_h = sweepProfileLoopsSE3(
        memory.persistent_allocator,
        src.feature_hash,
        src.sweep_branch_hash,
        src.frame_p0,
        src.frame_e1,
        src.frame_e2,
        .{ .wire_id = "outer", .is_hole = false, .points = outer_out.items },
        hole_loops,
        st,
        src.cap_ends,
    ) catch return failFillet(error.FilletRadiusCollapse, "rebuilt filleted sweep is degenerate");

    solid_free(solid_h);
    return new_h;
}

fn rebuildSweepWithCapFillets(
    allocator: std.mem.Allocator,
    src: *const SweepSource,
    outer_pts: []const ProfileEdgeSample2D,
    hole_loops: []const ProfileLoop2D,
    fillet_hash: u64,
    radius: f64,
    angle_tol: f64,
    fillet_bot_cap: bool,
    fillet_top_cap: bool,
) FilletError!u64 {
    const M = outer_pts.len;
    if (M < 3) return failFillet(error.FilletRadiusCollapse, "degenerate outer profile loop");

    const step0 = src.steps[0];
    const step_last = src.steps[src.steps.len - 1];
    const S = step_last.translation.sub(step0.translation);
    const s_len = S.length();
    const req_z = (if (fillet_bot_cap) radius else 0.0) + (if (fillet_top_cap) radius else 0.0);
    if (req_z >= s_len * (1.0 - 1e-6)) {
        return failFillet(error.FilletRadiusCollapse, "cap fillet radius exceeds sweep depth");
    }

    var area2: f64 = 0.0;
    for (0..M) |i| {
        const p = outer_pts[i];
        const q = outer_pts[(i + 1) % M];
        area2 += p.u * q.v - q.u * p.v;
    }
    const ccw = area2 > 0.0;

    // Compute inward miter offset vector (miter_u[i], miter_v[i]) per outer vertex
    var miter_u = try allocator.alloc(f64, M);
    defer allocator.free(miter_u);
    var miter_v = try allocator.alloc(f64, M);
    defer allocator.free(miter_v);

    for (0..M) |i| {
        const prev = outer_pts[(i + M - 1) % M];
        const cur = outer_pts[i];
        const next = outer_pts[(i + 1) % M];
        const din = dir2(prev.u, prev.v, cur.u, cur.v);
        const dout = dir2(cur.u, cur.v, next.u, next.v);
        const nin_u = if (ccw) din[1] else -din[1];
        const nin_v = if (ccw) -din[0] else din[0];
        const nout_u = if (ccw) dout[1] else -dout[1];
        const nout_v = if (ccw) -dout[0] else dout[0];
        const bx = nin_u + nout_u;
        const by = nin_v + nout_v;
        const blen = @sqrt(bx * bx + by * by);
        const bu = if (blen > 1e-12) bx / blen else nout_u;
        const bv = if (blen > 1e-12) by / blen else nout_v;
        const cos_half = @max(0.25, bu * nout_u + bv * nout_v);
        miter_u[i] = -bu / cos_half;
        miter_v[i] = -bv / cos_half;
    }

    // Validate that full inset by `radius` does not invert any edge or collapse loop area
    var inset_area2: f64 = 0.0;
    for (0..M) |i| {
        const ni = (i + 1) % M;
        const pu0 = outer_pts[i].u + radius * miter_u[i];
        const pv0 = outer_pts[i].v + radius * miter_v[i];
        const pu1 = outer_pts[ni].u + radius * miter_u[ni];
        const pv1 = outer_pts[ni].v + radius * miter_v[ni];
        const orig_du = outer_pts[ni].u - outer_pts[i].u;
        const orig_dv = outer_pts[ni].v - outer_pts[i].v;
        if ((pu1 - pu0) * orig_du + (pv1 - pv0) * orig_dv <= 1e-9) {
            return failFillet(error.FilletRadiusCollapse, "cap fillet radius collapses profile edge");
        }
        inset_area2 += pu0 * pv1 - pu1 * pv0;
    }
    if (@abs(inset_area2) <= 1e-6 or (inset_area2 > 0.0) != ccw) {
        return failFillet(error.FilletRadiusCollapse, "cap fillet radius collapses profile area");
    }

    const CapStation = struct {
        v_frac: f64,
        inset: f64,
        is_fillet_span: bool,
    };
    const n_strip: usize = @max(4, @as(usize, @intFromFloat(@ceil((0.5 * std.math.pi) / @max(0.05, angle_tol)))));
    var stations: std.ArrayList(CapStation) = .empty;
    defer stations.deinit(allocator);

    if (fillet_bot_cap) {
        for (0..n_strip + 1) |k| {
            const phi = 0.5 * std.math.pi * (1.0 - @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n_strip)));
            const z_off = radius * (1.0 - @sin(phi));
            const inset = radius * (1.0 - @cos(phi));
            try stations.append(allocator, .{
                .v_frac = z_off / s_len,
                .inset = inset,
                .is_fillet_span = (k < n_strip),
            });
        }
    } else {
        try stations.append(allocator, .{ .v_frac = 0.0, .inset = 0.0, .is_fillet_span = false });
    }

    if (fillet_top_cap) {
        for (0..n_strip + 1) |k| {
            const phi = 0.5 * std.math.pi * (@as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n_strip)));
            const z_off = (s_len - radius) + radius * @sin(phi);
            const inset = radius * (1.0 - @cos(phi));
            try stations.append(allocator, .{
                .v_frac = z_off / s_len,
                .inset = inset,
                .is_fillet_span = (k < n_strip),
            });
        }
    } else {
        try stations.append(allocator, .{ .v_frac = 1.0, .inset = 0.0, .is_fillet_span = false });
    }

    const p_alloc = memory.persistent_allocator;
    const solid_id = next_solid_id;
    next_solid_id += 1;
    var solid = BRepSolid.init(p_alloc, solid_id);
    errdefer solid.deinit();
    solid.feature_hash = src.feature_hash;
    solid.genus = hole_loops.len;

    const K = stations.items.len;
    const total_loops = 1 + hole_loops.len;
    var loop_offsets = try allocator.alloc(u32, total_loops * K);
    defer allocator.free(loop_offsets);

    const frame_normal = src.frame_e1.cross(src.frame_e2).normalize();

    for (0..K) |k| {
        const st_k = stations.items[k];
        const step = TrajectoryStep{
            .v = st_k.v_frac,
            .translation = step0.translation.add(S.scale(st_k.v_frac)),
            .axis = Vec3d.init(0.0, 0.0, 1.0),
            .angle_rad = 0.0,
        };
        loop_offsets[0 * K + k] = @intCast(solid.vertices.items.len);
        for (outer_pts, 0..) |pt, i| {
            const u_in = pt.u + st_k.inset * miter_u[i];
            const v_in = pt.v + st_k.inset * miter_v[i];
            const wp = evalTrajectoryPoint(u_in, v_in, src.frame_p0, src.frame_e1, src.frame_e2, step);
            try solid.vertices.append(p_alloc, wp);
            try solid.normals.append(p_alloc, frame_normal);
        }
        for (hole_loops, 0..) |hl, h_idx| {
            loop_offsets[(1 + h_idx) * K + k] = @intCast(solid.vertices.items.len);
            for (hl.points) |pt| {
                const wp = evalTrajectoryPoint(pt.u, pt.v, src.frame_p0, src.frame_e1, src.frame_e2, step);
                try solid.vertices.append(p_alloc, wp);
                try solid.normals.append(p_alloc, frame_normal);
            }
        }
    }

    const k_fillet = 1.0 / radius;
    for (0..total_loops) |l_idx| {
        const pts = if (l_idx == 0) outer_pts else hole_loops[l_idx - 1].points;
        const is_hole = (l_idx > 0);
        const L = pts.len;

        var h_area2: f64 = 0.0;
        if (is_hole) {
            for (0..L) |mi| {
                const p_c = pts[mi];
                const p_n = pts[(mi + 1) % L];
                h_area2 += p_c.u * p_n.v - p_n.u * p_c.v;
            }
        }

        for (0..K - 1) |k| {
            const is_f_span = (l_idx == 0) and stations.items[k].is_fillet_span;
            for (0..L) |i| {
                const next_i = (i + 1) % L;
                const b0 = loop_offsets[l_idx * K + k] + @as(u32, @intCast(i));
                const b1 = loop_offsets[l_idx * K + k] + @as(u32, @intCast(next_i));
                const t0 = loop_offsets[l_idx * K + (k + 1)] + @as(u32, @intCast(i));
                const t1 = loop_offsets[l_idx * K + (k + 1)] + @as(u32, @intCast(next_i));

                const p_b0 = solid.vertices.items[b0];
                const p_b1 = solid.vertices.items[b1];
                const p_t0 = solid.vertices.items[t0];
                const cross_uv = p_b1.sub(p_b0).cross(p_t0.sub(p_b0));
                if (cross_uv.length() < 1e-10) {
                    return failFillet(error.FilletRadiusCollapse, "degenerate cap fillet strip triangle");
                }
                const out_n = if (!is_hole) cross_uv.normalize() else cross_uv.normalize().scale(-1.0);
                solid.normals.items[b0] = out_n;
                solid.normals.items[t0] = out_n;

                const base_chash = if (pts[i].curve_hash != 0) pts[i].curve_hash else src.sweep_branch_hash;
                var c_hash = base_chash;
                if (is_f_span) {
                    var hbuf: [16]u8 = undefined;
                    std.mem.writeInt(u64, hbuf[0..8], fillet_hash, .little);
                    std.mem.writeInt(u64, hbuf[8..16], base_chash, .little);
                    c_hash = std.hash.Wyhash.hash(0, &hbuf) & 0x3FFFFFFFFFFFFFFF;
                }
                const tid = TopoId.init(src.feature_hash, c_hash, SUBSHAPE_FACE, TopoFlags.ANALYTIC | TopoFlags.PRESERVE, 0);

                const k2d = pts[i].curvature_2d;
                const curv = if (is_f_span) FaceCurvature{
                    .k_min = @min(k2d, k_fillet),
                    .k_max = @max(k2d, k_fillet),
                    .k_gauss = k2d * k_fillet,
                    .k_mean = 0.5 * (k2d + k_fillet),
                } else FaceCurvature{
                    .k_min = 0.0,
                    .k_max = k2d,
                    .k_gauss = 0.0,
                    .k_mean = 0.5 * k2d,
                };

                if (!is_hole or h_area2 <= 0.0) {
                    try solid.addTriangle(b0, b1, t1, tid, curv);
                    try solid.addTriangle(b0, t1, t0, tid, curv);
                } else {
                    try solid.addTriangle(b0, t1, b1, tid, curv);
                    try solid.addTriangle(b0, t0, t1, tid, curv);
                }
            }
        }
    }

    // Triangulate bottom cap (station 0) and top cap (station K - 1) using their respective inset outer loops
    const cap_stations = [2]usize{ 0, K - 1 };
    for (cap_stations, 0..) |st_idx, cap_i| {
        const st_inset = stations.items[st_idx].inset;
        var outer_poly = try allocator.alloc(PolyVert2D, M);
        defer allocator.free(outer_poly);
        for (outer_pts, 0..) |pt, i| {
            outer_poly[i] = .{
                .u = pt.u + st_inset * miter_u[i],
                .v = pt.v + st_inset * miter_v[i],
                .orig_idx = @intCast(i),
            };
        }

        var hole_polys = try allocator.alloc([]PolyVert2D, hole_loops.len);
        defer {
            for (hole_polys) |hp| allocator.free(hp);
            allocator.free(hole_polys);
        }
        var cum_offset: u32 = @intCast(M);
        for (hole_loops, 0..) |hl, h_idx| {
            hole_polys[h_idx] = try allocator.alloc(PolyVert2D, hl.points.len);
            for (hl.points, 0..) |pt, i| {
                hole_polys[h_idx][i] = .{
                    .u = pt.u,
                    .v = pt.v,
                    .orig_idx = cum_offset + @as(u32, @intCast(i)),
                };
            }
            cum_offset += @intCast(hl.points.len);
        }

        var cap_tris: std.ArrayList([3]u32) = .empty;
        defer cap_tris.deinit(allocator);
        triangulatePolygonWithHoles2D(allocator, outer_poly, hole_polys, &cap_tris) catch {
            return failFillet(error.FilletRadiusCollapse, "cap triangulation failed after cap fillet inset");
        };

        const mapIdx = struct {
            fn f(local_idx: u32, station_k: usize, num_k: usize, outer_len: usize, holes_slice: []const ProfileLoop2D, offsets: []const u32) u32 {
                if (local_idx < outer_len) return offsets[0 * num_k + station_k] + local_idx;
                var rem = local_idx - @as(u32, @intCast(outer_len));
                for (holes_slice, 0..) |hl, hi| {
                    const hlen: u32 = @intCast(hl.points.len);
                    if (rem < hlen) return offsets[(1 + hi) * num_k + station_k] + rem;
                    rem -= hlen;
                }
                return offsets[station_k];
            }
        }.f;

        const cap_tid = TopoId.init(src.feature_hash, src.sweep_branch_hash, SUBSHAPE_FACE, TopoFlags.ANALYTIC | TopoFlags.BOUNDARY, 0);
        const flat_curv = FaceCurvature{};
        for (cap_tris.items) |tri| {
            const v0 = mapIdx(tri[0], st_idx, K, M, hole_loops, loop_offsets);
            const v1 = mapIdx(tri[1], st_idx, K, M, hole_loops, loop_offsets);
            const v2 = mapIdx(tri[2], st_idx, K, M, hole_loops, loop_offsets);
            if (cap_i == 0) {
                try solid.addTriangle(v0, v2, v1, cap_tid, flat_curv);
            } else {
                try solid.addTriangle(v0, v1, v2, cap_tid, flat_curv);
            }
        }
    }

    const handle: u64 = (@as(u64, 0b00) << 62) | @as(u64, solid_id);
    try solid_brep_store.put(handle, solid);
    return handle;
}

/// CDML-facing wrapper: compiles `edge_predicate_str` in predicate context against document variables.
pub fn applyEdgePredicateFillet(
    allocator: std.mem.Allocator,
    solid_h: u64,
    fillet_feature_hash: u64,
    edge_predicate_str: []const u8,
    radius_val: f64,
    angle_tol: f64,
    var_indices: ?*const std.StringHashMap(u32),
    var_values: []const f64,
) !u64 {
    var pred_map = std.StringHashMap(u32).init(allocator);
    defer pred_map.deinit();
    if (var_indices) |vi| {
        var it = vi.iterator();
        while (it.next()) |entry| try pred_map.put(entry.key_ptr.*, entry.value_ptr.* + 15);
    }
    const names = [_][]const u8{ "x", "y", "z", "nx", "ny", "nz", "tx", "ty", "tz", "k_min", "k_max", "k_gauss", "k_mean", "area", "length" };
    for (names, 0..) |nm, i| try pred_map.put(nm, @intCast(i));

    var maybe_pred: ?autodiff.Expression = null;
    defer if (maybe_pred) |*p| p.deinit();
    if (edge_predicate_str.len > 0) {
        maybe_pred = try autodiff.compileExpressionWithContext(allocator, edge_predicate_str, .predicate, &pred_map);
    }

    const vars = try allocator.alloc(f64, 15 + var_values.len);
    defer allocator.free(vars);
    @memset(vars, 0.0);
    @memcpy(vars[15..], var_values);

    const sel = EdgeSelector{ .expr = if (maybe_pred) |*p| p else null, .vars = vars };
    return filletSweptSolid(allocator, solid_h, fillet_feature_hash, &sel, radius_val, angle_tol);
}

fn computeTriNormal(solid: *const BRepSolid, tri_idx: usize) Vec3d {
    const idx0 = solid.indices.items[tri_idx * 3];
    const idx1 = solid.indices.items[tri_idx * 3 + 1];
    const idx2 = solid.indices.items[tri_idx * 3 + 2];
    const p0 = solid.vertices.items[idx0];
    const p1 = solid.vertices.items[idx1];
    const p2 = solid.vertices.items[idx2];
    return p1.sub(p0).cross(p2.sub(p0)).normalize();
}

// ============================================================================
// Lazy CSG Node & Real Hybrid B-Rep / Implicit CSG Evaluation (§9)
// ============================================================================

pub const CsgNode = struct {
    op: u32, // 0 = Union, 1 = Subtract (Cut), 2 = Intersect
    left: u64,
    right: u64,
    preserve_brep_tags: bool = true,
    collar_tol: f64 = 1e-6,
};

pub const RegionAnalyticalSolid = struct {
    allocator: std.mem.Allocator,
    exprs: []autodiff.Expression,
    var_values: []f64,

    pub fn deinit(self: *RegionAnalyticalSolid) void {
        for (self.exprs) |*e| e.deinit();
        self.allocator.free(self.exprs);
        self.allocator.free(self.var_values);
    }

    pub fn evalSignedDistance(self: *const RegionAnalyticalSolid, pt: Vec3d) f64 {
        var ev_buf: [64]f64 = undefined;
        const total = 3 + self.var_values.len;
        if (total > ev_buf.len) return 1.0;
        ev_buf[0] = pt.x;
        ev_buf[1] = pt.y;
        ev_buf[2] = pt.z;
        @memcpy(ev_buf[3..total], self.var_values);
        var max_f: f64 = -1e30;
        for (self.exprs) |*e| {
            const f_i = -e.evalScalar(ev_buf[0..total]);
            if (f_i > max_f) max_f = f_i;
        }
        return max_f;
    }
};

var next_solid_id: u32 = 1;
pub var solid_brep_store: std.AutoHashMap(u64, BRepSolid) = std.AutoHashMap(u64, BRepSolid).init(memory.persistent_allocator);
pub var csg_store: std.AutoHashMap(u64, CsgNode) = std.AutoHashMap(u64, CsgNode).init(memory.persistent_allocator);
pub var region_solid_store: std.AutoHashMap(u64, RegionAnalyticalSolid) = std.AutoHashMap(u64, RegionAnalyticalSolid).init(memory.persistent_allocator);

/// Evaluates a continuous signed distance to a solid handle (`<= 0` inside, `> 0` outside)
pub fn evalSolidSignedDistance(solid_h: u64, pt: Vec3d) f64 {
    const tag = solid_h >> 62;
    if (tag == 0b10) {
        // Implicit field solid: evaluate exact scalar expression F(x,y,z) bounded continuously by domain box
        if (implicit_field.implicit_store.get(solid_h)) |imp| {
            const dx_dom = @max(imp.bbox_min.x - pt.x, pt.x - imp.bbox_max.x);
            const dy_dom = @max(imp.bbox_min.y - pt.y, pt.y - imp.bbox_max.y);
            const dz_dom = @max(imp.bbox_min.z - pt.z, pt.z - imp.bbox_max.z);
            const d_dom = @max(dx_dom, @max(dy_dom, dz_dom));
            if (d_dom > 5.0) return d_dom;
            const f_val = autodiff.expr_eval(imp.scalar_expr_h, &[3]f64{ pt.x, pt.y, pt.z }, 3, null);
            return @max(f_val, d_dom);
        }
    } else if (tag == 0b01) {
        if (csg_store.get(solid_h)) |node| {
            // Short-circuit when right operand is an O(1) analytical/implicit field and determines outside/inside sign
            const is_fast_b = ((node.right >> 62) == 0b10) or region_solid_store.contains(node.right);
            const is_fast_a = ((node.left >> 62) == 0b10) or region_solid_store.contains(node.left);
            if (is_fast_b and !is_fast_a) {
                const fb = evalSolidSignedDistance(node.right, pt);
                const tol_b: f64 = if (region_solid_store.contains(node.right)) 2.5 else 0.05;
                if (node.op == 1 and -fb >= -tol_b) return @max(0.0, -fb);
                if (node.op == 2 and fb >= -tol_b) return @max(0.0, fb);
                if (node.op == 0 and fb <= tol_b) return @min(0.0, fb);
                const fa = evalSolidSignedDistance(node.left, pt);
                return switch (node.op) {
                    0 => @min(fa, fb),
                    1 => @max(fa, -fb),
                    2 => @max(fa, fb),
                    else => fa,
                };
            }
            const fa = evalSolidSignedDistance(node.left, pt);
            if (node.op == 1 and fa > 1e-5) return fa;
            if (node.op == 2 and fa > 1e-5) return fa;
            if (node.op == 0 and fa < -1e-5) return fa;
            const fb = evalSolidSignedDistance(node.right, pt);
            return switch (node.op) {
                0 => @min(fa, fb), // union
                1 => @max(fa, -fb), // subtract A \ B
                2 => @max(fa, fb), // intersect A n B
                else => fa,
            };
        }
    }

    // Analytic region B-Rep solid: evaluate exact conjunction max_i(-f_i(x,y,z)) in O(1) time
    if (region_solid_store.getPtr(solid_h)) |reg| {
        return reg.evalSignedDistance(pt);
    }

    // B-Rep solid: evaluate continuous signed distance via ray-parity + closest point on mesh
    if (solid_brep_store.getPtr(solid_h)) |brep| {
        return evalPointInBrepMesh(brep, pt);
    }
    return 1.0;
}

inline fn vec3LenSq(v: Vec3d) f64 {
    return v.dot(v);
}

fn pointToTriangleDistSq(pt: Vec3d, a: Vec3d, b: Vec3d, c: Vec3d) f64 {
    const ab = b.sub(a);
    const ac = c.sub(a);
    const ap = pt.sub(a);
    const d1 = ab.dot(ap);
    const d2 = ac.dot(ap);
    if (d1 <= 0.0 and d2 <= 0.0) return vec3LenSq(ap);

    const bp = pt.sub(b);
    const d3 = ab.dot(bp);
    const d4 = ac.dot(bp);
    if (d3 >= 0.0 and d4 <= d3) return vec3LenSq(bp);

    const vc = d1 * d4 - d3 * d2;
    if (vc <= 0.0 and d1 >= 0.0 and d3 <= 0.0) {
        const v = d1 / (d1 - d3);
        return vec3LenSq(pt.sub(a.add(ab.scale(v))));
    }

    const cp = pt.sub(c);
    const d5 = ab.dot(cp);
    const d6 = ac.dot(cp);
    if (d6 >= 0.0 and d5 <= d6) return vec3LenSq(cp);

    const vb = d5 * d2 - d1 * d6;
    if (vb <= 0.0 and d2 >= 0.0 and d6 <= 0.0) {
        const w = d2 / (d2 - d6);
        return vec3LenSq(pt.sub(a.add(ac.scale(w))));
    }

    const va = d3 * d6 - d5 * d4;
    if (va <= 0.0 and (d4 - d3) >= 0.0 and (d5 - d6) >= 0.0) {
        const w = (d4 - d3) / ((d4 - d3) + (d5 - d6));
        return vec3LenSq(pt.sub(b.add(c.sub(b).scale(w))));
    }

    const denom = 1.0 / (va + vb + vc);
    const v = vb * denom;
    const w = vc * denom;
    const closest = a.add(ab.scale(v)).add(ac.scale(w));
    return vec3LenSq(pt.sub(closest));
}

fn evalPointInBrepMesh(brep: *const BRepSolid, pt: Vec3d) f64 {
    if (brep.vertices.items.len == 0) return 1.0;
    var min_p = Vec3d.init(1e30, 1e30, 1e30);
    var max_p = Vec3d.init(-1e30, -1e30, -1e30);
    for (brep.vertices.items) |v| {
        if (v.x < min_p.x) min_p.x = v.x;
        if (v.y < min_p.y) min_p.y = v.y;
        if (v.z < min_p.z) min_p.z = v.z;
        if (v.x > max_p.x) max_p.x = v.x;
        if (v.y > max_p.y) max_p.y = v.y;
        if (v.z > max_p.z) max_p.z = v.z;
    }
    const dx_box = @max(0.0, @max(min_p.x - pt.x, pt.x - max_p.x));
    const dy_box = @max(0.0, @max(min_p.y - pt.y, pt.y - max_p.y));
    const dz_box = @max(0.0, @max(min_p.z - pt.z, pt.z - max_p.z));
    const d_box = @sqrt(dx_box * dx_box + dy_box * dy_box + dz_box * dz_box);
    if (d_box > 3.0) {
        return d_box;
    }

    // Cast perturbed +X ray to count intersections and compute closest surface distance
    const dir = Vec3d.init(1.0, 0.000137, 0.000293).normalize();
    const tri_count = brep.indices.items.len / 3;
    var hits: usize = 0;
    var min_dist_sq: f64 = 16.0;
    for (0..tri_count) |t| {
        const idx0 = brep.indices.items[t * 3];
        const idx1 = brep.indices.items[t * 3 + 1];
        const idx2 = brep.indices.items[t * 3 + 2];
        const p0 = brep.vertices.items[idx0];
        const p1 = brep.vertices.items[idx1];
        const p2 = brep.vertices.items[idx2];

        const t_min_x = @min(p0.x, @min(p1.x, p2.x));
        const t_max_x = @max(p0.x, @max(p1.x, p2.x));
        const t_min_y = @min(p0.y, @min(p1.y, p2.y));
        const t_max_y = @max(p0.y, @max(p1.y, p2.y));
        const t_min_z = @min(p0.z, @min(p1.z, p2.z));
        const t_max_z = @max(p0.z, @max(p1.z, p2.z));

        const dx_tri = @max(0.0, @max(t_min_x - pt.x, pt.x - t_max_x));
        const dy_tri = @max(0.0, @max(t_min_y - pt.y, pt.y - t_max_y));
        const dz_tri = @max(0.0, @max(t_min_z - pt.z, pt.z - t_max_z));
        if (dx_tri * dx_tri + dy_tri * dy_tri + dz_tri * dz_tri < min_dist_sq) {
            const dsq = pointToTriangleDistSq(pt, p0, p1, p2);
            if (dsq < min_dist_sq) min_dist_sq = dsq;
        }

        if (d_box > 1e-5) continue;
        if (t_max_x < pt.x or pt.y < t_min_y - 0.1 or pt.y > t_max_y + 0.01 or pt.z < t_min_z - 0.1 or pt.z > t_max_z + 0.01) continue;

        const e1 = p1.sub(p0);
        const e2 = p2.sub(p0);
        const h = dir.cross(e2);
        const a = e1.dot(h);
        if (@abs(a) < 1e-12) continue;
        const f = 1.0 / a;
        const s = pt.sub(p0);
        const u = f * s.dot(h);
        if (u < 0.0 or u > 1.0) continue;
        const q = s.cross(e1);
        const v = f * dir.dot(q);
        if (v < 0.0 or u + v > 1.0) continue;
        const dist = f * e2.dot(q);
        if (dist > 1e-7) hits += 1;
    }
    const sign: f64 = if (d_box <= 1e-5 and (hits % 2) == 1) -1.0 else 1.0;
    return sign * @max(1e-9, @sqrt(min_dist_sq));
}

const CsgVertData = struct {
    pos: Vec3d,
    nrm: Vec3d,
};

fn hashCsgWeldKey(pos: Vec3d, nrm: Vec3d) u64 {
    const qx: i64 = @intFromFloat(@round(pos.x * 1e5));
    const qy: i64 = @intFromFloat(@round(pos.y * 1e5));
    const qz: i64 = @intFromFloat(@round(pos.z * 1e5));
    const nx: i64 = @intFromFloat(@round(nrm.x * 50.0));
    const ny: i64 = @intFromFloat(@round(nrm.y * 50.0));
    const nz: i64 = @intFromFloat(@round(nrm.z * 50.0));
    var buf: [48]u8 = undefined;
    std.mem.writeInt(i64, buf[0..8], qx, .little);
    std.mem.writeInt(i64, buf[8..16], qy, .little);
    std.mem.writeInt(i64, buf[16..24], qz, .little);
    std.mem.writeInt(i64, buf[24..32], nx, .little);
    std.mem.writeInt(i64, buf[32..40], ny, .little);
    std.mem.writeInt(i64, buf[40..48], nz, .little);
    return std.hash.Wyhash.hash(0, &buf);
}

fn addWeldedCsgVertex(
    out: *BRepSolid,
    allocator: std.mem.Allocator,
    weld_map: *std.AutoHashMap(u64, u32),
    v: CsgVertData,
) !u32 {
    const key = hashCsgWeldKey(v.pos, v.nrm);
    if (weld_map.get(key)) |existing_idx| {
        if (vec3LenSq(out.vertices.items[existing_idx].sub(v.pos)) < 1e-8) {
            return existing_idx;
        }
    }
    const new_idx: u32 = @intCast(out.vertices.items.len);
    try out.vertices.append(allocator, v.pos);
    try out.normals.append(allocator, v.nrm);
    try weld_map.put(key, new_idx);
    return new_idx;
}

fn addWeldedCsgTriangle(
    out: *BRepSolid,
    allocator: std.mem.Allocator,
    weld_map: *std.AutoHashMap(u64, u32),
    v0: CsgVertData,
    v1: CsgVertData,
    v2: CsgVertData,
    invert: bool,
    tid: TopoId,
    curv: FaceCurvature,
) !void {
    if (vec3LenSq(v1.pos.sub(v0.pos).cross(v2.pos.sub(v0.pos))) < 1e-18) return;
    const idx0 = try addWeldedCsgVertex(out, allocator, weld_map, v0);
    const idx1 = try addWeldedCsgVertex(out, allocator, weld_map, v1);
    const idx2 = try addWeldedCsgVertex(out, allocator, weld_map, v2);
    if (idx0 == idx1 or idx1 == idx2 or idx2 == idx0) return;
    if (invert) {
        try out.addTriangle(idx0, idx2, idx1, tid, curv);
    } else {
        try out.addTriangle(idx0, idx1, idx2, tid, curv);
    }
}

/// Finds the zero-crossing of `s(x) = sign_mul * evalSolidSignedDistance(other_h, x) + collar = 0`
/// along edge `(va, vb)` via safeguarded secant/bisection root-finding with canonical endpoint ordering.
fn findEdgeZeroCrossing(
    other_h: u64,
    va: CsgVertData,
    sa: f64,
    vb: CsgVertData,
    sb: f64,
    sign_mul: f64,
    collar: f64,
) CsgVertData {
    // Canonicalize endpoint ordering lexicographically so shared edges between adjacent triangles
    // produce bit-identical intersection points regardless of traversal direction.
    const swap = if (va.pos.x != vb.pos.x)
        va.pos.x > vb.pos.x
    else if (va.pos.y != vb.pos.y)
        va.pos.y > vb.pos.y
    else
        va.pos.z > vb.pos.z;

    const p0 = if (swap) vb.pos else va.pos;
    const n0 = if (swap) vb.nrm else va.nrm;
    const f0 = if (swap) sb else sa;
    const p1 = if (swap) va.pos else vb.pos;
    const n1 = if (swap) va.nrm else vb.nrm;
    const f1 = if (swap) sa else sb;

    var t_lo: f64 = 0.0;
    var t_hi: f64 = 1.0;
    var flo = f0;
    var fhi = f1;
    const denom = @abs(f0) + @abs(f1);
    var t_cur: f64 = if (denom > 1e-15) std.math.clamp(@abs(f0) / denom, 0.02, 0.98) else 0.5;

    for (0..6) |_| {
        const pt = p0.add(p1.sub(p0).scale(t_cur));
        const fm = sign_mul * evalSolidSignedDistance(other_h, pt) + collar;
        if (@abs(fm) < 1e-7) break;
        if ((flo >= 0.0 and fm >= 0.0) or (flo < 0.0 and fm < 0.0)) {
            t_lo = t_cur;
            flo = fm;
        } else {
            t_hi = t_cur;
            fhi = fm;
        }
        const span_d = @abs(flo) + @abs(fhi);
        const secant_t = if (span_d > 1e-15) t_lo + (t_hi - t_lo) * (@abs(flo) / span_d) else 0.5 * (t_lo + t_hi);
        // Safeguard secant step within the bracket [t_lo, t_hi]
        const margin = 0.05 * (t_hi - t_lo);
        t_cur = std.math.clamp(secant_t, t_lo + margin, t_hi - margin);
    }

    const pos = p0.add(p1.sub(p0).scale(t_cur));
    const nrm = n0.scale(1.0 - t_cur).add(n1.scale(t_cur)).normalize();
    return .{ .pos = pos, .nrm = nrm };
}

fn clipAndEmitCsgTriangle(
    out: *BRepSolid,
    allocator: std.mem.Allocator,
    weld_map: *std.AutoHashMap(u64, u32),
    v0: CsgVertData,
    s0: f64,
    v1: CsgVertData,
    s1: f64,
    v2: CsgVertData,
    s2: f64,
    other_h: u64,
    sign_mul: f64,
    collar: f64,
    invert: bool,
    tid: TopoId,
    curv: FaceCurvature,
    depth: u2,
) !void {
    if (other_h == 0) {
        try addWeldedCsgTriangle(out, allocator, weld_map, v0, v1, v2, invert, tid, curv);
        return;
    }

    const k0 = s0 >= 0.0;
    const k1 = s1 >= 0.0;
    const k2 = s2 >= 0.0;
    const kept_count: u8 = @as(u8, @intFromBool(k0)) + @as(u8, @intFromBool(k1)) + @as(u8, @intFromBool(k2));

    if (kept_count == 3 or kept_count == 0) {
        if (depth < 1 and ((other_h >> 62) == 0b10)) {
            const centroid = v0.pos.add(v1.pos).add(v2.pos).scale(1.0 / 3.0);
            const sc = sign_mul * evalSolidSignedDistance(other_h, centroid) + collar;
            const kc = sc >= 0.0;
            if (kc != k0) {
                const vc = CsgVertData{
                    .pos = centroid,
                    .nrm = v0.nrm.add(v1.nrm).add(v2.nrm).normalize(),
                };
                try clipAndEmitCsgTriangle(out, allocator, weld_map, v0, s0, v1, s1, vc, sc, other_h, sign_mul, collar, invert, tid, curv, depth + 1);
                try clipAndEmitCsgTriangle(out, allocator, weld_map, v1, s1, v2, s2, vc, sc, other_h, sign_mul, collar, invert, tid, curv, depth + 1);
                try clipAndEmitCsgTriangle(out, allocator, weld_map, v2, s2, v0, s0, vc, sc, other_h, sign_mul, collar, invert, tid, curv, depth + 1);
                return;
            }
        }
        if (kept_count == 3) {
            try addWeldedCsgTriangle(out, allocator, weld_map, v0, v1, v2, invert, tid, curv);
        }
        return;
    }

    const verts = [3]CsgVertData{ v0, v1, v2 };
    const s_vals = [3]f64{ s0, s1, s2 };

    if (kept_count == 1) {
        // Rotate (a, b, c) cyclically so `a` is the single kept vertex (s[a] >= 0, s[b] < 0, s[c] < 0)
        const a: usize = if (k0) 0 else if (k1) 1 else 2;
        const b: usize = (a + 1) % 3;
        const c: usize = (a + 2) % 3;

        const m_ab = findEdgeZeroCrossing(other_h, verts[a], s_vals[a], verts[b], s_vals[b], sign_mul, collar);
        const m_ca = findEdgeZeroCrossing(other_h, verts[c], s_vals[c], verts[a], s_vals[a], sign_mul, collar);
        try addWeldedCsgTriangle(out, allocator, weld_map, verts[a], m_ab, m_ca, invert, tid, curv);
    } else {
        // kept_count == 2: Rotate (a, b, c) cyclically so `a` and `b` are kept and `c` is discarded
        const c: usize = if (!k2) 2 else if (!k0) 0 else 1;
        const a: usize = (c + 1) % 3;
        const b: usize = (c + 2) % 3;

        const m_bc = findEdgeZeroCrossing(other_h, verts[b], s_vals[b], verts[c], s_vals[c], sign_mul, collar);
        const m_ca = findEdgeZeroCrossing(other_h, verts[c], s_vals[c], verts[a], s_vals[a], sign_mul, collar);
        try addWeldedCsgTriangle(out, allocator, weld_map, verts[a], verts[b], m_bc, invert, tid, curv);
        try addWeldedCsgTriangle(out, allocator, weld_map, verts[a], m_bc, m_ca, invert, tid, curv);
    }
}

/// Resolves a CSG node into an evaluated mesh stored in `solid_brep_store[handle]`,
/// subdividing straddling triangles along $F(\mathbf{x}) = 0$, welding shared intersection vertices,
/// and preserving 192-bit `TopoId`s (§9.1–§9.4).
pub fn materializeCsgNode(
    allocator: std.mem.Allocator,
    handle: u64,
    node: CsgNode,
) !void {
    if (solid_brep_store.contains(handle)) return;

    // Ensure children are materialized first
    if ((node.left >> 62) == 0b01) {
        if (csg_store.get(node.left)) |l_node| {
            try materializeCsgNode(allocator, node.left, l_node);
        }
    }
    if ((node.right >> 62) == 0b01) {
        if (csg_store.get(node.right)) |r_node| {
            try materializeCsgNode(allocator, node.right, r_node);
        }
    }

    const left_mesh = solid_brep_store.getPtr(node.left);
    const right_mesh = solid_brep_store.getPtr(node.right);

    const solid_id: u32 = @intCast(handle & 0xFFFFFFFF);
    var out = BRepSolid.init(allocator, solid_id);
    errdefer out.deinit();

    var weld_map = std.AutoHashMap(u64, u32).init(allocator);
    defer weld_map.deinit();

    const collar = if (node.collar_tol > 0.0) node.collar_tol else 1e-6;

    // 1. Classify, subdivide straddling triangles, and weld surviving triangles from left operand A
    if (left_mesh) |lm| {
        out.feature_hash = lm.feature_hash;
        const other_b = if (node.right != 0 and node.right != node.left) node.right else 0;
        const sign_mul_a: f64 = switch (node.op) {
            0 => 1.0, // Union: keep A outside B (fb >= -collar)
            1 => 1.0, // Subtract A \ B: keep A outside B (fb >= -collar)
            2 => -1.0, // Intersect A n B: keep A inside B (-fb + collar >= 0)
            else => 1.0,
        };

        var s_cache_a = try allocator.alloc(f64, lm.vertices.items.len);
        defer allocator.free(s_cache_a);
        if (other_b != 0) {
            for (lm.vertices.items, 0..) |vp, vi| {
                s_cache_a[vi] = sign_mul_a * evalSolidSignedDistance(other_b, vp) + collar;
            }
        } else {
            @memset(s_cache_a, 1.0);
        }

        const tri_count = lm.indices.items.len / 3;
        for (0..tri_count) |t| {
            const idx0 = lm.indices.items[t * 3];
            const idx1 = lm.indices.items[t * 3 + 1];
            const idx2 = lm.indices.items[t * 3 + 2];
            const v0 = CsgVertData{ .pos = lm.vertices.items[idx0], .nrm = lm.normals.items[idx0] };
            const v1 = CsgVertData{ .pos = lm.vertices.items[idx1], .nrm = lm.normals.items[idx1] };
            const v2 = CsgVertData{ .pos = lm.vertices.items[idx2], .nrm = lm.normals.items[idx2] };
            const tid = if (t < lm.triangle_to_topo_id.items.len)
                lm.triangle_to_topo_id.items[t]
            else
                makeTopoId(solid_id, SUBSHAPE_FACE, 1);
            const curv = lm.getCurvature(t);
            try clipAndEmitCsgTriangle(&out, allocator, &weld_map, v0, s_cache_a[idx0], v1, s_cache_a[idx1], v2, s_cache_a[idx2], other_b, sign_mul_a, collar, false, tid, curv, 0);
        }
    }

    // 2. Classify, subdivide straddling triangles, and weld surviving triangles from right operand B
    if (right_mesh) |rm| {
        if (node.right != node.left) {
            const other_a = node.left;
            const sign_mul_b: f64 = switch (node.op) {
                0 => 1.0, // Union: keep B outside A (fa >= -collar)
                1 => -1.0, // Subtract A \ B: keep B inside A (-fa + collar >= 0, inverted)
                2 => -1.0, // Intersect A n B: keep B inside A (-fa + collar >= 0)
                else => -1.0,
            };
            const invert_b = (node.op == 1);
            const nrm_scale: f64 = if (invert_b) -1.0 else 1.0;

            var s_cache_b = try allocator.alloc(f64, rm.vertices.items.len);
            defer allocator.free(s_cache_b);
            if (other_a != 0) {
                for (rm.vertices.items, 0..) |vp, vi| {
                    s_cache_b[vi] = sign_mul_b * evalSolidSignedDistance(other_a, vp) + collar;
                }
            } else {
                @memset(s_cache_b, 1.0);
            }

            const tri_count = rm.indices.items.len / 3;
            for (0..tri_count) |t| {
                const idx0 = rm.indices.items[t * 3];
                const idx1 = rm.indices.items[t * 3 + 1];
                const idx2 = rm.indices.items[t * 3 + 2];
                const v0 = CsgVertData{ .pos = rm.vertices.items[idx0], .nrm = rm.normals.items[idx0].scale(nrm_scale) };
                const v1 = CsgVertData{ .pos = rm.vertices.items[idx1], .nrm = rm.normals.items[idx1].scale(nrm_scale) };
                const v2 = CsgVertData{ .pos = rm.vertices.items[idx2], .nrm = rm.normals.items[idx2].scale(nrm_scale) };
                const tid = if (t < rm.triangle_to_topo_id.items.len)
                    rm.triangle_to_topo_id.items[t]
                else
                    makeTopoId(solid_id, SUBSHAPE_FACE, 2);
                const curv = rm.getCurvature(t);
                try clipAndEmitCsgTriangle(&out, allocator, &weld_map, v0, s_cache_b[idx0], v1, s_cache_b[idx1], v2, s_cache_b[idx2], other_a, sign_mul_b, collar, invert_b, tid, curv, 0);
            }
        }
    }

    // Fallback if boolean classification clipped all triangles (e.g. disjoint subtract/union edge case)
    if (out.indices.items.len == 0) {
        if (left_mesh) |lm| {
            out.deinit();
            out = try lm.clone(allocator, solid_id);
        }
    }

    try solid_brep_store.put(handle, out);
}

// ============================================================================
// Canonical 18-Function C-ABI Entry Points
// ============================================================================

pub var active_sweep_depth: f64 = 10.0;

pub fn solid_kinematic_sweep(
    wire_h: u64,
    se3_expr_h: u64,
    cap_ends: bool,
) u64 {
    const alloc = memory.persistent_allocator;
    const wire = curve_wire.wire_store.get(wire_h) orelse return 0;

    var depth: f64 = active_sweep_depth;
    if (se3_expr_h != 0) {
        const v_in = [_]f64{1.0};
        const res_val = autodiff.expr_eval(se3_expr_h, &v_in, 1, null);
        if (res_val > 0.0) {
            depth = res_val;
        }
    }

    // Sample wire in 2D chart coordinates
    var samples: std.ArrayList(ProfileEdgeSample2D) = .empty;
    defer samples.deinit(alloc);

    for (wire.curve_handles) |ch| {
        if (curve_wire.curve_store.get(ch)) |curve| {
            const u_min = curve.knots[curve.degree];
            const u_max = curve.knots[curve.ctrl_count];
            const n_steps: usize = if (curve.degree == 1) 1 else 16;
            for (0..n_steps) |s| {
                const frac = @as(f64, @floatFromInt(s)) / @as(f64, @floatFromInt(n_steps));
                const t = u_min + frac * (u_max - u_min);
                const d = curve.evalDerivs(t);
                const speed = @sqrt(d.d1.x * d.d1.x + d.d1.y * d.d1.y);
                const k2d = if (speed > 1e-9)
                    @abs(d.d1.x * d.d2.y - d.d1.y * d.d2.x) / (speed * speed * speed)
                else
                    0.0;
                samples.append(alloc, .{
                    .u = d.point.x,
                    .v = d.point.y,
                    .curve_hash = ch & 0x3FFFFFFFFFFFFFFF,
                    .curvature_2d = k2d,
                }) catch return 0;
            }
        }
    }

    if (samples.items.len < 3) return 0;

    const normal = wire.frame_u.cross(wire.frame_v).normalize();
    const steps = [2]TrajectoryStep{
        .{ .v = 0.0, .translation = Vec3d.zero() },
        .{ .v = 1.0, .translation = normal.scale(depth) },
    };

    const outer_loop = ProfileLoop2D{
        .wire_id = "outer",
        .is_hole = false,
        .points = samples.items,
    };

    const f_hash = (@as(u64, next_solid_id) << 32) | 1;
    return sweepProfileLoopsSE3(
        alloc,
        f_hash,
        wire_h & 0x3FFFFFFFFFFFFFFF,
        wire.frame_origin,
        wire.frame_u,
        wire.frame_v,
        outer_loop,
        &[_]ProfileLoop2D{},
        &steps,
        cap_ends,
    ) catch 0;
}

const LoftSectionSample = struct {
    world_p: Vec3d,
    local_u: f64,
    local_v: f64,
    curve_hash: u64,
    curvature_2d: f64,
};

fn sampleWireSection(
    alloc: std.mem.Allocator,
    wire: curve_wire.Wire,
    steps_per_curve: usize,
    out: *std.ArrayList(LoftSectionSample),
) !void {
    for (wire.curve_handles) |ch| {
        if (curve_wire.curve_store.get(ch)) |curve| {
            const u_min = curve.knots[curve.degree];
            const u_max = curve.knots[curve.ctrl_count];
            const n_steps: usize = if (steps_per_curve > 0) steps_per_curve else (if (curve.degree == 1) 1 else 16);
            for (0..n_steps) |s| {
                const frac = @as(f64, @floatFromInt(s)) / @as(f64, @floatFromInt(n_steps));
                const t = u_min + frac * (u_max - u_min);
                const d = curve.evalDerivs(t);
                const speed = @sqrt(d.d1.x * d.d1.x + d.d1.y * d.d1.y);
                const k2d = if (speed > 1e-9)
                    @abs(d.d1.x * d.d2.y - d.d1.y * d.d2.x) / (speed * speed * speed)
                else
                    0.0;
                const wp = wire.frame_origin
                    .add(wire.frame_u.scale(d.point.x))
                    .add(wire.frame_v.scale(d.point.y));
                try out.append(alloc, .{
                    .world_p = wp,
                    .local_u = d.point.x,
                    .local_v = d.point.y,
                    .curve_hash = ch & 0x3FFFFFFFFFFFFFFF,
                    .curvature_2d = k2d,
                });
            }
        }
    }
}

/// Evaluates a bivariate tensor-product NURBS loft across `count` profile wires of longitudinal degree `degree_v` (§7.2).
pub fn solid_tensor_loft(
    wire_handles_ptr: [*]const u64,
    count: u32,
    degree_v: u32,
) u64 {
    last_brep_status = 0;
    if (count == 0) return 0;
    if (count == 1) return solid_kinematic_sweep(wire_handles_ptr[0], 0, true);

    const alloc = memory.persistent_allocator;
    const K: usize = @intCast(count);

    // Check whether all wires have identical curve counts and linear segments
    var first_curve_count: usize = 0;
    var same_curve_counts = true;
    var all_degree_one = true;
    for (0..K) |k| {
        const w = curve_wire.wire_store.get(wire_handles_ptr[k]) orelse return 0;
        if (w.curve_handles.len == 0) return 0;
        if (k == 0) {
            first_curve_count = w.curve_handles.len;
        } else if (w.curve_handles.len != first_curve_count) {
            same_curve_counts = false;
        }
        for (w.curve_handles) |ch| {
            const c = curve_wire.curve_store.get(ch) orelse return 0;
            if (c.degree > 1) all_degree_one = false;
        }
    }

    var raw_sections = alloc.alloc(std.ArrayList(LoftSectionSample), K) catch return 0;
    for (0..K) |k| raw_sections[k] = .empty;
    defer {
        for (0..K) |k| raw_sections[k].deinit(alloc);
        alloc.free(raw_sections);
    }

    const steps_per_curve: usize = if (same_curve_counts and all_degree_one) 1 else 16;
    for (0..K) |k| {
        const w = curve_wire.wire_store.get(wire_handles_ptr[k]).?;
        sampleWireSection(alloc, w, steps_per_curve, &raw_sections[k]) catch return 0;
        if (raw_sections[k].items.len < 3) return 0;
    }

    // Harmonize perimeter sample count M across all K sections
    var M: usize = raw_sections[0].items.len;
    var need_resample = false;
    for (1..K) |k| {
        if (raw_sections[k].items.len != M) {
            need_resample = true;
            if (raw_sections[k].items.len > M) M = raw_sections[k].items.len;
        }
    }
    if (need_resample and M < 64) M = 64;

    var sections = alloc.alloc([]LoftSectionSample, K) catch return 0;
    var sec_allocated: usize = 0;
    defer {
        for (0..sec_allocated) |k| alloc.free(sections[k]);
        alloc.free(sections);
    }

    for (0..K) |k| {
        const src = raw_sections[k].items;
        const dst = alloc.alloc(LoftSectionSample, M) catch return 0;
        sec_allocated += 1;
        if (src.len == M) {
            @memcpy(dst, src);
        } else {
            const src_len_f = @as(f64, @floatFromInt(src.len));
            for (0..M) |j| {
                const pos = (@as(f64, @floatFromInt(j)) / @as(f64, @floatFromInt(M))) * src_len_f;
                const idx0: usize = @min(@as(usize, @intFromFloat(@floor(pos))), src.len - 1);
                const idx1: usize = (idx0 + 1) % src.len;
                const alpha = pos - @floor(pos);
                dst[j] = .{
                    .world_p = src[idx0].world_p.scale(1.0 - alpha).add(src[idx1].world_p.scale(alpha)),
                    .local_u = src[idx0].local_u * (1.0 - alpha) + src[idx1].local_u * alpha,
                    .local_v = src[idx0].local_v * (1.0 - alpha) + src[idx1].local_v * alpha,
                    .curve_hash = src[idx0].curve_hash,
                    .curvature_2d = src[idx0].curvature_2d * (1.0 - alpha) + src[idx1].curvature_2d * alpha,
                };
            }
        }
        sections[k] = dst;
    }

    // Longitudinal B-spline degree p_v in [1, K - 1]
    const p_v: u32 = @min(@max(degree_v, 1), @as(u32, @intCast(K - 1)));
    const knot_count = K + @as(usize, p_v) + 1;
    var knots_v = alloc.alloc(f64, knot_count) catch return 0;
    defer alloc.free(knots_v);

    for (0..@as(usize, p_v) + 1) |i| {
        knots_v[i] = 0.0;
        knots_v[knot_count - 1 - i] = 1.0;
    }
    const interior_spans = K - @as(usize, p_v);
    if (interior_spans > 1) {
        for (1..interior_spans) |j| {
            knots_v[@as(usize, p_v) + j] = @as(f64, @floatFromInt(j)) / @as(f64, @floatFromInt(interior_spans));
        }
    }

    // Number of longitudinal evaluation stations N_v
    const N_v: usize = if (p_v == 1) K else (8 * (K - 1) + 1);

    const solid_id = next_solid_id;
    next_solid_id += 1;
    const f_hash = (@as(u64, solid_id) << 32) | 1;
    const loft_branch_hash = wire_handles_ptr[0] & 0x3FFFFFFFFFFFFFFF;

    var solid = BRepSolid.init(alloc, solid_id);
    errdefer solid.deinit();
    solid.feature_hash = f_hash;

    // 1. Evaluate bivariate tensor surface S(u_j, v_s) and longitudinal derivative dS/dv
    var ds_dv_grid = alloc.alloc(Vec3d, N_v * M) catch {
        solid.deinit();
        return 0;
    };
    defer alloc.free(ds_dv_grid);

    var d2s_dv2_grid = alloc.alloc(Vec3d, N_v * M) catch {
        solid.deinit();
        return 0;
    };
    defer alloc.free(d2s_dv2_grid);

    for (0..N_v) |s| {
        const v_param = @as(f64, @floatFromInt(s)) / @as(f64, @floatFromInt(N_v - 1));
        const span = nurbs.findSpan(@intCast(K - 1), p_v, v_param, knots_v);
        var N0: [16]f64 = undefined;
        var N1: [16]f64 = undefined;
        var N2: [16]f64 = undefined;
        nurbs.evalBasisAndDerivs(span, v_param, p_v, knots_v, N0[0 .. p_v + 1], N1[0 .. p_v + 1], N2[0 .. p_v + 1]);

        for (0..M) |j| {
            var pt = Vec3d.zero();
            var d1v = Vec3d.zero();
            var d2v = Vec3d.zero();
            for (0..@as(usize, p_v) + 1) |b| {
                const sec_idx = @as(usize, span - p_v) + b;
                const cp = sections[sec_idx][j].world_p;
                pt = pt.add(cp.scale(N0[b]));
                d1v = d1v.add(cp.scale(N1[b]));
                d2v = d2v.add(cp.scale(N2[b]));
            }
            solid.vertices.append(alloc, pt) catch {
                solid.deinit();
                return 0;
            };
            solid.normals.append(alloc, Vec3d.init(0.0, 0.0, 1.0)) catch {
                solid.deinit();
                return 0;
            };
            ds_dv_grid[s * M + j] = d1v;
            d2s_dv2_grid[s * M + j] = d2v;
        }
    }

    // 2. Emit lateral faces and compute analytical surface normals & fundamental form curvatures
    for (0..N_v - 1) |s| {
        for (0..M) |j| {
            const next_j = (j + 1) % M;
            const b0: u32 = @intCast(s * M + j);
            const b1: u32 = @intCast(s * M + next_j);
            const t0: u32 = @intCast((s + 1) * M + j);
            const t1: u32 = @intCast((s + 1) * M + next_j);

            const p_b0 = solid.vertices.items[b0];
            const p_b1 = solid.vertices.items[b1];
            const p_t0 = solid.vertices.items[t0];

            const ds_du = p_b1.sub(p_b0);
            const ds_dv_chord = p_t0.sub(p_b0);
            const cross_uv = ds_du.cross(ds_dv_chord);
            if (cross_uv.length() < 1e-10) {
                last_brep_status = ERR_SWEEP_SELF_INTERSECT;
                solid.deinit();
                return 0;
            }

            const n_unit = cross_uv.normalize();
            solid.normals.items[b0] = n_unit;
            solid.normals.items[t0] = n_unit;

            // Curvature from profile 2D curvature and longitudinal B-spline second derivative
            const k_u = sections[0][j].curvature_2d;
            const d1v = ds_dv_grid[s * M + j];
            const d2v = d2s_dv2_grid[s * M + j];
            const v_speed2 = d1v.dot(d1v);
            const k_v = if (v_speed2 > 1e-12) d2v.dot(n_unit) / v_speed2 else 0.0;
            const k1 = @min(k_u, k_v);
            const k2 = @max(k_u, k_v);
            const curv = FaceCurvature{
                .k_min = k1,
                .k_max = k2,
                .k_gauss = k1 * k2,
                .k_mean = 0.5 * (k1 + k2),
            };

            const c_hash = if (sections[0][j].curve_hash != 0) sections[0][j].curve_hash else loft_branch_hash;
            const tid = TopoId.init(f_hash, c_hash, SUBSHAPE_FACE, TopoFlags.ANALYTIC | TopoFlags.PRESERVE, 0);

            solid.addTriangle(b0, b1, t1, tid, curv) catch {
                solid.deinit();
                return 0;
            };
            solid.addTriangle(b0, t1, t0, tid, curv) catch {
                solid.deinit();
                return 0;
            };
        }
    }

    // 3. Triangulate bottom cap (section 0, s = 0) and top cap (section K-1, s = N_v - 1)
    var bot_poly = alloc.alloc(PolyVert2D, M) catch {
        solid.deinit();
        return 0;
    };
    defer alloc.free(bot_poly);
    for (0..M) |j| {
        bot_poly[j] = .{ .u = sections[0][j].local_u, .v = sections[0][j].local_v, .orig_idx = @intCast(j) };
    }
    var bot_tris: std.ArrayList([3]u32) = .empty;
    defer bot_tris.deinit(alloc);
    triangulatePolygonWithHoles2D(alloc, bot_poly, &[_][]PolyVert2D{}, &bot_tris) catch {
        solid.deinit();
        return 0;
    };

    const bot_tid = TopoId.init(f_hash, loft_branch_hash, SUBSHAPE_FACE, TopoFlags.ANALYTIC | TopoFlags.BOUNDARY, 0);
    const top_tid = TopoId.init(f_hash, wire_handles_ptr[K - 1] & 0x3FFFFFFFFFFFFFFF, SUBSHAPE_FACE, TopoFlags.ANALYTIC | TopoFlags.BOUNDARY, 0);
    const flat_curv = FaceCurvature{};

    for (bot_tris.items) |tri| {
        solid.addTriangle(tri[0], tri[2], tri[1], bot_tid, flat_curv) catch {
            solid.deinit();
            return 0;
        };
    }

    var top_poly = alloc.alloc(PolyVert2D, M) catch {
        solid.deinit();
        return 0;
    };
    defer alloc.free(top_poly);
    const top_base: u32 = @intCast((N_v - 1) * M);
    for (0..M) |j| {
        top_poly[j] = .{
            .u = sections[K - 1][j].local_u,
            .v = sections[K - 1][j].local_v,
            .orig_idx = top_base + @as(u32, @intCast(j)),
        };
    }
    var top_tris: std.ArrayList([3]u32) = .empty;
    defer top_tris.deinit(alloc);
    triangulatePolygonWithHoles2D(alloc, top_poly, &[_][]PolyVert2D{}, &top_tris) catch {
        solid.deinit();
        return 0;
    };

    for (top_tris.items) |tri| {
        solid.addTriangle(tri[0], tri[1], tri[2], top_tid, flat_curv) catch {
            solid.deinit();
            return 0;
        };
    }

    const handle: u64 = (@as(u64, 0b00) << 62) | @as(u64, solid_id);
    solid_brep_store.put(handle, solid) catch {
        solid.deinit();
        return 0;
    };
    return handle;
}

pub fn solid_envelope_fillet(
    solid_h: u64,
    edge_pred_expr_h: u64,
    radius_expr_h: u64,
) u64 {
    // radius_expr_h is a constant expression; edge_pred_expr_h (optional) is evaluated over the
    // EdgeSelector variable layout. Returns 0 and sets last_brep_status on failure.
    if (radius_expr_h == 0) {
        last_brep_status = ERR_FILLET_RADIUS_COLLAPSE;
        return 0;
    }
    const zero = [_]f64{0.0};
    const r_val = autodiff.expr_eval(radius_expr_h, &zero, 1, null);
    var vars: [15]f64 = undefined;
    @memset(&vars, 0.0);
    const sel = EdgeSelector{ .expr_h = edge_pred_expr_h, .vars = &vars };
    return filletSweptSolid(memory.persistent_allocator, solid_h, 0, &sel, r_val, 0.05) catch 0;
}

/// Constructs a non-destructive thick-walled offset shell from `solid_h` with wall thickness `offset_dist`.
/// Triangles where `face_pred_expr_h != 0` evaluates to non-zero are removed (pierced/open faces) and their
/// boundary edges are stitched between the outer and inner offset sheets to form a watertight 2-manifold shell.
pub fn solid_offset_shell(
    solid_h: u64,
    face_pred_expr_h: u64,
    offset_dist: f64,
) u64 {
    const alloc = memory.persistent_allocator;
    const base = solid_brep_store.getPtr(solid_h) orelse return 0;
    const tri_count = base.indices.items.len / 3;
    if (tri_count == 0 or @abs(offset_dist) < 1e-12) {
        const new_id = next_solid_id;
        next_solid_id += 1;
        const copy = base.clone(alloc, new_id) catch return 0;
        const h: u64 = (@as(u64, 0b00) << 62) | @as(u64, new_id);
        solid_brep_store.put(h, copy) catch return 0;
        return h;
    }

    // 1. Weld coincident vertices (within 1e-6) so shared corners offset coherently without cracking
    const v_len = base.vertices.items.len;
    var vert_to_group = alloc.alloc(u32, v_len) catch return 0;
    defer alloc.free(vert_to_group);

    var group_pos: std.ArrayList(Vec3d) = .empty;
    defer group_pos.deinit(alloc);

    for (base.vertices.items, 0..) |v, vi| {
        var found: ?u32 = null;
        for (group_pos.items, 0..) |gp, gi| {
            if (v.sub(gp).length() < 1e-6) {
                found = @intCast(gi);
                break;
            }
        }
        if (found) |gi| {
            vert_to_group[vi] = gi;
        } else {
            const gi: u32 = @intCast(group_pos.items.len);
            group_pos.append(alloc, v) catch return 0;
            vert_to_group[vi] = gi;
        }
    }

    const G = group_pos.items.len;
    var group_nrm_sum = alloc.alloc(Vec3d, G) catch return 0;
    defer alloc.free(group_nrm_sum);
    for (0..G) |g| group_nrm_sum[g] = Vec3d.zero();

    // 2. Evaluate face predicate on every triangle
    var is_open = alloc.alloc(bool, tri_count) catch return 0;
    defer alloc.free(is_open);

    var open_count: usize = 0;
    for (0..tri_count) |t| {
        const idx0 = base.indices.items[t * 3 + 0];
        const idx1 = base.indices.items[t * 3 + 1];
        const idx2 = base.indices.items[t * 3 + 2];
        const p0 = base.vertices.items[idx0];
        const p1 = base.vertices.items[idx1];
        const p2 = base.vertices.items[idx2];

        const e1 = p1.sub(p0);
        const e2 = p2.sub(p0);
        const cr = e1.cross(e2);
        const area = 0.5 * cr.length();
        const n_unit = cr.normalize();

        if (face_pred_expr_h != 0) {
            const centroid = p0.add(p1).add(p2).scale(1.0 / 3.0);
            const tang = e1.normalize();
            const curv = base.getCurvature(t);
            const tid = if (t < base.triangle_to_topo_id.items.len)
                base.triangle_to_topo_id.items[t]
            else
                makeTopoId(base.solid_id, SUBSHAPE_FACE, 1);
            autodiff.setCurrentTopoId(tid);

            const pred_vars = [15]f64{
                centroid.x,
                centroid.y,
                centroid.z,
                n_unit.x,
                n_unit.y,
                n_unit.z,
                tang.x,
                tang.y,
                tang.z,
                curv.k_min,
                curv.k_max,
                curv.k_gauss,
                curv.k_mean,
                area,
                e1.length(),
            };
            is_open[t] = autodiff.expr_eval(face_pred_expr_h, &pred_vars, 15, null) != 0.0;
            if (is_open[t]) open_count += 1;
        } else {
            is_open[t] = false;
        }
    }

    // Collect distinct incident face normals per welded vertex so planar faces offset by exact perpendicular distance `offset_dist`
    var group_distinct_nrms = alloc.alloc([8]Vec3d, G) catch return 0;
    defer alloc.free(group_distinct_nrms);
    var group_distinct_cnt = alloc.alloc(u32, G) catch return 0;
    defer alloc.free(group_distinct_cnt);
    @memset(group_distinct_cnt, 0);

    for (0..tri_count) |t| {
        if (is_open[t]) continue;
        const idx0 = base.indices.items[t * 3 + 0];
        const idx1 = base.indices.items[t * 3 + 1];
        const idx2 = base.indices.items[t * 3 + 2];
        const n_tri = computeTriNormal(base, t);
        if (n_tri.length() < 1e-9) continue;
        const gs = [3]u32{ vert_to_group[idx0], vert_to_group[idx1], vert_to_group[idx2] };
        for (gs) |g| {
            const cnt = group_distinct_cnt[g];
            var dup = false;
            for (0..cnt) |k| {
                if (group_distinct_nrms[g][k].dot(n_tri) > 1.0 - 1e-5) {
                    dup = true;
                    break;
                }
            }
            if (!dup and cnt < 8) {
                group_distinct_nrms[g][cnt] = n_tri;
                group_distinct_cnt[g] = cnt + 1;
                group_nrm_sum[g] = group_nrm_sum[g].add(n_tri);
            }
        }
    }

    var group_inner_pos = alloc.alloc(Vec3d, G) catch return 0;
    defer alloc.free(group_inner_pos);
    for (0..G) |g| {
        const n_avg = group_nrm_sum[g].normalize();
        group_nrm_sum[g] = n_avg;
        const cnt = group_distinct_cnt[g];
        var dot_sum: f64 = 0.0;
        for (0..cnt) |k| {
            dot_sum += @abs(n_avg.dot(group_distinct_nrms[g][k]));
        }
        const avg_cos = if (cnt > 0)
            std.math.clamp(dot_sum / @as(f64, @floatFromInt(cnt)), 0.35, 1.0)
        else
            1.0;
        const miter_vec = n_avg.scale(offset_dist / avg_cos);
        group_inner_pos[g] = group_pos.items[g].sub(miter_vec);
    }

    // 3. Construct new shelled BRepSolid
    const new_id = next_solid_id;
    next_solid_id += 1;
    var out = BRepSolid.init(alloc, new_id);
    errdefer out.deinit();
    out.feature_hash = base.feature_hash;
    out.genus = base.genus;
    out.shells = if (open_count == 0 and open_count < tri_count) 2 else 1;

    // Emit outer welded vertices [0..G-1] and inner welded vertices [G..2*G-1]
    for (0..G) |g| {
        out.vertices.append(alloc, group_pos.items[g]) catch return 0;
        out.normals.append(alloc, group_nrm_sum[g]) catch return 0;
    }
    for (0..G) |g| {
        out.vertices.append(alloc, group_inner_pos[g]) catch return 0;
        out.normals.append(alloc, group_nrm_sum[g].scale(-1.0)) catch return 0;
    }

    const G_u32: u32 = @intCast(G);

    // Track directed edges (g_a << 32 | g_b) of kept triangles to identify rim edges bordering open faces
    var kept_half_edges = std.AutoHashMap(u64, u32).init(alloc);
    defer kept_half_edges.deinit();

    for (0..tri_count) |t| {
        if (is_open[t]) continue;

        const g0 = vert_to_group[base.indices.items[t * 3 + 0]];
        const g1 = vert_to_group[base.indices.items[t * 3 + 1]];
        const g2 = vert_to_group[base.indices.items[t * 3 + 2]];

        const tid_out = if (t < base.triangle_to_topo_id.items.len)
            base.triangle_to_topo_id.items[t]
        else
            makeTopoId(new_id, SUBSHAPE_FACE, 1);

        const tid_in = TopoId.init(
            tid_out.getFeatureHash(),
            tid_out.getBranchHash(),
            SUBSHAPE_FACE,
            tid_out.getTopoFlags(),
            tid_out.getSplitGeneration() + 1,
        );

        const curv_out = base.getCurvature(t);
        const curv_in = FaceCurvature{
            .k_min = -curv_out.k_max,
            .k_max = -curv_out.k_min,
            .k_gauss = curv_out.k_gauss,
            .k_mean = -curv_out.k_mean,
        };

        // Outer shell triangle (original CCW winding)
        out.addTriangle(g0, g1, g2, tid_out, curv_out) catch return 0;
        // Inner shell triangle (reversed winding so normal points inward into the cavity)
        out.addTriangle(G_u32 + g0, G_u32 + g2, G_u32 + g1, tid_in, curv_in) catch return 0;

        kept_half_edges.put((@as(u64, g0) << 32) | @as(u64, g1), @intCast(t)) catch return 0;
        kept_half_edges.put((@as(u64, g1) << 32) | @as(u64, g2), @intCast(t)) catch return 0;
        kept_half_edges.put((@as(u64, g2) << 32) | @as(u64, g0), @intCast(t)) catch return 0;
    }

    // 4. Stitch rim quads along every kept directed edge (g_a -> g_b) whose opposite (g_b -> g_a) is open
    var he_it = kept_half_edges.iterator();
    while (he_it.next()) |entry| {
        const key = entry.key_ptr.*;
        const ga: u32 = @intCast(key >> 32);
        const gb: u32 = @intCast(key & 0xFFFFFFFF);
        const opp_key = (@as(u64, gb) << 32) | @as(u64, ga);
        if (!kept_half_edges.contains(opp_key)) {
            const src_t = entry.value_ptr.*;
            const base_tid = if (src_t < base.triangle_to_topo_id.items.len)
                base.triangle_to_topo_id.items[src_t]
            else
                makeTopoId(new_id, SUBSHAPE_FACE, 2);
            const rim_tid = TopoId.init(
                base_tid.getFeatureHash(),
                base_tid.getBranchHash(),
                SUBSHAPE_FACE,
                TopoFlags.ANALYTIC | TopoFlags.BOUNDARY,
                base_tid.getSplitGeneration() + 1,
            );
            const flat_curv = FaceCurvature{};
            // Stitch outer boundary edge (gb -> ga) to inner boundary edge (G+ga -> G+gb)
            out.addTriangle(gb, ga, G_u32 + ga, rim_tid, flat_curv) catch return 0;
            out.addTriangle(gb, G_u32 + ga, G_u32 + gb, rim_tid, flat_curv) catch return 0;
        }
    }

    const handle: u64 = (@as(u64, 0b00) << 62) | @as(u64, new_id);
    solid_brep_store.put(handle, out) catch {
        out.deinit();
        return 0;
    };
    return handle;
}

pub fn solid_boolean(
    bool_op: u32,
    solid_a: u64,
    solid_b: u64,
) u64 {
    const node = CsgNode{
        .op = bool_op,
        .left = solid_a,
        .right = solid_b,
    };

    const id = next_solid_id;
    next_solid_id += 1;

    // Rule 4: bits [63:62] == 0b01 for CSG Tree Node
    const handle: u64 = (@as(u64, 0b01) << 62) | @as(u64, id);
    csg_store.put(handle, node) catch return 0;
    materializeCsgNode(memory.persistent_allocator, handle, node) catch {};

    return handle;
}

pub fn solid_free(h: u64) void {
    const tag = h >> 62;
    if (sweep_source_store.fetchRemove(h)) |kv| {
        var src = kv.value;
        src.deinit(memory.persistent_allocator);
    }
    if (region_solid_store.fetchRemove(h)) |kv| {
        var reg = kv.value;
        reg.deinit();
    }
    if (tag == 0b00) {
        if (solid_brep_store.fetchRemove(h)) |kv| {
            var s = kv.value;
            s.deinit();
        }
    } else if (tag == 0b01) {
        _ = csg_store.remove(h);
        if (solid_brep_store.fetchRemove(h)) |kv| {
            var s = kv.value;
            s.deinit();
        }
    } else if (tag == 0b10) {
        _ = implicit_field.implicit_store.remove(h);
        if (solid_brep_store.fetchRemove(h)) |kv| {
            var s = kv.value;
            s.deinit();
        }
    }
}
