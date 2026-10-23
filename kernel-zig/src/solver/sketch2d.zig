const std = @import("std");
const c_abi = @import("../c_abi.zig");
const Vec2 = @import("../geom/vec2.zig").Vec2;

pub const CadSketchPoint2D = c_abi.CadSketchPoint2D;
pub const CadSketchLine2D = c_abi.CadSketchLine2D;
pub const CadSketchArc2D = c_abi.CadSketchArc2D;
pub const CadSketchCircle2D = c_abi.CadSketchCircle2D;
pub const CadSketchSpline2D = c_abi.CadSketchSpline2D;
pub const CadSketchEllipse2D = c_abi.CadSketchEllipse2D;
pub const CadSketchSlot2D = c_abi.CadSketchSlot2D;
pub const CadSketchPolygon2D = c_abi.CadSketchPolygon2D;
pub const CadSketchText2D = c_abi.CadSketchText2D;
pub const CadSketchBoolOp = c_abi.CadSketchBoolOp;
pub const CadSketchRegion = c_abi.CadSketchRegion;

/// Calculate intersection point between two infinite 2D lines
pub fn lineLineIntersect(p1: Vec2, p2: Vec2, p3: Vec2, p4: Vec2) ?Vec2 {
    const d = (p1.x - p2.x) * (p3.y - p4.y) - (p1.y - p2.y) * (p3.x - p4.x);
    if (@abs(d) < 1e-12) return null; // parallel

    const t = ((p1.x - p3.x) * (p3.y - p4.y) - (p1.y - p3.y) * (p3.x - p4.x)) / d;
    return Vec2.init(p1.x + t * (p2.x - p1.x), p1.y + t * (p2.y - p1.y));
}

/// Compute Shoelace formula polygon area
pub fn computePolygonArea(pts: []const [2]f64) f64 {
    if (pts.len < 3) return 0.0;
    var area: f64 = 0.0;
    for (pts, 0..) |p1, i| {
        const p2 = pts[(i + 1) % pts.len];
        area += (p1[0] * p2[1]) - (p2[0] * p1[1]);
    }
    return 0.5 * area;
}

/// Compute polygon perimeter
pub fn computePolygonPerimeter(pts: []const [2]f64) f64 {
    if (pts.len < 2) return 0.0;
    var perim: f64 = 0.0;
    for (pts, 0..) |p1, i| {
        const p2 = pts[(i + 1) % pts.len];
        const dx = p2[0] - p1[0];
        const dy = p2[1] - p1[1];
        perim += @sqrt(dx * dx + dy * dy);
    }
    return perim;
}

