const std = @import("std");

pub const SectionPlane = struct {
    point: [3]f64,
    normal: [3]f64,
};

pub const SectionHatchLine = struct {
    x0: f64,
    y0: f64,
    x1: f64,
    y1: f64,
};

pub const SectionSlicer = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SectionSlicer {
        return .{ .allocator = allocator };
    }

    /// Generates ANSI31 45-degree cross-hatching lines inside sliced planar region bounds
    pub fn generateCrossHatching(
        self: *SectionSlicer,
        min_x: f64,
        max_x: f64,
        min_y: f64,
        max_y: f64,
        spacing: f64,
    ) !std.ArrayListUnmanaged(SectionHatchLine) {
        var lines: std.ArrayListUnmanaged(SectionHatchLine) = .empty;
        errdefer lines.deinit(self.allocator);

        var c = min_x - (max_y - min_y);
        const limit = max_x + (max_y - min_y);

        while (c < limit) : (c += spacing) {
            try lines.append(self.allocator, .{
                .x0 = c,
                .y0 = min_y,
                .x1 = c + (max_y - min_y),
                .y1 = max_y,
            });
        }

        return lines;
    }
};

test "SectionSlicer cross hatching" {
    var slicer = SectionSlicer.init(std.testing.allocator);
    var hatches = try slicer.generateCrossHatching(0.0, 10.0, 0.0, 10.0, 2.5);
    defer hatches.deinit(std.testing.allocator);

    try std.testing.expect(hatches.items.len > 0);
}
