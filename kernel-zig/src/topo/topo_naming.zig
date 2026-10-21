const std = @import("std");
const Vec3 = @import("../math/vec3.zig").Vec3;
const half_edge = @import("half_edge.zig");

pub const CadTopoId = half_edge.CadTopoId;
pub const CadSubshapeType = half_edge.CadSubshapeType;
pub const SoASolid = half_edge.SoASolid;
pub const FaceId = half_edge.FaceId;
pub const EdgeId = half_edge.EdgeId;
pub const VertexId = half_edge.VertexId;
pub const INVALID_ID = half_edge.INVALID_ID;

// Disambiguation flags (4 bits)
pub const FLAG_NONE: u4 = 0;
pub const FLAG_CAP_BOTTOM: u4 = 1;
pub const FLAG_CAP_TOP: u4 = 2;
pub const FLAG_LATERAL: u4 = 3;
pub const FLAG_START_CAP: u4 = 4;
pub const FLAG_END_CAP: u4 = 5;
pub const FLAG_SEAM: u4 = 6;
pub const FLAG_FILLET: u4 = 7;
pub const FLAG_CHAMFER: u4 = 8;
pub const FLAG_INTERIOR: u4 = 9;

pub const TopoIdParts = struct {
    origin_feature_id: u16,
    source_sketch_entity_id: u16,
    op_type: u8,
    subshape_type: CadSubshapeType,
    flags: u4,
    subshape_hash: u16,
};

pub fn constructTopoId(parts: TopoIdParts) CadTopoId {
    return CadTopoId.init(
        parts.origin_feature_id,
        parts.source_sketch_entity_id,
        parts.op_type,
        parts.subshape_type,
        parts.flags,
        parts.subshape_hash,
    );
}

pub fn decomposeTopoId(id: CadTopoId) TopoIdParts {
    const subshape: CadSubshapeType = @enumFromInt(id.fields.subshape_type);
    return .{
        .origin_feature_id = id.fields.origin_feature_id,
        .source_sketch_entity_id = id.fields.source_sketch_entity_id,
        .op_type = id.fields.op_type,
        .subshape_type = subshape,
        .flags = id.fields.flags,
        .subshape_hash = id.fields.subshape_hash,
    };
}

/// Quantize normal vector into a 16-bit geometric direction hash
pub fn hashNormal(normal: Vec3) u16 {
    const n = normal.normalize();
    const qx: u16 = @intFromFloat(std.math.clamp((n.x + 1.0) * 15.5, 0.0, 31.0));
    const qy: u16 = @intFromFloat(std.math.clamp((n.y + 1.0) * 15.5, 0.0, 31.0));
    const qz: u16 = @intFromFloat(std.math.clamp((n.z + 1.0) * 15.5, 0.0, 31.0));
    return (qx << 10) | (qy << 5) | qz;
}

/// Hash a 3D point coordinate with 0.1mm spatial quantization
pub fn hashPoint(p: Vec3) u16 {
    const qx: i32 = @intFromFloat(@round(p.x * 10.0));
    const qy: i32 = @intFromFloat(@round(p.y * 10.0));
    const qz: i32 = @intFromFloat(@round(p.z * 10.0));
    var h: u32 = 2166136261;
    h = (h ^ @as(u32, @bitCast(qx))) *% 16777619;
    h = (h ^ @as(u32, @bitCast(qy))) *% 16777619;
    h = (h ^ @as(u32, @bitCast(qz))) *% 16777619;
    return @truncate(h ^ (h >> 16));
}

/// Hash an edge from its midpoint and direction
pub fn hashEdge(p1: Vec3, p2: Vec3) u16 {
    const mid = p1.add(p2).scale(0.5);
    const dir = p2.sub(p1).normalize();
    return hashNormal(dir) ^ hashPoint(mid);
}

/// Hash a face from its normal and disambiguation flag
pub fn hashFace(normal: Vec3, flags: u4) u16 {
    const hn = hashNormal(normal);
    return (hn ^ (@as(u16, flags) << 12));
}

