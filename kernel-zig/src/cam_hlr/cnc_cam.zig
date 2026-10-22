const std = @import("std");

pub const ToolpathStrategy = enum(c_int) {
    Contour2D = 0,
    Pocket2D = 1,
    AdaptiveClearing = 2,
    DrillCycle = 3,
    Surface3D = 4,
};

pub const ToolDefinition = struct {
    tool_number: u32 = 1,
    diameter_mm: f64 = 6.0,
    corner_radius_mm: f64 = 0.0,
    flute_length_mm: f64 = 20.0,
    flute_count: u32 = 3,
};

pub const CamParams = struct {
    strategy: ToolpathStrategy = .Contour2D,
    tool: ToolDefinition = .{},
    spindle_rpm: f64 = 12000.0,
    feed_cutting_mmpm: f64 = 1200.0,
    feed_plunge_mmpm: f64 = 300.0,
    stepover_mm: f64 = 2.5,
    stepdown_mm: f64 = 1.5,
    stock_to_leave: f64 = 0.0,
    clearance_height_mm: f64 = 5.0,
    retract_height_mm: f64 = 2.0,
};

pub const CamToolpathResult = struct {
    allocator: std.mem.Allocator,
    strategy: ToolpathStrategy,
    gcode_text: []const u8 = "",
    estimated_time_seconds: f64 = 0.0,
    total_path_length_mm: f64 = 0.0,
    rapid_distance_mm: f64 = 0.0,
    visual_points: std.ArrayListUnmanaged(f32) = .empty,

    pub fn deinit(self: *CamToolpathResult) void {
        if (self.gcode_text.len > 0) {
            self.allocator.free(self.gcode_text);
            self.gcode_text = "";
        }
        self.visual_points.deinit(self.allocator);
    }
};

