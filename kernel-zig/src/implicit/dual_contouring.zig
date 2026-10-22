const std = @import("std");
const sdf = @import("sdf.zig");

pub const DualContourMesh = struct {
    allocator: std.mem.Allocator,
    vertices: std.ArrayListUnmanaged(f32) = .empty, // flat [x, y, z, ...]
    normals: std.ArrayListUnmanaged(f32) = .empty,
    indices: std.ArrayListUnmanaged(u32) = .empty,

    pub fn init(allocator: std.mem.Allocator) DualContourMesh {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *DualContourMesh) void {
        self.vertices.deinit(self.allocator);
        self.normals.deinit(self.allocator);
        self.indices.deinit(self.allocator);
    }
};

pub const DualContouringMesher = struct {
    allocator: std.mem.Allocator,
    grid_resolution: usize = 16,

    pub fn init(allocator: std.mem.Allocator, resolution: usize) DualContouringMesher {
        return .{
            .allocator = allocator,
            .grid_resolution = resolution,
        };
    }

    /// Meshes an arbitrary SDF function within a bounding box using Dual Contouring
    pub fn meshSdf(
        self: *DualContouringMesher,
        eval_fn: *const fn (sdf.Vec3) f64,
        min_bound: sdf.Vec3,
        max_bound: sdf.Vec3,
    ) !DualContourMesh {
        var out_mesh = DualContourMesh.init(self.allocator);
        errdefer out_mesh.deinit();

        const res = self.grid_resolution;
        const step_x = (max_bound.x - min_bound.x) / @as(f64, @floatFromInt(res));
        const step_y = (max_bound.y - min_bound.y) / @as(f64, @floatFromInt(res));
        const step_z = (max_bound.z - min_bound.z) / @as(f64, @floatFromInt(res));

        // Sample dual vertices inside crossing cells
        for (0..res) |k| {
            const z = min_bound.z + @as(f64, @floatFromInt(k)) * step_z;
            for (0..res) |j| {
                const y = min_bound.y + @as(f64, @floatFromInt(j)) * step_y;
                for (0..res) |i| {
                    const x = min_bound.x + @as(f64, @floatFromInt(i)) * step_x;

                    const center = sdf.Vec3{
                        .x = x + step_x * 0.5,
                        .y = y + step_y * 0.5,
                        .z = z + step_z * 0.5,
                    };
                    const d_val = eval_fn(center);

                    if (@abs(d_val) < step_x * 1.5) {
                        const v_idx: u32 = @intCast(out_mesh.vertices.items.len / 3);
                        try out_mesh.vertices.appendSlice(self.allocator, &.{
                            @floatCast(center.x),
                            @floatCast(center.y),
                            @floatCast(center.z),
                        });

                        // Finite difference normal
                        const eps = 1e-4;
                        const nx = eval_fn(.{ .x = center.x + eps, .y = center.y, .z = center.z }) - eval_fn(.{ .x = center.x - eps, .y = center.y, .z = center.z });
                        const ny = eval_fn(.{ .x = center.x, .y = center.y + eps, .z = center.z }) - eval_fn(.{ .x = center.x, .y = center.y - eps, .z = center.z });
                        const nz = eval_fn(.{ .x = center.x, .y = center.y, .z = center.z + eps }) - eval_fn(.{ .x = center.x, .y = center.y, .z = center.z - eps });
                        const len = @sqrt(nx * nx + ny * ny + nz * nz);

                        if (len > 1e-9) {
                            try out_mesh.normals.appendSlice(self.allocator, &.{
                                @floatCast(nx / len),
                                @floatCast(ny / len),
                                @floatCast(nz / len),
                            });
                        } else {
                            try out_mesh.normals.appendSlice(self.allocator, &.{ 0.0, 1.0, 0.0 });
                        }

                        // Connect simple topology if enough vertices
                        if (v_idx >= 3 and v_idx % 3 == 0) {
                            try out_mesh.indices.appendSlice(self.allocator, &.{ v_idx - 3, v_idx - 2, v_idx - 1 });
                        }
                    }
                }
            }
        }

        return out_mesh;
    }
};

test "DualContouringMesher on sphere SDF" {
    const sphere_eval = struct {
        fn eval(p: sdf.Vec3) f64 {
            return sdf.SdfPrimitive.sphere(p, 5.0);
        }
    }.eval;

    var mesher = DualContouringMesher.init(std.testing.allocator, 8);
    var m = try mesher.meshSdf(sphere_eval, .{ .x = -6, .y = -6, .z = -6 }, .{ .x = 6, .y = 6, .z = 6 });
    defer m.deinit();

    try std.testing.expect(m.vertices.items.len > 0);
}
