const std = @import("std");
const hlr = @import("hlr.zig");

pub const SvgDrawingExporter = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SvgDrawingExporter {
        return .{ .allocator = allocator };
    }

    fn writeFmt(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
        const s = try std.fmt.allocPrint(alloc, fmt, args);
        defer alloc.free(s);
        try buf.appendSlice(alloc, s);
    }

    /// Exports drawing view curves to a W3C SVG vector document with standard ISO/ASME title block
    pub fn exportSvg(
        self: *SvgDrawingExporter,
        view: *const hlr.HlrDrawingView,
        sheet_w: f64,
        sheet_h: f64,
    ) ![]const u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(self.allocator);

        // SVG XML Header
        try buf.appendSlice(self.allocator, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
        try writeFmt(&buf, self.allocator,
            \\<svg xmlns="http://www.w3.org/2000/svg" width="{d:.1}mm" height="{d:.1}mm" viewBox="0 0 {d:.1} {d:.1}">
            \\  <defs>
            \\    <style>
            \\      .border {{ stroke: #000000; stroke-width: 0.7; fill: none; }}
            \\      .title-text {{ font-family: monospace; font-size: 3.5px; fill: #000; }}
            \\      .visible {{ stroke: #000000; stroke-width: 0.5; fill: none; }}
            \\      .hidden {{ stroke: #777777; stroke-width: 0.35; stroke-dasharray: 2, 2; fill: none; }}
            \\      .centerline {{ stroke: #0055cc; stroke-width: 0.35; stroke-dasharray: 6, 2, 1, 2; fill: none; }}
            \\      .hatch {{ stroke: #444444; stroke-width: 0.25; fill: none; }}
            \\    </style>
            \\  </defs>
            \\
        , .{ sheet_w, sheet_h, sheet_w, sheet_h });

        // Outer sheet border & margin (10mm margin)
        const margin = 10.0;
        try writeFmt(&buf, self.allocator,
            \\  <rect x="{d:.1}" y="{d:.1}" width="{d:.1}" height="{d:.1}" class="border" />
            \\
        , .{ margin, margin, sheet_w - 2.0 * margin, sheet_h - 2.0 * margin });

        // ISO Title Block at bottom right corner (140mm x 35mm)
        const tb_w = 140.0;
        const tb_h = 35.0;
        const tb_x = sheet_w - margin - tb_w;
        const tb_y = sheet_h - margin - tb_h;
        try writeFmt(&buf, self.allocator,
            \\  <g id="title-block">
            \\    <rect x="{d:.1}" y="{d:.1}" width="{d:.1}" height="{d:.1}" class="border" />
            \\    <line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" class="border" />
            \\    <text x="{d:.1}" y="{d:.1}" class="title-text" font-weight="bold">OPENCAD ENGINEERING DRAWING</text>
            \\    <text x="{d:.1}" y="{d:.1}" class="title-text">STANDARD: ISO 128 / ASME Y14.5</text>
            \\    <text x="{d:.1}" y="{d:.1}" class="title-text">SCALE: 1:1 | UNITS: MM</text>
            \\  </g>
            \\
        , .{
            tb_x, tb_y, tb_w, tb_h,
            tb_x, tb_y + 12.0, tb_x + tb_w, tb_y + 12.0,
            tb_x + 5.0, tb_y + 8.0,
            tb_x + 5.0, tb_y + 20.0,
            tb_x + 5.0, tb_y + 28.0,
        });

        // Compute transform to place view in center of sheet
        const vw = view.bbox[2] - view.bbox[0];
        const vh = view.bbox[3] - view.bbox[1];
        const cx = (sheet_w - margin) * 0.45;
        const cy = (sheet_h - margin) * 0.45;
        const ox = cx - (view.bbox[0] + vw * 0.5);
        // SVG Y is downward, CAD Y is upward, so invert Y
        const oy = cy + (view.bbox[1] + vh * 0.5);

        try writeFmt(&buf, self.allocator, "  <g id=\"drawing-curves\" transform=\"translate({d:.2}, {d:.2}) scale(1, -1)\">\n", .{ ox, oy });

        for (view.curves.items) |curve| {
            const class_name = switch (curve.visibility) {
                .Visible => "visible",
                .Hidden => "hidden",
                .Silhouette => "visible",
                .Centerline => "centerline",
                .Hatch => "hatch",
            };

            const pts = curve.points_2d.items;
            if (pts.len >= 4) {
                var i: usize = 0;
                while (i + 3 < pts.len) : (i += 2) {
                    try writeFmt(&buf, self.allocator,
                        "    <line x1=\"{d:.3}\" y1=\"{d:.3}\" x2=\"{d:.3}\" y2=\"{d:.3}\" class=\"{s}\" />\n",
                        .{ pts[i], pts[i + 1], pts[i + 2], pts[i + 3], class_name },
                    );
                }
            }
        }

        try buf.appendSlice(self.allocator, "  </g>\n</svg>\n");

        return buf.toOwnedSlice(self.allocator);
    }
};

test "SvgDrawingExporter produces valid SVG" {
    var proj = hlr.HlrProjector.init(std.testing.allocator);
    var view = try proj.projectBox([_]f64{ 0.0, 0.0, 0.0 }, [_]f64{ 40.0, 40.0, 20.0 }, .Front, true);
    defer view.deinit();

    var exporter = SvgDrawingExporter.init(std.testing.allocator);
    const svg = try exporter.exportSvg(&view, 420.0, 297.0);
    defer std.testing.allocator.free(svg);

    try std.testing.expect(std.mem.indexOf(u8, svg, "<svg xmlns=") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "class=\"visible\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "class=\"hidden\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "title-block") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "</svg>") != null);
}
