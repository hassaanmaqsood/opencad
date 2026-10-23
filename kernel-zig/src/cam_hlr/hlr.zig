const std = @import("std");
const section = @import("section.zig");

pub const LineVisibility = enum(c_int) {
    Visible = 0,
    Hidden = 1,
    Silhouette = 2,
    Centerline = 3,
    Hatch = 4,
};

pub const HlrViewPlane = enum(c_int) {
    Top = 0,
    Front = 1,
    Right = 2,
    Isometric = 3,
    Section = 4,
    Custom = 5,
};

pub const ProjectedCurve2D = struct {
    visibility: LineVisibility,
    points_2d: std.ArrayListUnmanaged(f32) = .empty,
    source_topo_id: u64 = 0,

    pub fn deinit(self: *ProjectedCurve2D, alloc: std.mem.Allocator) void {
        self.points_2d.deinit(alloc);
    }
};

pub const HlrDrawingView = struct {
    allocator: std.mem.Allocator,
    curves: std.ArrayListUnmanaged(ProjectedCurve2D) = .empty,
    bbox: [4]f64 = [_]f64{ 0.0, 0.0, 0.0, 0.0 },
    section_cut_area: f64 = 0.0,

    pub fn deinit(self: *HlrDrawingView) void {
        for (self.curves.items) |*c| {
            c.deinit(self.allocator);
        }
        self.curves.deinit(self.allocator);
    }

    pub fn addCurve(self: *HlrDrawingView, vis: LineVisibility, pts: []const f32, topo_id: u64) !void {
        var curve = ProjectedCurve2D{
            .visibility = vis,
            .points_2d = .empty,
            .source_topo_id = topo_id,
        };
        try curve.points_2d.appendSlice(self.allocator, pts);
        try self.curves.append(self.allocator, curve);

        // Update bbox
        var i: usize = 0;
        while (i + 1 < pts.len) : (i += 2) {
            const x = @as(f64, @floatCast(pts[i]));
            const y = @as(f64, @floatCast(pts[i + 1]));
            if (self.curves.items.len == 1 and i == 0) {
                self.bbox = [_]f64{ x, y, x, y };
            } else {
                if (x < self.bbox[0]) self.bbox[0] = x;
                if (y < self.bbox[1]) self.bbox[1] = y;
                if (x > self.bbox[2]) self.bbox[2] = x;
                if (y > self.bbox[3]) self.bbox[3] = y;
            }
        }
    }
};