/// Heuristic / lineage resolver: given a historical target CadTopoId,
/// find the matching Face in a freshly re-evaluated SoASolid,
/// gracefully handling dimension changes and parameter edits.
pub fn resolveFace(solid: *const SoASolid, target: CadTopoId) ?FaceId {
    if (solid.faces.len == 0) return null;

    var best_face: ?FaceId = null;
    var best_score: u32 = 0;

    const f_slice = solid.faces.slice();
    const topo_ids = f_slice.items(.topo_id);
    const normals = f_slice.items(.normal);

    for (topo_ids, 0..) |tid, idx| {
        // 1. Exact raw match
        if (tid.raw == target.raw) {
            return @intCast(idx);
        }

        // 2. Subshape type must match
        if (tid.fields.subshape_type != target.fields.subshape_type) continue;

        var score: u32 = 0;

        // Originating feature match
        if (tid.fields.origin_feature_id == target.fields.origin_feature_id) {
            score += 400;
        }

        // Disambiguation flag match (e.g. CAP_TOP, CAP_BOTTOM, LATERAL)
        if (tid.fields.flags == target.fields.flags) {
            score += 300;
        }

        // Source sketch entity match
        if (tid.fields.source_sketch_entity_id == target.fields.source_sketch_entity_id) {
            score += 200;
        }

        // Hash match
        if (tid.fields.subshape_hash == target.fields.subshape_hash) {
            score += 150;
        }

        // Normal direction alignment with target hash
        const n = normals[idx];
        if (hashNormal(n) == (target.fields.subshape_hash & 0x0FFF)) {
            score += 100;
        }

        if (score > best_score) {
            best_score = score;
            best_face = @intCast(idx);
        }
    }

    if (best_score >= 300) {
        return best_face;
    }
    return null;
}

/// Resolves an Edge in freshly evaluated SoASolid from historical target CadTopoId
pub fn resolveEdge(solid: *const SoASolid, target: CadTopoId) ?EdgeId {
    if (solid.edges.len == 0) return null;

    var best_edge: ?EdgeId = null;
    var best_score: u32 = 0;

    const e_slice = solid.edges.slice();
    const topo_ids = e_slice.items(.topo_id);

    for (topo_ids, 0..) |tid, idx| {
        if (tid.raw == target.raw) return @intCast(idx);
        if (tid.fields.subshape_type != target.fields.subshape_type) continue;

        var score: u32 = 0;
        if (tid.fields.origin_feature_id == target.fields.origin_feature_id) score += 400;
        if (tid.fields.flags == target.fields.flags) score += 300;
        if (tid.fields.source_sketch_entity_id == target.fields.source_sketch_entity_id) score += 200;
        if (tid.fields.subshape_hash == target.fields.subshape_hash) score += 150;

        if (score > best_score) {
            best_score = score;
            best_edge = @intCast(idx);
        }
    }

    if (best_score >= 300) return best_edge;
    return null;
}

/// Resolves a Vertex in freshly evaluated SoASolid from historical target CadTopoId
pub fn resolveVertex(solid: *const SoASolid, target: CadTopoId) ?VertexId {
    if (solid.vertices.len == 0) return null;

    var best_vertex: ?VertexId = null;
    var best_score: u32 = 0;

    const v_slice = solid.vertices.slice();
    const topo_ids = v_slice.items(.topo_id);

    for (topo_ids, 0..) |tid, idx| {
        if (tid.raw == target.raw) return @intCast(idx);
        if (tid.fields.subshape_type != target.fields.subshape_type) continue;

        var score: u32 = 0;
        if (tid.fields.origin_feature_id == target.fields.origin_feature_id) score += 400;
        if (tid.fields.flags == target.fields.flags) score += 300;
        if (tid.fields.source_sketch_entity_id == target.fields.source_sketch_entity_id) score += 200;
        if (tid.fields.subshape_hash == target.fields.subshape_hash) score += 150;

        if (score > best_score) {
            best_score = score;
            best_vertex = @intCast(idx);
        }
    }

    if (best_score >= 300) return best_vertex;
    return null;
}

pub const ResolvedSubshape = struct {
    subshape_type: CadSubshapeType,
    index: u32,
};

