const std = @import("std");
const Allocator = std.mem.Allocator;
const Vec3 = @import("../math/vec3.zig").Vec3;
const topology = @import("../brep/topology.zig");
const Solid = topology.Solid;
const Wire = topology.Wire;

pub fn createBox(allocator: Allocator, id: u64, dx: f32, dy: f32, dz: f32) !Solid {
    if (dx <= 0.0 or dy <= 0.0 or dz <= 0.0) {
        return error.InvalidArguments;
    }

    var solid = Solid.init(id);
    errdefer solid.deinit(allocator);

    // 8 vertices
    const raw_pts = [8][3]f32{
        .{ 0, 0, 0 },   .{ dx, 0, 0 },   .{ dx, dy, 0 },   .{ 0, dy, 0 },
        .{ 0, 0, dz },  .{ dx, 0, dz },  .{ dx, dy, dz },  .{ 0, dy, dz },
    };

    for (raw_pts) |pt| {
        try solid.vertices.append(allocator, .{ .point = Vec3.init(pt[0], pt[1], pt[2]) });
    }

    // 12 edges
    const edge_defs = [12][2]u32{
        .{ 0, 1 }, .{ 1, 2 }, .{ 2, 3 }, .{ 3, 0 }, // Bottom 0..3
        .{ 4, 5 }, .{ 5, 6 }, .{ 6, 7 }, .{ 7, 4 }, // Top 4..7
        .{ 0, 4 }, .{ 1, 5 }, .{ 2, 6 }, .{ 3, 7 }, // Pillars 8..11
    };

    for (edge_defs, 0..) |ed, i| {
        try solid.edges.append(allocator, .{
            .v_start = ed[0],
            .v_end = ed[1],
            .id = @intCast(i + 1),
        });
    }

    // 6 faces: each with Face ID 1..6 and normal
    const face_specs = [6]struct {
        edges: [4]u32,
        normal: Vec3,
        id: u32,
    }{
        // Face 1: -Z (Bottom)
        .{ .edges = .{ 0, 1, 2, 3 }, .normal = Vec3.init(0, 0, -1), .id = 1 },
        // Face 2: +Z (Top)
        .{ .edges = .{ 4, 5, 6, 7 }, .normal = Vec3.init(0, 0, 1), .id = 2 },
        // Face 3: -Y (Front)
        .{ .edges = .{ 0, 9, 4, 8 }, .normal = Vec3.init(0, -1, 0), .id = 3 },
        // Face 4: +Y (Back)
        .{ .edges = .{ 2, 10, 6, 11 }, .normal = Vec3.init(0, 1, 0), .id = 4 },
        // Face 5: -X (Left)
        .{ .edges = .{ 3, 11, 7, 8 }, .normal = Vec3.init(-1, 0, 0), .id = 5 },
        // Face 6: +X (Right)
        .{ .edges = .{ 1, 10, 5, 9 }, .normal = Vec3.init(1, 0, 0), .id = 6 },
    };

    for (face_specs) |spec| {
        var wire = Wire.init();
        errdefer wire.deinit(allocator);

        for (spec.edges) |e_idx| {
            try wire.edge_indices.append(allocator, e_idx);
        }

        try solid.shell.faces.append(allocator, .{
            .id = spec.id,
            .surface = .Plane,
            .normal = spec.normal,
            .wire = wire,
        });
    }

    solid.volume = dx * dy * dz;
    solid.surface_area = 2.0 * (dx * dy + dy * dz + dz * dx);

    return solid;
}