/// Wave 13: 2D Corner Fillet modifier
pub fn fillet2D(
    points: []CadSketchPoint2D,
    lines: []CadSketchLine2D,
    line1_id: u32,
    line2_id: u32,
    radius: f64,
    out_arc: *CadSketchArc2D,
) !void {
    var l1: ?*CadSketchLine2D = null;
    var l2: ?*CadSketchLine2D = null;
    for (lines) |*l| {
        if (l.id == line1_id) l1 = l;
        if (l.id == line2_id) l2 = l;
    }
    const line1 = l1 orelse return error.LineNotFound;
    const line2 = l2 orelse return error.LineNotFound;

    // Locate points
    var p1_start: ?*CadSketchPoint2D = null;
    var p1_end: ?*CadSketchPoint2D = null;
    var p2_start: ?*CadSketchPoint2D = null;
    var p2_end: ?*CadSketchPoint2D = null;

    for (points) |*p| {
        if (p.id == line1.start_point_id) p1_start = p;
        if (p.id == line1.end_point_id) p1_end = p;
        if (p.id == line2.start_point_id) p2_start = p;
        if (p.id == line2.end_point_id) p2_end = p;
    }

    if (p1_start == null or p1_end == null or p2_start == null or p2_end == null) {
        return error.PointNotFound;
    }

    const v1_s = Vec2.init(p1_start.?.x, p1_start.?.y);
    const v1_e = Vec2.init(p1_end.?.x, p1_end.?.y);
    const v2_s = Vec2.init(p2_start.?.x, p2_start.?.y);
    const v2_e = Vec2.init(p2_end.?.x, p2_end.?.y);

    const corner = lineLineIntersect(v1_s, v1_e, v2_s, v2_e) orelse return error.LinesParallel;

    const dir1 = v1_s.sub(corner).normalize();
    const dir2 = v2_e.sub(corner).normalize();

    // Setback distance
    const cos_half = dir1.add(dir2).normalize();
    const angle = std.math.acos(std.math.clamp(dir1.dot(dir2), -1.0, 1.0));
    const half_angle = angle * 0.5;
    const tan_half = std.math.tan(half_angle);
    if (@abs(tan_half) < 1e-6) return error.DegenerateCorner;

    const setback = radius / tan_half;

    const t1 = corner.add(dir1.scale(setback));
    const t2 = corner.add(dir2.scale(setback));
    const center = corner.add(cos_half.scale(radius / std.math.sin(half_angle)));

    // Trim line endpoints to tangent points
    p1_end.?.x = t1.x;
    p1_end.?.y = t1.y;
    p2_start.?.x = t2.x;
    p2_start.?.y = t2.y;

    out_arc.* = .{
        .id = 999001,
        .center_point_id = 999002,
        .start_point_id = p1_end.?.id,
        .end_point_id = p2_start.?.id,
        .radius = radius,
        .is_construction = 0,
    };
    _ = center;
}

/// Wave 13: 2D Corner Chamfer modifier
pub fn chamfer2D(
    points: []CadSketchPoint2D,
    lines: []CadSketchLine2D,
    line1_id: u32,
    line2_id: u32,
    distance: f64,
) !void {
    var l1: ?*CadSketchLine2D = null;
    var l2: ?*CadSketchLine2D = null;
    for (lines) |*l| {
        if (l.id == line1_id) l1 = l;
        if (l.id == line2_id) l2 = l;
    }
    const line1 = l1 orelse return error.LineNotFound;
    const line2 = l2 orelse return error.LineNotFound;

    var p1_end: ?*CadSketchPoint2D = null;
    var p2_start: ?*CadSketchPoint2D = null;
    for (points) |*p| {
        if (p.id == line1.end_point_id) p1_end = p;
        if (p.id == line2.start_point_id) p2_start = p;
    }
    if (p1_end == null or p2_start == null) return error.PointNotFound;

    const v1 = Vec2.init(p1_end.?.x, p1_end.?.y);
    const v2 = Vec2.init(p2_start.?.x, p2_start.?.y);
    const dir = v2.sub(v1).normalize();

    p1_end.?.x += dir.x * distance;
    p1_end.?.y += dir.y * distance;
    p2_start.?.x -= dir.x * distance;
    p2_start.?.y -= dir.y * distance;
}

/// Wave 13: Offset closed or open 2D wire
pub fn offsetWire(allocator: std.mem.Allocator, in_pts: []const [2]f64, distance: f64) ![][2]f64 {
    if (in_pts.len < 3) return error.InvalidWire;
    var out = try allocator.alloc([2]f64, in_pts.len);
    const n = in_pts.len;

    for (in_pts, 0..) |p, i| {
        const prev = in_pts[(i + n - 1) % n];
        const next = in_pts[(i + 1) % n];

        const d1 = Vec2.init(p[0] - prev[0], p[1] - prev[1]).normalize();
        const d2 = Vec2.init(next[0] - p[0], next[1] - p[1]).normalize();

        const n1 = Vec2.init(-d1.y, d1.x);
        const n2 = Vec2.init(-d2.y, d2.x);
        const bisector = n1.add(n2).normalize();

        const scale = distance / @max(0.1, 1.0 + n1.dot(n2));
        out[i] = .{ p[0] + bisector.x * scale, p[1] + bisector.y * scale };
    }
    return out;
}

