const std = @import("std");

pub const NestingMode = enum(c_int) {
    BuildPlate2D = 0,
    SinterBox3D = 1,
};

pub const NestingConfig = struct {
    mode: NestingMode = .BuildPlate2D,
    build_volume_dx: f64 = 250.0, // mm
    build_volume_dy: f64 = 250.0,
    build_volume_dz: f64 = 250.0,
    part_spacing_mm: f64 = 5.0,
    margin_boundary_mm: f64 = 10.0,
    allow_rotation_xy: bool = true,
    allow_rotation_3d: bool = false,
};

pub const NestPlacement = struct {
    solid_handle: u64,
    transform_4x4: [16]f32,
    fits_in_volume: bool,
};

pub const NestingResult = struct {
    allocator: std.mem.Allocator,
    instances: std.ArrayListUnmanaged(NestPlacement) = .empty,
    packing_density_percent: f64 = 0.0,
    max_height_reached_mm: f64 = 0.0,
    parts_packed_count: u32 = 0,
    parts_overflow_count: u32 = 0,

    pub fn deinit(self: *NestingResult) void {
        self.instances.deinit(self.allocator);
    }
};

pub const NestingPacker = struct {
    allocator: std.mem.Allocator,
    config: NestingConfig,

    pub fn init(allocator: std.mem.Allocator, config: NestingConfig) NestingPacker {
        return .{
            .allocator = allocator,
            .config = config,
        };
    }

    /// Packs parts with bounding boxes [w, d, h] into the specified build volume
    pub fn packParts(
        self: *NestingPacker,
        solid_handles: []const u64,
        part_boxes: []const [3]f64,
    ) !NestingResult {
        var res = NestingResult{
            .allocator = self.allocator,
        };
        errdefer res.deinit();

        const margin = self.config.margin_boundary_mm;
        const spacing = self.config.part_spacing_mm;

        var cur_x = margin;
        var cur_y = margin;
        var cur_z: f64 = 0.0;
        var row_max_y: f64 = 0.0;
        var layer_max_z: f64 = 0.0;
        var total_part_vol: f64 = 0.0;

        for (part_boxes, 0..) |box, idx| {
            const handle = if (idx < solid_handles.len) solid_handles[idx] else @as(u64, idx + 1);
            const bw = box[0];
            const bd = box[1];
            const bh = box[2];
            total_part_vol += bw * bd * bh;

            var fits = true;
            // Check if exceeds current shelf row in X
            if (cur_x + bw + margin > self.config.build_volume_dx) {
                // Move to next row in Y
                cur_x = margin;
                cur_y += row_max_y + spacing;
                row_max_y = 0.0;
            }

            // Check if exceeds bed in Y
            if (cur_y + bd + margin > self.config.build_volume_dy) {
                if (self.config.mode == .SinterBox3D) {
                    // Move to next 3D Z layer in SLS sinter box
                    cur_x = margin;
                    cur_y = margin;
                    cur_z += layer_max_z + spacing;
                    row_max_y = 0.0;
                    layer_max_z = 0.0;
                } else {
                    fits = false;
                }
            }

            // Check if exceeds Z in 3D mode
            if (self.config.mode == .SinterBox3D and cur_z + bh > self.config.build_volume_dz) {
                fits = false;
            }

            var mat = [_]f32{
                1.0, 0.0, 0.0, 0.0,
                0.0, 1.0, 0.0, 0.0,
                0.0, 0.0, 1.0, 0.0,
                0.0, 0.0, 0.0, 1.0,
            };

            if (fits) {
                const tx = @as(f32, @floatCast(cur_x + bw * 0.5));
                const ty = @as(f32, @floatCast(cur_y + bd * 0.5));
                const tz = @as(f32, @floatCast(cur_z));
                // Column-major 4x4 matrix translation
                mat[12] = tx;
                mat[13] = ty;
                mat[14] = tz;

                cur_x += bw + spacing;
                if (bd > row_max_y) row_max_y = bd;
                if (bh > layer_max_z) layer_max_z = bh;
                if (cur_z + bh > res.max_height_reached_mm) res.max_height_reached_mm = cur_z + bh;
                res.parts_packed_count += 1;
            } else {
                res.parts_overflow_count += 1;
            }

            try res.instances.append(self.allocator, .{
                .solid_handle = handle,
                .transform_4x4 = mat,
                .fits_in_volume = fits,
            });
        }

        const chamber_vol = if (self.config.mode == .SinterBox3D)
            self.config.build_volume_dx * self.config.build_volume_dy * self.config.build_volume_dz
        else
            self.config.build_volume_dx * self.config.build_volume_dy * (if (res.max_height_reached_mm > 0.0) res.max_height_reached_mm else 10.0);

        if (chamber_vol > 0.0) {
            res.packing_density_percent = (total_part_vol / chamber_vol) * 100.0;
        }

        return res;
    }
};

test "NestingPacker 2D and 3D build volume packing" {
    const cfg_2d = NestingConfig{
        .mode = .BuildPlate2D,
        .build_volume_dx = 100.0,
        .build_volume_dy = 100.0,
        .part_spacing_mm = 5.0,
        .margin_boundary_mm = 5.0,
    };
    var packer_2d = NestingPacker.init(std.testing.allocator, cfg_2d);

    const handles = [_]u64{ 1, 2, 3, 4 };
    const boxes = [_][3]f64{
        [_]f64{ 30.0, 30.0, 20.0 },
        [_]f64{ 30.0, 30.0, 20.0 },
        [_]f64{ 30.0, 30.0, 20.0 },
        [_]f64{ 30.0, 30.0, 20.0 },
    };

    var res_2d = try packer_2d.packParts(&handles, &boxes);
    defer res_2d.deinit();

    try std.testing.expectEqual(@as(u32, 4), res_2d.parts_packed_count);
    try std.testing.expectEqual(@as(u32, 0), res_2d.parts_overflow_count);
    try std.testing.expect(res_2d.packing_density_percent > 0.0);
}