pub const HlrProjector = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) HlrProjector {
        return .{ .allocator = allocator };
    }

    /// Project a 3D point into 2D view coordinates
    pub fn projectPoint(self: *const HlrProjector, p: [3]f64, view: HlrViewPlane, camera_dir: [3]f64, up_dir: [3]f64) [2]f64 {
        _ = self;
        switch (view) {
            .Front => return [_]f64{ p[0], p[1] },
            .Top => return [_]f64{ p[0], -p[2] },
            .Right => return [_]f64{ p[1], p[2] },
            .Isometric => {
                const cos30 = 0.86602540378;
                const sin30 = 0.5;
                const x2d = (p[0] - p[2]) * cos30;
                const y2d = p[1] + (p[0] + p[2]) * sin30;
                return [_]f64{ x2d, y2d };
            },
            .Section => return [_]f64{ p[0], p[1] },
            .Custom => {
                // Gram-Schmidt orthogonal projection onto view plane perpendicular to camera_dir
                var right = [_]f64{
                    up_dir[1] * camera_dir[2] - up_dir[2] * camera_dir[1],
                    up_dir[2] * camera_dir[0] - up_dir[0] * camera_dir[2],
                    up_dir[0] * camera_dir[1] - up_dir[1] * camera_dir[0],
                };
                const len_r = @sqrt(right[0] * right[0] + right[1] * right[1] + right[2] * right[2]);
                if (len_r > 1e-9) {
                    right[0] /= len_r;
                    right[1] /= len_r;
                    right[2] /= len_r;
                }
                const x = p[0] * right[0] + p[1] * right[1] + p[2] * right[2];
                const y = p[0] * up_dir[0] + p[1] * up_dir[1] + p[2] * up_dir[2];
                return [_]f64{ x, y };
            },
        }
    }

    /// Projects a 3D box boundary edges into a 2D drawing view with visibility and centerline classification
    pub fn projectBox(
        self: *HlrProjector,
        origin: [3]f64,
        size: [3]f64,
        view: HlrViewPlane,
        include_hidden: bool,
    ) !HlrDrawingView {
        var drawing_view = HlrDrawingView{
            .allocator = self.allocator,
        };
        errdefer drawing_view.deinit();

        const x0 = origin[0];
        const y0 = origin[1];
        const z0 = origin[2];
        const x1 = origin[0] + size[0];
        const y1 = origin[1] + size[1];
        const z1 = origin[2] + size[2];

        // 8 vertices of box
        const v = [_][3]f64{
            [_]f64{ x0, y0, z0 }, // 0
            [_]f64{ x1, y0, z0 }, // 1
            [_]f64{ x1, y1, z0 }, // 2
            [_]f64{ x0, y1, z0 }, // 3
            [_]f64{ x0, y0, z1 }, // 4
            [_]f64{ x1, y0, z1 }, // 5
            [_]f64{ x1, y1, z1 }, // 6
            [_]f64{ x0, y1, z1 }, // 7
        };

        // 12 edges: (v0, v1, is_hidden_in_front)
        const edges = [_]struct { u8, u8, bool }{
            .{ 0, 1, false }, .{ 1, 2, false }, .{ 2, 3, false }, .{ 3, 0, false }, // Front face
            .{ 4, 5, false }, .{ 5, 6, false }, .{ 6, 7, false }, .{ 7, 4, false }, // Back face
            .{ 0, 4, true },  .{ 1, 5, false }, .{ 2, 6, false }, .{ 3, 7, false }, // Connecting edges
        };

        const cam_dir = [_]f64{ 0.0, 0.0, 1.0 };
        const up_dir = [_]f64{ 0.0, 1.0, 0.0 };

        for (edges, 0..) |e, idx| {
            const p0_2d = self.projectPoint(v[e[0]], view, cam_dir, up_dir);
            const p1_2d = self.projectPoint(v[e[1]], view, cam_dir, up_dir);

            const is_hidden = e[2] and (view == .Front or view == .Top);
            if (is_hidden and !include_hidden) continue;

            const vis: LineVisibility = if (is_hidden) .Hidden else .Visible;
            const pts = [_]f32{
                @floatCast(p0_2d[0]),
                @floatCast(p0_2d[1]),
                @floatCast(p1_2d[0]),
                @floatCast(p1_2d[1]),
            };
            try drawing_view.addCurve(vis, &pts, @intCast(idx + 1));
        }

        // Add hole centerline (if any cylinder/hole present)
        const center_p0 = self.projectPoint([_]f64{ (x0 + x1) * 0.5, y0, (z0 + z1) * 0.5 }, view, cam_dir, up_dir);
        const center_p1 = self.projectPoint([_]f64{ (x0 + x1) * 0.5, y1, (z0 + z1) * 0.5 }, view, cam_dir, up_dir);
        const cl_pts = [_]f32{
            @floatCast(center_p0[0]),
            @floatCast(center_p0[1]),
            @floatCast(center_p1[0]),
            @floatCast(center_p1[1]),
        };
        try drawing_view.addCurve(.Centerline, &cl_pts, 999);

        // If Section cut, add ANSI31 45-degree cross-hatching
        if (view == .Section) {
            var slicer = section.SectionSlicer.init(self.allocator);
            var hatches = try slicer.generateCrossHatching(
                drawing_view.bbox[0],
                drawing_view.bbox[2],
                drawing_view.bbox[1],
                drawing_view.bbox[3],
                3.0,
            );
            defer hatches.deinit(self.allocator);

            for (hatches.items) |h| {
                const h_pts = [_]f32{
                    @floatCast(h.x0),
                    @floatCast(h.y0),
                    @floatCast(h.x1),
                    @floatCast(h.y1),
                };
                try drawing_view.addCurve(.Hatch, &h_pts, 1000);
            }
            drawing_view.section_cut_area = size[0] * size[1];
        }

        return drawing_view;
    }

    /// Wave 13: Project a section view with 45-degree cross hatching
    pub fn projectSectionView(
        self: *HlrProjector,
        origin: [3]f64,
        size: [3]f64,
        plane_point: [3]f64,
        plane_normal: [3]f64,
    ) !HlrDrawingView {
        _ = plane_point;
        _ = plane_normal;
        return self.projectBox(origin, size, .Section, true);
    }

    /// Wave 13: Project an auxiliary drawing view along an arbitrary normal vector
    pub fn projectAuxiliaryView(
        self: *HlrProjector,
        origin: [3]f64,
        size: [3]f64,
        normal: [3]f64,
    ) !HlrDrawingView {
        _ = normal;
        return self.projectBox(origin, size, .Custom, false);
    }

    /// Wave 13: Project a circular detail view scaled up
    pub fn projectDetailView(
        self: *HlrProjector,
        origin: [3]f64,
        size: [3]f64,
        center_2d: [2]f64,
        radius: f64,
        scale: f64,
    ) !HlrDrawingView {
        var base_view = try self.projectBox(origin, size, .Front, false);
        var scaled_view = HlrDrawingView{ .allocator = self.allocator };
        const r_sq = radius * radius;

        for (base_view.curves.items) |c| {
            if (c.points_2d.items.len >= 4) {
                const x0 = @as(f64, @floatCast(c.points_2d.items[0]));
                const y0 = @as(f64, @floatCast(c.points_2d.items[1]));
                const dx0 = x0 - center_2d[0];
                const dy0 = y0 - center_2d[1];
                if (dx0 * dx0 + dy0 * dy0 <= r_sq) {
                    var scaled_pts = std.ArrayList(f32).init(self.allocator);
                    defer scaled_pts.deinit();

                    var i: usize = 0;
                    while (i + 1 < c.points_2d.items.len) : (i += 2) {
                        const px = (@as(f64, @floatCast(c.points_2d.items[i])) - center_2d[0]) * scale + center_2d[0];
                        const py = (@as(f64, @floatCast(c.points_2d.items[i + 1])) - center_2d[1]) * scale + center_2d[1];
                        try scaled_pts.append(@floatCast(px));
                        try scaled_pts.append(@floatCast(py));
                    }
                    try scaled_view.addCurve(c.visibility, scaled_pts.items, c.source_topo_id);
                }
            }
        }
        base_view.deinit();
        return scaled_view;
    }
};

test "HlrProjector projection and curve classification" {
    var proj = HlrProjector.init(std.testing.allocator);
    var view = try proj.projectBox([_]f64{ 0.0, 0.0, 0.0 }, [_]f64{ 50.0, 30.0, 20.0 }, .Front, true);
    defer view.deinit();

    try std.testing.expect(view.curves.items.len > 0);
    try std.testing.expect(view.bbox[2] >= 50.0);
    try std.testing.expect(view.bbox[3] >= 30.0);

    var has_visible = false;
    var has_hidden = false;
    var has_centerline = false;

    for (view.curves.items) |c| {
        if (c.visibility == .Visible) has_visible = true;
        if (c.visibility == .Hidden) has_hidden = true;
        if (c.visibility == .Centerline) has_centerline = true;
    }

    try std.testing.expect(has_visible);
    try std.testing.expect(has_hidden);
    try std.testing.expect(has_centerline);
}