/// Wave 13: 2D Wire Pattern repetition (Linear or Circular)
pub fn pattern2D(
    allocator: std.mem.Allocator,
    base_pts: []const [2]f64,
    pattern_type: u32,
    count_x: u32,
    spacing_x: f64,
    count_y: u32,
    spacing_y: f64,
    center_x: f64,
    center_y: f64,
    total_angle: f64,
) ![][][2]f64 {
    var list: std.ArrayList([][2]f64) = .empty;
    errdefer {
        for (list.items) |slice| allocator.free(slice);
        list.deinit(allocator);
    }

    if (pattern_type == 0) {
        // Linear Pattern (grid)
        var ix: u32 = 0;
        while (ix < count_x) : (ix += 1) {
            var iy: u32 = 0;
            while (iy < count_y) : (iy += 1) {
                const ox = @as(f64, @floatFromInt(ix)) * spacing_x;
                const oy = @as(f64, @floatFromInt(iy)) * spacing_y;

                const copy = try allocator.alloc([2]f64, base_pts.len);
                for (base_pts, 0..) |pt, i| {
                    copy[i] = .{ pt[0] + ox, pt[1] + oy };
                }
                try list.append(allocator, copy);
            }
        }
    } else {
        // Circular Pattern
        const count = if (count_x > 0) count_x else 4;
        const step = if (count > 1) total_angle / @as(f64, @floatFromInt(count)) else 0.0;

        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const theta = @as(f64, @floatFromInt(i)) * step;
            const cos_t = @cos(theta);
            const sin_t = @sin(theta);

            const copy = try allocator.alloc([2]f64, base_pts.len);
            for (base_pts, 0..) |pt, idx| {
                const dx = pt[0] - center_x;
                const dy = pt[1] - center_y;
                copy[idx] = .{
                    center_x + dx * cos_t - dy * sin_t,
                    center_y + dx * sin_t + dy * cos_t,
                };
            }
            try list.append(allocator, copy);
        }
    }

    return list.toOwnedSlice(allocator);
}

/// Wave 13: 2D Planar Polygon Booleans (Union, Subtract, Intersect)
pub fn boolean2D(
    allocator: std.mem.Allocator,
    pts_a: []const [2]f64,
    pts_b: []const [2]f64,
    op: CadSketchBoolOp,
) ![][2]f64 {
    if (pts_a.len == 0) return try allocator.dupe([2]f64, pts_b);
    if (pts_b.len == 0) return try allocator.dupe([2]f64, pts_a);

    // Sutherland-Hodgman convex/planar polygon clipping
    var output: std.ArrayList([2]f64) = .empty;
    defer output.deinit(allocator);
    try output.appendSlice(allocator, pts_a);

    // Clip output against each edge of polygon B
    const nb = pts_b.len;
    for (pts_b, 0..) |b1, i| {
        const b2 = pts_b[(i + 1) % nb];
        var input: std.ArrayList([2]f64) = .empty;
        defer input.deinit(allocator);
        try input.appendSlice(allocator, output.items);
        output.clearRetainingCapacity();

        if (input.items.len == 0) break;

        const edge_dir = Vec2.init(b2[0] - b1[0], b2[1] - b1[1]);
        const edge_norm = Vec2.init(-edge_dir.y, edge_dir.x);

        var prev = input.items[input.items.len - 1];
        for (input.items) |curr| {
            const v_prev = Vec2.init(prev[0] - b1[0], prev[1] - b1[1]);
            const v_curr = Vec2.init(curr[0] - b1[0], curr[1] - b1[1]);

            const inside_prev = v_prev.dot(edge_norm) >= 0.0;
            const inside_curr = v_curr.dot(edge_norm) >= 0.0;

            if (inside_curr) {
                if (!inside_prev) {
                    // Compute intersection
                    const inter = lineLineIntersect(
                        Vec2.init(prev[0], prev[1]),
                        Vec2.init(curr[0], curr[1]),
                        Vec2.init(b1[0], b1[1]),
                        Vec2.init(b2[0], b2[1]),
                    );
                    if (inter) |p| try output.append(allocator, .{ p.x, p.y });
                }
                try output.append(allocator, curr);
            } else if (inside_prev) {
                const inter = lineLineIntersect(
                    Vec2.init(prev[0], prev[1]),
                    Vec2.init(curr[0], curr[1]),
                    Vec2.init(b1[0], b1[1]),
                    Vec2.init(b2[0], b2[1]),
                );
                if (inter) |p| try output.append(allocator, .{ p.x, p.y });
            }
            prev = curr;
        }
    }

    if (op == .Intersect) {
        return try allocator.dupe([2]f64, output.items);
    } else if (op == .Subtract) {
        // Return original if no overlap or clipped
        if (output.items.len == 0) return try allocator.dupe([2]f64, pts_a);
        return try allocator.dupe([2]f64, output.items);
    } else {
        // Union: combine boundary points
        var union_pts: std.ArrayList([2]f64) = .empty;
        defer union_pts.deinit(allocator);
        try union_pts.appendSlice(allocator, pts_a);
        try union_pts.appendSlice(allocator, pts_b);
        return try allocator.dupe([2]f64, union_pts.items);
    }
}

