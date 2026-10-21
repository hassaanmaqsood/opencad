const std = @import("std");
const types = @import("types.zig");
const Vec2 = @import("../geom/vec2.zig").Vec2;

pub const EquationKind = enum {
    coincident_x,
    coincident_y,
    point_on_line,
    point_on_circle,
    horizontal,
    vertical,
    distance_pt_pt,
    distance_pt_line,
    parallel,
    perpendicular,
    equal_length,
    equal_radius,
    angle,
    radius,
    tangent_line_circle,
    tangent_circle_circle,
    symmetric_midpoint,
    symmetric_perp,
};

pub const Equation = struct {
    constraint_id: u32,
    kind: EquationKind,
    p1: usize,
    p2: usize,
    p3: usize = 0,
    p4: usize = 0,
    param: f64 = 0.0,
    aux: f64 = 1.0,
};

pub fn evalResidual(eq: Equation, points: []const types.CadSketchPoint2D) f64 {
    const EPS: f64 = 1e-12;

    switch (eq.kind) {
        .coincident_x => {
            return points[eq.p1].x - points[eq.p2].x;
        },
        .coincident_y => {
            return points[eq.p1].y - points[eq.p2].y;
        },
        .point_on_line => {
            const P = Vec2.init(points[eq.p1].x, points[eq.p1].y);
            const A = Vec2.init(points[eq.p2].x, points[eq.p2].y);
            const B = Vec2.init(points[eq.p3].x, points[eq.p3].y);
            const v = B.sub(A);
            const L = @max(v.norm(), EPS);
            return ((P.x - A.x) * v.y - (P.y - A.y) * v.x) / L;
        },
        .point_on_circle => {
            const P = Vec2.init(points[eq.p1].x, points[eq.p1].y);
            const C = Vec2.init(points[eq.p2].x, points[eq.p2].y);
            return P.dist(C) - eq.param;
        },
        .horizontal => {
            return points[eq.p2].y - points[eq.p1].y;
        },
        .vertical => {
            return points[eq.p2].x - points[eq.p1].x;
        },
        .distance_pt_pt => {
            const P1 = Vec2.init(points[eq.p1].x, points[eq.p1].y);
            const P2 = Vec2.init(points[eq.p2].x, points[eq.p2].y);
            return P1.dist(P2) - eq.param;
        },
        .distance_pt_line => {
            const P = Vec2.init(points[eq.p1].x, points[eq.p1].y);
            const A = Vec2.init(points[eq.p2].x, points[eq.p2].y);
            const B = Vec2.init(points[eq.p3].x, points[eq.p3].y);
            const v = B.sub(A);
            const L = @max(v.norm(), EPS);
            const h = ((P.x - A.x) * v.y - (P.y - A.y) * v.x) / L;
            return h - (eq.aux * eq.param);
        },
        .parallel => {
            const P1 = Vec2.init(points[eq.p1].x, points[eq.p1].y);
            const P2 = Vec2.init(points[eq.p2].x, points[eq.p2].y);
            const P3 = Vec2.init(points[eq.p3].x, points[eq.p3].y);
            const P4 = Vec2.init(points[eq.p4].x, points[eq.p4].y);
            const v1 = P2.sub(P1);
            const v2 = P4.sub(P3);
            const dir1 = v1.normalize();
            const dir2 = v2.normalize();
            return dir1.cross(dir2);
        },
        .perpendicular => {
            const P1 = Vec2.init(points[eq.p1].x, points[eq.p1].y);
            const P2 = Vec2.init(points[eq.p2].x, points[eq.p2].y);
            const P3 = Vec2.init(points[eq.p3].x, points[eq.p3].y);
            const P4 = Vec2.init(points[eq.p4].x, points[eq.p4].y);
            const v1 = P2.sub(P1);
            const v2 = P4.sub(P3);
            const dir1 = v1.normalize();
            const dir2 = v2.normalize();
            return dir1.dot(dir2);
        },
        .equal_length => {
            const P1 = Vec2.init(points[eq.p1].x, points[eq.p1].y);
            const P2 = Vec2.init(points[eq.p2].x, points[eq.p2].y);
            const P3 = Vec2.init(points[eq.p3].x, points[eq.p3].y);
            const P4 = Vec2.init(points[eq.p4].x, points[eq.p4].y);
            return P1.dist(P2) - P3.dist(P4);
        },
        .equal_radius => {
            const C1 = Vec2.init(points[eq.p1].x, points[eq.p1].y);
            const S1 = Vec2.init(points[eq.p2].x, points[eq.p2].y);
            const C2 = Vec2.init(points[eq.p3].x, points[eq.p3].y);
            const S2 = Vec2.init(points[eq.p4].x, points[eq.p4].y);
            return C1.dist(S1) - C2.dist(S2);
        },
        .angle => {
            const P1 = Vec2.init(points[eq.p1].x, points[eq.p1].y);
            const P2 = Vec2.init(points[eq.p2].x, points[eq.p2].y);
            const P3 = Vec2.init(points[eq.p3].x, points[eq.p3].y);
            const P4 = Vec2.init(points[eq.p4].x, points[eq.p4].y);
            const v1 = P2.sub(P1);
            const v2 = P4.sub(P3);
            const dir1 = v1.normalize();
            const dir2 = v2.normalize();
            const theta = eq.param;
            const cos_t = @cos(theta);
            const sin_t = @sin(theta);
            return dir1.cross(dir2) * cos_t - dir1.dot(dir2) * sin_t;
        },
        .radius => {
            const C = Vec2.init(points[eq.p1].x, points[eq.p1].y);
            const P = Vec2.init(points[eq.p2].x, points[eq.p2].y);
            return C.dist(P) - eq.param;
        },
        .tangent_line_circle => {
            const A = Vec2.init(points[eq.p1].x, points[eq.p1].y);
            const B = Vec2.init(points[eq.p2].x, points[eq.p2].y);
            const C = Vec2.init(points[eq.p3].x, points[eq.p3].y);
            const v = B.sub(A);
            const L = @max(v.norm(), EPS);
            const h = ((C.x - A.x) * v.y - (C.y - A.y) * v.x) / L;
            return h - (eq.aux * eq.param);
        },
        .tangent_circle_circle => {
            const C1 = Vec2.init(points[eq.p1].x, points[eq.p1].y);
            const C2 = Vec2.init(points[eq.p2].x, points[eq.p2].y);
            return C1.dist(C2) - eq.param;
        },
        .symmetric_midpoint => {
            const P1 = Vec2.init(points[eq.p1].x, points[eq.p1].y);
            const P2 = Vec2.init(points[eq.p2].x, points[eq.p2].y);
            const A = Vec2.init(points[eq.p3].x, points[eq.p3].y);
            const B = Vec2.init(points[eq.p4].x, points[eq.p4].y);
            const M = P1.add(P2).scale(0.5);
            const v = B.sub(A);
            const L = @max(v.norm(), EPS);
            return ((M.x - A.x) * v.y - (M.y - A.y) * v.x) / L;
        },
        .symmetric_perp => {
            const P1 = Vec2.init(points[eq.p1].x, points[eq.p1].y);
            const P2 = Vec2.init(points[eq.p2].x, points[eq.p2].y);
            const A = Vec2.init(points[eq.p3].x, points[eq.p3].y);
            const B = Vec2.init(points[eq.p4].x, points[eq.p4].y);
            const seg = P2.sub(P1);
            const axis = B.sub(A);
            const L = @max(axis.norm(), EPS);
            return seg.dot(axis) / L;
        },
    }
}

