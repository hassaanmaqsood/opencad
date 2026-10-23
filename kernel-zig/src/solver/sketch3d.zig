const std = @import("std");
const c_abi = @import("../c_abi.zig");
const Vec3 = @import("../math/vec3.zig").Vec3;

pub const CadSketchPoint3D = c_abi.CadSketchPoint3D;
pub const CadSketchLine3D = c_abi.CadSketchLine3D;
pub const CadSketchArc3D = c_abi.CadSketchArc3D;
pub const CadSketchSpline3D = c_abi.CadSketchSpline3D;
pub const CadSketch3DConstraintType = c_abi.CadSketch3DConstraintType;
pub const CadSketchConstraint3D = c_abi.CadSketchConstraint3D;
pub const CadSolveState = c_abi.CadSolveState;
pub const CadSolverStatus = c_abi.CadSolverStatus;

pub fn solve3D(
    points: []CadSketchPoint3D,
    lines: []const CadSketchLine3D,
    arcs: []const CadSketchArc3D,
    splines: []const CadSketchSpline3D,
    constraints: []const CadSketchConstraint3D,
    max_iterations: u32,
    convergence_tol: f64,
    out_status: *CadSolverStatus,
) !void {
    _ = arcs;
    _ = splines;

    // Fast path: if no constraints or all points fixed
    var free_points: u32 = 0;
    for (points) |pt| {
        if (pt.is_fixed == 0) free_points += 1;
    }

    if (constraints.len == 0 or free_points == 0) {
        out_status.* = .{
            .solve_state = if (constraints.len == 0 and free_points > 0) .UnderConstrained else .Solved,
            .degrees_of_freedom = free_points * 3,
            .iterations = 0,
            .max_residual = 0.0,
            .updated_coords = null,
            .coord_count = 0,
            .conflicting_constraint_ids = null,
            .conflicting_count = 0,
        };
        return;
    }

    var iter: u32 = 0;
    var max_res: f64 = 0.0;

    while (iter < max_iterations) : (iter += 1) {
        max_res = 0.0;

        for (constraints) |c| {
            var p1_idx: ?usize = null;
            var p2_idx: ?usize = null;

            for (points, 0..) |pt, i| {
                if (pt.id == c.entity1_id) p1_idx = i;
                if (pt.id == c.entity2_id) p2_idx = i;
            }

            // If entity is a line, lookup start/end
            if (p1_idx == null) {
                for (lines) |l| {
                    if (l.id == c.entity1_id) {
                        for (points, 0..) |pt, i| {
                            if (pt.id == l.start_point_id) p1_idx = i;
                            if (pt.id == l.end_point_id) p2_idx = i;
                        }
                        break;
                    }
                }
            }

            switch (c.type) {
                .AlongX => {
                    if (p1_idx != null and p2_idx != null) {
                        const idx1 = p1_idx.?;
                        const idx2 = p2_idx.?;
                        const dy = points[idx2].y - points[idx1].y;
                        const dz = points[idx2].z - points[idx1].z;
                        max_res = @max(max_res, @max(@abs(dy), @abs(dz)));

                        if (points[idx2].is_fixed == 0) {
                            points[idx2].y -= dy * 0.5;
                            points[idx2].z -= dz * 0.5;
                        }
                        if (points[idx1].is_fixed == 0) {
                            points[idx1].y += dy * 0.5;
                            points[idx1].z += dz * 0.5;
                        }
                    }
                },
                .AlongY => {
                    if (p1_idx != null and p2_idx != null) {
                        const idx1 = p1_idx.?;
                        const idx2 = p2_idx.?;
                        const dx = points[idx2].x - points[idx1].x;
                        const dz = points[idx2].z - points[idx1].z;
                        max_res = @max(max_res, @max(@abs(dx), @abs(dz)));

                        if (points[idx2].is_fixed == 0) {
                            points[idx2].x -= dx * 0.5;
                            points[idx2].z -= dz * 0.5;
                        }
                        if (points[idx1].is_fixed == 0) {
                            points[idx1].x += dx * 0.5;
                            points[idx1].z += dz * 0.5;
                        }
                    }
                },
                .AlongZ => {
                    if (p1_idx != null and p2_idx != null) {
                        const idx1 = p1_idx.?;
                        const idx2 = p2_idx.?;
                        const dx = points[idx2].x - points[idx1].x;
                        const dy = points[idx2].y - points[idx1].y;
                        max_res = @max(max_res, @max(@abs(dx), @abs(dy)));

                        if (points[idx2].is_fixed == 0) {
                            points[idx2].x -= dx * 0.5;
                            points[idx2].y -= dy * 0.5;
                        }
                        if (points[idx1].is_fixed == 0) {
                            points[idx1].x += dx * 0.5;
                            points[idx1].y += dy * 0.5;
                        }
                    }
                },
                .Distance => {
                    if (p1_idx != null and p2_idx != null) {
                        const idx1 = p1_idx.?;
                        const idx2 = p2_idx.?;
                        const dx = points[idx2].x - points[idx1].x;
                        const dy = points[idx2].y - points[idx1].y;
                        const dz = points[idx2].z - points[idx1].z;
                        const cur_dist = @sqrt(dx * dx + dy * dy + dz * dz);
                        const err = cur_dist - c.parameter_value;
                        max_res = @max(max_res, @abs(err));

                        if (cur_dist > 1e-12) {
                            const factor = 0.5 * err / cur_dist;
                            if (points[idx2].is_fixed == 0) {
                                points[idx2].x -= dx * factor;
                                points[idx2].y -= dy * factor;
                                points[idx2].z -= dz * factor;
                            }
                            if (points[idx1].is_fixed == 0) {
                                points[idx1].x += dx * factor;
                                points[idx1].y += dy * factor;
                                points[idx1].z += dz * factor;
                            }
                        }
                    }
                },
                .OnPlane => {
                    if (p1_idx != null) {
                        const idx1 = p1_idx.?;
                        const nx = c.plane_normal[0];
                        const ny = c.plane_normal[1];
                        const nz = c.plane_normal[2];
                        const dist = (points[idx1].x * nx + points[idx1].y * ny + points[idx1].z * nz) - c.parameter_value;
                        max_res = @max(max_res, @abs(dist));

                        if (points[idx1].is_fixed == 0) {
                            points[idx1].x -= dist * nx;
                            points[idx1].y -= dist * ny;
                            points[idx1].z -= dist * nz;
                        }
                    }
                },
                else => {},
            }
        }

        if (max_res <= convergence_tol) break;
    }

    const dof = getDof3D(@intCast(points.len), lines.len, constraints.len);

    out_status.* = .{
        .solve_state = if (max_res <= convergence_tol) (if (dof == 0) .Solved else .UnderConstrained) else .Conflicting,
        .degrees_of_freedom = dof,
        .iterations = iter,
        .max_residual = max_res,
        .updated_coords = null,
        .coord_count = 0,
        .conflicting_constraint_ids = null,
        .conflicting_count = 0,
    };
}

