const std = @import("std");
const Allocator = std.mem.Allocator;
const Vec3 = @import("../math/vec3.zig").Vec3;
const topo = @import("../topo/mod.zig");
const router = @import("../router.zig");
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

pub const BooleanType = enum {
    Union,
    Difference,
    Intersection,
};

pub const BooleanError = error{
    EmptySolid,
    DisjointIntersection,
    OutOfMemory,
    OperationFailed,
    ManifoldValidationFailed,
};

pub const Tri = struct {
    p: [3]Vec3,
    normal: Vec3,
    topo_id: CadTopoId,
};

pub const Plane = struct {
    point: Vec3,
    normal: Vec3,
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

/// Performs a Constructive Solid Geometry (CSG) Boolean operation
/// between solid_a and solid_b.
pub fn booleanOp(
    allocator: Allocator,
    feature_id: u16,
    op: BooleanType,
    solid_a: *const SoASolid,
    solid_b: *const SoASolid,
) BooleanError!SoASolid {
    if (solid_a.vertices.len == 0 and solid_b.vertices.len == 0) {
        return error.EmptySolid;
    }

    // Check Strangler-Fig Operation Router
    const cad_op: c_abi.CadOpType = switch (op) {
        .Union => .BooleanUnion,
        .Difference => .BooleanDifference,
        .Intersection => .BooleanIntersection,
    };
    const backend = router.global_router.getBackend(cad_op);
    _ = backend;

    switch (op) {
        .Union => return booleanUnion(allocator, feature_id, solid_a, solid_b),
        .Difference => return booleanDifference(allocator, feature_id, solid_a, solid_b),
        .Intersection => return booleanIntersection(allocator, feature_id, solid_a, solid_b),
    }
}

/// CSG Boolean Union: Combines geometry of solid_a and solid_b into a watertight SoASolid.
pub fn booleanUnion(
    allocator: Allocator,
    feature_id: u16,
    solid_a: *const SoASolid,
    solid_b: *const SoASolid,
) BooleanError!SoASolid {
    if (solid_a.vertices.len == 0) return solid_b.clone(allocator) catch return error.OutOfMemory;
    if (solid_b.vertices.len == 0) return solid_a.clone(allocator) catch return error.OutOfMemory;

    // Check bounding box disjointness
    const bbox_a = solid_a.calcBoundingBox();
    const bbox_b = solid_b.calcBoundingBox();
    const disjoint = (bbox_a.max.x < bbox_b.min.x - 1e-4 or bbox_a.min.x > bbox_b.max.x + 1e-4 or
        bbox_a.max.y < bbox_b.min.y - 1e-4 or bbox_a.min.y > bbox_b.max.y + 1e-4 or
        bbox_a.max.z < bbox_b.min.z - 1e-4 or bbox_a.min.z > bbox_b.max.z + 1e-4);

    if (disjoint) {
        var result = SoASolid.init();
        errdefer result.deinit(allocator);

        const solid_topo = CadTopoId.init(feature_id, 0, 4, .Shell, 0, 0);
        const solid_id = result.addSolid(allocator, solid_topo) catch return error.OutOfMemory;

        try mergeSolidInto(&result, allocator, solid_a, solid_id, feature_id);
        try mergeSolidInto(&result, allocator, solid_b, solid_id, feature_id);

        result.volume = solid_a.volume + solid_b.volume;
        result.surface_area = solid_a.surface_area + solid_b.surface_area;
        return result;
    }

    // Intersecting solids: perform exact CSG Boolean Union
    return executeCSG(allocator, feature_id, .Union, solid_a, solid_b);
}

/// CSG Boolean Difference: solid_a - solid_b
pub fn booleanDifference(
    allocator: Allocator,
    feature_id: u16,
    solid_a: *const SoASolid,
    solid_b: *const SoASolid,
) BooleanError!SoASolid {
    if (solid_a.vertices.len == 0) return error.EmptySolid;
    if (solid_b.vertices.len == 0) return solid_a.clone(allocator) catch return error.OutOfMemory;

    const bbox_a = solid_a.calcBoundingBox();
    const bbox_b = solid_b.calcBoundingBox();
    const disjoint = (bbox_a.max.x < bbox_b.min.x - 1e-4 or bbox_a.min.x > bbox_b.max.x + 1e-4 or
        bbox_a.max.y < bbox_b.min.y - 1e-4 or bbox_a.min.y > bbox_b.max.y + 1e-4 or
        bbox_a.max.z < bbox_b.min.z - 1e-4 or bbox_a.min.z > bbox_b.max.z + 1e-4);

    if (disjoint) {
        var copy = solid_a.clone(allocator) catch return error.OutOfMemory;
        updateFeatureTags(&copy, feature_id, 5);
        copy.volume = solid_a.volume;
        copy.surface_area = solid_a.surface_area;
        return copy;
    }

    // Intersecting solids: perform exact CSG Boolean Difference
    return executeCSG(allocator, feature_id, .Difference, solid_a, solid_b);
}

/// CSG Boolean Intersection: solid_a ∩ solid_b
pub fn booleanIntersection(
    allocator: Allocator,
    feature_id: u16,
    solid_a: *const SoASolid,
    solid_b: *const SoASolid,
) BooleanError!SoASolid {
    if (solid_a.vertices.len == 0 or solid_b.vertices.len == 0) {
        return error.DisjointIntersection;
    }

    const bbox_a = solid_a.calcBoundingBox();
    const bbox_b = solid_b.calcBoundingBox();
    const disjoint = (bbox_a.max.x < bbox_b.min.x - 1e-4 or bbox_a.min.x > bbox_b.max.x + 1e-4 or
        bbox_a.max.y < bbox_b.min.y - 1e-4 or bbox_a.min.y > bbox_b.max.y + 1e-4 or
        bbox_a.max.z < bbox_b.min.z - 1e-4 or bbox_a.min.z > bbox_b.max.z + 1e-4);

    if (disjoint) {
        return error.DisjointIntersection;
    }

    // Check if B is strictly nested inside A
    const eps: f32 = 1e-4;
    const b_inside_a = (bbox_b.min.x >= bbox_a.min.x - eps and bbox_b.max.x <= bbox_a.max.x + eps and
        bbox_b.min.y >= bbox_a.min.y - eps and bbox_b.max.y <= bbox_a.max.y + eps and
        bbox_b.min.z >= bbox_a.min.z - eps and bbox_b.max.z <= bbox_a.max.z + eps);

    if (b_inside_a) {
        var copy = solid_b.clone(allocator) catch return error.OutOfMemory;
        updateFeatureTags(&copy, feature_id, 6);
        return copy;
    }

    const a_inside_b = (bbox_a.min.x >= bbox_b.min.x - eps and bbox_a.max.x <= bbox_b.max.x + eps and
        bbox_a.min.y >= bbox_b.min.y - eps and bbox_a.max.y <= bbox_b.max.y + eps and
        bbox_a.min.z >= bbox_b.min.z - eps and bbox_a.max.z <= bbox_b.max.z + eps);

    if (a_inside_b) {
        var copy = solid_a.clone(allocator) catch return error.OutOfMemory;
        updateFeatureTags(&copy, feature_id, 6);
        return copy;
    }

    // General intersecting solids: perform exact CSG Boolean Intersection
    return executeCSG(allocator, feature_id, .Intersection, solid_a, solid_b);
}

/// Executes general Constructive Solid Geometry Boolean operation
/// between intersecting solids.
fn executeCSG(
    allocator: Allocator,
    feature_id: u16,
    op: BooleanType,
    solid_a: *const SoASolid,
    solid_b: *const SoASolid,
) BooleanError!SoASolid {
    // 1. Extract Triangles
    var tris_a = std.ArrayList(Tri).empty;
    defer tris_a.deinit(allocator);
    try solidToTriangles(allocator, solid_a, &tris_a);

    var tris_b = std.ArrayList(Tri).empty;
    defer tris_b.deinit(allocator);
    try solidToTriangles(allocator, solid_b, &tris_b);

    // 2. Extract Supporting Planes
    var planes_a = std.ArrayList(Plane).empty;
    defer planes_a.deinit(allocator);
    try extractPlanes(allocator, solid_a, &planes_a);

    var planes_b = std.ArrayList(Plane).empty;
    defer planes_b.deinit(allocator);
    try extractPlanes(allocator, solid_b, &planes_b);

    // 3. Face Splitting: Split Triangles of A against Planes of B
    var split_a = std.ArrayList(Tri).empty;
    defer split_a.deinit(allocator);
    try clipTrianglesAgainstPlanes(allocator, tris_a.items, planes_b.items, 1e-4, &split_a);

    // Split Triangles of B against Planes of A
    var split_b = std.ArrayList(Tri).empty;
    defer split_b.deinit(allocator);
    try clipTrianglesAgainstPlanes(allocator, tris_b.items, planes_a.items, 1e-4, &split_b);

    // 4. Point/Facet Classification and Assembly
    var assembled = std.ArrayList(Tri).empty;
    defer assembled.deinit(allocator);

    const bbox_a = solid_a.calcBoundingBox();
    const bbox_b = solid_b.calcBoundingBox();

    // Process Triangles of Solid A
    for (split_a.items) |tri| {
        const centroid = tri.p[0].add(tri.p[1]).add(tri.p[2]).scale(1.0 / 3.0);
        const inside = isPointInsideSolid(centroid, solid_b, tris_b.items, bbox_b);

        switch (op) {
            .Union => {
                if (!inside) {
                    try assembled.append(allocator, tri);
                }
            },
            .Difference => {
                if (!inside) {
                    try assembled.append(allocator, tri);
                }
            },
            .Intersection => {
                if (inside) {
                    try assembled.append(allocator, tri);
                }
            },
        }
    }

    // Process Triangles of Solid B
    for (split_b.items) |tri| {
        const centroid = tri.p[0].add(tri.p[1]).add(tri.p[2]).scale(1.0 / 3.0);
        const inside = isPointInsideSolid(centroid, solid_a, tris_a.items, bbox_a);

        switch (op) {
            .Union => {
                if (!inside) {
                    try assembled.append(allocator, tri);
                }
            },
            .Difference => {
                if (inside) {
                    // Reversed normal and vertex winding for interior cut walls
                    try assembled.append(allocator, Tri{
                        .p = .{ tri.p[0], tri.p[2], tri.p[1] },
                        .normal = tri.normal.scale(-1.0),
                        .topo_id = tri.topo_id,
                    });
                }
            },
            .Intersection => {
                if (inside) {
                    try assembled.append(allocator, tri);
                }
            },
        }
    }

    if (assembled.items.len == 0) {
        if (op == .Intersection) return error.DisjointIntersection;
        return error.OperationFailed;
    }

    // 5. Conforming Refinement: eliminate T-junctions
    var conforming_tris = std.ArrayList(Tri).empty;
    defer conforming_tris.deinit(allocator);
    try makeConforming(allocator, assembled.items, &conforming_tris);

    // 6. Watertight Solid Reconstruction
    const op_code: u8 = switch (op) {
        .Union => 4,
        .Difference => 5,
        .Intersection => 6,
    };
    return reconstructSolid(allocator, feature_id, op_code, conforming_tris.items);
}

fn solidToTriangles(allocator: Allocator, solid: *const SoASolid, out: *std.ArrayList(Tri)) !void {
    const v_slice = solid.vertices.slice();
    const pts = v_slice.items(.point);

    const f_slice = solid.faces.slice();
    const outer_loops = f_slice.items(.outer_loop);
    const normals = f_slice.items(.normal);
    const topos = f_slice.items(.topo_id);

    const l_slice = solid.loops.slice();
    const loop_hes = l_slice.items(.half_edge);

    const he_slice = solid.half_edges.slice();
    const origins = he_slice.items(.origin);
    const nexts = he_slice.items(.next);

    for (0..solid.faces.len) |f_idx| {
        const loop_id = outer_loops[f_idx];
        if (loop_id >= solid.loops.len) continue;
        const start_he = loop_hes[loop_id];
        if (start_he >= solid.half_edges.len) continue;

        var v_list = std.ArrayList(VertexId).empty;
        defer v_list.deinit(allocator);

        var curr = start_he;
        while (true) {
            try v_list.append(allocator, origins[curr]);
            curr = nexts[curr];
            if (curr == start_he or curr >= solid.half_edges.len) break;
        }

        if (v_list.items.len < 3) continue;

        const normal = normals[f_idx];
        const topo_id = topos[f_idx];

        for (1..v_list.items.len - 1) |i| {
            const p0 = pts[v_list.items[0]];
            const p1 = pts[v_list.items[i]];
            const p2 = pts[v_list.items[i + 1]];

            const cp = (p1.sub(p0)).cross(p2.sub(p0));
            if (cp.norm() < 1e-6) continue;

            try out.append(allocator, Tri{
                .p = .{ p0, p1, p2 },
                .normal = normal,
                .topo_id = topo_id,
            });
        }
    }
}

fn extractPlanes(allocator: Allocator, solid: *const SoASolid, out: *std.ArrayList(Plane)) !void {
    const f_slice = solid.faces.slice();
    const outer_loops = f_slice.items(.outer_loop);
    const normals = f_slice.items(.normal);

    const l_slice = solid.loops.slice();
    const loop_hes = l_slice.items(.half_edge);

    const he_slice = solid.half_edges.slice();
    const origins = he_slice.items(.origin);

    const pts = solid.vertices.slice().items(.point);

    for (0..solid.faces.len) |f_idx| {
        const nrm = normals[f_idx];
        if (nrm.norm() < 1e-6) continue;
        const norm = nrm.normalize();

        const loop_id = outer_loops[f_idx];
        if (loop_id >= solid.loops.len) continue;
        const start_he = loop_hes[loop_id];
        if (start_he >= solid.half_edges.len) continue;

        const p0 = pts[origins[start_he]];

        // Deduplicate planes
        var exists = false;
        for (out.items) |pl| {
            if ((pl.normal.sub(norm)).norm() < 1e-4 and @abs((p0.sub(pl.point)).dot(norm)) < 1e-4) {
                exists = true;
                break;
            }
        }
        if (!exists) {
            try out.append(allocator, Plane{ .point = p0, .normal = norm });
        }
    }
}

fn clipTrianglesAgainstPlanes(
    allocator: Allocator,
    input_tris: []const Tri,
    planes: []const Plane,
    eps: f32,
    out: *std.ArrayList(Tri),
) !void {
    var curr_list = std.ArrayList(Tri).empty;
    defer curr_list.deinit(allocator);

    for (input_tris) |t| {
        try curr_list.append(allocator, t);
    }

    for (planes) |pl| {
        var next_list = std.ArrayList(Tri).empty;
        defer next_list.deinit(allocator);

        for (curr_list.items) |tri| {
            try splitTriangleByPlane(allocator, tri, pl, eps, &next_list);
        }

        curr_list.clearRetainingCapacity();
        for (next_list.items) |t| {
            try curr_list.append(allocator, t);
        }
    }

    for (curr_list.items) |t| {
        try out.append(allocator, t);
    }
}

fn splitTriangleByPlane(
    allocator: Allocator,
    tri: Tri,
    plane: Plane,
    eps: f32,
    out: *std.ArrayList(Tri),
) !void {
    const d0 = (tri.p[0].sub(plane.point)).dot(plane.normal);
    const d1 = (tri.p[1].sub(plane.point)).dot(plane.normal);
    const d2 = (tri.p[2].sub(plane.point)).dot(plane.normal);

    const has_pos = (d0 > eps or d1 > eps or d2 > eps);
    const has_neg = (d0 < -eps or d1 < -eps or d2 < -eps);

    if (!has_pos or !has_neg) {
        // Entirely on one side or coplanar: keep unchanged
        try out.append(allocator, tri);
        return;
    }

    // Sutherland-Hodgman polygon clipping
    const pts = tri.p;
    const dists = [3]f32{ d0, d1, d2 };

    var front_pts: [8]Vec3 = undefined;
    var front_count: usize = 0;
    var back_pts: [8]Vec3 = undefined;
    var back_count: usize = 0;

    for (0..3) |i| {
        const next_i = (i + 1) % 3;
        const curr_p = pts[i];
        const next_p = pts[next_i];
        const curr_d = dists[i];
        const next_d = dists[next_i];

        if (curr_d >= -eps) {
            front_pts[front_count] = curr_p;
            front_count += 1;
            if (next_d < -eps) {
                const t = curr_d / (curr_d - next_d);
                front_pts[front_count] = curr_p.add((next_p.sub(curr_p)).scale(t));
                front_count += 1;
            }
        } else {
            if (next_d > eps) {
                const t = curr_d / (curr_d - next_d);
                front_pts[front_count] = curr_p.add((next_p.sub(curr_p)).scale(t));
                front_count += 1;
            }
        }

        if (curr_d <= eps) {
            back_pts[back_count] = curr_p;
            back_count += 1;
            if (next_d > eps) {
                const t = curr_d / (curr_d - next_d);
                back_pts[back_count] = curr_p.add((next_p.sub(curr_p)).scale(t));
                back_count += 1;
            }
        } else {
            if (next_d < -eps) {
                const t = curr_d / (curr_d - next_d);
                back_pts[back_count] = curr_p.add((next_p.sub(curr_p)).scale(t));
                back_count += 1;
            }
        }
    }

    if (front_count >= 3) {
        for (1..front_count - 1) |k| {
            const p0 = front_pts[0];
            const p1 = front_pts[k];
            const p2 = front_pts[k + 1];
            if ((p1.sub(p0)).cross(p2.sub(p0)).norm() > 1e-6) {
                try out.append(allocator, Tri{
                    .p = .{ p0, p1, p2 },
                    .normal = tri.normal,
                    .topo_id = tri.topo_id,
                });
            }
        }
    }

    if (back_count >= 3) {
        for (1..back_count - 1) |k| {
            const p0 = back_pts[0];
            const p1 = back_pts[k];
            const p2 = back_pts[k + 1];
            if ((p1.sub(p0)).cross(p2.sub(p0)).norm() > 1e-6) {
                try out.append(allocator, Tri{
                    .p = .{ p0, p1, p2 },
                    .normal = tri.normal,
                    .topo_id = tri.topo_id,
                });
            }
        }
    }
}

fn isPointInsideSolid(
    p: Vec3,
    solid: *const SoASolid,
    triangles: []const Tri,
    bbox: topo.BoundingBox,
) bool {
    _ = solid;
    const eps: f32 = 1e-3;
    if (p.x < bbox.min.x - eps or p.x > bbox.max.x + eps or
        p.y < bbox.min.y - eps or p.y > bbox.max.y + eps or
        p.z < bbox.min.z - eps or p.z > bbox.max.z + eps)
    {
        return false;
    }

    // Möller-Trumbore ray casting with non-axis-aligned ray direction
    const ray_dir = Vec3.init(0.3129, 0.5741, 0.7562).normalize();
    var hit_count: usize = 0;

    for (triangles) |tri| {
        const v0 = tri.p[0];
        const v1 = tri.p[1];
        const v2 = tri.p[2];

        const edge1 = v1.sub(v0);
        const edge2 = v2.sub(v0);
        const h = ray_dir.cross(edge2);
        const a = edge1.dot(h);

        if (@abs(a) < 1e-7) continue;
        const f = 1.0 / a;
        const s = p.sub(v0);
        const u = f * s.dot(h);
        if (u < -1e-4 or u > 1.0 + 1e-4) continue;

        const q = s.cross(edge1);
        const v = f * ray_dir.dot(q);
        if (v < -1e-4 or u + v > 1.0 + 1e-4) continue;

        const t = f * edge2.dot(q);
        if (t > 1e-4) {
            hit_count += 1;
        }
    }

    return (hit_count % 2 == 1);
}

fn pointOnSegment(p: Vec3, a: Vec3, b: Vec3, eps: f32) bool {
    const d_ab = (b.sub(a)).norm();
    const d_ap = (p.sub(a)).norm();
    const d_pb = (b.sub(p)).norm();
    if (d_ap < eps or d_pb < eps) return false;
    return @abs(d_ap + d_pb - d_ab) < eps;
}

fn makeConforming(allocator: Allocator, tris: []const Tri, out: *std.ArrayList(Tri)) !void {
    // Collect all unique vertex coordinates
    var verts = std.ArrayList(Vec3).empty;
    defer verts.deinit(allocator);

    for (tris) |tri| {
        for (tri.p) |p| {
            var exists = false;
            for (verts.items) |v| {
                if ((p.sub(v)).norm() < 1e-4) {
                    exists = true;
                    break;
                }
            }
            if (!exists) {
                try verts.append(allocator, p);
            }
        }
    }

    var curr = std.ArrayList(Tri).empty;
    defer curr.deinit(allocator);
    for (tris) |t| try curr.append(allocator, t);

    const max_passes = 10;
    var pass: usize = 0;

    while (pass < max_passes) : (pass += 1) {
        var split_any = false;
        var next = std.ArrayList(Tri).empty;
        defer next.deinit(allocator);

        for (curr.items) |t| {
            var did_split = false;
            for (verts.items) |v| {
                if (pointOnSegment(v, t.p[0], t.p[1], 1e-4)) {
                    try next.append(allocator, Tri{ .p = .{ t.p[0], v, t.p[2] }, .normal = t.normal, .topo_id = t.topo_id });
                    try next.append(allocator, Tri{ .p = .{ v, t.p[1], t.p[2] }, .normal = t.normal, .topo_id = t.topo_id });
                    did_split = true;
                    split_any = true;
                    break;
                } else if (pointOnSegment(v, t.p[1], t.p[2], 1e-4)) {
                    try next.append(allocator, Tri{ .p = .{ t.p[0], t.p[1], v }, .normal = t.normal, .topo_id = t.topo_id });
                    try next.append(allocator, Tri{ .p = .{ t.p[0], v, t.p[2] }, .normal = t.normal, .topo_id = t.topo_id });
                    did_split = true;
                    split_any = true;
                    break;
                } else if (pointOnSegment(v, t.p[2], t.p[0], 1e-4)) {
                    try next.append(allocator, Tri{ .p = .{ t.p[0], t.p[1], v }, .normal = t.normal, .topo_id = t.topo_id });
                    try next.append(allocator, Tri{ .p = .{ v, t.p[1], t.p[2] }, .normal = t.normal, .topo_id = t.topo_id });
                    did_split = true;
                    split_any = true;
                    break;
                }
            }
            if (!did_split) {
                try next.append(allocator, t);
            }
        }

        curr.clearRetainingCapacity();
        for (next.items) |t| try curr.append(allocator, t);
        if (!split_any) break;
    }

    for (curr.items) |t| {
        try out.append(allocator, t);
    }
}

fn reconstructSolid(
    allocator: Allocator,
    feature_id: u16,
    op_code: u8,
    triangles: []const Tri,
) BooleanError!SoASolid {
    var result = SoASolid.init();
    errdefer result.deinit(allocator);

    const solid_topo = CadTopoId.init(feature_id, 0, op_code, .Shell, 0, 0);
    const solid_id = result.addSolid(allocator, solid_topo) catch return error.OutOfMemory;

    const shell_topo = CadTopoId.init(feature_id, 0, op_code, .Shell, 0, 0);
    const shell_id = result.addShell(allocator, solid_id, true, shell_topo) catch return error.OutOfMemory;

    var v_map = std.AutoHashMap(QuantizedVec3, VertexId).init(allocator);
    defer v_map.deinit();

    var edge_map = std.AutoHashMap(EdgeKey, HalfEdgeId).init(allocator);
    defer edge_map.deinit();

    for (triangles, 0..) |tri, tri_idx| {
        const cp = (tri.p[1].sub(tri.p[0])).cross(tri.p[2].sub(tri.p[0]));
        if (cp.norm() < 1e-6) continue;

        const v0 = findOrAddVertex(&result, allocator, tri.p[0], tri.topo_id, &v_map) catch return error.OutOfMemory;
        const v1 = findOrAddVertex(&result, allocator, tri.p[1], tri.topo_id, &v_map) catch return error.OutOfMemory;
        const v2 = findOrAddVertex(&result, allocator, tri.p[2], tri.topo_id, &v_map) catch return error.OutOfMemory;

        if (v0 == v1 or v1 == v2 or v2 == v0) continue;

        const normal = cp.normalize();
        const face_topo = CadTopoId.init(feature_id, @intCast(tri_idx), op_code, .Face, 0, 0);
        const face_id = result.addFace(allocator, shell_id, normal, .Plane, face_topo) catch return error.OutOfMemory;
        const loop_id = result.addLoop(allocator, face_id, true, face_topo) catch return error.OutOfMemory;
        result.faces.slice().items(.outer_loop)[face_id] = loop_id;

        const he0 = result.addHalfEdge(allocator, v0, loop_id, face_topo) catch return error.OutOfMemory;
        const he1 = result.addHalfEdge(allocator, v1, loop_id, face_topo) catch return error.OutOfMemory;
        const he2 = result.addHalfEdge(allocator, v2, loop_id, face_topo) catch return error.OutOfMemory;

        result.setNextPrev(he0, he1);
        result.setNextPrev(he1, he2);
        result.setNextPrev(he2, he0);
        result.loops.slice().items(.half_edge)[loop_id] = he0;

        const hes = [3]HalfEdgeId{ he0, he1, he2 };
        const v_pairs = [3][2]VertexId{
            .{ v0, v1 },
            .{ v1, v2 },
            .{ v2, v0 },
        };

        for (0..3) |k| {
            const u = v_pairs[k][0];
            const v = v_pairs[k][1];
            const key = EdgeKey{ .min_v = @min(u, v), .max_v = @max(u, v) };

            if (edge_map.get(key)) |mate_he| {
                const edge_topo = CadTopoId.init(feature_id, @intCast(result.edges.len), op_code, .Edge, 0, 0);
                const edge_id = result.addEdge(allocator, hes[k], edge_topo) catch return error.OutOfMemory;
                result.setTwins(hes[k], mate_he, edge_id);
                _ = edge_map.remove(key);
            } else {
                edge_map.put(key, hes[k]) catch return error.OutOfMemory;
            }
        }
    }

    result.updateMetrics();
    return result;
}

fn findOrAddVertex(
    solid: *SoASolid,
    allocator: Allocator,
    p: Vec3,
    topo_id: CadTopoId,
    v_map: *std.AutoHashMap(QuantizedVec3, VertexId),
) !VertexId {
    const key = quantizePoint(p, 1000.0);
    if (v_map.get(key)) |vid| {
        return vid;
    }

    // Check neighboring grid cells within 1e-3 mm tolerance
    var dx: i32 = -1;
    while (dx <= 1) : (dx += 1) {
        var dy: i32 = -1;
        while (dy <= 1) : (dy += 1) {
            var dz: i32 = -1;
            while (dz <= 1) : (dz += 1) {
                const n_key = QuantizedVec3{ .x = key.x + dx, .y = key.y + dy, .z = key.z + dz };
                if (v_map.get(n_key)) |cand_vid| {
                    const cand_pt = solid.vertices.slice().items(.point)[cand_vid];
                    if ((p.sub(cand_pt)).norm() < 1e-3) {
                        return cand_vid;
                    }
                }
            }
        }
    }

    const vid = try solid.addVertex(allocator, p, topo_id);
    try v_map.put(key, vid);
    return vid;
}

fn mergeSolidInto(
    dest: *SoASolid,
    allocator: Allocator,
    src: *const SoASolid,
    target_solid_id: u32,
    feature_id: u16,
) BooleanError!void {
    const v_offset: u32 = @intCast(dest.vertices.len);
    const he_offset: u32 = @intCast(dest.half_edges.len);
    const e_offset: u32 = @intCast(dest.edges.len);
    const l_offset: u32 = @intCast(dest.loops.len);
    const f_offset: u32 = @intCast(dest.faces.len);

    const shell_topo = CadTopoId.init(feature_id, 0, 4, .Shell, 0, 0);
    const target_shell_id = dest.addShell(allocator, target_solid_id, true, shell_topo) catch return error.OutOfMemory;

    // 1. Copy vertices
    const v_slice = src.vertices.slice();
    for (0..src.vertices.len) |i| {
        const pt = v_slice.items(.point)[i];
        const old_he = v_slice.items(.half_edge)[i];
        const new_he = if (old_he != INVALID_ID) old_he + he_offset else INVALID_ID;
        const old_tid = v_slice.items(.topo_id)[i];

        dest.vertices.append(allocator, .{
            .point = pt,
            .half_edge = new_he,
            .topo_id = old_tid,
        }) catch return error.OutOfMemory;
    }

    // 2. Copy half-edges
    const he_slice = src.half_edges.slice();
    for (0..src.half_edges.len) |i| {
        const orig = he_slice.items(.origin)[i] + v_offset;
        const edge = if (he_slice.items(.edge)[i] != INVALID_ID) he_slice.items(.edge)[i] + e_offset else INVALID_ID;
        const twin = if (he_slice.items(.twin)[i] != INVALID_ID) he_slice.items(.twin)[i] + he_offset else INVALID_ID;
        const nxt = if (he_slice.items(.next)[i] != INVALID_ID) he_slice.items(.next)[i] + he_offset else INVALID_ID;
        const prv = if (he_slice.items(.prev)[i] != INVALID_ID) he_slice.items(.prev)[i] + he_offset else INVALID_ID;
        const loop = if (he_slice.items(.loop)[i] != INVALID_ID) he_slice.items(.loop)[i] + l_offset else INVALID_ID;
        const tid = he_slice.items(.topo_id)[i];

        dest.half_edges.append(allocator, .{
            .origin = orig,
            .edge = edge,
            .twin = twin,
            .next = nxt,
            .prev = prv,
            .loop = loop,
            .topo_id = tid,
        }) catch return error.OutOfMemory;
    }

    // 3. Copy edges
    const e_slice = src.edges.slice();
    for (0..src.edges.len) |i| {
        const he = if (e_slice.items(.half_edge)[i] != INVALID_ID) e_slice.items(.half_edge)[i] + he_offset else INVALID_ID;
        dest.edges.append(allocator, .{
            .half_edge = he,
            .topo_id = e_slice.items(.topo_id)[i],
        }) catch return error.OutOfMemory;
    }

    // 4. Copy loops
    const l_slice = src.loops.slice();
    for (0..src.loops.len) |i| {
        const he = if (l_slice.items(.half_edge)[i] != INVALID_ID) l_slice.items(.half_edge)[i] + he_offset else INVALID_ID;
        const f = if (l_slice.items(.face)[i] != INVALID_ID) l_slice.items(.face)[i] + f_offset else INVALID_ID;
        dest.loops.append(allocator, .{
            .half_edge = he,
            .face = f,
            .is_outer = l_slice.items(.is_outer)[i],
            .topo_id = l_slice.items(.topo_id)[i],
        }) catch return error.OutOfMemory;
    }

    // 5. Copy faces
    const f_slice = src.faces.slice();
    for (0..src.faces.len) |i| {
        const outer_l = if (f_slice.items(.outer_loop)[i] != INVALID_ID) f_slice.items(.outer_loop)[i] + l_offset else INVALID_ID;
        dest.faces.append(allocator, .{
            .outer_loop = outer_l,
            .shell = target_shell_id,
            .normal = f_slice.items(.normal)[i],
            .surface = f_slice.items(.surface)[i],
            .topo_id = f_slice.items(.topo_id)[i],
        }) catch return error.OutOfMemory;
    }
}

fn updateFeatureTags(solid: *SoASolid, feature_id: u16, op_type: u8) void {
    const f_slice = solid.faces.slice();
    for (f_slice.items(.topo_id)) |*tid| {
        tid.fields.origin_feature_id = feature_id;
        tid.fields.op_type = op_type;
    }
}

test "Boolean Union of disjoint prisms" {
    const allocator = std.testing.allocator;
    const extrude = @import("extrude.zig");

    const sq1 = [_][2]f32{ .{ 0, 0 }, .{ 2, 0 }, .{ 2, 2 }, .{ 0, 2 } };
    var box1 = try extrude.extrudePolygon(allocator, 1, &sq1, 5.0, Vec3.init(0, 0, 1), false);
    defer box1.deinit(allocator);

    const sq2 = [_][2]f32{ .{ 10, 0 }, .{ 12, 0 }, .{ 12, 2 }, .{ 10, 2 } };
    var box2 = try extrude.extrudePolygon(allocator, 2, &sq2, 5.0, Vec3.init(0, 0, 1), false);
    defer box2.deinit(allocator);

    var union_solid = try booleanOp(allocator, 3, .Union, &box1, &box2);
    defer union_solid.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 16), union_solid.vertices.len);
    try std.testing.expectEqual(@as(usize, 24), union_solid.edges.len);
    try std.testing.expectEqual(@as(usize, 12), union_solid.faces.len);
    try std.testing.expectApproxEqAbs(box1.volume + box2.volume, union_solid.volume, 1e-2);
}