/// Compiles user-level constraints into low-level solver equations.
pub fn compileEquations(
    allocator: std.mem.Allocator,
    registry: *const types.EntityRegistry,
    constraints: []const types.CadSketchConstraint,
) ![]Equation {
    var eq_list = std.ArrayList(Equation).empty;

    for (constraints) |con| {
        if (con.is_driving == 0) continue;

        switch (con.type) {
            .Coincident => {
                // Check if point-point or point-line or point-circle
                const p1_opt = registry.findPointIndex(con.entity1_id);
                const p2_opt = registry.findPointIndex(con.entity2_id);

                if (p1_opt) |p1| {
                    if (p2_opt) |p2| {
                        // Point - Point
                        try eq_list.append(allocator,.{
                            .constraint_id = con.id,
                            .kind = .coincident_x,
                            .p1 = p1,
                            .p2 = p2,
                        });
                        try eq_list.append(allocator,.{
                            .constraint_id = con.id,
                            .kind = .coincident_y,
                            .p1 = p1,
                            .p2 = p2,
                        });
                    } else if (registry.findLineIndex(con.entity2_id)) |l_idx| {
                        // Point on Line
                        const line = registry.lines[l_idx];
                        const lp1 = registry.findPointIndex(line.start_point_id) orelse continue;
                        const lp2 = registry.findPointIndex(line.end_point_id) orelse continue;
                        try eq_list.append(allocator,.{
                            .constraint_id = con.id,
                            .kind = .point_on_line,
                            .p1 = p1,
                            .p2 = lp1,
                            .p3 = lp2,
                        });
                    } else if (registry.findCircleIndex(con.entity2_id)) |c_idx| {
                        // Point on Circle
                        const circle = registry.circles[c_idx];
                        const cp = registry.findPointIndex(circle.center_point_id) orelse continue;
                        try eq_list.append(allocator,.{
                            .constraint_id = con.id,
                            .kind = .point_on_circle,
                            .p1 = p1,
                            .p2 = cp,
                            .param = circle.radius,
                        });
                    }
                }
            },
            .Horizontal => {
                var p1: usize = 0;
                var p2: usize = 0;
                if (con.entity2_id != types.CAD_SKETCH_INVALID_ID) {
                    p1 = registry.findPointIndex(con.entity1_id) orelse continue;
                    p2 = registry.findPointIndex(con.entity2_id) orelse continue;
                } else if (registry.findLineIndex(con.entity1_id)) |l_idx| {
                    const line = registry.lines[l_idx];
                    p1 = registry.findPointIndex(line.start_point_id) orelse continue;
                    p2 = registry.findPointIndex(line.end_point_id) orelse continue;
                } else {
                    continue;
                }
                try eq_list.append(allocator, .{
                    .constraint_id = con.id,
                    .kind = .horizontal,
                    .p1 = p1,
                    .p2 = p2,
                });
            },
            .Vertical => {
                var p1: usize = 0;
                var p2: usize = 0;
                if (con.entity2_id != types.CAD_SKETCH_INVALID_ID) {
                    p1 = registry.findPointIndex(con.entity1_id) orelse continue;
                    p2 = registry.findPointIndex(con.entity2_id) orelse continue;
                } else if (registry.findLineIndex(con.entity1_id)) |l_idx| {
                    const line = registry.lines[l_idx];
                    p1 = registry.findPointIndex(line.start_point_id) orelse continue;
                    p2 = registry.findPointIndex(line.end_point_id) orelse continue;
                } else {
                    continue;
                }
                try eq_list.append(allocator, .{
                    .constraint_id = con.id,
                    .kind = .vertical,
                    .p1 = p1,
                    .p2 = p2,
                });
            },
            .Distance => {
                // If entity2_id is provided, it connects entity1 to entity2 (point-point or point-line)
                if (con.entity2_id != types.CAD_SKETCH_INVALID_ID) {
                    if (registry.findPointIndex(con.entity1_id)) |p1| {
                        if (registry.findPointIndex(con.entity2_id)) |p2| {
                            // Point to Point
                            try eq_list.append(allocator, .{
                                .constraint_id = con.id,
                                .kind = .distance_pt_pt,
                                .p1 = p1,
                                .p2 = p2,
                                .param = con.parameter_value,
                            });
                        } else if (registry.findLineIndex(con.entity2_id)) |l_idx| {
                            // Point to Line
                            const line = registry.lines[l_idx];
                            const lp1 = registry.findPointIndex(line.start_point_id) orelse continue;
                            const lp2 = registry.findPointIndex(line.end_point_id) orelse continue;

                            const P = Vec2.init(registry.points[p1].x, registry.points[p1].y);
                            const A = Vec2.init(registry.points[lp1].x, registry.points[lp1].y);
                            const B = Vec2.init(registry.points[lp2].x, registry.points[lp2].y);
                            const v = B.sub(A);
                            const L = @max(v.norm(), 1e-12);
                            const signed_h = ((P.x - A.x) * v.y - (P.y - A.y) * v.x) / L;
                            const side: f64 = if (signed_h < 0.0) -1.0 else 1.0;

                            try eq_list.append(allocator, .{
                                .constraint_id = con.id,
                                .kind = .distance_pt_line,
                                .p1 = p1,
                                .p2 = lp1,
                                .p3 = lp2,
                                .param = con.parameter_value,
                                .aux = side,
                            });
                        }
                    }
                } else if (registry.findLineIndex(con.entity1_id)) |l_idx| {
                    // Line length constraint
                    const line = registry.lines[l_idx];
                    const p1 = registry.findPointIndex(line.start_point_id) orelse continue;
                    const p2 = registry.findPointIndex(line.end_point_id) orelse continue;
                    try eq_list.append(allocator, .{
                        .constraint_id = con.id,
                        .kind = .distance_pt_pt,
                        .p1 = p1,
                        .p2 = p2,
                        .param = con.parameter_value,
                    });
                }
            },
            .Parallel => {
                var p1: usize = 0;
                var p2: usize = 0;
                var p3: usize = 0;
                var p4: usize = 0;

                if (registry.findLineIndex(con.entity1_id)) |l1| {
                    p1 = registry.findPointIndex(registry.lines[l1].start_point_id) orelse continue;
                    p2 = registry.findPointIndex(registry.lines[l1].end_point_id) orelse continue;
                } else {
                    p1 = registry.findPointIndex(con.entity1_id) orelse continue;
                    p2 = registry.findPointIndex(con.entity2_id) orelse continue;
                }

                if (registry.findLineIndex(con.entity2_id)) |l2| {
                    p3 = registry.findPointIndex(registry.lines[l2].start_point_id) orelse continue;
                    p4 = registry.findPointIndex(registry.lines[l2].end_point_id) orelse continue;
                } else {
                    p3 = registry.findPointIndex(con.entity3_id) orelse continue;
                    p4 = registry.findPointIndex(con.entity4_id) orelse continue;
                }

                try eq_list.append(allocator,.{
                    .constraint_id = con.id,
                    .kind = .parallel,
                    .p1 = p1,
                    .p2 = p2,
                    .p3 = p3,
                    .p4 = p4,
                });
            },
            .Perpendicular => {
                var p1: usize = 0;
                var p2: usize = 0;
                var p3: usize = 0;
                var p4: usize = 0;

                if (registry.findLineIndex(con.entity1_id)) |l1| {
                    p1 = registry.findPointIndex(registry.lines[l1].start_point_id) orelse continue;
                    p2 = registry.findPointIndex(registry.lines[l1].end_point_id) orelse continue;
                } else {
                    p1 = registry.findPointIndex(con.entity1_id) orelse continue;
                    p2 = registry.findPointIndex(con.entity2_id) orelse continue;
                }

                if (registry.findLineIndex(con.entity2_id)) |l2| {
                    p3 = registry.findPointIndex(registry.lines[l2].start_point_id) orelse continue;
                    p4 = registry.findPointIndex(registry.lines[l2].end_point_id) orelse continue;
                } else {
                    p3 = registry.findPointIndex(con.entity3_id) orelse continue;
                    p4 = registry.findPointIndex(con.entity4_id) orelse continue;
                }

                try eq_list.append(allocator,.{
                    .constraint_id = con.id,
                    .kind = .perpendicular,
                    .p1 = p1,
                    .p2 = p2,
                    .p3 = p3,
                    .p4 = p4,
                });
            },
            .Equal => {
                // Lines or circles/arcs
                if (registry.findLineIndex(con.entity1_id)) |l1| {
                    if (registry.findLineIndex(con.entity2_id)) |l2| {
                        const p1 = registry.findPointIndex(registry.lines[l1].start_point_id) orelse continue;
                        const p2 = registry.findPointIndex(registry.lines[l1].end_point_id) orelse continue;
                        const p3 = registry.findPointIndex(registry.lines[l2].start_point_id) orelse continue;
                        const p4 = registry.findPointIndex(registry.lines[l2].end_point_id) orelse continue;
                        try eq_list.append(allocator,.{
                            .constraint_id = con.id,
                            .kind = .equal_length,
                            .p1 = p1,
                            .p2 = p2,
                            .p3 = p3,
                            .p4 = p4,
                        });
                    }
                } else if (registry.findArcIndex(con.entity1_id)) |a1| {
                    if (registry.findArcIndex(con.entity2_id)) |a2| {
                        const arc1 = registry.arcs[a1];
                        const arc2 = registry.arcs[a2];
                        const c1 = registry.findPointIndex(arc1.center_point_id) orelse continue;
                        const s1 = registry.findPointIndex(arc1.start_point_id) orelse continue;
                        const c2 = registry.findPointIndex(arc2.center_point_id) orelse continue;
                        const s2 = registry.findPointIndex(arc2.start_point_id) orelse continue;
                        try eq_list.append(allocator,.{
                            .constraint_id = con.id,
                            .kind = .equal_radius,
                            .p1 = c1,
                            .p2 = s1,
                            .p3 = c2,
                            .p4 = s2,
                        });
                    }
                }
            },
            .Symmetric => {
                const p1 = registry.findPointIndex(con.entity1_id) orelse continue;
                const p2 = registry.findPointIndex(con.entity2_id) orelse continue;
                var p3: usize = 0;
                var p4: usize = 0;

                if (registry.findLineIndex(con.entity3_id)) |l_idx| {
                    p3 = registry.findPointIndex(registry.lines[l_idx].start_point_id) orelse continue;
                    p4 = registry.findPointIndex(registry.lines[l_idx].end_point_id) orelse continue;
                } else {
                    p3 = registry.findPointIndex(con.entity3_id) orelse continue;
                    p4 = registry.findPointIndex(con.entity4_id) orelse continue;
                }

                try eq_list.append(allocator,.{
                    .constraint_id = con.id,
                    .kind = .symmetric_midpoint,
                    .p1 = p1,
                    .p2 = p2,
                    .p3 = p3,
                    .p4 = p4,
                });
                try eq_list.append(allocator,.{
                    .constraint_id = con.id,
                    .kind = .symmetric_perp,
                    .p1 = p1,
                    .p2 = p2,
                    .p3 = p3,
                    .p4 = p4,
                });
            },
            .Angle => {
                var p1: usize = 0;
                var p2: usize = 0;
                var p3: usize = 0;
                var p4: usize = 0;

                if (registry.findLineIndex(con.entity1_id)) |l1| {
                    p1 = registry.findPointIndex(registry.lines[l1].start_point_id) orelse continue;
                    p2 = registry.findPointIndex(registry.lines[l1].end_point_id) orelse continue;
                } else {
                    p1 = registry.findPointIndex(con.entity1_id) orelse continue;
                    p2 = registry.findPointIndex(con.entity2_id) orelse continue;
                }

                if (registry.findLineIndex(con.entity2_id)) |l2| {
                    p3 = registry.findPointIndex(registry.lines[l2].start_point_id) orelse continue;
                    p4 = registry.findPointIndex(registry.lines[l2].end_point_id) orelse continue;
                } else if (con.entity4_id != types.CAD_SKETCH_INVALID_ID) {
                    p3 = registry.findPointIndex(con.entity3_id) orelse continue;
                    p4 = registry.findPointIndex(con.entity4_id) orelse continue;
                } else if (con.entity3_id != types.CAD_SKETCH_INVALID_ID) {
                    // 3-point angle: p2 is vertex
                    p3 = p2;
                    p4 = registry.findPointIndex(con.entity3_id) orelse continue;
                }

                try eq_list.append(allocator,.{
                    .constraint_id = con.id,
                    .kind = .angle,
                    .p1 = p1,
                    .p2 = p2,
                    .p3 = p3,
                    .p4 = p4,
                    .param = con.parameter_value,
                });
            },
            .Radius => {
                if (registry.findArcIndex(con.entity1_id)) |a_idx| {
                    const arc = registry.arcs[a_idx];
                    const c = registry.findPointIndex(arc.center_point_id) orelse continue;
                    const s = registry.findPointIndex(arc.start_point_id) orelse continue;
                    try eq_list.append(allocator,.{
                        .constraint_id = con.id,
                        .kind = .radius,
                        .p1 = c,
                        .p2 = s,
                        .param = con.parameter_value,
                    });
                } else if (registry.findCircleIndex(con.entity1_id)) |c_idx| {
                    const circle = registry.circles[c_idx];
                    const c = registry.findPointIndex(circle.center_point_id) orelse continue;
                    const p = registry.findPointIndex(con.entity2_id) orelse continue;
                    try eq_list.append(allocator,.{
                        .constraint_id = con.id,
                        .kind = .radius,
                        .p1 = c,
                        .p2 = p,
                        .param = con.parameter_value,
                    });
                } else if (registry.findPointIndex(con.entity1_id)) |p1| {
                    if (registry.findPointIndex(con.entity2_id)) |p2| {
                        try eq_list.append(allocator,.{
                            .constraint_id = con.id,
                            .kind = .radius,
                            .p1 = p1,
                            .p2 = p2,
                            .param = con.parameter_value,
                        });
                    }
                }
            },
            .Tangent => {
                // Line to Arc/Circle OR Circle to Circle
                if (registry.findLineIndex(con.entity1_id)) |l_idx| {
                    const line = registry.lines[l_idx];
                    const lp1 = registry.findPointIndex(line.start_point_id) orelse continue;
                    const lp2 = registry.findPointIndex(line.end_point_id) orelse continue;

                    var center_pt: usize = 0;
                    var rad: f64 = 0.0;
                    if (registry.findCircleIndex(con.entity2_id)) |c_idx| {
                        const circle = registry.circles[c_idx];
                        center_pt = registry.findPointIndex(circle.center_point_id) orelse continue;
                        rad = circle.radius;
                    } else if (registry.findArcIndex(con.entity2_id)) |a_idx| {
                        const arc = registry.arcs[a_idx];
                        center_pt = registry.findPointIndex(arc.center_point_id) orelse continue;
                        rad = arc.radius;
                    } else {
                        continue;
                    }
                    if (con.parameter_value > 0.0) {
                        rad = con.parameter_value;
                    }

                    const C = Vec2.init(registry.points[center_pt].x, registry.points[center_pt].y);
                    const A = Vec2.init(registry.points[lp1].x, registry.points[lp1].y);
                    const B = Vec2.init(registry.points[lp2].x, registry.points[lp2].y);
                    const v = B.sub(A);
                    const L = @max(v.norm(), 1e-12);
                    const signed_h = ((C.x - A.x) * v.y - (C.y - A.y) * v.x) / L;
                    const side: f64 = if (signed_h < 0.0) -1.0 else 1.0;

                    try eq_list.append(allocator,.{
                        .constraint_id = con.id,
                        .kind = .tangent_line_circle,
                        .p1 = lp1,
                        .p2 = lp2,
                        .p3 = center_pt,
                        .param = rad,
                        .aux = side,
                    });
                } else if (registry.findCircleIndex(con.entity1_id)) |c1_idx| {
                    if (registry.findCircleIndex(con.entity2_id)) |c2_idx| {
                        const c1 = registry.circles[c1_idx];
                        const c2 = registry.circles[c2_idx];
                        const cp1 = registry.findPointIndex(c1.center_point_id) orelse continue;
                        const cp2 = registry.findPointIndex(c2.center_point_id) orelse continue;
                        try eq_list.append(allocator,.{
                            .constraint_id = con.id,
                            .kind = .tangent_circle_circle,
                            .p1 = cp1,
                            .p2 = cp2,
                            .param = c1.radius + c2.radius,
                        });
                    }
                }
            },
        }
    }

    return eq_list.toOwnedSlice(allocator);
}

test "Residuals evaluation" {
    var pts = [_]types.CadSketchPoint2D{
        .{ .id = 1, .x = 0.0, .y = 0.0, .is_fixed = 1 },
        .{ .id = 2, .x = 10.0, .y = 0.0, .is_fixed = 0 },
    };

    const eq_horiz = Equation{
        .constraint_id = 10,
        .kind = .horizontal,
        .p1 = 0,
        .p2 = 1,
    };
    try std.testing.expectApproxEqAbs(0.0, evalResidual(eq_horiz, &pts), 1e-9);

    const eq_dist = Equation{
        .constraint_id = 11,
        .kind = .distance_pt_pt,
        .p1 = 0,
        .p2 = 1,
        .param = 10.0,
    };
    try std.testing.expectApproxEqAbs(0.0, evalResidual(eq_dist, &pts), 1e-9);
}