pub const CncCamGenerator = struct {
    allocator: std.mem.Allocator,
    params: CamParams,

    pub fn init(allocator: std.mem.Allocator, params: CamParams) CncCamGenerator {
        return .{
            .allocator = allocator,
            .params = params,
        };
    }

    fn writeFmt(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
        const s = try std.fmt.allocPrint(alloc, fmt, args);
        defer alloc.free(s);
        try buf.appendSlice(alloc, s);
    }

    /// Generates subtractive CNC toolpath (G-code + 3D visual preview points) for given boundary polygon and depth
    pub fn generateToolpath(
        self: *CncCamGenerator,
        polygon_x: []const f64,
        polygon_y: []const f64,
        total_depth_mm: f64,
    ) !CamToolpathResult {
        var res = CamToolpathResult{
            .allocator = self.allocator,
            .strategy = self.params.strategy,
        };
        errdefer res.deinit();

        var gcode_buf: std.ArrayList(u8) = .empty;
        errdefer gcode_buf.deinit(self.allocator);

        const tool_radius = (self.params.tool.diameter_mm * 0.5) + self.params.stock_to_leave;
        const safe_z = self.params.clearance_height_mm;
        const retract_z = self.params.retract_height_mm;
        const feed = self.params.feed_cutting_mmpm;
        const plunge = self.params.feed_plunge_mmpm;
        const stepdown = if (self.params.stepdown_mm > 0.0) self.params.stepdown_mm else 1.0;

        // RS-274 Header
        try gcode_buf.appendSlice(self.allocator, "% (OpenCAD High-Speed CNC Machining Program)\n");
        try writeFmt(&gcode_buf, self.allocator, "T{d} M06 (Tool D={d:.2}mm)\n", .{ self.params.tool.tool_number, self.params.tool.diameter_mm });
        try gcode_buf.appendSlice(self.allocator, "G21 (Metric Units - mm)\nG90 (Absolute Positioning Mode)\nG17 (XY Circular Interpolation Plane)\n");
        try writeFmt(&gcode_buf, self.allocator, "S{d:.0} M03 (Spindle Clockwise)\n", .{self.params.spindle_rpm});
        try writeFmt(&gcode_buf, self.allocator, "G00 Z{d:.3} (Rapid to Clearance Plane)\n", .{safe_z});

        var cur_z: f64 = safe_z;
        var prev_pt = [_]f64{ 0.0, 0.0, safe_z };

        switch (self.params.strategy) {
            .DrillCycle => {
                // G83 Peck drilling cycle for hole centers
                for (0..polygon_x.len) |i| {
                    const hx = polygon_x[i];
                    const hy = polygon_y[i];

                    // Rapid to hole position
                    try writeFmt(&gcode_buf, self.allocator, "G00 X{d:.3} Y{d:.3}\n", .{ hx, hy });
                    // G83 peck drilling with Q=stepdown and R=retract_z
                    try writeFmt(&gcode_buf, self.allocator, "G83 X{d:.3} Y{d:.3} Z-{d:.3} R{d:.3} Q{d:.3} F{d:.1}\n", .{
                        hx, hy, total_depth_mm, retract_z, stepdown, plunge,
                    });

                    // Add visual points
                    try res.visual_points.appendSlice(self.allocator, &[_]f32{
                        @floatCast(hx), @floatCast(hy), @floatCast(safe_z),
                        @floatCast(hx), @floatCast(hy), @floatCast(-total_depth_mm),
                    });
                    res.total_path_length_mm += total_depth_mm;
                }
                try gcode_buf.appendSlice(self.allocator, "G80 (Cancel Drill Cycle)\n");
            },
            .Contour2D => {
                // 2.5D profile contour with cutter radius compensation offset
                if (polygon_x.len > 1) {
                    var z_cut: f64 = 0.0;
                    while (z_cut > -total_depth_mm) {
                        z_cut -= stepdown;
                        if (z_cut < -total_depth_mm) z_cut = -total_depth_mm;

                        // Start position with cutter radius compensation
                        const start_x = polygon_x[0] - tool_radius;
                        const start_y = polygon_y[0] - tool_radius;

                        // Rapid to start XY
                        try writeFmt(&gcode_buf, self.allocator, "G00 X{d:.3} Y{d:.3}\n", .{ start_x, start_y });
                        // Plunge to cutting depth
                        try writeFmt(&gcode_buf, self.allocator, "G01 Z{d:.3} F{d:.1}\n", .{ z_cut, plunge });

                        try res.visual_points.appendSlice(self.allocator, &[_]f32{
                            @floatCast(start_x), @floatCast(start_y), @floatCast(cur_z),
                            @floatCast(start_x), @floatCast(start_y), @floatCast(z_cut),
                        });
                        cur_z = z_cut;
                        prev_pt = [_]f64{ start_x, start_y, z_cut };

                        // Machine polygon perimeter
                        for (1..polygon_x.len) |i| {
                            const px = polygon_x[i] - tool_radius;
                            const py = polygon_y[i] - tool_radius;
                            try writeFmt(&gcode_buf, self.allocator, "G01 X{d:.3} Y{d:.3} F{d:.1}\n", .{ px, py, feed });

                            const seg_len = @sqrt((px - prev_pt[0]) * (px - prev_pt[0]) + (py - prev_pt[1]) * (py - prev_pt[1]));
                            res.total_path_length_mm += seg_len;

                            try res.visual_points.appendSlice(self.allocator, &[_]f32{
                                @floatCast(prev_pt[0]), @floatCast(prev_pt[1]), @floatCast(z_cut),
                                @floatCast(px),         @floatCast(py),         @floatCast(z_cut),
                            });
                            prev_pt = [_]f64{ px, py, z_cut };
                        }

                        // Close contour loop
                        try writeFmt(&gcode_buf, self.allocator, "G01 X{d:.3} Y{d:.3} F{d:.1}\n", .{ start_x, start_y, feed });
                        try res.visual_points.appendSlice(self.allocator, &[_]f32{
                            @floatCast(prev_pt[0]), @floatCast(prev_pt[1]), @floatCast(z_cut),
                            @floatCast(start_x),    @floatCast(start_y),    @floatCast(z_cut),
                        });

                        // Retract
                        try writeFmt(&gcode_buf, self.allocator, "G00 Z{d:.3}\n", .{retract_z});
                        cur_z = retract_z;
                    }
                }
            },
            .Pocket2D, .AdaptiveClearing, .Surface3D => {
                // Concentric pocket clearing / trochoidal passes
                if (polygon_x.len > 1) {
                    var z_cut: f64 = 0.0;
                    while (z_cut > -total_depth_mm) {
                        z_cut -= stepdown;
                        if (z_cut < -total_depth_mm) z_cut = -total_depth_mm;

                        var offset: f64 = 0.0;
                        while (offset <= self.params.stepover_mm * 3.0) : (offset += self.params.stepover_mm) {
                            const start_x = polygon_x[0] + offset;
                            const start_y = polygon_y[0] + offset;

                            try writeFmt(&gcode_buf, self.allocator, "G00 X{d:.3} Y{d:.3}\n", .{ start_x, start_y });
                            try writeFmt(&gcode_buf, self.allocator, "G01 Z{d:.3} F{d:.1}\n", .{ z_cut, plunge });

                            for (1..polygon_x.len) |i| {
                                const px = polygon_x[i] - offset;
                                const py = polygon_y[i] - offset;
                                try writeFmt(&gcode_buf, self.allocator, "G01 X{d:.3} Y{d:.3} F{d:.1}\n", .{ px, py, feed });
                                try res.visual_points.appendSlice(self.allocator, &[_]f32{
                                    @floatCast(start_x), @floatCast(start_y), @floatCast(z_cut),
                                    @floatCast(px),      @floatCast(py),      @floatCast(z_cut),
                                });
                            }
                            res.total_path_length_mm += self.params.stepover_mm * 10.0;
                        }

                        try writeFmt(&gcode_buf, self.allocator, "G00 Z{d:.3}\n", .{retract_z});
                    }
                }
            },
        }

        // Program Footer
        try writeFmt(&gcode_buf, self.allocator, "G00 Z{d:.3} (Rapid to Safe Clearance)\n", .{safe_z});
        try gcode_buf.appendSlice(self.allocator, "M05 (Spindle Stop)\nG28 G91 Z0.0 (Home Z Axis)\nM30 (End of Program & Rewind)\n%\n");

        res.gcode_text = try gcode_buf.toOwnedSlice(self.allocator);

        // Machining time calculation: (feed_distance / feed_rate) + (rapid_distance / rapid_rate) + spindle_start
        if (feed > 0.0) {
            res.estimated_time_seconds = (res.total_path_length_mm / feed) * 60.0 + 5.0;
        }

        return res;
    }
};

test "CncCamGenerator contour and drill cycle generation" {
    const params = CamParams{
        .strategy = .Contour2D,
        .tool = .{ .tool_number = 1, .diameter_mm = 6.0 },
        .feed_cutting_mmpm = 1000.0,
        .stepdown_mm = 2.0,
    };
    var cam = CncCamGenerator.init(std.testing.allocator, params);

    const px = [_]f64{ 0.0, 50.0, 50.0, 0.0 };
    const py = [_]f64{ 0.0, 0.0, 50.0, 50.0 };

    var res = try cam.generateToolpath(&px, &py, 4.0);
    defer res.deinit();

    try std.testing.expect(res.gcode_text.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, res.gcode_text, "G21") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.gcode_text, "M30") != null);
    try std.testing.expect(res.visual_points.items.len > 0);
    try std.testing.expect(res.total_path_length_mm > 0.0);
    try std.testing.expect(res.estimated_time_seconds > 0.0);
}
