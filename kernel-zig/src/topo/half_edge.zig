const std = @import("std");
const Allocator = std.mem.Allocator;
const Vec3 = @import("../math/vec3.zig").Vec3;
const c_abi = @import("../c_abi.zig");

pub const CadSubshapeType = c_abi.CadSubshapeType;
pub const CadTopoId = c_abi.CadTopoId;


pub const VertexId = u32;
pub const HalfEdgeId = u32;
pub const EdgeId = u32;
pub const LoopId = u32;
pub const FaceId = u32;
pub const ShellId = u32;
pub const SolidId = u32;

pub const INVALID_ID: u32 = std.math.maxInt(u32);

pub const SurfaceType = enum(u8) {
    Plane = 0,
    Cylinder = 1,
    Cone = 2,
    Sphere = 3,
    Torus = 4,
    BSpline = 5,
};

pub const Vertex = struct {
    point: Vec3,
    half_edge: HalfEdgeId,
    topo_id: CadTopoId,
};

pub const HalfEdge = struct {
    origin: VertexId,
    edge: EdgeId,
    twin: HalfEdgeId,
    next: HalfEdgeId,
    prev: HalfEdgeId,
    loop: LoopId,
    topo_id: CadTopoId,
};

pub const Edge = struct {
    half_edge: HalfEdgeId,
    topo_id: CadTopoId,
};

pub const Loop = struct {
    half_edge: HalfEdgeId,
    face: FaceId,
    is_outer: bool,
    topo_id: CadTopoId,
};

pub const Face = struct {
    outer_loop: LoopId,
    shell: ShellId,
    normal: Vec3,
    surface: SurfaceType,
    topo_id: CadTopoId,
};

pub const Shell = struct {
    solid: SolidId,
    is_closed: bool,
    topo_id: CadTopoId,
};

pub const SolidRecord = struct {
    shell: ShellId,
    topo_id: CadTopoId,
};

pub const BoundingBox = struct {
    min: Vec3,
    max: Vec3,

    pub fn isValid(self: BoundingBox) bool {
        return self.min.x <= self.max.x and self.min.y <= self.max.y and self.min.z <= self.max.z;
    }

    pub fn size(self: BoundingBox) Vec3 {
        return self.max.sub(self.min);
    }
};

pub const LoopIterator = struct {
    solid: *const SoASolid,
    start_he: HalfEdgeId,
    curr_he: HalfEdgeId,
    started: bool,

    pub fn init(solid: *const SoASolid, start_he: HalfEdgeId) LoopIterator {
        return .{
            .solid = solid,
            .start_he = start_he,
            .curr_he = start_he,
            .started = false,
        };
    }

    pub fn next(self: *LoopIterator) ?HalfEdgeId {
        if (self.start_he == INVALID_ID or self.start_he >= self.solid.half_edges.len) {
            return null;
        }
        if (self.started and self.curr_he == self.start_he) {
            return null;
        }
        self.started = true;
        const res = self.curr_he;
        if (res >= self.solid.half_edges.len) return null;
        self.curr_he = self.solid.half_edges.slice().items(.next)[res];
        return res;
    }
};

pub const ManifoldError = error{
    EmptySolid,
    InvalidCoordinates,
    InvalidOriginVertex,
    InvalidEdgeRef,
    InvalidLoopRef,
    InvalidTwinRef,
    TwinMismatch,
    NextPrevMismatch,
    LoopNotClosed,
    DegenerateLoop,
    LoopCycleOverflow,
    LoopMismatch,
    InvalidNormal,
    EulerPoincareViolated,
};

