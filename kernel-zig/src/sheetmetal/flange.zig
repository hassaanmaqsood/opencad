const std = @import("std");
const kfactor = @import("kfactor.zig");

pub const ReliefType = enum(u8) {
    Tear = 0,
    Rectangular = 1,
    Obround = 2,
    None = 3,
};

pub const HemType = enum(u8) {
    Closed = 0,
    Open = 1,
    Teardrop = 2,
    Rolled = 3,
};

pub const FlangePosition = enum(u8) {
    MaterialInside = 0,
    MaterialOutside = 1,
    BendOutside = 2,
};

pub const EdgeFlange = struct {
    edge_index: u32,
    length: f64, // mm (extruded flange height)
    angle_rad: f64 = std.math.pi / 2.0, // default 90 deg bend
    bend_radius: f64 = 2.0,
    offset_start: f64 = 0.0,
    offset_end: f64 = 0.0,
    relief_type: ReliefType = .Rectangular,
    relief_width: f64 = 1.0,
    relief_depth: f64 = 1.5,
    flange_pos: FlangePosition = .MaterialInside,
    miter_angle_rad: f64 = std.math.pi / 4.0, // 45 deg miter for 90 deg corner
};

pub const Hem = struct {
    edge_index: u32,
    hem_type: HemType = .Open,
    length: f64 = 10.0,
    gap: f64 = 1.0,
    bend_radius: f64 = 0.5,
};

