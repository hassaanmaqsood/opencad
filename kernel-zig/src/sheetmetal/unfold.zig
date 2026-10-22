const std = @import("std");
const flange = @import("flange.zig");
const kfactor = @import("kfactor.zig");

pub const BendDirection = enum(u8) {
    Up = 0,
    Down = 1,
};

pub const BendNote = struct {
    center_x: f64,
    center_y: f64,
    angle_deg: f64,
    radius: f64,
    direction: BendDirection,
};

pub const FlatPattern2D = struct {
    allocator: std.mem.Allocator,
    total_width: f64,
    total_length: f64,
    boundary_points_x: std.ArrayListUnmanaged(f64) = .empty,
    boundary_points_y: std.ArrayListUnmanaged(f64) = .empty,
    bend_notes: std.ArrayListUnmanaged(BendNote) = .empty,

    pub fn deinit(self: *FlatPattern2D) void {
        self.boundary_points_x.deinit(self.allocator);
        self.boundary_points_y.deinit(self.allocator);
        self.bend_notes.deinit(self.allocator);
    }
};

pub const SheetMetalUnfolder = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SheetMetalUnfolder {
        return .{ .allocator = allocator };
    }

    pub fn unfold(self: *SheetMetalUnfolder, solid: *const flange.SheetMetalSolid) !FlatPattern2D {
        var pattern = FlatPattern2D{
            .allocator = self.allocator,
            .total_width = solid.base_width,
            .total_length = solid.base_length,
        };
        errdefer pattern.deinit();

        // Calculate unrolled dimensions including bend allowances for each flange
        var extra_length: f64 = 0.0;
        for (solid.flanges.items) |fl| {
            const ba = solid.material.calcBendAllowance(fl.angle_rad);
            extra_length += fl.length + ba;

            try pattern.bend_notes.append(self.allocator, .{
                .center_x = solid.base_width / 2.0,
                .center_y = solid.base_length + extra_length - fl.length,
                .angle_deg = fl.angle_rad * (180.0 / std.math.pi),
                .radius = fl.bend_radius,
                .direction = .Up,
            });
        }
        pattern.total_length += extra_length;

        // Generate bounding rectangle points
        try pattern.boundary_points_x.append(self.allocator, 0.0);
        try pattern.boundary_points_y.append(self.allocator, 0.0);

        try pattern.boundary_points_x.append(self.allocator, pattern.total_width);
        try pattern.boundary_points_y.append(self.allocator, 0.0);

        try pattern.boundary_points_x.append(self.allocator, pattern.total_width);
        try pattern.boundary_points_y.append(self.allocator, pattern.total_length);

        try pattern.boundary_points_x.append(self.allocator, 0.0);
        try pattern.boundary_points_y.append(self.allocator, pattern.total_length);

        return pattern;
    }
};

test "SheetMetalUnfolder basic unfold" {
    const mat = kfactor.SheetMetalMaterial{
        .thickness = 1.0,
        .inner_bend_radius = 1.5,
        .default_k_factor = 0.44,
    };
    var sm = flange.SheetMetalSolid.init(std.testing.allocator, mat, 40.0, 60.0);
    defer sm.deinit();

    try sm.addFlange(.{
        .edge_index = 0,
        .length = 20.0,
        .angle_rad = std.math.pi / 2.0,
    });

    var unfolder = SheetMetalUnfolder.init(std.testing.allocator);
    var flat = try unfolder.unfold(&sm);
    defer flat.deinit();

    try std.testing.expect(flat.total_length > 80.0);
    try std.testing.expectEqual(@as(usize, 1), flat.bend_notes.items.len);
}