test "Boolean CSG: Overlapping Boxes Union, Cut and Intersect" {
    const allocator = std.testing.allocator;
    const extrude = @import("extrude.zig");

    // Box A: [0, 10] x [0, 10] x [0, 10], Vol = 1000
    const sq_a = [_][2]f32{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 }, .{ 0, 10 } };
    var box_a = try extrude.extrudePolygon(allocator, 1, &sq_a, 10.0, Vec3.init(0, 0, 1), false);
    defer box_a.deinit(allocator);

    // Box B: [5, 15] x [5, 15] x [5, 15], Vol = 1000
    const sq_b = [_][2]f32{ .{ 5, 5 }, .{ 15, 5 }, .{ 15, 15 }, .{ 5, 15 } };
    var box_b = try extrude.extrudePolygon(allocator, 2, &sq_b, 10.0, Vec3.init(0, 0, 1), false);
    // Shift box_b in Z by +5 so Z is [5, 15]
    for (box_b.vertices.slice().items(.point)) |*pt| {
        pt.z += 5.0;
    }
    defer box_b.deinit(allocator);

    // 1. Union: [0, 10]^3 U [5, 15]^3 => Vol = 1875
    var u_solid = try booleanOp(allocator, 10, .Union, &box_a, &box_b);
    defer u_solid.deinit(allocator);
    try u_solid.validateManifold();
    try std.testing.expectApproxEqAbs(@as(f32, 1875.0), u_solid.volume, 1e-1);

    // 2. Cut (A - B): [0, 10]^3 \ [5, 15]^3 => Vol = 875
    var diff_solid = try booleanOp(allocator, 11, .Difference, &box_a, &box_b);
    defer diff_solid.deinit(allocator);
    try diff_solid.validateManifold();
    try std.testing.expectApproxEqAbs(@as(f32, 875.0), diff_solid.volume, 1e-1);

    // 3. Intersect (A n B): [5, 10]^3 => Vol = 125
    var inter_solid = try booleanOp(allocator, 12, .Intersection, &box_a, &box_b);
    defer inter_solid.deinit(allocator);
    try inter_solid.validateManifold();
    try std.testing.expectApproxEqAbs(@as(f32, 125.0), inter_solid.volume, 1e-1);
}
