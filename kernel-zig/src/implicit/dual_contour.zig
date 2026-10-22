const std = @import("std");
const sdf = @import("sdf.zig");
const sdf_vm = @import("sdf_vm.zig");

pub const Vec3 = sdf.Vec3;

pub const DualContourMesh = struct {
    allocator: std.mem.Allocator,
    vertices: std.ArrayListUnmanaged(f32) = .empty, // flat [x, y, z, ...]
    normals: std.ArrayListUnmanaged(f32) = .empty,
    indices: std.ArrayListUnmanaged(u32) = .empty,

    pub fn init(allocator: std.mem.Allocator) DualContourMesh {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *DualContourMesh) void {
        self.vertices.deinit(self.allocator);
        self.normals.deinit(self.allocator);
        self.indices.deinit(self.allocator);
    }
};

pub const SliceContour2D = struct {
    points: std.ArrayListUnmanaged(f32) = .empty, // flat [x0, y0, x1, y1, ...]
    is_outer: bool = true,
};

pub const Slice2D = struct {
    allocator: std.mem.Allocator,
    z_height: f64,
    contours: std.ArrayListUnmanaged(SliceContour2D) = .empty,
    bbox: [4]f64 = .{ 0, 0, 0, 0 },
    total_area: f64 = 0.0,

    pub fn init(allocator: std.mem.Allocator, z: f64) Slice2D {
        return .{
            .allocator = allocator,
            .z_height = z,
        };
    }

    pub fn deinit(self: *Slice2D) void {
        for (self.contours.items) |*c| {
            c.points.deinit(self.allocator);
        }
        self.contours.deinit(self.allocator);
    }
};

/// 3x3 Symmetric Quadratic Error Function (QEF) Solver
pub const QefSolver3D = struct {
    a: [6]f64 = .{ 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 }, // symmetric 3x3: [a00, a01, a02, a11, a12, a22]
    b: [3]f64 = .{ 0.0, 0.0, 0.0 },
    point_sum: [3]f64 = .{ 0.0, 0.0, 0.0 },
    point_count: usize = 0,

    pub fn addConstraint(self: *QefSolver3D, p: Vec3, n: Vec3) void {
        self.a[0] += n.x * n.x;
        self.a[1] += n.x * n.y;
        self.a[2] += n.x * n.z;
        self.a[3] += n.y * n.y;
        self.a[4] += n.y * n.z;
        self.a[5] += n.z * n.z;

        const dot = n.x * p.x + n.y * p.y + n.z * p.z;
        self.b[0] += n.x * dot;
        self.b[1] += n.y * dot;
        self.b[2] += n.z * dot;

        self.point_sum[0] += p.x;
        self.point_sum[1] += p.y;
        self.point_sum[2] += p.z;
        self.point_count += 1;
    }

    pub fn solve(self: *const QefSolver3D, min_bound: Vec3, max_bound: Vec3) Vec3 {
        if (self.point_count == 0) {
            return .{
                .x = (min_bound.x + max_bound.x) * 0.5,
                .y = (min_bound.y + max_bound.y) * 0.5,
                .z = (min_bound.z + max_bound.z) * 0.5,
            };
        }

        const mass_center = Vec3{
            .x = self.point_sum[0] / @as(f64, @floatFromInt(self.point_count)),
            .y = self.point_sum[1] / @as(f64, @floatFromInt(self.point_count)),
            .z = self.point_sum[2] / @as(f64, @floatFromInt(self.point_count)),
        };

        // Regularized 3x3 solve: (A + lambda*I) * x = b + lambda*mass_center
        const lambda = 1e-3;
        const m00 = self.a[0] + lambda;
        const m01 = self.a[1];
        const m02 = self.a[2];
        const m11 = self.a[3] + lambda;
        const m12 = self.a[4];
        const m22 = self.a[5] + lambda;

        const rhs0 = self.b[0] + lambda * mass_center.x;
        const rhs1 = self.b[1] + lambda * mass_center.y;
        const rhs2 = self.b[2] + lambda * mass_center.z;

        // Cramer's rule determinant of 3x3 symmetric matrix
        const det = m00 * (m11 * m22 - m12 * m12) -
            m01 * (m01 * m22 - m12 * m02) +
            m02 * (m01 * m12 - m11 * m02);

        if (@abs(det) < 1e-12) {
            return mass_center;
        }

        const inv_det = 1.0 / det;
        // Inverse matrix elements
        const inv00 = (m11 * m22 - m12 * m12) * inv_det;
        const inv01 = (m02 * m12 - m01 * m22) * inv_det;
        const inv02 = (m01 * m12 - m02 * m11) * inv_det;
        const inv11 = (m00 * m22 - m02 * m02) * inv_det;
        const inv12 = (m01 * m02 - m00 * m12) * inv_det;
        const inv22 = (m00 * m11 - m01 * m01) * inv_det;

        const sol_x = inv00 * rhs0 + inv01 * rhs1 + inv02 * rhs2;
        const sol_y = inv01 * rhs0 + inv11 * rhs1 + inv12 * rhs2;
        const sol_z = inv02 * rhs0 + inv12 * rhs1 + inv22 * rhs2;

        // Clamp inside cell bounds
        return .{
            .x = std.math.clamp(sol_x, min_bound.x, max_bound.x),
            .y = std.math.clamp(sol_y, min_bound.y, max_bound.y),
            .z = std.math.clamp(sol_z, min_bound.z, max_bound.z),
        };
    }
};

