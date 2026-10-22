const std = @import("std");
const flange = @import("flange.zig");
const kfactor = @import("kfactor.zig");

pub const BendDirection = enum(u8) {
    Up = 0,
    Down = 1,
};

pub const BendCenterline = struct {
    start_point: [2]f64,
    end_point: [2]f64,
    bend_angle_rad: f64,
    bend_radius: f64,
    direction: BendDirection,
    bend_allowance: f64,
    source_bend_edge: u64,
};

pub const FlatPattern2D = struct {
    allocator: std.mem.Allocator,
    total_width: f64,
    total_length: f64,
    bounding_box: [4]f64, // [min_x, min_y, max_x, max_y]
    total_cut_length: f64,
    total_area: f64,
    boundary_points_x: std.ArrayListUnmanaged(f64) = .empty,
    boundary_points_y: std.ArrayListUnmanaged(f64) = .empty,
    bend_lines: std.ArrayListUnmanaged(BendCenterline) = .empty,
    flat_mesh_vertices: std.ArrayListUnmanaged(f32) = .empty,
    flat_mesh_indices: std.ArrayListUnmanaged(u32) = .empty,

    pub fn deinit(self: *FlatPattern2D) void {
        self.boundary_points_x.deinit(self.allocator);
        self.boundary_points_y.deinit(self.allocator);
        self.bend_lines.deinit(self.allocator);
        self.flat_mesh_vertices.deinit(self.allocator);
        self.flat_mesh_indices.deinit(self.allocator);
    }
};

