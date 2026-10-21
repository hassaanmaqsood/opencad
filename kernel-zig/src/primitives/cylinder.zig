const std = @import("std");
const Allocator = std.mem.Allocator;
const Vec3 = @import("../math/vec3.zig").Vec3;
const topology = @import("../brep/topology.zig");
const Solid = topology.Solid;
const Wire = topology.Wire;

pub fn createCylinder(allocator: Allocator, id: u64, radius: f32, height: f32) !Solid {
    if (radius <= 0.0 or height <= 0.0) {
        return error.InvalidArguments;
    }

    var solid = Solid.init(id);
    errdefer solid.deinit(allocator);

    // 2 vertices
    try solid.vertices.append(allocator, .{ .point = Vec3.init(0, 0, 0) });
    try solid.vertices.append(allocator, .{ .point = Vec3.init(0, 0, height) });

    // 3 edges
    try solid.edges.append(allocator, .{ .v_start = 0, .v_end = 0, .id = 1 });
    try solid.edges.append(allocator, .{ .v_start = 1, .v_end = 1, .id = 2 });
    try solid.edges.append(allocator, .{ .v_start = 0, .v_end = 1, .id = 3 });

    // Face 1: Bottom cap
    var wire_bot = Wire.init();
    errdefer wire_bot.deinit(allocator);
    try wire_bot.edge_indices.append(allocator, 0);
    try solid.shell.faces.append(allocator, .{
        .id = 1,
        .surface = .Plane,
        .normal = Vec3.init(0, 0, -1),
        .wire = wire_bot,
    });

    // Face 2: Top cap
    var wire_top = Wire.init();
    errdefer wire_top.deinit(allocator);
    try wire_top.edge_indices.append(allocator, 1);
    try solid.shell.faces.append(allocator, .{
        .id = 2,
        .surface = .Plane,
        .normal = Vec3.init(0, 0, 1),
        .wire = wire_top,
    });

    // Face 3: Cylindrical lateral wall
    var wire_lat = Wire.init();
    errdefer wire_lat.deinit(allocator);
    try wire_lat.edge_indices.append(allocator, 0);
    try wire_lat.edge_indices.append(allocator, 1);
    try wire_lat.edge_indices.append(allocator, 2);
    try solid.shell.faces.append(allocator, .{
        .id = 3,
        .surface = .Cylinder,
        .normal = Vec3.init(1, 0, 0),
        .wire = wire_lat,
    });

    const pi = std.math.pi;
    solid.volume = pi * radius * radius * height;
    solid.surface_area = 2.0 * pi * radius * height + 2.0 * pi * radius * radius;

    return solid;
}
