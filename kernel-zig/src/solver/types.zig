const std = @import("std");
const c_abi = @import("../c_abi.zig");
const Vec2 = @import("../geom/vec2.zig").Vec2;

pub const CAD_SKETCH_INVALID_ID = c_abi.CAD_SKETCH_INVALID_ID;
pub const CadSketchPoint2D = c_abi.CadSketchPoint2D;
pub const CadSketchLine2D = c_abi.CadSketchLine2D;
pub const CadSketchArc2D = c_abi.CadSketchArc2D;
pub const CadSketchCircle2D = c_abi.CadSketchCircle2D;
pub const CadSketchConstraintType = c_abi.CadSketchConstraintType;
pub const CadSketchConstraint = c_abi.CadSketchConstraint;
pub const CadSolveState = c_abi.CadSolveState;
pub const CadSolverStatus = c_abi.CadSolverStatus;

/// Free variable mapping for degrees-of-freedom and Jacobian assembly.
pub const FreeVarMapping = struct {
    num_free_points: usize,
    num_free_vars: usize, // num_free_points * 2
    point_to_free: []?usize,
    free_to_point: []usize,

    pub fn init(allocator: std.mem.Allocator, points: []const CadSketchPoint2D) !FreeVarMapping {
        var point_to_free = try allocator.alloc(?usize, points.len);
        var free_count: usize = 0;

        for (points, 0..) |pt, i| {
            if (pt.is_fixed == 0) {
                point_to_free[i] = free_count;
                free_count += 1;
            } else {
                point_to_free[i] = null;
            }
        }

        var free_to_point = try allocator.alloc(usize, free_count);
        var cur: usize = 0;
        for (points, 0..) |pt, i| {
            if (pt.is_fixed == 0) {
                free_to_point[cur] = i;
                cur += 1;
            }
        }

        return .{
            .num_free_points = free_count,
            .num_free_vars = free_count * 2,
            .point_to_free = point_to_free,
            .free_to_point = free_to_point,
        };
    }

    pub fn getVarIndex(self: *const FreeVarMapping, point_idx: usize, is_y: bool) ?usize {
        if (point_idx >= self.point_to_free.len) return null;
        const free_pt = self.point_to_free[point_idx] orelse return null;
        return (free_pt * 2) + (if (is_y) @as(usize, 1) else @as(usize, 0));
    }
};

/// Fast lookup table for sketch entities.
pub const EntityRegistry = struct {
    points: []CadSketchPoint2D,
    lines: []const CadSketchLine2D,
    arcs: []const CadSketchArc2D,
    circles: []const CadSketchCircle2D,

    pub fn init(
        points: []CadSketchPoint2D,
        lines: []const CadSketchLine2D,
        arcs: []const CadSketchArc2D,
        circles: []const CadSketchCircle2D,
    ) EntityRegistry {
        return .{
            .points = points,
            .lines = lines,
            .arcs = arcs,
            .circles = circles,
        };
    }

    pub fn findPointIndex(self: *const EntityRegistry, id: u32) ?usize {
        for (self.points, 0..) |p, i| {
            if (p.id == id) return i;
        }
        return null;
    }

    pub fn findLineIndex(self: *const EntityRegistry, id: u32) ?usize {
        for (self.lines, 0..) |l, i| {
            if (l.id == id) return i;
        }
        return null;
    }

    pub fn findArcIndex(self: *const EntityRegistry, id: u32) ?usize {
        for (self.arcs, 0..) |a, i| {
            if (a.id == id) return i;
        }
        return null;
    }

    pub fn findCircleIndex(self: *const EntityRegistry, id: u32) ?usize {
        for (self.circles, 0..) |c, i| {
            if (c.id == id) return i;
        }
        return null;
    }

    pub fn getPointVec(self: *const EntityRegistry, point_idx: usize) Vec2 {
        const p = self.points[point_idx];
        return Vec2.init(p.x, p.y);
    }

    pub fn setPointVec(self: *EntityRegistry, point_idx: usize, v: Vec2) void {
        self.points[point_idx].x = v.x;
        self.points[point_idx].y = v.y;
    }
};