pub const SheetMetalUnfolder = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SheetMetalUnfolder {
        return .{ .allocator = allocator };
    }

    /// Unfolds a 3D folded sheet metal solid into a 2D flat blank with DIN 6935 neutral axis bend allowances
    pub fn unfold(self: *SheetMetalUnfolder, solid: *const flange.SheetMetalSolid) !FlatPattern2D {
        var pattern = FlatPattern2D{
            .allocator = self.allocator,
            .total_width = solid.base_width,
            .total_length = solid.base_length,
            .bounding_box = [_]f64{ 0.0, 0.0, solid.base_width, solid.base_length },
            .total_cut_length = 0.0,
            .total_area = 0.0,
        };
        errdefer pattern.deinit();

        var extra_y_neg: f64 = 0.0;
        var extra_x_pos: f64 = 0.0;
        var extra_y_pos: f64 = 0.0;
        var extra_x_neg: f64 = 0.0;

        // Process flanges and add bend centerlines
        for (solid.flanges.items) |fl| {
            const ba = solid.material.calcBendAllowance(fl.angle_rad);
            // Unfolded flat flange length = leg length + bend allowance
            const unfolded_flange_len = fl.length + ba;

            switch (fl.edge_index % 4) {
                0 => { // Bottom edge (Y = 0)
                    extra_y_neg += unfolded_flange_len;
                    try pattern.bend_lines.append(self.allocator, .{
                        .start_point = [_]f64{ 0.0, 0.0 },
                        .end_point = [_]f64{ solid.base_width, 0.0 },
                        .bend_angle_rad = fl.angle_rad,
                        .bend_radius = fl.bend_radius,
                        .direction = .Up,
                        .bend_allowance = ba,
                        .source_bend_edge = fl.edge_index,
                    });
                },
                1 => { // Right edge (X = base_width)
                    extra_x_pos += unfolded_flange_len;
                    try pattern.bend_lines.append(self.allocator, .{
                        .start_point = [_]f64{ solid.base_width, 0.0 },
                        .end_point = [_]f64{ solid.base_width, solid.base_length },
                        .bend_angle_rad = fl.angle_rad,
                        .bend_radius = fl.bend_radius,
                        .direction = .Up,
                        .bend_allowance = ba,
                        .source_bend_edge = fl.edge_index,
                    });
                },
                2 => { // Top edge (Y = base_length)
                    extra_y_pos += unfolded_flange_len;
                    try pattern.bend_lines.append(self.allocator, .{
                        .start_point = [_]f64{ solid.base_width, solid.base_length },
                        .end_point = [_]f64{ 0.0, solid.base_length },
                        .bend_angle_rad = fl.angle_rad,
                        .bend_radius = fl.bend_radius,
                        .direction = .Up,
                        .bend_allowance = ba,
                        .source_bend_edge = fl.edge_index,
                    });
                },
                else => { // Left edge (X = 0)
                    extra_x_neg += unfolded_flange_len;
                    try pattern.bend_lines.append(self.allocator, .{
                        .start_point = [_]f64{ 0.0, solid.base_length },
                        .end_point = [_]f64{ 0.0, 0.0 },
                        .bend_angle_rad = fl.angle_rad,
                        .bend_radius = fl.bend_radius,
                        .direction = .Up,
                        .bend_allowance = ba,
                        .source_bend_edge = fl.edge_index,
                    });
                },
            }
        }

        // Process hems
        for (solid.hems.items) |h| {
            const hem_ba = solid.material.calcBendAllowance(std.math.pi);
            const unfolded_hem_len = h.length + hem_ba;
            extra_y_pos += unfolded_hem_len;
        }

        const min_x = -extra_x_neg;
        const max_x = solid.base_width + extra_x_pos;
        const min_y = -extra_y_neg;
        const max_y = solid.base_length + extra_y_pos;

        pattern.bounding_box = [_]f64{ min_x, min_y, max_x, max_y };
        pattern.total_width = max_x - min_x;
        pattern.total_length = max_y - min_y;

        // Build 2D boundary polygon (cruciform flat sheet pattern)
        try pattern.boundary_points_x.append(self.allocator, 0.0);
        try pattern.boundary_points_y.append(self.allocator, min_y);

        try pattern.boundary_points_x.append(self.allocator, solid.base_width);
        try pattern.boundary_points_y.append(self.allocator, min_y);

        try pattern.boundary_points_x.append(self.allocator, solid.base_width);
        try pattern.boundary_points_y.append(self.allocator, 0.0);

        try pattern.boundary_points_x.append(self.allocator, max_x);
        try pattern.boundary_points_y.append(self.allocator, 0.0);

        try pattern.boundary_points_x.append(self.allocator, max_x);
        try pattern.boundary_points_y.append(self.allocator, solid.base_length);

        try pattern.boundary_points_x.append(self.allocator, solid.base_width);
        try pattern.boundary_points_y.append(self.allocator, solid.base_length);

        try pattern.boundary_points_x.append(self.allocator, solid.base_width);
        try pattern.boundary_points_y.append(self.allocator, max_y);

        try pattern.boundary_points_x.append(self.allocator, 0.0);
        try pattern.boundary_points_y.append(self.allocator, max_y);

        try pattern.boundary_points_x.append(self.allocator, 0.0);
        try pattern.boundary_points_y.append(self.allocator, solid.base_length);

        try pattern.boundary_points_x.append(self.allocator, min_x);
        try pattern.boundary_points_y.append(self.allocator, solid.base_length);

        try pattern.boundary_points_x.append(self.allocator, min_x);
        try pattern.boundary_points_y.append(self.allocator, 0.0);

        try pattern.boundary_points_x.append(self.allocator, 0.0);
        try pattern.boundary_points_y.append(self.allocator, 0.0);

        // Calculate perimeter cut length
        var cut_len: f64 = 0.0;
        const n_pts = pattern.boundary_points_x.items.len;
        for (0..n_pts) |i| {
            const next = (i + 1) % n_pts;
            const dx = pattern.boundary_points_x.items[next] - pattern.boundary_points_x.items[i];
            const dy = pattern.boundary_points_y.items[next] - pattern.boundary_points_y.items[i];
            cut_len += @sqrt(dx * dx + dy * dy);
        }
        pattern.total_cut_length = cut_len;

        // Calculate total flat area
        pattern.total_area = (solid.base_width * solid.base_length) +
            (extra_y_neg * solid.base_width) +
            (extra_y_pos * solid.base_width) +
            (extra_x_pos * solid.base_length) +
            (extra_x_neg * solid.base_length);

        // Generate flat 2D triangulation for Three.js rendering
        const min_xf = @as(f32, @floatCast(min_x));
        const max_xf = @as(f32, @floatCast(max_x));
        const min_yf = @as(f32, @floatCast(min_y));
        const max_yf = @as(f32, @floatCast(max_y));

        try pattern.flat_mesh_vertices.appendSlice(self.allocator, &[_]f32{
            min_xf, min_yf, 0.0,
            max_xf, min_yf, 0.0,
            max_xf, max_yf, 0.0,
            min_xf, max_yf, 0.0,
        });

        try pattern.flat_mesh_indices.appendSlice(self.allocator, &[_]u32{
            0, 1, 2,
            0, 2, 3,
        });

        return pattern;
    }
};

test "SheetMetalUnfolder cruciform unfold and bend metrics" {
    const mat = kfactor.SheetMetalMaterial{
        .thickness = 1.0,
        .inner_bend_radius = 1.5,
        .default_k_factor = 0.44,
    };
    var sm = flange.SheetMetalSolid.init(std.testing.allocator, mat, 50.0, 70.0);
    defer sm.deinit();

    try sm.addFlange(.{
        .edge_index = 0,
        .length = 20.0,
        .angle_rad = std.math.pi / 2.0,
    });
    try sm.addFlange(.{
        .edge_index = 1,
        .length = 20.0,
        .angle_rad = std.math.pi / 2.0,
    });

    var unfolder = SheetMetalUnfolder.init(std.testing.allocator);
    var flat = try unfolder.unfold(&sm);
    defer flat.deinit();

    // Verify bend centerlines count
    try std.testing.expectEqual(@as(usize, 2), flat.bend_lines.items.len);

    // Verify bend allowance formula BA = theta * (R + K * T)
    const expected_ba = (std.math.pi / 2.0) * (1.5 + 0.44 * 1.0);
    try std.testing.expectApproxEqAbs(expected_ba, flat.bend_lines.items[0].bend_allowance, 1e-9);

    // Verify perimeter cut length > 0
    try std.testing.expect(flat.total_cut_length > 0.0);
    // Verify blank area > base plate area (50 * 70 = 3500)
    try std.testing.expect(flat.total_area > 3500.0);
}