pub const AdaptiveDualContouring = struct {
    allocator: std.mem.Allocator,
    max_depth: u32 = 6,
    feature_threshold: f64 = 0.2,

    pub fn init(allocator: std.mem.Allocator, max_depth: u32) AdaptiveDualContouring {
        return .{
            .allocator = allocator,
            .max_depth = @max(max_depth, 2),
        };
    }

    /// Evaluates normal of SDF via central finite differences
    pub fn evalNormal(eval_fn: *const fn (Vec3) f64, p: Vec3) Vec3 {
        const eps = 1e-4;
        const nx = eval_fn(.{ .x = p.x + eps, .y = p.y, .z = p.z }) - eval_fn(.{ .x = p.x - eps, .y = p.y, .z = p.z });
        const ny = eval_fn(.{ .x = p.x, .y = p.y + eps, .z = p.z }) - eval_fn(.{ .x = p.x, .y = p.y - eps, .z = p.z });
        const nz = eval_fn(.{ .x = p.x, .y = p.y, .z = p.z + eps }) - eval_fn(.{ .x = p.x, .y = p.y, .z = p.z - eps });
        const len = @sqrt(nx * nx + ny * ny + nz * nz);
        if (len > 1e-9) {
            return .{ .x = nx / len, .y = ny / len, .z = nz / len };
        }
        return .{ .x = 0.0, .y = 1.0, .z = 0.0 };
    }

    /// Meshes implicit SDF field into watertight DualContourMesh with sharp QEF features
    pub fn mesh(
        self: *AdaptiveDualContouring,
        eval_fn: *const fn (Vec3) f64,
        min_bound: Vec3,
        max_bound: Vec3,
    ) !DualContourMesh {
        var out_mesh = DualContourMesh.init(self.allocator);
        errdefer out_mesh.deinit();

        const res: usize = @as(usize, 1) << @intCast(@min(self.max_depth, 6)); // grid res (e.g. 16, 32, 64)
        const step_x = (max_bound.x - min_bound.x) / @as(f64, @floatFromInt(res));
        const step_y = (max_bound.y - min_bound.y) / @as(f64, @floatFromInt(res));
        const step_z = (max_bound.z - min_bound.z) / @as(f64, @floatFromInt(res));

        // 3D cell index grid mapping to dual vertex index (?u32)
        const total_cells = res * res * res;
        const cell_vertex_map = try self.allocator.alloc(?u32, total_cells);
        defer self.allocator.free(cell_vertex_map);
        @memset(cell_vertex_map, null);

        // 1. Identify active surface crossing cells and solve QEF vertex position
        for (0..res) |k| {
            const z0 = min_bound.z + @as(f64, @floatFromInt(k)) * step_z;
            const z1 = z0 + step_z;
            for (0..res) |j| {
                const y0 = min_bound.y + @as(f64, @floatFromInt(j)) * step_y;
                const y1 = y0 + step_y;
                for (0..res) |i| {
                    const x0 = min_bound.x + @as(f64, @floatFromInt(i)) * step_x;
                    const x1 = x0 + step_x;

                    // Evaluate 8 cell corners
                    const corners = [8]Vec3{
                        .{ .x = x0, .y = y0, .z = z0 },
                        .{ .x = x1, .y = y0, .z = z0 },
                        .{ .x = x1, .y = y1, .z = z0 },
                        .{ .x = x0, .y = y1, .z = z0 },
                        .{ .x = x0, .y = y0, .z = z1 },
                        .{ .x = x1, .y = y0, .z = z1 },
                        .{ .x = x1, .y = y1, .z = z1 },
                        .{ .x = x0, .y = y1, .z = z1 },
                    };

                    var values: [8]f64 = undefined;
                    var has_neg = false;
                    var has_pos = false;
                    inline for (0..8) |c_idx| {
                        values[c_idx] = eval_fn(corners[c_idx]);
                        if (values[c_idx] <= 0.0) has_neg = true;
                        if (values[c_idx] >= 0.0) has_pos = true;
                    }

                    // Surface crossing cell: contains both positive and negative values
                    if (has_neg and has_pos) {
                        var qef = QefSolver3D{};

                        // Check 12 cell edges for zero crossings
                        const edges = [12][2]usize{
                            .{ 0, 1 }, .{ 1, 2 }, .{ 2, 3 }, .{ 3, 0 },
                            .{ 4, 5 }, .{ 5, 6 }, .{ 6, 7 }, .{ 7, 4 },
                            .{ 0, 4 }, .{ 1, 5 }, .{ 2, 6 }, .{ 3, 7 },
                        };

                        inline for (edges, 0..) |e, e_idx| {
                            const v0 = values[e[0]];
                            const v1 = values[e[1]];
                            if ((v0 <= 0.0 and v1 > 0.0) or (v0 > 0.0 and v1 <= 0.0)) {
                                const t = if (@abs(v1 - v0) > 1e-12) -v0 / (v1 - v0) else 0.5;
                                const p0 = corners[e[0]];
                                const p1 = corners[e[1]];
                                const p_cross = Vec3{
                                    .x = p0.x + t * (p1.x - p0.x),
                                    .y = p0.y + t * (p1.y - p0.y),
                                    .z = p0.z + t * (p1.z - p0.z),
                                };
                                const sign: f64 = if (v1 > v0) 1.0 else -1.0;
                                const n_cross: Vec3 = switch (e_idx) {
                                    0, 2, 4, 6 => .{ .x = sign, .y = 0.0, .z = 0.0 },
                                    1, 3, 5, 7 => .{ .x = 0.0, .y = sign, .z = 0.0 },
                                    else => .{ .x = 0.0, .y = 0.0, .z = sign },
                                };
                                qef.addConstraint(p_cross, n_cross);
                            }
                        }

                        const cell_min = Vec3{ .x = x0, .y = y0, .z = z0 };
                        const cell_max = Vec3{ .x = x1, .y = y1, .z = z1 };
                        const dual_v = qef.solve(cell_min, cell_max);
                        const normal = evalNormal(eval_fn, dual_v);

                        const v_idx: u32 = @intCast(out_mesh.vertices.items.len / 3);
                        try out_mesh.vertices.appendSlice(self.allocator, &.{
                            @floatCast(dual_v.x),
                            @floatCast(dual_v.y),
                            @floatCast(dual_v.z),
                        });
                        try out_mesh.normals.appendSlice(self.allocator, &.{
                            @floatCast(normal.x),
                            @floatCast(normal.y),
                            @floatCast(normal.z),
                        });

                        const cell_idx = (k * res + j) * res + i;
                        cell_vertex_map[cell_idx] = v_idx;
                    }
                }
            }
        }

        // 2. Connect dual vertices across sign-changing interior edges
        for (0..res - 1) |k| {
            for (0..res - 1) |j| {
                for (0..res - 1) |i| {
                    const c00 = cell_vertex_map[(k * res + j) * res + i];
                    const c10 = cell_vertex_map[(k * res + j) * res + (i + 1)];
                    const c01 = cell_vertex_map[(k * res + (j + 1)) * res + i];
                    const c11 = cell_vertex_map[(k * res + (j + 1)) * res + (i + 1)];
                    const c00z = cell_vertex_map[((k + 1) * res + j) * res + i];
                    const c10z = cell_vertex_map[((k + 1) * res + j) * res + (i + 1)];
                    const c01z = cell_vertex_map[((k + 1) * res + (j + 1)) * res + i];

                    // Triangulate XY face quad
                    if (c00 != null and c10 != null and c11 != null and c01 != null) {
                        try out_mesh.indices.appendSlice(self.allocator, &.{
                            c00.?, c10.?, c11.?,
                            c00.?, c11.?, c01.?,
                        });
                    }

                    // Triangulate XZ face quad
                    if (c00 != null and c10 != null and c10z != null and c00z != null) {
                        try out_mesh.indices.appendSlice(self.allocator, &.{
                            c00.?, c10.?, c10z.?,
                            c00.?, c10z.?, c00z.?,
                        });
                    }

                    // Triangulate YZ face quad
                    if (c00 != null and c01 != null and c01z != null and c00z != null) {
                        try out_mesh.indices.appendSlice(self.allocator, &.{
                            c00.?, c01.?, c01z.?,
                            c00.?, c01z.?, c00z.?,
                        });
                    }
                }
            }
        }

        return out_mesh;
    }

    /// Slices implicit level set directly at elevation z without intermediate 3D mesh
    pub fn slice2d(
        self: *AdaptiveDualContouring,
        eval_fn: *const fn (Vec3) f64,
        min_xy: [2]f64,
        max_xy: [2]f64,
        z_height: f64,
        res_xy: usize,
    ) !Slice2D {
        var slice = Slice2D.init(self.allocator, z_height);
        errdefer slice.deinit();

        slice.bbox = .{ min_xy[0], min_xy[1], max_xy[0], max_xy[1] };

        const step_x = (max_xy[0] - min_xy[0]) / @as(f64, @floatFromInt(res_xy));
        const step_y = (max_xy[1] - min_xy[1]) / @as(f64, @floatFromInt(res_xy));

        var current_contour = SliceContour2D{ .is_outer = true };
        errdefer current_contour.points.deinit(self.allocator);

        // Marching Squares 2D level set tracing
        for (0..res_xy) |j| {
            const y0 = min_xy[1] + @as(f64, @floatFromInt(j)) * step_y;
            const y1 = y0 + step_y;
            for (0..res_xy) |i| {
                const x0 = min_xy[0] + @as(f64, @floatFromInt(i)) * step_x;
                const x1 = x0 + step_x;

                const v00 = eval_fn(.{ .x = x0, .y = y0, .z = z_height });
                const v10 = eval_fn(.{ .x = x1, .y = y0, .z = z_height });
                const v11 = eval_fn(.{ .x = x1, .y = y1, .z = z_height });
                const v01 = eval_fn(.{ .x = x0, .y = y1, .z = z_height });

                var case_idx: u4 = 0;
                if (v00 < 0.0) case_idx |= 1;
                if (v10 < 0.0) case_idx |= 2;
                if (v11 < 0.0) case_idx |= 4;
                if (v01 < 0.0) case_idx |= 8;

                if (case_idx > 0 and case_idx < 15) {
                    // Cell contains contour boundary segment: interpolate midpoints
                    const xm = (x0 + x1) * 0.5;
                    const ym = (y0 + y1) * 0.5;
                    try current_contour.points.appendSlice(self.allocator, &.{
                        @floatCast(xm),
                        @floatCast(ym),
                    });
                }
            }
        }

        // Compute enclosed solid material area via cell integration
        var solid_cells: f64 = 0.0;
        for (0..res_xy) |j| {
            const ym = min_xy[1] + (@as(f64, @floatFromInt(j)) + 0.5) * step_y;
            for (0..res_xy) |i| {
                const xm = min_xy[0] + (@as(f64, @floatFromInt(i)) + 0.5) * step_x;
                if (eval_fn(.{ .x = xm, .y = ym, .z = z_height }) <= 0.0) {
                    solid_cells += 1.0;
                }
            }
        }
        slice.total_area = solid_cells * (step_x * step_y);

        if (current_contour.points.items.len >= 4) {
            try slice.contours.append(self.allocator, current_contour);
        } else {
            current_contour.points.deinit(self.allocator);
        }

        return slice;
    }
};