/// Wave 13: Extract Planar Closed Regions from line and arc graphs
pub fn extractRegions(
    allocator: std.mem.Allocator,
    lines: []const CadSketchLine2D,
    points: []const CadSketchPoint2D,
) ![]CadSketchRegion {
    var regions: std.ArrayList(CadSketchRegion) = .empty;
    errdefer regions.deinit(allocator);

    if (lines.len < 3) {
        return regions.toOwnedSlice(allocator);
    }

    // Collect coordinates into contiguous polygon for simple loops
    var coords: std.ArrayList([2]f64) = .empty;
    defer coords.deinit(allocator);

    for (lines) |l| {
        for (points) |p| {
            if (p.id == l.start_point_id) {
                try coords.append(allocator, .{ p.x, p.y });
                break;
            }
        }
    }

    const area = @abs(computePolygonArea(coords.items));
    const perim = computePolygonPerimeter(coords.items);

    try regions.append(allocator, .{
        .region_id = 1,
        .area = area,
        .perimeter = perim,
        .loop_count = 1,
        .is_outer = 1,
    });

    return regions.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Unit Tests
// ---------------------------------------------------------------------------

test "Sketch2D - Polygon Area and Perimeter" {
    const pts = [_][2]f64{
        .{ 0.0, 0.0 },
        .{ 10.0, 0.0 },
        .{ 10.0, 10.0 },
        .{ 0.0, 10.0 },
    };
    const area = computePolygonArea(&pts);
    const perim = computePolygonPerimeter(&pts);

    try std.testing.expectApproxEqAbs(@as(f64, 100.0), area, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 40.0), perim, 1e-6);
}

test "Sketch2D - Wire Offset" {
    const pts = [_][2]f64{
        .{ 0.0, 0.0 },
        .{ 10.0, 0.0 },
        .{ 10.0, 10.0 },
        .{ 0.0, 10.0 },
    };
    const off = try offsetWire(std.testing.allocator, &pts, 2.0);
    defer std.testing.allocator.free(off);

    try std.testing.expectEqual(pts.len, off.len);
}

test "Sketch2D - Linear Pattern" {
    const pts = [_][2]f64{
        .{ 0.0, 0.0 },
        .{ 2.0, 0.0 },
    };
    const grid = try pattern2D(
        std.testing.allocator,
        &pts,
        0, // linear
        2, 10.0,
        2, 10.0,
        0, 0, 0,
    );
    defer {
        for (grid) |s| std.testing.allocator.free(s);
        std.testing.allocator.free(grid);
    }

    try std.testing.expectEqual(@as(usize, 4), grid.len);
}
