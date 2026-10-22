const std = @import("std");
const kfactor = @import("kfactor.zig");

pub const ReliefType = enum(u8) {
    Tear = 0,
    Rectangular = 1,
    Obround = 2,
};

pub const FlangePosition = enum(u8) {
    MaterialInside = 0,
    MaterialOutside = 1,
    BendOutside = 2,
};

pub const EdgeFlange = struct {
    edge_index: u32,
    length: f64, // mm
    angle_rad: f64 = std.math.pi / 2.0, // default 90 deg
    bend_radius: f64 = 2.0,
    relief_type: ReliefType = .Rectangular,
    relief_width: f64 = 1.0,
    relief_depth: f64 = 1.5,
    flange_pos: FlangePosition = .MaterialInside,
};

pub const SheetMetalSolid = struct {
    allocator: std.mem.Allocator,
    material: kfactor.SheetMetalMaterial,
    base_width: f64,
    base_length: f64,
    flanges: std.ArrayListUnmanaged(EdgeFlange) = .empty,

    pub fn init(alloc: std.mem.Allocator, material: kfactor.SheetMetalMaterial, width: f64, length: f64) SheetMetalSolid {
        return .{
            .allocator = alloc,
            .material = material,
            .base_width = width,
            .base_length = length,
            .flanges = .empty,
        };
    }

    pub fn deinit(self: *SheetMetalSolid) void {
        self.flanges.deinit(self.allocator);
    }

    pub fn addFlange(self: *SheetMetalSolid, flange: EdgeFlange) !void {
        try self.flanges.append(self.allocator, flange);
    }
};

test "SheetMetalSolid initialization and flange addition" {
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

    try std.testing.expectEqual(@as(usize, 1), sm.flanges.items.len);
}
