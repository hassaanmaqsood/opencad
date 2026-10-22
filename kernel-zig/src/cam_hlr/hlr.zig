const std = @import("std");

pub const LineVisibility = enum(u8) {
    Visible = 0,
    Hidden = 1,
    Silhouette = 2,
    Crease = 3,
};

pub const ProjectedSegment2D = struct {
    x0: f64,
    y0: f64,
    x1: f64,
    y1: f64,
    visibility: LineVisibility,
    source_edge_id: u64 = 0,
};

pub const HlrViewPlane = enum(u8) {
    FrontXY = 0,
    TopXZ = 1,
    RightYZ = 2,
    Isometric = 3,
};

pub const HlrProjector = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) HlrProjector {
        return .{ .allocator = allocator };
    }

    /// Projects 3D line segment into 2D view plane and determines visible vs hidden state
    pub fn projectSegment(
        self: *HlrProjector,
        p0: [3]f64,
        p1: [3]f64,
        view: HlrViewPlane,
        is_occluded: bool,
    ) ProjectedSegment2D {
        _ = self;
        var s2d: ProjectedSegment2D = undefined;
        switch (view) {
            .FrontXY => {
                s2d.x0 = p0[0];
                s2d.y0 = p0[1];
                s2d.x1 = p1[0];
                s2d.y1 = p1[1];
            },
            .TopXZ => {
                s2d.x0 = p0[0];
                s2d.y0 = p0[2];
                s2d.x1 = p1[0];
                s2d.y1 = p1[2];
            },
            .RightYZ => {
                s2d.x0 = p0[1];
                s2d.y0 = p0[2];
                s2d.x1 = p1[1];
                s2d.y1 = p1[2];
            },
            .Isometric => {
                // Isometric axonometric projection matrix (30 deg tilt)
                const cos30 = 0.86602540378;
                const sin30 = 0.5;
                s2d.x0 = (p0[0] - p0[2]) * cos30;
                s2d.y0 = p0[1] + (p0[0] + p0[2]) * sin30;
                s2d.x1 = (p1[0] - p1[2]) * cos30;
                s2d.y1 = p1[1] + (p1[0] + p1[2]) * sin30;
            },
        }

        s2d.visibility = if (is_occluded) .Hidden else .Visible;
        return s2d;
    }
};

test "HlrProjector front and isometric projections" {
    var hlr = HlrProjector.init(std.testing.allocator);
    const p0 = [3]f64{ 0.0, 0.0, 0.0 };
    const p1 = [3]f64{ 10.0, 20.0, 0.0 };

    const front = hlr.projectSegment(p0, p1, .FrontXY, false);
    try std.testing.expectEqual(@as(f64, 10.0), front.x1);
    try std.testing.expectEqual(@as(f64, 20.0), front.y1);
    try std.testing.expectEqual(LineVisibility.Visible, front.visibility);

    const iso = hlr.projectSegment(p0, p1, .Isometric, true);
    try std.testing.expectEqual(LineVisibility.Hidden, iso.visibility);
}