/// Generic subshape resolver for any subshape type
pub fn resolveSubshape(solid: *const SoASolid, target: CadTopoId) ?ResolvedSubshape {
    const st = target.fields.subshape_type;
    const subshape_type: CadSubshapeType = @enumFromInt(st);
    switch (subshape_type) {
        .Face => {
            const idx = resolveFace(solid, target) orelse return null;
            return .{ .subshape_type = .Face, .index = idx };
        },
        .Edge => {
            const idx = resolveEdge(solid, target) orelse return null;
            return .{ .subshape_type = .Edge, .index = idx };
        },
        .Vertex => {
            const idx = resolveVertex(solid, target) orelse return null;
            return .{ .subshape_type = .Vertex, .index = idx };
        },
        .Shell => {
            if (solid.shells.len > 0) {
                return .{ .subshape_type = .Shell, .index = 0 };
            }
            return null;
        },
    }
}

test "construct and decompose CadTopoId" {
    const parts = TopoIdParts{
        .origin_feature_id = 42,
        .source_sketch_entity_id = 7,
        .op_type = 3,
        .subshape_type = .Face,
        .flags = FLAG_CAP_TOP,
        .subshape_hash = 0xABCD,
    };

    const id = constructTopoId(parts);
    const decoded = decomposeTopoId(id);

    try std.testing.expectEqual(parts.origin_feature_id, decoded.origin_feature_id);
    try std.testing.expectEqual(parts.source_sketch_entity_id, decoded.source_sketch_entity_id);
    try std.testing.expectEqual(parts.op_type, decoded.op_type);
    try std.testing.expectEqual(parts.subshape_type, decoded.subshape_type);
    try std.testing.expectEqual(parts.flags, decoded.flags);
    try std.testing.expectEqual(parts.subshape_hash, decoded.subshape_hash);
}

test "Geometric invariant hashing stability" {
    const n1 = Vec3.init(0.0, 0.0, 1.0);
    const n2 = Vec3.init(0.0, 0.0, 1.0001); // Minor numeric noise
    try std.testing.expectEqual(hashNormal(n1), hashNormal(n2));

    const p1 = Vec3.init(10.0, 20.0, 30.0);
    const p2 = Vec3.init(10.001, 20.001, 30.001); // Within 0.1mm
    try std.testing.expectEqual(hashPoint(p1), hashPoint(p2));
}

test "TNP Heuristic Resolver" {
    const allocator = std.testing.allocator;
    var solid = SoASolid.init();
    defer solid.deinit(allocator);

    const solid_id = try solid.addSolid(allocator, CadTopoId.INVALID);
    const shell_id = try solid.addShell(allocator, solid_id, true, CadTopoId.INVALID);

    const top_face_topo = constructTopoId(.{
        .origin_feature_id = 1,
        .source_sketch_entity_id = 0,
        .op_type = 3,
        .subshape_type = .Face,
        .flags = FLAG_CAP_TOP,
        .subshape_hash = hashNormal(Vec3.init(0, 0, 1)),
    });

    const bottom_face_topo = constructTopoId(.{
        .origin_feature_id = 1,
        .source_sketch_entity_id = 0,
        .op_type = 3,
        .subshape_type = .Face,
        .flags = FLAG_CAP_BOTTOM,
        .subshape_hash = hashNormal(Vec3.init(0, 0, -1)),
    });

    _ = try solid.addFace(allocator, shell_id, Vec3.init(0, 0, -1), .Plane, bottom_face_topo);
    const top_face_idx = try solid.addFace(allocator, shell_id, Vec3.init(0, 0, 1), .Plane, top_face_topo);

    // Exact resolution
    const resolved_exact = resolveFace(&solid, top_face_topo);
    try std.testing.expectEqual(top_face_idx, resolved_exact.?);

    // Heuristic resolution with slightly different hash (e.g. from modified dimension)
    const modified_target = constructTopoId(.{
        .origin_feature_id = 1,
        .source_sketch_entity_id = 0,
        .op_type = 3,
        .subshape_type = .Face,
        .flags = FLAG_CAP_TOP,
        .subshape_hash = 0x9999, // Changed hash
    });

    const resolved_heuristic = resolveFace(&solid, modified_target);
    try std.testing.expectEqual(top_face_idx, resolved_heuristic.?);
}