pub fn getDof3D(point_count: u32, line_count: usize, constraint_count: usize) u32 {
    _ = line_count;
    const total_vars = point_count * 3;
    const eq_count: u32 = @intCast(constraint_count);
    if (total_vars > eq_count) {
        return total_vars - eq_count;
    }
    return 0;
}

// ---------------------------------------------------------------------------
// Unit Tests
// ---------------------------------------------------------------------------

test "Sketch3D - AlongX and Distance Constraint" {
    var pts = [_]CadSketchPoint3D{
        .{ .id = 1, .x = 0.0, .y = 0.0, .z = 0.0, .is_fixed = 1, .is_construction = 0 },
        .{ .id = 2, .x = 5.0, .y = 2.0, .z = 3.0, .is_fixed = 0, .is_construction = 0 },
    };

    const constraints = [_]CadSketchConstraint3D{
        .{
            .id = 101,
            .type = .AlongX,
            .entity1_id = 1,
            .entity2_id = 2,
            .parameter_value = 0.0,
            .plane_normal = [_]f64{ 0, 0, 0 },
            .is_driving = 1,
        },
        .{
            .id = 102,
            .type = .Distance,
            .entity1_id = 1,
            .entity2_id = 2,
            .parameter_value = 10.0,
            .plane_normal = [_]f64{ 0, 0, 0 },
            .is_driving = 1,
        },
    };

    var status: CadSolverStatus = undefined;
    try solve3D(&pts, &[_]CadSketchLine3D{}, &[_]CadSketchArc3D{}, &[_]CadSketchSpline3D{}, &constraints, 50, 1e-6, &status);

    try std.testing.expectEqual(CadSolveState.UnderConstrained, status.solve_state);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), pts[1].y, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), pts[1].z, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), pts[1].x, 1e-4);
}
