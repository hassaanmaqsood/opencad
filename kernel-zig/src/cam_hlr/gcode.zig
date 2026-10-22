const std = @import("std");

pub const CncToolParams = struct {
    tool_diameter: f64 = 6.0,  // mm
    feed_rate: f64 = 1200.0,   // mm/min (F)
    plunge_rate: f64 = 300.0,  // mm/min
    spindle_rpm: u32 = 12000,  // RPM (S)
    safe_z: f64 = 5.0,         // mm clearance plane
    cut_depth_per_pass: f64 = 1.5, // mm step-down
};

pub const GCodeGenerator = struct {
    allocator: std.mem.Allocator,
    tool: CncToolParams = .{},

    pub fn init(allocator: std.mem.Allocator, tool: CncToolParams) GCodeGenerator {
        return .{
            .allocator = allocator,
            .tool = tool,
        };
    }

    fn writeFmt(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
        const s = try std.fmt.allocPrint(alloc, fmt, args);
        defer alloc.free(s);
        try buf.appendSlice(alloc, s);
    }

    /// Generates 2.5D profile contouring toolpaths around a polygon boundary
    pub fn generateContourGCode(
        self: *GCodeGenerator,
        polygon_x: []const f64,
        polygon_y: []const f64,
        total_depth: f64,
    ) ![]const u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(self.allocator);

        // Header
        try buf.appendSlice(self.allocator, "G21 (Metric mm)\nG90 (Absolute coordinates)\n");
        try writeFmt(&buf, self.allocator, "M03 S{d} (Spindle CW)\n", .{self.tool.spindle_rpm});
        try writeFmt(&buf, self.allocator, "G00 Z{d:.3} (Rapid to safe Z)\n", .{self.tool.safe_z});

        var current_z: f64 = 0.0;
        while (current_z > -total_depth) {
            current_z -= self.tool.cut_depth_per_pass;
            if (current_z < -total_depth) current_z = -total_depth;

            if (polygon_x.len > 0) {
                // Rapid to start point
                try writeFmt(&buf, self.allocator, "G00 X{d:.3} Y{d:.3}\n", .{ polygon_x[0], polygon_y[0] });
                // Plunge
                try writeFmt(&buf, self.allocator, "G01 Z{d:.3} F{d:.1}\n", .{ current_z, self.tool.plunge_rate });

                // Cut around contour
                for (1..polygon_x.len) |i| {
                    try writeFmt(&buf, self.allocator, "G01 X{d:.3} Y{d:.3} F{d:.1}\n", .{ polygon_x[i], polygon_y[i], self.tool.feed_rate });
                }
                // Close loop
                try writeFmt(&buf, self.allocator, "G01 X{d:.3} Y{d:.3} F{d:.1}\n", .{ polygon_x[0], polygon_y[0], self.tool.feed_rate });
            }
        }

        // Retract and footer
        try writeFmt(&buf, self.allocator, "G00 Z{d:.3}\n", .{self.tool.safe_z});
        try buf.appendSlice(self.allocator, "M05 (Spindle off)\nM30 (End of program)\n");

        return buf.toOwnedSlice(self.allocator);
    }
};

test "GCodeGenerator generates valid contour program" {
    var gen = GCodeGenerator.init(std.testing.allocator, .{});
    const px = [_]f64{ 0.0, 50.0, 50.0, 0.0 };
    const py = [_]f64{ 0.0, 0.0, 50.0, 50.0 };

    const gcode = try gen.generateContourGCode(&px, &py, 3.0);
    defer std.testing.allocator.free(gcode);

    try std.testing.expect(std.mem.indexOf(u8, gcode, "G21") != null);
    try std.testing.expect(std.mem.indexOf(u8, gcode, "M30") != null);
}
