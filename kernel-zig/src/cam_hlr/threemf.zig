const std = @import("std");

pub const BuildPlateLimits = struct {
    size_x: f64 = 250.0, // mm (e.g. 250 x 250 x 250 mm volume)
    size_y: f64 = 250.0,
    size_z: f64 = 250.0,
    part_spacing: f64 = 5.0, // mm clearance between nested parts
};

pub const NestedPartPlacement = struct {
    part_id: u32,
    pos_x: f64,
    pos_y: f64,
    pos_z: f64,
    rot_deg: f64 = 0.0,
};

pub const ThreeMfPacker = struct {
    allocator: std.mem.Allocator,
    build_plate: BuildPlateLimits = .{},

    pub fn init(allocator: std.mem.Allocator, limits: BuildPlateLimits) ThreeMfPacker {
        return .{
            .allocator = allocator,
            .build_plate = limits,
        };
    }

    /// Packs multiple part bounding boxes onto the build plate using 2D bottom-left shelf bin-packing
    pub fn nestParts(
        self: *ThreeMfPacker,
        part_boxes: []const [3]f64, // [width, depth, height]
    ) !std.ArrayListUnmanaged(NestedPartPlacement) {
        var placements: std.ArrayListUnmanaged(NestedPartPlacement) = .empty;
        errdefer placements.deinit(self.allocator);

        var current_x: f64 = self.build_plate.part_spacing;
        var current_y: f64 = self.build_plate.part_spacing;
        var max_row_height: f64 = 0.0;

        for (part_boxes, 0..) |box, idx| {
            const w = box[0];
            const d = box[1];

            if (current_x + w + self.build_plate.part_spacing > self.build_plate.size_x) {
                // Move to next shelf row
                current_x = self.build_plate.part_spacing;
                current_y += max_row_height + self.build_plate.part_spacing;
                max_row_height = 0.0;
            }

            try placements.append(self.allocator, .{
                .part_id = @intCast(idx + 1),
                .pos_x = current_x + w * 0.5,
                .pos_y = current_y + d * 0.5,
                .pos_z = 0.0, // Placed flat on build bed
            });

            current_x += w + self.build_plate.part_spacing;
            if (d > max_row_height) max_row_height = d;
        }

        return placements;
    }

    fn writeFmt(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
        const s = try std.fmt.allocPrint(alloc, fmt, args);
        defer alloc.free(s);
        try buf.appendSlice(alloc, s);
    }

    /// Generates minimal valid 3MF model XML string
    pub fn generate3MfModelXml(
        self: *ThreeMfPacker,
        mesh_vertices: []const f32,
        mesh_indices: []const u32,
    ) ![]const u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(self.allocator);

        try buf.appendSlice(self.allocator, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
        try buf.appendSlice(self.allocator, "<model unit=\"millimeter\" xml:lang=\"en-US\" xmlns=\"http://schemas.microsoft.com/3dmanufacturing/core/2015/02\">\n");
        try buf.appendSlice(self.allocator, "  <resources>\n    <object id=\"1\" type=\"model\">\n      <mesh>\n        <vertices>\n");

        var v: usize = 0;
        while (v + 2 < mesh_vertices.len) : (v += 3) {
            try writeFmt(&buf, self.allocator, "          <vertex x=\"{d:.4}\" y=\"{d:.4}\" z=\"{d:.4}\" />\n", .{
                mesh_vertices[v],
                mesh_vertices[v + 1],
                mesh_vertices[v + 2],
            });
        }

        try buf.appendSlice(self.allocator, "        </vertices>\n        <triangles>\n");
        var t: usize = 0;
        while (t + 2 < mesh_indices.len) : (t += 3) {
            try writeFmt(&buf, self.allocator, "          <triangle v1=\"{d}\" v2=\"{d}\" v3=\"{d}\" />\n", .{
                mesh_indices[t],
                mesh_indices[t + 1],
                mesh_indices[t + 2],
            });
        }

        try buf.appendSlice(self.allocator, "        </triangles>\n      </mesh>\n    </object>\n  </resources>\n  <build>\n    <item objectid=\"1\" />\n  </build>\n</model>\n");

        return buf.toOwnedSlice(self.allocator);
    }
};

test "ThreeMfPacker nesting and xml generation" {
    var packer = ThreeMfPacker.init(std.testing.allocator, .{});
    const boxes = [_][3]f64{
        .{ 30.0, 30.0, 10.0 },
        .{ 40.0, 20.0, 15.0 },
        .{ 50.0, 50.0, 25.0 },
    };
    var nested = try packer.nestParts(&boxes);
    defer nested.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), nested.items.len);

    const verts = [_]f32{ 0, 0, 0, 10, 0, 0, 0, 10, 0 };
    const idxs = [_]u32{ 0, 1, 2 };
    const xml = try packer.generate3MfModelXml(&verts, &idxs);
    defer std.testing.allocator.free(xml);

    try std.testing.expect(std.mem.indexOf(u8, xml, "<model") != null);
}