pub const SoASolid = struct {
    vertices: std.MultiArrayList(Vertex),
    half_edges: std.MultiArrayList(HalfEdge),
    edges: std.MultiArrayList(Edge),
    loops: std.MultiArrayList(Loop),
    faces: std.MultiArrayList(Face),
    shells: std.MultiArrayList(Shell),
    solids: std.MultiArrayList(SolidRecord),
    volume: f32,
    surface_area: f32,

    pub fn init() SoASolid {
        return .{
            .vertices = .{},
            .half_edges = .{},
            .edges = .{},
            .loops = .{},
            .faces = .{},
            .shells = .{},
            .solids = .{},
            .volume = 0.0,
            .surface_area = 0.0,
        };
    }

    pub fn deinit(self: *SoASolid, allocator: Allocator) void {
        self.vertices.deinit(allocator);
        self.half_edges.deinit(allocator);
        self.edges.deinit(allocator);
        self.loops.deinit(allocator);
        self.faces.deinit(allocator);
        self.shells.deinit(allocator);
        self.solids.deinit(allocator);
    }

    pub fn clone(self: *const SoASolid, allocator: Allocator) !SoASolid {
        var copy = SoASolid.init();
        errdefer copy.deinit(allocator);

        try copy.vertices.ensureTotalCapacity(allocator, self.vertices.len);
        var i: usize = 0;
        while (i < self.vertices.len) : (i += 1) {
            copy.vertices.appendAssumeCapacity(self.vertices.get(i));
        }

        try copy.half_edges.ensureTotalCapacity(allocator, self.half_edges.len);
        i = 0;
        while (i < self.half_edges.len) : (i += 1) {
            copy.half_edges.appendAssumeCapacity(self.half_edges.get(i));
        }

        try copy.edges.ensureTotalCapacity(allocator, self.edges.len);
        i = 0;
        while (i < self.edges.len) : (i += 1) {
            copy.edges.appendAssumeCapacity(self.edges.get(i));
        }

        try copy.loops.ensureTotalCapacity(allocator, self.loops.len);
        i = 0;
        while (i < self.loops.len) : (i += 1) {
            copy.loops.appendAssumeCapacity(self.loops.get(i));
        }

        try copy.faces.ensureTotalCapacity(allocator, self.faces.len);
        i = 0;
        while (i < self.faces.len) : (i += 1) {
            copy.faces.appendAssumeCapacity(self.faces.get(i));
        }

        try copy.shells.ensureTotalCapacity(allocator, self.shells.len);
        i = 0;
        while (i < self.shells.len) : (i += 1) {
            copy.shells.appendAssumeCapacity(self.shells.get(i));
        }

        try copy.solids.ensureTotalCapacity(allocator, self.solids.len);
        i = 0;
        while (i < self.solids.len) : (i += 1) {
            copy.solids.appendAssumeCapacity(self.solids.get(i));
        }

        copy.volume = self.volume;
        copy.surface_area = self.surface_area;
        return copy;
    }

    pub fn addVertex(self: *SoASolid, allocator: Allocator, point: Vec3, topo_id: CadTopoId) !VertexId {
        const id: VertexId = @intCast(self.vertices.len);
        try self.vertices.append(allocator, .{
            .point = point,
            .half_edge = INVALID_ID,
            .topo_id = topo_id,
        });
        return id;
    }

    pub fn addHalfEdge(
        self: *SoASolid,
        allocator: Allocator,
        origin: VertexId,
        loop_id: LoopId,
        topo_id: CadTopoId,
    ) !HalfEdgeId {
        const id: HalfEdgeId = @intCast(self.half_edges.len);
        try self.half_edges.append(allocator, .{
            .origin = origin,
            .edge = INVALID_ID,
            .twin = INVALID_ID,
            .next = INVALID_ID,
            .prev = INVALID_ID,
            .loop = loop_id,
            .topo_id = topo_id,
        });
        if (origin < self.vertices.len) {
            var v_slice = self.vertices.slice();
            if (v_slice.items(.half_edge)[origin] == INVALID_ID) {
                v_slice.items(.half_edge)[origin] = id;
            }
        }
        return id;
    }

    pub fn addEdge(self: *SoASolid, allocator: Allocator, he: HalfEdgeId, topo_id: CadTopoId) !EdgeId {
        const id: EdgeId = @intCast(self.edges.len);
        try self.edges.append(allocator, .{
            .half_edge = he,
            .topo_id = topo_id,
        });
        if (he < self.half_edges.len) {
            self.half_edges.slice().items(.edge)[he] = id;
        }
        return id;
    }

    pub fn addLoop(
        self: *SoASolid,
        allocator: Allocator,
        face: FaceId,
        is_outer: bool,
        topo_id: CadTopoId,
    ) !LoopId {
        const id: LoopId = @intCast(self.loops.len);
        try self.loops.append(allocator, .{
            .half_edge = INVALID_ID,
            .face = face,
            .is_outer = is_outer,
            .topo_id = topo_id,
        });
        return id;
    }

    pub fn addFace(
        self: *SoASolid,
        allocator: Allocator,
        shell: ShellId,
        normal: Vec3,
        surface: SurfaceType,
        topo_id: CadTopoId,
    ) !FaceId {
        const id: FaceId = @intCast(self.faces.len);
        try self.faces.append(allocator, .{
            .outer_loop = INVALID_ID,
            .shell = shell,
            .normal = normal,
            .surface = surface,
            .topo_id = topo_id,
        });
        return id;
    }

    pub fn addShell(
        self: *SoASolid,
        allocator: Allocator,
        solid: SolidId,
        is_closed: bool,
        topo_id: CadTopoId,
    ) !ShellId {
        const id: ShellId = @intCast(self.shells.len);
        try self.shells.append(allocator, .{
            .solid = solid,
            .is_closed = is_closed,
            .topo_id = topo_id,
        });
        return id;
    }

    pub fn addSolid(self: *SoASolid, allocator: Allocator, topo_id: CadTopoId) !SolidId {
        const id: SolidId = @intCast(self.solids.len);
        try self.solids.append(allocator, .{
            .shell = INVALID_ID,
            .topo_id = topo_id,
        });
        return id;
    }

    pub fn setTwins(self: *SoASolid, he1: HalfEdgeId, he2: HalfEdgeId, edge_id: EdgeId) void {
        var slice = self.half_edges.slice();
        slice.items(.twin)[he1] = he2;
        slice.items(.twin)[he2] = he1;
        slice.items(.edge)[he1] = edge_id;
        slice.items(.edge)[he2] = edge_id;
        if (edge_id < self.edges.len) {
            self.edges.slice().items(.half_edge)[edge_id] = he1;
        }
    }

    pub fn setNextPrev(self: *SoASolid, prev_he: HalfEdgeId, next_he: HalfEdgeId) void {
        var slice = self.half_edges.slice();
        slice.items(.next)[prev_he] = next_he;
        slice.items(.prev)[next_he] = prev_he;
    }

    pub fn iterateLoop(self: *const SoASolid, start_he: HalfEdgeId) LoopIterator {
        return LoopIterator.init(self, start_he);
    }

    pub fn calcBoundingBox(self: *const SoASolid) BoundingBox {
        if (self.vertices.len == 0) {
            return .{
                .min = Vec3.init(0, 0, 0),
                .max = Vec3.init(0, 0, 0),
            };
        }
        const pts = self.vertices.slice().items(.point);
        var min_pt = pts[0];
        var max_pt = pts[0];
        for (pts[1..]) |p| {
            min_pt.x = @min(min_pt.x, p.x);
            min_pt.y = @min(min_pt.y, p.y);
            min_pt.z = @min(min_pt.z, p.z);
            max_pt.x = @max(max_pt.x, p.x);
            max_pt.y = @max(max_pt.y, p.y);
            max_pt.z = @max(max_pt.z, p.z);
        }
        return .{ .min = min_pt, .max = max_pt };
    }

    /// Euler-Poincaré characteristic:
    /// V - E + F - (L - F) - 2 * (S - G)
    /// For a valid closed orientable manifold of genus G, this evaluates to 0.
    pub fn calcEulerPoincare(self: *const SoASolid, genus: u32) i32 {
        const v: i32 = @intCast(self.vertices.len);
        const e: i32 = @intCast(self.edges.len);
        const f: i32 = @intCast(self.faces.len);
        const l: i32 = @intCast(self.loops.len);
        const s: i32 = @intCast(self.shells.len);
        const g: i32 = @intCast(genus);

        return v - e + f - (l - f) - 2 * (s - g);
    }

    /// Asserts half-edge invariants:
    /// 1. twin.twin == self
    /// 2. next.prev == self and prev.next == self
    /// 3. face loop closure with >= 3 edges
    /// 4. non-NaN, non-Inf coordinates
    /// 5. Euler-Poincaré invariant
    pub fn validateManifold(self: *const SoASolid) ManifoldError!void {
        if (self.vertices.len == 0 or self.faces.len == 0 or self.half_edges.len == 0) {
            return error.EmptySolid;
        }

        // 1. Validate vertex coordinates
        const v_slice = self.vertices.slice();
        const pts = v_slice.items(.point);
        for (pts) |p| {
            if (std.math.isNan(p.x) or std.math.isNan(p.y) or std.math.isNan(p.z) or
                std.math.isInf(p.x) or std.math.isInf(p.y) or std.math.isInf(p.z))
            {
                return error.InvalidCoordinates;
            }
        }

        // 2. Validate half-edges
        const he_slice = self.half_edges.slice();
        const origins = he_slice.items(.origin);
        const edges = he_slice.items(.edge);
        const twins = he_slice.items(.twin);
        const nexts = he_slice.items(.next);
        const prevs = he_slice.items(.prev);
        const loop_ids = he_slice.items(.loop);

        var i: usize = 0;
        while (i < self.half_edges.len) : (i += 1) {
            const orig = origins[i];
            if (orig >= self.vertices.len) return error.InvalidOriginVertex;

            const edge_id = edges[i];
            if (edge_id >= self.edges.len) return error.InvalidEdgeRef;

            const loop_id = loop_ids[i];
            if (loop_id >= self.loops.len) return error.InvalidLoopRef;

            const tw = twins[i];
            if (tw == INVALID_ID or tw >= self.half_edges.len or tw == i) {
                return error.InvalidTwinRef;
            }
            if (twins[tw] != @as(u32, @intCast(i))) {
                return error.TwinMismatch;
            }

            const nxt = nexts[i];
            const prv = prevs[i];
            if (nxt == INVALID_ID or nxt >= self.half_edges.len or
                prv == INVALID_ID or prv >= self.half_edges.len)
            {
                return error.NextPrevMismatch;
            }

            if (prevs[nxt] != @as(u32, @intCast(i)) or nexts[prv] != @as(u32, @intCast(i))) {
                return error.NextPrevMismatch;
            }
        }

        // 3. Validate face loop closure
        const f_slice = self.faces.slice();
        const outer_loops = f_slice.items(.outer_loop);
        const normals = f_slice.items(.normal);

        const l_slice = self.loops.slice();
        const loop_hes = l_slice.items(.half_edge);

        for (outer_loops, 0..) |loop_idx, face_idx| {
            if (loop_idx >= self.loops.len) return error.InvalidLoopRef;
            const start_he = loop_hes[loop_idx];
            if (start_he >= self.half_edges.len) return error.InvalidLoopRef;

            const nrm = normals[face_idx];
            if (nrm.norm() < 1e-6) return error.InvalidNormal;

            var curr_he = start_he;
            var edge_count: usize = 0;
            const max_steps = self.half_edges.len;

            while (true) {
                edge_count += 1;
                if (edge_count > max_steps) return error.LoopCycleOverflow;

                if (loop_ids[curr_he] != loop_idx) {
                    return error.LoopMismatch;
                }

                curr_he = nexts[curr_he];
                if (curr_he == start_he) break;
            }

            if (edge_count < 3) {
                return error.DegenerateLoop;
            }
        }

        // 4. Validate Euler-Poincaré invariant for genus 0
        const euler = self.calcEulerPoincare(0);
        if (euler != 0) {
            return error.EulerPoincareViolated;
        }
    }

    /// Calculate total surface area and volume of the closed manifold.
    pub fn updateMetrics(self: *SoASolid) void {
        var total_area: f32 = 0.0;
        var total_volume: f32 = 0.0;

        const he_slice = self.half_edges.slice();
        const origins = he_slice.items(.origin);
        const nexts = he_slice.items(.next);

        const v_slice = self.vertices.slice();
        const pts = v_slice.items(.point);

        const l_slice = self.loops.slice();
        const loop_hes = l_slice.items(.half_edge);

        for (0..self.faces.len) |f_idx| {
            const outer_loop = self.faces.slice().items(.outer_loop)[f_idx];
            if (outer_loop >= self.loops.len) continue;
            const start_he = loop_hes[outer_loop];
            if (start_he >= self.half_edges.len) continue;

            const v0_idx = origins[start_he];
            const p0 = pts[v0_idx];

            var curr_he = nexts[start_he];
            while (curr_he != start_he and nexts[curr_he] != start_he) {
                const v1_idx = origins[curr_he];
                const v2_idx = origins[nexts[curr_he]];
                const p1 = pts[v1_idx];
                const p2 = pts[v2_idx];

                // Triangle area: 0.5 * |(p1 - p0) x (p2 - p0)|
                const cross_prod = (p1.sub(p0)).cross(p2.sub(p0));
                total_area += 0.5 * cross_prod.norm();

                // Signed volume contribution: 1/6 * p0 . (p1 x p2)
                const vol_contrib = p0.dot(p1.cross(p2)) / 6.0;
                total_volume += vol_contrib;

                curr_he = nexts[curr_he];
            }
        }

        self.surface_area = total_area;
        self.volume = @abs(total_volume);
    }

    /// Converts the SoASolid to the legacy topology.Solid representation
    /// for backward compatibility with existing tessellator and stats routines.
    pub fn toLegacySolid(self: *const SoASolid, allocator: Allocator, solid_id: u64) !@import("../brep/topology.zig").Solid {
        const topology = @import("../brep/topology.zig");
        var legacy = topology.Solid.init(solid_id);
        errdefer legacy.deinit(allocator);

        // 1. Copy vertices
        const v_pts = self.vertices.slice().items(.point);
        try legacy.vertices.ensureTotalCapacity(allocator, v_pts.len);
        for (v_pts) |pt| {
            legacy.vertices.appendAssumeCapacity(.{ .point = pt });
        }

        // 2. Copy edges
        const he_slice = self.half_edges.slice();
        const origins = he_slice.items(.origin);
        const twins = he_slice.items(.twin);
        const e_slice = self.edges.slice();
        const e_hes = e_slice.items(.half_edge);

        try legacy.edges.ensureTotalCapacity(allocator, self.edges.len);
        for (e_hes, 0..) |he_idx, i| {
            const v_start = origins[he_idx];
            const twin_he = twins[he_idx];
            const v_end = if (twin_he != INVALID_ID) origins[twin_he] else v_start;
            legacy.edges.appendAssumeCapacity(.{
                .v_start = v_start,
                .v_end = v_end,
                .id = @intCast(i + 1),
            });
        }

        // 3. Copy faces
        const f_slice = self.faces.slice();
        const outer_loops = f_slice.items(.outer_loop);
        const normals = f_slice.items(.normal);
        const surfaces = f_slice.items(.surface);

        const l_slice = self.loops.slice();
        const loop_hes = l_slice.items(.half_edge);
        const nexts = he_slice.items(.next);
        const edge_refs = he_slice.items(.edge);

        try legacy.shell.faces.ensureTotalCapacity(allocator, self.faces.len);
        for (outer_loops, 0..) |loop_idx, face_idx| {
            var wire = topology.Wire.init();
            errdefer wire.deinit(allocator);

            if (loop_idx < self.loops.len) {
                const start_he = loop_hes[loop_idx];
                if (start_he < self.half_edges.len) {
                    var curr_he = start_he;
                    var count: usize = 0;
                    while (count < self.half_edges.len) : (count += 1) {
                        const edge_id = edge_refs[curr_he];
                        if (edge_id != INVALID_ID) {
                            try wire.edge_indices.append(allocator, edge_id);
                        }
                        curr_he = nexts[curr_he];
                        if (curr_he == start_he or curr_he >= self.half_edges.len) break;
                    }
                }
            }

            const legacy_surf: topology.SurfaceType = switch (surfaces[face_idx]) {
                .Cylinder => .Cylinder,
                else => .Plane,
            };

            legacy.shell.faces.appendAssumeCapacity(.{
                .id = @intCast(face_idx + 1),
                .surface = legacy_surf,
                .normal = normals[face_idx],
                .wire = wire,
            });
        }

        legacy.volume = self.volume;
        legacy.surface_area = self.surface_area;
        return legacy;
    }
};