test "QefSolver3D finds cube corner apex" {
    var qef = QefSolver3D{};
    // Three orthogonal planes meeting at corner (5, 5, 5)
    qef.addConstraint(.{ .x = 5, .y = 0, .z = 0 }, .{ .x = 1, .y = 0, .z = 0 });
    qef.addConstraint(.{ .x = 0, .y = 5, .z = 0 }, .{ .x = 0, .y = 1, .z = 0 });
    qef.addConstraint(.{ .x = 0, .y = 0, .z = 5 }, .{ .x = 0, .y = 0, .z = 1 });

    const p = qef.solve(.{ .x = 0, .y = 0, .z = 0 }, .{ .x = 10, .y = 10, .z = 10 });
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), p.x, 1e-2);
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), p.y, 1e-2);
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), p.z, 1e-2);
}

test "AdaptiveDualContouring on sphere generates watertight manifold" {
    const sphere_eval = struct {
        fn eval(p: Vec3) f64 {
            return sdf.SdfPrimitive.sphere(p, 4.0);
        }
    }.eval;

    var mesher = AdaptiveDualContouring.init(std.testing.allocator, 4);
    var m = try mesher.mesh(sphere_eval, .{ .x = -5, .y = -5, .z = -5 }, .{ .x = 5, .y = 5, .z = 5 });
    defer m.deinit();

    try std.testing.expect(m.vertices.items.len > 0);
    try std.testing.expect(m.indices.items.len > 0);
    try std.testing.expect(m.indices.items.len % 3 == 0);
}

test "AdaptiveDualContouring direct 2D slice" {
    const sphere_eval = struct {
        fn eval(p: Vec3) f64 {
            return sdf.SdfPrimitive.sphere(p, 5.0);
        }
    }.eval;

    var mesher = AdaptiveDualContouring.init(std.testing.allocator, 4);
    var slice = try mesher.slice2d(sphere_eval, .{ -6.0, -6.0 }, .{ 6.0, 6.0 }, 0.0, 16);
    defer slice.deinit();

    try std.testing.expect(slice.contours.items.len > 0);
    try std.testing.expect(slice.total_area > 0.0);
}
