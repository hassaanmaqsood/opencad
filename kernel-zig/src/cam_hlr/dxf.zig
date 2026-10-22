const std = @import("std");
const hlr = @import("hlr.zig");

pub const DxfExporter = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) DxfExporter {
        return .{ .allocator = allocator };
    }

    fn writeFmt(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
        const s = try std.fmt.allocPrint(alloc, fmt, args);
        defer alloc.free(s);
        try buf.appendSlice(alloc, s);
    }

    /// Exports drawing view curves to industry-standard AutoCAD DXF R12/2000 text
    pub fn exportDxf(self: *DxfExporter, view: *const hlr.HlrDrawingView) ![]const u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(self.allocator);

        // DXF HEADER
        try buf.appendSlice(self.allocator, "0\nSECTION\n2\nHEADER\n9\n$ACADVER\n1\nAC1009\n0\nENDSEC\n");

        // DXF TABLES & LAYERS
        try buf.appendSlice(self.allocator, "0\nSECTION\n2\nTABLES\n0\nTABLE\n2\nLAYER\n70\n4\n");
        // Layer VISIBLE (white/black, color 7)
        try buf.appendSlice(self.allocator, "0\nLAYER\n2\nVISIBLE\n70\n0\n62\n7\n6\nCONTINUOUS\n");
        // Layer HIDDEN (gray, color 8)
        try buf.appendSlice(self.allocator, "0\nLAYER\n2\nHIDDEN\n70\n0\n62\n8\n6\nDASHED\n");
        // Layer CENTERLINE (cyan, color 4)
        try buf.appendSlice(self.allocator, "0\nLAYER\n2\nCENTERLINE\n70\n0\n62\n4\n6\nDASHDOT\n");
        // Layer HATCH (light gray, color 9)
        try buf.appendSlice(self.allocator, "0\nLAYER\n2\nHATCH\n70\n0\n62\n9\n6\nCONTINUOUS\n");
        try buf.appendSlice(self.allocator, "0\nENDTAB\n0\nENDSEC\n");

        // DXF ENTITIES
        try buf.appendSlice(self.allocator, "0\nSECTION\n2\nENTITIES\n");

        for (view.curves.items) |curve| {
            const layer_name = switch (curve.visibility) {
                .Visible => "VISIBLE",
                .Hidden => "HIDDEN",
                .Silhouette => "VISIBLE",
                .Centerline => "CENTERLINE",
                .Hatch => "HATCH",
            };

            const pts = curve.points_2d.items;
            if (pts.len >= 4) {
                var i: usize = 0;
                while (i + 3 < pts.len) : (i += 2) {
                    try buf.appendSlice(self.allocator, "0\nLINE\n8\n");
                    try buf.appendSlice(self.allocator, layer_name);
                    try buf.appendSlice(self.allocator, "\n");

                    try writeFmt(&buf, self.allocator, "10\n{d:.4}\n20\n{d:.4}\n30\n0.0\n", .{ pts[i], pts[i + 1] });
                    try writeFmt(&buf, self.allocator, "11\n{d:.4}\n21\n{d:.4}\n31\n0.0\n", .{ pts[i + 2], pts[i + 3] });
                }
            }
        }

        try buf.appendSlice(self.allocator, "0\nENDSEC\n0\nEOF\n");

        return buf.toOwnedSlice(self.allocator);
    }
};

test "DxfExporter produces valid DXF format" {
    var proj = hlr.HlrProjector.init(std.testing.allocator);
    var view = try proj.projectBox([_]f64{ 0.0, 0.0, 0.0 }, [_]f64{ 20.0, 30.0, 10.0 }, .Front, true);
    defer view.deinit();

    var exporter = DxfExporter.init(std.testing.allocator);
    const dxf = try exporter.exportDxf(&view);
    defer std.testing.allocator.free(dxf);

    try std.testing.expect(std.mem.indexOf(u8, dxf, "SECTION\n2\nHEADER") != null);
    try std.testing.expect(std.mem.indexOf(u8, dxf, "LAYER\n2\nVISIBLE") != null);
    try std.testing.expect(std.mem.indexOf(u8, dxf, "0\nLINE\n8\nVISIBLE") != null);
    try std.testing.expect(std.mem.indexOf(u8, dxf, "0\nEOF\n") != null);
}