test "SoASolid init, add entities, clone, and deinit without leaks" {
    const allocator = std.testing.allocator;
    var solid = SoASolid.init();
    defer solid.deinit(allocator);

    const dummy_topo = CadTopoId.INVALID;

    const v0 = try solid.addVertex(allocator, Vec3.init(0, 0, 0), dummy_topo);
    const v1 = try solid.addVertex(allocator, Vec3.init(1, 0, 0), dummy_topo);
    const v2 = try solid.addVertex(allocator, Vec3.init(0, 1, 0), dummy_topo);

    try std.testing.expectEqual(@as(u32, 0), v0);
    try std.testing.expectEqual(@as(u32, 1), v1);
    try std.testing.expectEqual(@as(u32, 2), v2);

    const bbox = solid.calcBoundingBox();
    try std.testing.expectEqual(@as(f32, 0.0), bbox.min.x);
    try std.testing.expectEqual(@as(f32, 1.0), bbox.max.x);
    try std.testing.expectEqual(@as(f32, 1.0), bbox.max.y);

    var cloned = try solid.clone(allocator);
    defer cloned.deinit(allocator);

    try std.testing.expectEqual(solid.vertices.len, cloned.vertices.len);
}

test "SoASolid validateManifold and Euler-Poincare on Tetrahedron" {
    const allocator = std.testing.allocator;
    var solid = SoASolid.init();
    defer solid.deinit(allocator);

    const dummy_topo = CadTopoId.INVALID;
    const solid_id = try solid.addSolid(allocator, dummy_topo);
    const shell_id = try solid.addShell(allocator, solid_id, true, dummy_topo);

    // 4 Vertices
    const v0 = try solid.addVertex(allocator, Vec3.init(0.0, 0.0, 0.0), dummy_topo);
    const v1 = try solid.addVertex(allocator, Vec3.init(1.0, 0.0, 0.0), dummy_topo);
    const v2 = try solid.addVertex(allocator, Vec3.init(0.5, 0.866, 0.0), dummy_topo);
    const v3 = try solid.addVertex(allocator, Vec3.init(0.5, 0.288, 0.816), dummy_topo);

    // 4 Faces with outward normals
    const f0 = try solid.addFace(allocator, shell_id, Vec3.init(0, 0, -1), .Plane, dummy_topo);
    const f1 = try solid.addFace(allocator, shell_id, Vec3.init(0, -0.943, 0.333).normalize(), .Plane, dummy_topo);
    const f2 = try solid.addFace(allocator, shell_id, Vec3.init(0.816, 0.471, 0.333).normalize(), .Plane, dummy_topo);
    const f3 = try solid.addFace(allocator, shell_id, Vec3.init(-0.816, 0.471, 0.333).normalize(), .Plane, dummy_topo);

    const l0 = try solid.addLoop(allocator, f0, true, dummy_topo);
    const l1 = try solid.addLoop(allocator, f1, true, dummy_topo);
    const l2 = try solid.addLoop(allocator, f2, true, dummy_topo);
    const l3 = try solid.addLoop(allocator, f3, true, dummy_topo);

    solid.faces.slice().items(.outer_loop)[f0] = l0;
    solid.faces.slice().items(.outer_loop)[f1] = l1;
    solid.faces.slice().items(.outer_loop)[f2] = l2;
    solid.faces.slice().items(.outer_loop)[f3] = l3;

    // Face 0: (v0 -> v2 -> v1)
    const he0_02 = try solid.addHalfEdge(allocator, v0, l0, dummy_topo);
    const he0_21 = try solid.addHalfEdge(allocator, v2, l0, dummy_topo);
    const he0_10 = try solid.addHalfEdge(allocator, v1, l0, dummy_topo);
    solid.setNextPrev(he0_02, he0_21);
    solid.setNextPrev(he0_21, he0_10);
    solid.setNextPrev(he0_10, he0_02);
    solid.loops.slice().items(.half_edge)[l0] = he0_02;

    // Face 1: (v0 -> v1 -> v3)
    const he1_01 = try solid.addHalfEdge(allocator, v0, l1, dummy_topo);
    const he1_13 = try solid.addHalfEdge(allocator, v1, l1, dummy_topo);
    const he1_30 = try solid.addHalfEdge(allocator, v3, l1, dummy_topo);
    solid.setNextPrev(he1_01, he1_13);
    solid.setNextPrev(he1_13, he1_30);
    solid.setNextPrev(he1_30, he1_01);
    solid.loops.slice().items(.half_edge)[l1] = he1_01;

    // Face 2: (v1 -> v2 -> v3)
    const he2_12 = try solid.addHalfEdge(allocator, v1, l2, dummy_topo);
    const he2_23 = try solid.addHalfEdge(allocator, v2, l2, dummy_topo);
    const he2_31 = try solid.addHalfEdge(allocator, v3, l2, dummy_topo);
    solid.setNextPrev(he2_12, he2_23);
    solid.setNextPrev(he2_23, he2_31);
    solid.setNextPrev(he2_31, he2_12);
    solid.loops.slice().items(.half_edge)[l2] = he2_12;

    // Face 3: (v2 -> v0 -> v3)
    const he3_20 = try solid.addHalfEdge(allocator, v2, l3, dummy_topo);
    const he3_03 = try solid.addHalfEdge(allocator, v0, l3, dummy_topo);
    const he3_32 = try solid.addHalfEdge(allocator, v3, l3, dummy_topo);
    solid.setNextPrev(he3_20, he3_03);
    solid.setNextPrev(he3_03, he3_32);
    solid.setNextPrev(he3_32, he3_20);
    solid.loops.slice().items(.half_edge)[l3] = he3_20;

    // 6 Edges connecting twins
    const e_01 = try solid.addEdge(allocator, he1_01, dummy_topo);
    solid.setTwins(he1_01, he0_10, e_01);

    const e_02 = try solid.addEdge(allocator, he0_02, dummy_topo);
    solid.setTwins(he0_02, he3_20, e_02);

    const e_12 = try solid.addEdge(allocator, he2_12, dummy_topo);
    solid.setTwins(he2_12, he0_21, e_12);

    const e_03 = try solid.addEdge(allocator, he3_03, dummy_topo);
    solid.setTwins(he3_03, he1_30, e_03);

    const e_13 = try solid.addEdge(allocator, he1_13, dummy_topo);
    solid.setTwins(he1_13, he2_31, e_13);

    const e_23 = try solid.addEdge(allocator, he2_23, dummy_topo);
    solid.setTwins(he2_23, he3_32, e_23);

    // Validate manifold
    try solid.validateManifold();

    // Verify Euler-Poincaré = 0 (V - E + F - (L - F) - 2(S - G) = 4 - 6 + 4 - 0 - 2 = 0)
    try std.testing.expectEqual(@as(i32, 0), solid.calcEulerPoincare(0));

    // Update metrics
    solid.updateMetrics();
    try std.testing.expect(solid.volume > 0.05);
    try std.testing.expect(solid.surface_area > 1.0);
}