pub const SheetMetalSolid = struct {
    allocator: std.mem.Allocator,
    material: kfactor.SheetMetalMaterial,
    base_width: f64,
    base_length: f64,
    flanges: std.ArrayListUnmanaged(EdgeFlange) = .empty,
    hems: std.ArrayListUnmanaged(Hem) = .empty,

    pub fn init(alloc: std.mem.Allocator, material: kfactor.SheetMetalMaterial, width: f64, length: f64) SheetMetalSolid {
        return .{
            .allocator = alloc,
            .material = material,
            .base_width = width,
            .base_length = length,
            .flanges = .empty,
            .hems = .empty,
        };
    }

    pub fn deinit(self: *SheetMetalSolid) void {
        self.flanges.deinit(self.allocator);
        self.hems.deinit(self.allocator);
    }

    pub fn addFlange(self: *SheetMetalSolid, fl: EdgeFlange) !void {
        var flange_copy = fl;
        // Automatic miter detection: check if an adjacent edge already has a flange
        for (self.flanges.items) |existing| {
            const diff = if (fl.edge_index > existing.edge_index)
                fl.edge_index - existing.edge_index
            else
                existing.edge_index - fl.edge_index;

            // Edges 0,1,2,3 around rectangle: adjacent if diff == 1 or diff == 3
            if (diff == 1 or diff == 3) {
                // Adjacent corner junction: apply 45 degree miter trim
                flange_copy.miter_angle_rad = std.math.pi / 4.0;
            }
        }
        try self.flanges.append(self.allocator, flange_copy);
    }

    pub fn addHem(self: *SheetMetalSolid, hem: Hem) !void {
        try self.hems.append(self.allocator, hem);
    }

    /// Generates 3D mesh vertices [x, y, z] and triangle indices for the folded sheet metal solid
    pub fn generateFoldedMesh(
        self: *const SheetMetalSolid,
        alloc: std.mem.Allocator,
        out_vertices: *std.ArrayListUnmanaged(f32),
        out_indices: *std.ArrayListUnmanaged(u32),
    ) !void {
        const w = @as(f32, @floatCast(self.base_width));
        const l = @as(f32, @floatCast(self.base_length));
        const t = @as(f32, @floatCast(self.material.thickness));

        // Base plate: bottom (Z = 0) and top (Z = t)
        const base_v_start = @as(u32, @intCast(out_vertices.items.len / 3));

        // Bottom face (Z = 0)
        try out_vertices.appendSlice(alloc, &[_]f32{
            0.0, 0.0, 0.0,
            w,   0.0, 0.0,
            w,   l,   0.0,
            0.0, l,   0.0,
        });

        // Top face (Z = t)
        try out_vertices.appendSlice(alloc, &[_]f32{
            0.0, 0.0, t,
            w,   0.0, t,
            w,   l,   t,
            0.0, l,   t,
        });

        // Base box triangles (bottom, top, 4 side walls)
        const b = base_v_start;
        const base_tris = [_]u32{
            // Bottom
            b + 0, b + 2, b + 1,
            b + 0, b + 3, b + 2,
            // Top
            b + 4, b + 5, b + 6,
            b + 4, b + 6, b + 7,
            // Side 0 (Y=0)
            b + 0, b + 1, b + 5,
            b + 0, b + 5, b + 4,
            // Side 1 (X=w)
            b + 1, b + 2, b + 6,
            b + 1, b + 6, b + 5,
            // Side 2 (Y=l)
            b + 2, b + 3, b + 7,
            b + 2, b + 7, b + 6,
            // Side 3 (X=0)
            b + 3, b + 0, b + 4,
            b + 3, b + 4, b + 7,
        };
        try out_indices.appendSlice(alloc, &base_tris);

        // Extrude each folded flange
        for (self.flanges.items) |fl| {
            const fl_len = @as(f32, @floatCast(fl.length));
            const sin_a = @as(f32, @floatCast(@sin(fl.angle_rad)));
            const cos_a = @as(f32, @floatCast(@cos(fl.angle_rad)));

            const f_start = @as(u32, @intCast(out_vertices.items.len / 3));
            switch (fl.edge_index % 4) {
                0 => { // Flange along Y = 0 edge (extruding -Y and +Z)
                    try out_vertices.appendSlice(alloc, &[_]f32{
                        0.0, -fl_len * cos_a, fl_len * sin_a,
                        w,   -fl_len * cos_a, fl_len * sin_a,
                        w,   0.0,             0.0,
                        0.0, 0.0,             0.0,
                    });
                },
                1 => { // Flange along X = w edge (extruding +X and +Z)
                    try out_vertices.appendSlice(alloc, &[_]f32{
                        w + fl_len * cos_a, 0.0, fl_len * sin_a,
                        w + fl_len * cos_a, l,   fl_len * sin_a,
                        w,                  l,   0.0,
                        w,                  0.0, 0.0,
                    });
                },
                2 => { // Flange along Y = l edge (extruding +Y and +Z)
                    try out_vertices.appendSlice(alloc, &[_]f32{
                        w,   l + fl_len * cos_a, fl_len * sin_a,
                        0.0, l + fl_len * cos_a, fl_len * sin_a,
                        0.0, l,                  0.0,
                        w,   l,                  0.0,
                    });
                },
                else => { // Flange along X = 0 edge (extruding -X and +Z)
                    try out_vertices.appendSlice(alloc, &[_]f32{
                        -fl_len * cos_a, l,   fl_len * sin_a,
                        -fl_len * cos_a, 0.0, fl_len * sin_a,
                        0.0,             0.0, 0.0,
                        0.0,             l,   0.0,
                    });
                },
            }

            try out_indices.appendSlice(alloc, &[_]u32{
                f_start + 0, f_start + 1, f_start + 2,
                f_start + 0, f_start + 2, f_start + 3,
            });
        }
    }
};

test "SheetMetalSolid initialization, flanges, and mesh generation" {
    const mat = kfactor.SheetMetalMaterial{
        .thickness = 1.5,
        .inner_bend_radius = 2.0,
    };
    var sm = SheetMetalSolid.init(std.testing.allocator, mat, 50.0, 80.0);
    defer sm.deinit();

    try sm.addFlange(.{
        .edge_index = 0,
        .length = 25.0,
        .angle_rad = std.math.pi / 2.0,
        .relief_type = .Rectangular,
    });
    try sm.addFlange(.{
        .edge_index = 1,
        .length = 25.0,
        .angle_rad = std.math.pi / 2.0,
        .relief_type = .Obround,
    });

    try std.testing.expectEqual(@as(usize, 2), sm.flanges.items.len);

    var vertices: std.ArrayListUnmanaged(f32) = .empty;
    defer vertices.deinit(std.testing.allocator);
    var indices: std.ArrayListUnmanaged(u32) = .empty;
    defer indices.deinit(std.testing.allocator);

    try sm.generateFoldedMesh(std.testing.allocator, &vertices, &indices);
    try std.testing.expect(vertices.items.len > 0);
    try std.testing.expect(indices.items.len > 0);
}
