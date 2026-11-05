const std = @import("std");
const memory = @import("memory.zig");
const memory_map = @import("memory_map.zig");
const topo_id_mod = @import("topo/topo_id.zig");
pub const TopoId = topo_id_mod.TopoId;
pub const h64 = topo_id_mod.h64;

// ============================================================================
// Dual Numbers for Exact Analytical Forward-Mode Automatic Differentiation
// ============================================================================

pub const Dual = struct {
    val: f64,
    der: f64,
    depends_on_seed: bool = false,

    pub fn constant(v: f64) Dual {
        return .{ .val = v, .der = 0.0, .depends_on_seed = false };
    }

    pub fn variable(v: f64, is_seed: bool) Dual {
        return .{ .val = v, .der = if (is_seed) 1.0 else 0.0, .depends_on_seed = is_seed };
    }

    pub fn add(a: Dual, b: Dual) Dual {
        return .{
            .val = a.val + b.val,
            .der = a.der + b.der,
            .depends_on_seed = a.depends_on_seed or b.depends_on_seed,
        };
    }

    pub fn sub(a: Dual, b: Dual) Dual {
        return .{
            .val = a.val - b.val,
            .der = a.der - b.der,
            .depends_on_seed = a.depends_on_seed or b.depends_on_seed,
        };
    }

    pub fn mul(a: Dual, b: Dual) Dual {
        return .{
            .val = a.val * b.val,
            .der = a.val * b.der + a.der * b.val,
            .depends_on_seed = a.depends_on_seed or b.depends_on_seed,
        };
    }

    pub fn div(a: Dual, b: Dual) Dual {
        if (@abs(b.val) <= 1e-30) {
            return .{
                .val = std.math.nan(f64),
                .der = std.math.nan(f64),
                .depends_on_seed = a.depends_on_seed or b.depends_on_seed,
            };
        }
        const inv_b = 1.0 / b.val;
        return .{
            .val = a.val * inv_b,
            .der = (a.der * b.val - a.val * b.der) * (inv_b * inv_b),
            .depends_on_seed = a.depends_on_seed or b.depends_on_seed,
        };
    }

    pub fn neg(a: Dual) Dual {
        return .{ .val = -a.val, .der = -a.der, .depends_on_seed = a.depends_on_seed };
    }

    pub fn sqr(a: Dual) Dual {
        return .{
            .val = a.val * a.val,
            .der = 2.0 * a.val * a.der,
            .depends_on_seed = a.depends_on_seed,
        };
    }

    pub fn sqrt(a: Dual) Dual {
        if (a.val < 0.0) {
            return .{ .val = std.math.nan(f64), .der = std.math.nan(f64), .depends_on_seed = a.depends_on_seed };
        }
        const s = @sqrt(a.val);
        if (s <= 1e-15) {
            // CDML §3.3.1: SQRT rule divides by zero at u = 0 when differentiating wrt active seed
            const d = if (a.depends_on_seed or @abs(a.der) > 0.0) std.math.nan(f64) else 0.0;
            return .{ .val = 0.0, .der = d, .depends_on_seed = a.depends_on_seed };
        }
        return .{
            .val = s,
            .der = a.der / (2.0 * s),
            .depends_on_seed = a.depends_on_seed,
        };
    }

    pub fn sin(a: Dual) Dual {
        return .{
            .val = @sin(a.val),
            .der = a.der * @cos(a.val),
            .depends_on_seed = a.depends_on_seed,
        };
    }

    pub fn cos(a: Dual) Dual {
        return .{
            .val = @cos(a.val),
            .der = -a.der * @sin(a.val),
            .depends_on_seed = a.depends_on_seed,
        };
    }

    pub fn exp(a: Dual) Dual {
        const v = @exp(a.val);
        return .{ .val = v, .der = v * a.der, .depends_on_seed = a.depends_on_seed };
    }

    pub fn log(a: Dual) Dual {
        if (a.val <= 0.0) {
            return .{ .val = std.math.nan(f64), .der = std.math.nan(f64), .depends_on_seed = a.depends_on_seed };
        }
        const v = @log(a.val);
        return .{ .val = v, .der = a.der / a.val, .depends_on_seed = a.depends_on_seed };
    }

    pub fn abs(a: Dual) Dual {
        const v = @abs(a.val);
        const d = if (a.val > 0.0) a.der else if (a.val < 0.0) -a.der else 0.0;
        return .{ .val = v, .der = d, .depends_on_seed = a.depends_on_seed };
    }

    pub fn absSmooth(u: Dual, eps: Dual) Dual {
        const s = @sqrt(u.val * u.val + eps.val * eps.val);
        const d = if (s > 1e-15) (u.val * u.der + eps.val * eps.der) / s else 0.0;
        return .{
            .val = s,
            .der = d,
            .depends_on_seed = u.depends_on_seed or eps.depends_on_seed,
        };
    }

    pub fn rUnion(u: Dual, v: Dual) Dual {
        const s = @sqrt(u.val * u.val + v.val * v.val);
        const val = u.val + v.val - s;
        const der = if (s > 1e-15)
            u.der * (1.0 - u.val / s) + v.der * (1.0 - v.val / s)
        else
            u.der + v.der;
        return .{
            .val = val,
            .der = der,
            .depends_on_seed = u.depends_on_seed or v.depends_on_seed,
        };
    }

    pub fn rIntersect(u: Dual, v: Dual) Dual {
        const s = @sqrt(u.val * u.val + v.val * v.val);
        const val = u.val + v.val + s;
        const der = if (s > 1e-15)
            u.der * (1.0 + u.val / s) + v.der * (1.0 + v.val / s)
        else
            u.der + v.der;
        return .{
            .val = val,
            .der = der,
            .depends_on_seed = u.depends_on_seed or v.depends_on_seed,
        };
    }

    pub fn pow(a: Dual, b: Dual) Dual {
        const p = b.val;
        if (@abs(b.der) <= 1e-16 and !b.depends_on_seed) {
            if (p == 2.0) return a.sqr();
            if (p == 0.5) return a.sqrt();
            if (p == 0.0) return constant(1.0);
            if (p == 1.0) return a;
            const val = std.math.pow(f64, a.val, p);
            const der = if (std.math.approxEqAbs(f64, a.val, 0.0, 1e-15))
                0.0
            else
                p * std.math.pow(f64, a.val, p - 1.0) * a.der;
            return .{ .val = val, .der = der, .depends_on_seed = a.depends_on_seed };
        }
        if (a.val <= 0.0) {
            return .{ .val = std.math.nan(f64), .der = std.math.nan(f64), .depends_on_seed = true };
        }
        const val = std.math.pow(f64, a.val, p);
        const der = std.math.pow(f64, a.val, p - 1.0) * (p * a.der + a.val * @log(a.val) * b.der);
        return .{
            .val = val,
            .der = der,
            .depends_on_seed = a.depends_on_seed or b.depends_on_seed,
        };
    }
};

// ============================================================================
// Interval Arithmetic for Range Bounding (§3.2)
// ============================================================================

pub const Interval = struct {
    min: f64,
    max: f64,

    pub fn init(min: f64, max: f64) Interval {
        return .{ .min = @min(min, max), .max = @max(min, max) };
    }

    pub fn point(v: f64) Interval {
        return .{ .min = v, .max = v };
    }

    pub fn add(a: Interval, b: Interval) Interval {
        return .{ .min = a.min + b.min, .max = a.max + b.max };
    }

    pub fn sub(a: Interval, b: Interval) Interval {
        return .{ .min = a.min - b.max, .max = a.max - b.min };
    }

    pub fn mul(a: Interval, b: Interval) Interval {
        const p1 = a.min * b.min;
        const p2 = a.min * b.max;
        const p3 = a.max * b.min;
        const p4 = a.max * b.max;
        return .{
            .min = @min(@min(p1, p2), @min(p3, p4)),
            .max = @max(@max(p1, p2), @max(p3, p4)),
        };
    }

    pub fn div(a: Interval, b: Interval) Interval {
        if (b.min <= 0.0 and b.max >= 0.0) {
            return .{ .min = -1e30, .max = 1e30 };
        }
        const inv_b = Interval{ .min = 1.0 / b.max, .max = 1.0 / b.min };
        return a.mul(inv_b);
    }

    pub fn sqr(a: Interval) Interval {
        if (a.min <= 0.0 and a.max >= 0.0) {
            return .{ .min = 0.0, .max = @max(a.min * a.min, a.max * a.max) };
        } else {
            const sq1 = a.min * a.min;
            const sq2 = a.max * a.max;
            return .{ .min = @min(sq1, sq2), .max = @max(sq1, sq2) };
        }
    }

    pub fn sqrt(a: Interval) Interval {
        const lo = if (a.min > 0.0) @sqrt(a.min) else 0.0;
        const hi = if (a.max > 0.0) @sqrt(a.max) else 0.0;
        return .{ .min = lo, .max = hi };
    }

    pub fn abs(a: Interval) Interval {
        if (a.min <= 0.0 and a.max >= 0.0) {
            return .{ .min = 0.0, .max = @max(@abs(a.min), @abs(a.max)) };
        }
        const a1 = @abs(a.min);
        const a2 = @abs(a.max);
        return .{ .min = @min(a1, a2), .max = @max(a1, a2) };
    }

    pub fn absSmooth(u: Interval, eps: Interval) Interval {
        return u.sqr().add(eps.sqr()).sqrt();
    }

    pub fn rUnion(u: Interval, v: Interval) Interval {
        // r_union(u, v) = u + v - sqrt(u^2 + v^2) is monotonically non-decreasing in u and v
        const lo = u.min + v.min - @sqrt(u.min * u.min + v.min * v.min);
        const hi = u.max + v.max - @sqrt(u.max * u.max + v.max * v.max);
        return init(lo, hi);
    }

    pub fn rIntersect(u: Interval, v: Interval) Interval {
        // r_intersect(u, v) = u + v + sqrt(u^2 + v^2) is monotonically non-decreasing in u and v
        const lo = u.min + v.min + @sqrt(u.min * u.min + v.min * v.min);
        const hi = u.max + v.max + @sqrt(u.max * u.max + v.max * v.max);
        return init(lo, hi);
    }

    pub fn sin(a: Interval) Interval {
        const two_pi = 2.0 * std.math.pi;
        if (a.max - a.min >= two_pi) return .{ .min = -1.0, .max = 1.0 };
        const s_min = @sin(a.min);
        const s_max = @sin(a.max);
        var lo = @min(s_min, s_max);
        var hi = @max(s_min, s_max);

        // Check if pi/2 + 2*k*pi lies in [a.min, a.max] -> max = 1.0
        const k_max = @ceil((a.min - 0.5 * std.math.pi) / two_pi);
        if (0.5 * std.math.pi + k_max * two_pi <= a.max) hi = 1.0;

        // Check if -pi/2 + 2*k*pi lies in [a.min, a.max] -> min = -1.0
        const k_min = @ceil((a.min + 0.5 * std.math.pi) / two_pi);
        if (-0.5 * std.math.pi + k_min * two_pi <= a.max) lo = -1.0;

        return .{ .min = lo, .max = hi };
    }

    pub fn cos(a: Interval) Interval {
        const two_pi = 2.0 * std.math.pi;
        if (a.max - a.min >= two_pi) return .{ .min = -1.0, .max = 1.0 };
        const c_min = @cos(a.min);
        const c_max = @cos(a.max);
        var lo = @min(c_min, c_max);
        var hi = @max(c_min, c_max);

        // Check if 2*k*pi lies in [a.min, a.max] -> max = 1.0
        const k_max = @ceil(a.min / two_pi);
        if (k_max * two_pi <= a.max) hi = 1.0;

        // Check if pi + 2*k*pi lies in [a.min, a.max] -> min = -1.0
        const k_min = @ceil((a.min - std.math.pi) / two_pi);
        if (std.math.pi + k_min * two_pi <= a.max) lo = -1.0;

        return .{ .min = lo, .max = hi };
    }

    pub fn pow(a: Interval, p_int: Interval) Interval {
        const p = p_int.min;
        if (@abs(p - 2.0) < 1e-12) return a.sqr();
        if (@abs(p - 1.0) < 1e-12) return a;
        if (@abs(p) < 1e-12) return point(1.0);
        if (@abs(p - 0.5) < 1e-12) return a.sqrt();
        const v1 = std.math.pow(f64, @max(0.0, a.min), p);
        const v2 = std.math.pow(f64, @max(0.0, a.max), p);
        return init(v1, v2);
    }
};

// ============================================================================
// Shared Memory Field Buffer (0x1F0000) Trilinear Sampler (§8.4 & §13.2 Case 7)
// ============================================================================

pub const FieldSlotConfig = struct {
    active: bool = false,
    grid_x: u32 = 64,
    grid_y: u32 = 64,
    grid_z: u32 = 24,
    min_x: f64 = -45.0,
    min_y: f64 = -45.0,
    min_z: f64 = 0.0,
    max_x: f64 = 45.0,
    max_y: f64 = 45.0,
    max_z: f64 = 16.0,
    byte_offset: usize = 0,
};

pub var field_slots_config: [8]FieldSlotConfig = .{
    .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{},
};

pub fn configureFieldSlot(
    slot: u32,
    grid_x: u32,
    grid_y: u32,
    grid_z: u32,
    min_x: f64,
    min_y: f64,
    min_z: f64,
    max_x: f64,
    max_y: f64,
    max_z: f64,
) void {
    if (slot >= field_slots_config.len) return;
    field_slots_config[slot] = .{
        .active = true,
        .grid_x = if (grid_x >= 2) grid_x else 64,
        .grid_y = if (grid_y >= 2) grid_y else 64,
        .grid_z = if (grid_z >= 2) grid_z else 24,
        .min_x = min_x,
        .min_y = min_y,
        .min_z = min_z,
        .max_x = max_x,
        .max_y = max_y,
        .max_z = max_z,
        .byte_offset = 0,
    };
}

fn resolveFieldDomainAndCheckAllocated(slot: u32) ?struct {
    gx: u32,
    gy: u32,
    gz: u32,
    min_x: f64,
    min_y: f64,
    min_z: f64,
    max_x: f64,
    max_y: f64,
    max_z: f64,
    slice: []const u8,
} {
    const idx = if (slot < field_slots_config.len) slot else 0;
    const cfg = field_slots_config[idx];
    const gx = if (cfg.grid_x >= 2) cfg.grid_x else 64;
    const gy = if (cfg.grid_y >= 2) cfg.grid_y else 64;
    const gz = if (cfg.grid_z >= 2) cfg.grid_z else 24;
    const voxel_count: usize = @as(usize, gx) * @as(usize, gy) * @as(usize, gz);
    const byte_len = voxel_count * 4;

    const field_bytes = memory_map.getMemorySlice(memory_map.FIELD_BUFFER_OFFSET + cfg.byte_offset, byte_len);

    // Check if the slot in 0x1F0000 has non-zero populated data
    const v0: f32 = @bitCast(std.mem.readInt(u32, field_bytes[0..4], .little));
    const mid_off = (voxel_count / 2) * 4;
    const v_mid: f32 = @bitCast(std.mem.readInt(u32, field_bytes[mid_off..][0..4], .little));

    const is_populated = (@abs(v0) > 1e-9 or @abs(v_mid) > 1e-9) and !std.math.isNan(v0);
    if (!is_populated) {
        return null; // Unallocated / unpopulated slot -> return default with 0 derivative
    }

    var min_x = cfg.min_x;
    var min_y = cfg.min_y;
    var min_z = cfg.min_z;
    var max_x = cfg.max_x;
    var max_y = cfg.max_y;
    var max_z = cfg.max_z;

    if (!cfg.active) {
        // Check if tessellation buffer at 0x0F0020 has a valid bounding box
        const tess_hdr = memory_map.getMemorySlice(memory_map.TESS_BUFFER_OFFSET, 0x50);
        const b0: f64 = @bitCast(std.mem.readInt(u64, tess_hdr[0x20..0x28], .little));
        const b1: f64 = @bitCast(std.mem.readInt(u64, tess_hdr[0x28..0x30], .little));
        const b2: f64 = @bitCast(std.mem.readInt(u64, tess_hdr[0x30..0x38], .little));
        const b3: f64 = @bitCast(std.mem.readInt(u64, tess_hdr[0x38..0x40], .little));
        const b4: f64 = @bitCast(std.mem.readInt(u64, tess_hdr[0x40..0x48], .little));
        const b5: f64 = @bitCast(std.mem.readInt(u64, tess_hdr[0x48..0x50], .little));
        if (b3 > b0 and b4 > b1 and b5 > b2 and !std.math.isNan(b0)) {
            min_x = b0;
            min_y = b1;
            min_z = b2;
            max_x = b3;
            max_y = b4;
            max_z = b5;
        }
    }

    return .{
        .gx = gx,
        .gy = gy,
        .gz = gz,
        .min_x = min_x,
        .min_y = min_y,
        .min_z = min_z,
        .max_x = max_x,
        .max_y = max_y,
        .max_z = max_z,
        .slice = field_bytes,
    };
}

inline fn readVoxel(slice: []const u8, gx: u32, gy: u32, ix: u32, iy: u32, iz: u32) f64 {
    const idx = (@as(usize, iz) * @as(usize, gy) * @as(usize, gx) + @as(usize, iy) * @as(usize, gx) + @as(usize, ix)) * 4;
    const val_f32: f32 = @bitCast(std.mem.readInt(u32, slice[idx..][0..4], .little));
    return @floatCast(val_f32);
}

pub fn sampleFieldTrilinearDual(slot: u32, x: Dual, y: Dual, z: Dual, default_val: Dual) Dual {
    const info = resolveFieldDomainAndCheckAllocated(slot) orelse {
        // CDML §13.2 Case 7: Unallocated field slot returns default with 0.0 gradient
        return Dual.constant(default_val.val);
    };

    const span_x = @max(1e-12, info.max_x - info.min_x);
    const span_y = @max(1e-12, info.max_y - info.min_y);
    const span_z = @max(1e-12, info.max_z - info.min_z);

    const max_ix_f = @as(f64, @floatFromInt(info.gx - 1));
    const max_iy_f = @as(f64, @floatFromInt(info.gy - 1));
    const max_iz_f = @as(f64, @floatFromInt(info.gz - 1));

    const raw_ux = ((x.val - info.min_x) / span_x) * max_ix_f;
    const raw_uy = ((y.val - info.min_y) / span_y) * max_iy_f;
    const raw_uz = ((z.val - info.min_z) / span_z) * max_iz_f;

    // CLAMP_TO_EDGE
    const ux = std.math.clamp(raw_ux, 0.0, max_ix_f);
    const uy = std.math.clamp(raw_uy, 0.0, max_iy_f);
    const uz = std.math.clamp(raw_uz, 0.0, max_iz_f);

    const dux_dx = if (raw_ux >= 0.0 and raw_ux <= max_ix_f) max_ix_f / span_x else 0.0;
    const duy_dy = if (raw_uy >= 0.0 and raw_uy <= max_iy_f) max_iy_f / span_y else 0.0;
    const duz_dz = if (raw_uz >= 0.0 and raw_uz <= max_iz_f) max_iz_f / span_z else 0.0;

    const ix0: u32 = @min(@as(u32, @intFromFloat(@floor(ux))), info.gx - 2);
    const iy0: u32 = @min(@as(u32, @intFromFloat(@floor(uy))), info.gy - 2);
    const iz0: u32 = @min(@as(u32, @intFromFloat(@floor(uz))), info.gz - 2);
    const ix1 = ix0 + 1;
    const iy1 = iy0 + 1;
    const iz1 = iz0 + 1;

    const tx = ux - @as(f64, @floatFromInt(ix0));
    const ty = uy - @as(f64, @floatFromInt(iy0));
    const tz = uz - @as(f64, @floatFromInt(iz0));

    const c000 = readVoxel(info.slice, info.gx, info.gy, ix0, iy0, iz0);
    const c100 = readVoxel(info.slice, info.gx, info.gy, ix1, iy0, iz0);
    const c010 = readVoxel(info.slice, info.gx, info.gy, ix0, iy1, iz0);
    const c110 = readVoxel(info.slice, info.gx, info.gy, ix1, iy1, iz0);
    const c001 = readVoxel(info.slice, info.gx, info.gy, ix0, iy0, iz1);
    const c101 = readVoxel(info.slice, info.gx, info.gy, ix1, iy0, iz1);
    const c011 = readVoxel(info.slice, info.gx, info.gy, ix0, iy1, iz1);
    const c111 = readVoxel(info.slice, info.gx, info.gy, ix1, iy1, iz1);

    const c00 = c000 * (1.0 - tx) + c100 * tx;
    const c10 = c010 * (1.0 - tx) + c110 * tx;
    const c01 = c001 * (1.0 - tx) + c101 * tx;
    const c11 = c011 * (1.0 - tx) + c111 * tx;

    const c0 = c00 * (1.0 - ty) + c10 * ty;
    const c1 = c01 * (1.0 - ty) + c11 * ty;

    const val = c0 * (1.0 - tz) + c1 * tz;

    // Exact trilinear partial derivatives
    const d_dtx = ((c100 - c000) * (1.0 - ty) + (c110 - c010) * ty) * (1.0 - tz) +
        ((c101 - c001) * (1.0 - ty) + (c111 - c011) * ty) * tz;
    const d_dty = (c10 - c00) * (1.0 - tz) + (c11 - c01) * tz;
    const d_dtz = c1 - c0;

    const der = (d_dtx * dux_dx) * x.der + (d_dty * duy_dy) * y.der + (d_dtz * duz_dz) * z.der;

    return .{
        .val = val,
        .der = der,
        .depends_on_seed = x.depends_on_seed or y.depends_on_seed or z.depends_on_seed,
    };
}

pub fn sampleFieldTrilinearScalar(slot: u32, x: f64, y: f64, z: f64, default_val: f64) f64 {
    const res = sampleFieldTrilinearDual(
        slot,
        Dual.constant(x),
        Dual.constant(y),
        Dual.constant(z),
        Dual.constant(default_val),
    );
    return res.val;
}

pub fn sampleFieldTrilinearInterval(slot: u32, x: Interval, y: Interval, z: Interval, default_val: Interval) Interval {
    const info = resolveFieldDomainAndCheckAllocated(slot) orelse {
        return default_val;
    };

    const span_x = @max(1e-12, info.max_x - info.min_x);
    const span_y = @max(1e-12, info.max_y - info.min_y);
    const span_z = @max(1e-12, info.max_z - info.min_z);

    const max_ix_f = @as(f64, @floatFromInt(info.gx - 1));
    const max_iy_f = @as(f64, @floatFromInt(info.gy - 1));
    const max_iz_f = @as(f64, @floatFromInt(info.gz - 1));

    const ux_min = std.math.clamp(((x.min - info.min_x) / span_x) * max_ix_f, 0.0, max_ix_f);
    const ux_max = std.math.clamp(((x.max - info.min_x) / span_x) * max_ix_f, 0.0, max_ix_f);
    const uy_min = std.math.clamp(((y.min - info.min_y) / span_y) * max_iy_f, 0.0, max_iy_f);
    const uy_max = std.math.clamp(((y.max - info.min_y) / span_y) * max_iy_f, 0.0, max_iy_f);
    const uz_min = std.math.clamp(((z.min - info.min_z) / span_z) * max_iz_f, 0.0, max_iz_f);
    const uz_max = std.math.clamp(((z.max - info.min_z) / span_z) * max_iz_f, 0.0, max_iz_f);

    // Evaluate all 8 corners of the query box (exact extrema when box lies inside a single voxel cell)
    const xs = [2]f64{ x.min, x.max };
    const ys = [2]f64{ y.min, y.max };
    const zs = [2]f64{ z.min, z.max };
    var lo: f64 = std.math.inf(f64);
    var hi: f64 = -std.math.inf(f64);

    for (xs) |px| {
        for (ys) |py| {
            for (zs) |pz| {
                const v = sampleFieldTrilinearScalar(slot, px, py, pz, default_val.min);
                if (v < lo) lo = v;
                if (v > hi) hi = v;
            }
        }
    }

    // If the box spans across voxel cell boundaries, include all spanned voxel lattice nodes
    const cell_x0: u32 = @min(@as(u32, @intFromFloat(@floor(ux_min))), info.gx - 2);
    const cell_x1: u32 = @min(@as(u32, @intFromFloat(@floor(ux_max))), info.gx - 2);
    const cell_y0: u32 = @min(@as(u32, @intFromFloat(@floor(uy_min))), info.gy - 2);
    const cell_y1: u32 = @min(@as(u32, @intFromFloat(@floor(uy_max))), info.gy - 2);
    const cell_z0: u32 = @min(@as(u32, @intFromFloat(@floor(uz_min))), info.gz - 2);
    const cell_z1: u32 = @min(@as(u32, @intFromFloat(@floor(uz_max))), info.gz - 2);

    if (cell_x0 != cell_x1 or cell_y0 != cell_y1 or cell_z0 != cell_z1) {
        var iz: u32 = cell_z0;
        while (iz <= cell_z1 + 1) : (iz += 1) {
            var iy: u32 = cell_y0;
            while (iy <= cell_y1 + 1) : (iy += 1) {
                var ix: u32 = cell_x0;
                while (ix <= cell_x1 + 1) : (ix += 1) {
                    const v = readVoxel(info.slice, info.gx, info.gy, ix, iy, iz);
                    if (v < lo) lo = v;
                    if (v > hi) hi = v;
                }
            }
        }
    }

    return Interval.init(lo - 1e-9, hi + 1e-9);
}

// ============================================================================
// SSA Bytecode Instruction Set (CDML §3.3)
// ============================================================================

pub const OpCode = enum(u8) {
    Const = 0x01,
    Var = 0x02,
    Add = 0x10,
    Sub = 0x11,
    Mul = 0x12,
    Div = 0x13,
    Pow = 0x14,
    Sin = 0x20,
    Cos = 0x21,
    Exp = 0x22,
    Log = 0x23,
    Sqrt = 0x24,
    AbsSmooth = 0x25,
    Abs = 0x26,
    RUnion = 0x30,
    RIntersect = 0x31,
    Lt = 0x32,
    Gt = 0x33,
    And = 0x34,
    Or = 0x35,
    FieldSample = 0x40,
    Probe = 0x41,
    FromId = 0x42,
};

pub const Instruction = union(OpCode) {
    Const: f64,
    Var: u32,
    Add: void,
    Sub: void,
    Mul: void,
    Div: void,
    Pow: void,
    Sin: void,
    Cos: void,
    Exp: void,
    Log: void,
    Sqrt: void,
    AbsSmooth: void,
    Abs: void,
    RUnion: void,
    RIntersect: void,
    Lt: void,
    Gt: void,
    And: void,
    Or: void,
    FieldSample: u32,
    Probe: []const u8,
    FromId: u64,
};

pub const ExprContext = enum {
    field,
    residual,
    predicate,
};

// Active evaluation state
pub var current_topo_id: TopoId = TopoId.INVALID;
pub var global_probe_cache: std.StringHashMap(f64) = std.StringHashMap(f64).init(memory.persistent_allocator);

pub fn setCurrentTopoId(tid: TopoId) void {
    current_topo_id = tid;
}

pub fn setProbeValue(id: []const u8, val: f64) !void {
    try global_probe_cache.put(id, val);
}

pub fn getProbeValue(id: []const u8) ?f64 {
    return global_probe_cache.get(id);
}

pub const Expression = struct {
    instructions: []Instruction,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Expression) void {
        for (self.instructions) |inst| {
            switch (inst) {
                .Probe => |s| self.allocator.free(s),
                else => {},
            }
        }
        self.allocator.free(self.instructions);
    }

    pub fn evalScalar(self: *const Expression, vars: []const f64) f64 {
        var stack: [256]f64 = undefined;
        var sp: usize = 0;

        for (self.instructions) |inst| {
            switch (inst) {
                .Const => |c| {
                    stack[sp] = c;
                    sp += 1;
                },
                .Var => |idx| {
                    stack[sp] = if (idx < vars.len) vars[idx] else 0.0;
                    sp += 1;
                },
                .Add => {
                    sp -= 1;
                    stack[sp - 1] += stack[sp];
                },
                .Sub => {
                    sp -= 1;
                    stack[sp - 1] -= stack[sp];
                },
                .Mul => {
                    sp -= 1;
                    stack[sp - 1] *= stack[sp];
                },
                .Div => {
                    sp -= 1;
                    stack[sp - 1] /= stack[sp];
                },
                .Pow => {
                    sp -= 1;
                    stack[sp - 1] = std.math.pow(f64, stack[sp - 1], stack[sp]);
                },
                .Sin => {
                    stack[sp - 1] = @sin(stack[sp - 1]);
                },
                .Cos => {
                    stack[sp - 1] = @cos(stack[sp - 1]);
                },
                .Exp => {
                    stack[sp - 1] = @exp(stack[sp - 1]);
                },
                .Log => {
                    stack[sp - 1] = if (stack[sp - 1] > 0.0) @log(stack[sp - 1]) else std.math.nan(f64);
                },
                .Sqrt => {
                    stack[sp - 1] = if (stack[sp - 1] >= 0.0) @sqrt(stack[sp - 1]) else std.math.nan(f64);
                },
                .AbsSmooth => {
                    sp -= 1;
                    const eps = stack[sp];
                    const u = stack[sp - 1];
                    stack[sp - 1] = @sqrt(u * u + eps * eps);
                },
                .Abs => {
                    stack[sp - 1] = @abs(stack[sp - 1]);
                },
                .RUnion => {
                    sp -= 1;
                    const v = stack[sp];
                    const u = stack[sp - 1];
                    stack[sp - 1] = u + v - @sqrt(u * u + v * v);
                },
                .RIntersect => {
                    sp -= 1;
                    const v = stack[sp];
                    const u = stack[sp - 1];
                    stack[sp - 1] = u + v + @sqrt(u * u + v * v);
                },
                .Lt => {
                    sp -= 1;
                    stack[sp - 1] = if (stack[sp - 1] < stack[sp]) 1.0 else 0.0;
                },
                .Gt => {
                    sp -= 1;
                    stack[sp - 1] = if (stack[sp - 1] > stack[sp]) 1.0 else 0.0;
                },
                .And => {
                    sp -= 1;
                    stack[sp - 1] = if (stack[sp - 1] != 0.0 and stack[sp] != 0.0) 1.0 else 0.0;
                },
                .Or => {
                    sp -= 1;
                    stack[sp - 1] = if (stack[sp - 1] != 0.0 or stack[sp] != 0.0) 1.0 else 0.0;
                },
                .FieldSample => {
                    // Pops 5 arguments: (slot, x, y, z, default)
                    const def_val = stack[sp - 1];
                    const z = stack[sp - 2];
                    const y = stack[sp - 3];
                    const x = stack[sp - 4];
                    const slot_f = stack[sp - 5];
                    sp -= 4;
                    const slot_id: u32 = @intFromFloat(@max(0.0, slot_f));
                    stack[sp - 1] = sampleFieldTrilinearScalar(slot_id, x, y, z, def_val);
                },
                .Probe => |id| {
                    stack[sp] = getProbeValue(id) orelse 0.0;
                    sp += 1;
                },
                .FromId => |target_h64| {
                    const match = current_topo_id.matchesId(target_h64);
                    stack[sp] = if (match) 1.0 else 0.0;
                    sp += 1;
                },
            }
        }

        return if (sp > 0) stack[sp - 1] else 0.0;
    }

    pub fn evalDual(self: *const Expression, vars: []const Dual) Dual {
        var stack: [256]Dual = undefined;
        var sp: usize = 0;

        for (self.instructions) |inst| {
            switch (inst) {
                .Const => |c| {
                    stack[sp] = Dual.constant(c);
                    sp += 1;
                },
                .Var => |idx| {
                    stack[sp] = if (idx < vars.len) vars[idx] else Dual.constant(0.0);
                    sp += 1;
                },
                .Add => {
                    sp -= 1;
                    stack[sp - 1] = stack[sp - 1].add(stack[sp]);
                },
                .Sub => {
                    sp -= 1;
                    stack[sp - 1] = stack[sp - 1].sub(stack[sp]);
                },
                .Mul => {
                    sp -= 1;
                    stack[sp - 1] = stack[sp - 1].mul(stack[sp]);
                },
                .Div => {
                    sp -= 1;
                    stack[sp - 1] = stack[sp - 1].div(stack[sp]);
                },
                .Pow => {
                    sp -= 1;
                    stack[sp - 1] = stack[sp - 1].pow(stack[sp]);
                },
                .Sin => {
                    stack[sp - 1] = stack[sp - 1].sin();
                },
                .Cos => {
                    stack[sp - 1] = stack[sp - 1].cos();
                },
                .Exp => {
                    stack[sp - 1] = stack[sp - 1].exp();
                },
                .Log => {
                    stack[sp - 1] = stack[sp - 1].log();
                },
                .Sqrt => {
                    stack[sp - 1] = stack[sp - 1].sqrt();
                },
                .AbsSmooth => {
                    sp -= 1;
                    stack[sp - 1] = stack[sp - 1].absSmooth(stack[sp]);
                },
                .Abs => {
                    stack[sp - 1] = stack[sp - 1].abs();
                },
                .RUnion => {
                    sp -= 1;
                    stack[sp - 1] = stack[sp - 1].rUnion(stack[sp]);
                },
                .RIntersect => {
                    sp -= 1;
                    stack[sp - 1] = stack[sp - 1].rIntersect(stack[sp]);
                },
                .Lt => {
                    sp -= 1;
                    const v: f64 = if (stack[sp - 1].val < stack[sp].val) 1.0 else 0.0;
                    stack[sp - 1] = Dual.constant(v);
                },
                .Gt => {
                    sp -= 1;
                    const v: f64 = if (stack[sp - 1].val > stack[sp].val) 1.0 else 0.0;
                    stack[sp - 1] = Dual.constant(v);
                },
                .And => {
                    sp -= 1;
                    const v: f64 = if (stack[sp - 1].val != 0.0 and stack[sp].val != 0.0) 1.0 else 0.0;
                    stack[sp - 1] = Dual.constant(v);
                },
                .Or => {
                    sp -= 1;
                    const v: f64 = if (stack[sp - 1].val != 0.0 or stack[sp].val != 0.0) 1.0 else 0.0;
                    stack[sp - 1] = Dual.constant(v);
                },
                .FieldSample => {
                    const def_d = stack[sp - 1];
                    const z_d = stack[sp - 2];
                    const y_d = stack[sp - 3];
                    const x_d = stack[sp - 4];
                    const slot_d = stack[sp - 5];
                    sp -= 4;
                    const slot_id: u32 = @intFromFloat(@max(0.0, slot_d.val));
                    stack[sp - 1] = sampleFieldTrilinearDual(slot_id, x_d, y_d, z_d, def_d);
                },
                .Probe => |id| {
                    const v = getProbeValue(id) orelse 0.0;
                    stack[sp] = Dual.constant(v);
                    sp += 1;
                },
                .FromId => |target_h64| {
                    const match = current_topo_id.matchesId(target_h64);
                    stack[sp] = Dual.constant(if (match) 1.0 else 0.0);
                    sp += 1;
                },
            }
        }

        return if (sp > 0) stack[sp - 1] else Dual.constant(0.0);
    }

    pub fn evalGrad(self: *const Expression, vars: []const f64, out_grad: ?[]f64) f64 {
        const val = self.evalScalar(vars);
        if (out_grad) |grad| {
            var dual_vars: [64]Dual = undefined;
            const n = @min(vars.len, 64);

            for (0..grad.len) |target_var| {
                for (0..n) |i| {
                    dual_vars[i] = Dual.variable(vars[i], i == target_var);
                }
                const res = self.evalDual(dual_vars[0..n]);
                grad[target_var] = res.der;
            }
        }
        return val;
    }

    /// Evaluates scalar value and gradient, returning error.ErrExprNanInf if any value or derivative is NaN/Inf (CDML §3.3.1, §13.1)
    pub fn evalGradChecked(self: *const Expression, vars: []const f64, out_grad: ?[]f64) !f64 {
        const val = self.evalGrad(vars, out_grad);
        if (std.math.isNan(val) or std.math.isInf(val)) {
            return error.ErrExprNanInf;
        }
        if (out_grad) |grad| {
            for (grad) |g| {
                if (std.math.isNan(g) or std.math.isInf(g)) {
                    return error.ErrExprNanInf;
                }
            }
        }
        return val;
    }

    pub fn evalInterval(self: *const Expression, vars: []const Interval) Interval {
        var stack: [256]Interval = undefined;
        var sp: usize = 0;

        for (self.instructions) |inst| {
            switch (inst) {
                .Const => |c| {
                    stack[sp] = Interval.point(c);
                    sp += 1;
                },
                .Var => |idx| {
                    stack[sp] = if (idx < vars.len) vars[idx] else Interval.point(0.0);
                    sp += 1;
                },
                .Add => {
                    sp -= 1;
                    stack[sp - 1] = stack[sp - 1].add(stack[sp]);
                },
                .Sub => {
                    sp -= 1;
                    stack[sp - 1] = stack[sp - 1].sub(stack[sp]);
                },
                .Mul => {
                    sp -= 1;
                    stack[sp - 1] = stack[sp - 1].mul(stack[sp]);
                },
                .Div => {
                    sp -= 1;
                    stack[sp - 1] = stack[sp - 1].div(stack[sp]);
                },
                .Pow => {
                    sp -= 1;
                    stack[sp - 1] = stack[sp - 1].pow(stack[sp]);
                },
                .Sin => {
                    stack[sp - 1] = stack[sp - 1].sin();
                },
                .Cos => {
                    stack[sp - 1] = stack[sp - 1].cos();
                },
                .Exp => {
                    stack[sp - 1] = Interval.init(@exp(stack[sp - 1].min), @exp(stack[sp - 1].max));
                },
                .Log => {
                    stack[sp - 1] = Interval.init(@log(@max(1e-15, stack[sp - 1].min)), @log(@max(1e-15, stack[sp - 1].max)));
                },
                .Sqrt => {
                    stack[sp - 1] = stack[sp - 1].sqrt();
                },
                .AbsSmooth => {
                    sp -= 1;
                    stack[sp - 1] = stack[sp - 1].absSmooth(stack[sp]);
                },
                .Abs => {
                    stack[sp - 1] = stack[sp - 1].abs();
                },
                .RUnion => {
                    sp -= 1;
                    stack[sp - 1] = stack[sp - 1].rUnion(stack[sp]);
                },
                .RIntersect => {
                    sp -= 1;
                    stack[sp - 1] = stack[sp - 1].rIntersect(stack[sp]);
                },
                .Lt, .Gt, .And, .Or => {
                    sp -= 1;
                    stack[sp - 1] = Interval.init(0.0, 1.0);
                },
                .FieldSample => {
                    const def_i = stack[sp - 1];
                    const z_i = stack[sp - 2];
                    const y_i = stack[sp - 3];
                    const x_i = stack[sp - 4];
                    const slot_i = stack[sp - 5];
                    sp -= 4;
                    const slot_id: u32 = @intFromFloat(@max(0.0, slot_i.min));
                    stack[sp - 1] = sampleFieldTrilinearInterval(slot_id, x_i, y_i, z_i, def_i);
                },
                .Probe => |id| {
                    const v = getProbeValue(id) orelse 0.0;
                    stack[sp] = Interval.point(v);
                    sp += 1;
                },
                .FromId => {
                    stack[sp] = Interval.init(0.0, 1.0);
                    sp += 1;
                },
            }
        }

        return if (sp > 0) stack[sp - 1] else Interval.point(0.0);
    }
};

// ============================================================================
// Recursive-Descent Expression Compiler with Vector Scalarisation (CDML §3.3.1)
// ============================================================================

const CompValue = union(enum) {
    scalar: std.ArrayList(Instruction),
    vec2: [2]std.ArrayList(Instruction),
    vec3: [3]std.ArrayList(Instruction),

    fn deinit(self: *CompValue, alloc: std.mem.Allocator) void {
        switch (self.*) {
            .scalar => |*s| freeInstList(s, alloc),
            .vec2 => |*v| {
                freeInstList(&v[0], alloc);
                freeInstList(&v[1], alloc);
            },
            .vec3 => |*v| {
                freeInstList(&v[0], alloc);
                freeInstList(&v[1], alloc);
                freeInstList(&v[2], alloc);
            },
        }
    }
};

fn freeInstList(list: *std.ArrayList(Instruction), alloc: std.mem.Allocator) void {
    for (list.items) |inst| {
        switch (inst) {
            .Probe => |s| alloc.free(s),
            else => {},
        }
    }
    list.deinit(alloc);
}

fn cloneInstList(src: *const std.ArrayList(Instruction), alloc: std.mem.Allocator) !std.ArrayList(Instruction) {
    var dst: std.ArrayList(Instruction) = .empty;
    errdefer freeInstList(&dst, alloc);
    try dst.ensureTotalCapacity(alloc, src.items.len);
    for (src.items) |inst| {
        switch (inst) {
            .Probe => |s| {
                const copy = try alloc.dupe(u8, s);
                try dst.append(alloc, .{ .Probe = copy });
            },
            else => try dst.append(alloc, inst),
        }
    }
    return dst;
}

fn appendInstList(dst: *std.ArrayList(Instruction), src: *const std.ArrayList(Instruction), alloc: std.mem.Allocator) !void {
    for (src.items) |inst| {
        switch (inst) {
            .Probe => |s| {
                const copy = try alloc.dupe(u8, s);
                try dst.append(alloc, .{ .Probe = copy });
            },
            else => try dst.append(alloc, inst),
        }
    }
}

fn combineBinaryScalar(
    mut_a: *std.ArrayList(Instruction),
    mut_b: *std.ArrayList(Instruction),
    op: Instruction,
    alloc: std.mem.Allocator,
) !std.ArrayList(Instruction) {
    var out: std.ArrayList(Instruction) = .empty;
    errdefer freeInstList(&out, alloc);
    try appendInstList(&out, mut_a, alloc);
    try appendInstList(&out, mut_b, alloc);
    try out.append(alloc, op);
    return out;
}

const CompilerError = error{
    OutOfMemory,
    InvalidCharacter,
    Overflow,
    ErrExprContext,
    ErrUndefinedRef,
    SyntaxError,
};

const Parser = struct {
    allocator: std.mem.Allocator,
    text: []const u8,
    pos: usize = 0,
    context: ExprContext,
    var_map: ?*const std.StringHashMap(u32),
    const_map: ?*const std.StringHashMap(f64) = null,
    def_map: ?*const std.StringHashMap([]const u8) = null,

    fn skipWhitespace(self: *Parser) void {
        while (self.pos < self.text.len and std.ascii.isWhitespace(self.text[self.pos])) {
            self.pos += 1;
        }
    }

    fn peekChar(self: *Parser) ?u8 {
        self.skipWhitespace();
        if (self.pos < self.text.len) return self.text[self.pos];
        return null;
    }

    fn matchChar(self: *Parser, ch: u8) bool {
        self.skipWhitespace();
        if (self.pos < self.text.len and self.text[self.pos] == ch) {
            self.pos += 1;
            return true;
        }
        return false;
    }

    fn matchKeyword(self: *Parser, kw: []const u8) bool {
        self.skipWhitespace();
        if (self.pos + kw.len > self.text.len) return false;
        if (!std.mem.eql(u8, self.text[self.pos .. self.pos + kw.len], kw)) return false;
        const after = self.pos + kw.len;
        if (after < self.text.len and (std.ascii.isAlphanumeric(self.text[after]) or self.text[after] == '_' or self.text[after] == '.')) {
            return false;
        }
        self.pos = after;
        return true;
    }

    fn parseExpr(self: *Parser) CompilerError!CompValue {
        return self.parseOr();
    }

    fn parseOr(self: *Parser) CompilerError!CompValue {
        var left = try self.parseAnd();
        errdefer left.deinit(self.allocator);

        while (self.matchKeyword("or")) {
            if (self.context != .predicate) return error.ErrExprContext;
            var right = try self.parseAnd();
            defer right.deinit(self.allocator);
            if (left != .scalar or right != .scalar) return error.SyntaxError;
            const combined = try combineBinaryScalar(&left.scalar, &right.scalar, .Or, self.allocator);
            left.deinit(self.allocator);
            left = .{ .scalar = combined };
        }
        return left;
    }

    fn parseAnd(self: *Parser) CompilerError!CompValue {
        var left = try self.parseCmp();
        errdefer left.deinit(self.allocator);

        while (self.matchKeyword("and")) {
            if (self.context != .predicate) return error.ErrExprContext;
            var right = try self.parseCmp();
            defer right.deinit(self.allocator);
            if (left != .scalar or right != .scalar) return error.SyntaxError;
            const combined = try combineBinaryScalar(&left.scalar, &right.scalar, .And, self.allocator);
            left.deinit(self.allocator);
            left = .{ .scalar = combined };
        }
        return left;
    }

    fn parseCmp(self: *Parser) CompilerError!CompValue {
        var left = try self.parseAdd();
        errdefer left.deinit(self.allocator);

        while (true) {
            const c = self.peekChar() orelse break;
            if (c == '<' or c == '>') {
                if (self.context != .predicate) return error.ErrExprContext;
                self.pos += 1;
                var right = try self.parseAdd();
                defer right.deinit(self.allocator);
                if (left != .scalar or right != .scalar) return error.SyntaxError;
                const op: Instruction = if (c == '<') .Lt else .Gt;
                const combined = try combineBinaryScalar(&left.scalar, &right.scalar, op, self.allocator);
                left.deinit(self.allocator);
                left = .{ .scalar = combined };
            } else {
                break;
            }
        }
        return left;
    }

    fn parseAdd(self: *Parser) CompilerError!CompValue {
        var left = try self.parseMul();
        errdefer left.deinit(self.allocator);

        while (true) {
            const c = self.peekChar() orelse break;
            if (c == '+' or c == '-') {
                self.pos += 1;
                var right = try self.parseMul();
                defer right.deinit(self.allocator);
                const op: Instruction = if (c == '+') .Add else .Sub;

                if (left == .scalar and right == .scalar) {
                    const combined = try combineBinaryScalar(&left.scalar, &right.scalar, op, self.allocator);
                    left.deinit(self.allocator);
                    left = .{ .scalar = combined };
                } else if (left == .vec2 and right == .vec2) {
                    const c0 = try combineBinaryScalar(&left.vec2[0], &right.vec2[0], op, self.allocator);
                    errdefer {
                        var tmp = c0;
                        freeInstList(&tmp, self.allocator);
                    }
                    const c1 = try combineBinaryScalar(&left.vec2[1], &right.vec2[1], op, self.allocator);
                    left.deinit(self.allocator);
                    left = .{ .vec2 = .{ c0, c1 } };
                } else if (left == .vec3 and right == .vec3) {
                    const c0 = try combineBinaryScalar(&left.vec3[0], &right.vec3[0], op, self.allocator);
                    errdefer {
                        var tmp = c0;
                        freeInstList(&tmp, self.allocator);
                    }
                    const c1 = try combineBinaryScalar(&left.vec3[1], &right.vec3[1], op, self.allocator);
                    errdefer {
                        var tmp = c1;
                        freeInstList(&tmp, self.allocator);
                    }
                    const c2 = try combineBinaryScalar(&left.vec3[2], &right.vec3[2], op, self.allocator);
                    left.deinit(self.allocator);
                    left = .{ .vec3 = .{ c0, c1, c2 } };
                } else {
                    return error.SyntaxError;
                }
            } else {
                break;
            }
        }
        return left;
    }

    fn parseMul(self: *Parser) CompilerError!CompValue {
        var left = try self.parseUnary();
        errdefer left.deinit(self.allocator);

        while (true) {
            const c = self.peekChar() orelse break;
            if (c == '*' or c == '/') {
                self.pos += 1;
                var right = try self.parseUnary();
                defer right.deinit(self.allocator);
                const op: Instruction = if (c == '*') .Mul else .Div;

                if (left == .scalar and right == .scalar) {
                    const combined = try combineBinaryScalar(&left.scalar, &right.scalar, op, self.allocator);
                    left.deinit(self.allocator);
                    left = .{ .scalar = combined };
                } else if (left == .scalar and right == .vec2 and c == '*') {
                    const c0 = try combineBinaryScalar(&left.scalar, &right.vec2[0], .Mul, self.allocator);
                    errdefer {
                        var tmp = c0;
                        freeInstList(&tmp, self.allocator);
                    }
                    const c1 = try combineBinaryScalar(&left.scalar, &right.vec2[1], .Mul, self.allocator);
                    left.deinit(self.allocator);
                    left = .{ .vec2 = .{ c0, c1 } };
                } else if (left == .vec2 and right == .scalar) {
                    const c0 = try combineBinaryScalar(&left.vec2[0], &right.scalar, op, self.allocator);
                    errdefer {
                        var tmp = c0;
                        freeInstList(&tmp, self.allocator);
                    }
                    const c1 = try combineBinaryScalar(&left.vec2[1], &right.scalar, op, self.allocator);
                    left.deinit(self.allocator);
                    left = .{ .vec2 = .{ c0, c1 } };
                } else if (left == .scalar and right == .vec3 and c == '*') {
                    const c0 = try combineBinaryScalar(&left.scalar, &right.vec3[0], .Mul, self.allocator);
                    errdefer {
                        var tmp = c0;
                        freeInstList(&tmp, self.allocator);
                    }
                    const c1 = try combineBinaryScalar(&left.scalar, &right.vec3[1], .Mul, self.allocator);
                    errdefer {
                        var tmp = c1;
                        freeInstList(&tmp, self.allocator);
                    }
                    const c2 = try combineBinaryScalar(&left.scalar, &right.vec3[2], .Mul, self.allocator);
                    left.deinit(self.allocator);
                    left = .{ .vec3 = .{ c0, c1, c2 } };
                } else if (left == .vec3 and right == .scalar) {
                    const c0 = try combineBinaryScalar(&left.vec3[0], &right.scalar, op, self.allocator);
                    errdefer {
                        var tmp = c0;
                        freeInstList(&tmp, self.allocator);
                    }
                    const c1 = try combineBinaryScalar(&left.vec3[1], &right.scalar, op, self.allocator);
                    errdefer {
                        var tmp = c1;
                        freeInstList(&tmp, self.allocator);
                    }
                    const c2 = try combineBinaryScalar(&left.vec3[2], &right.scalar, op, self.allocator);
                    left.deinit(self.allocator);
                    left = .{ .vec3 = .{ c0, c1, c2 } };
                } else {
                    return error.SyntaxError;
                }
            } else {
                break;
            }
        }
        return left;
    }

    fn parseUnary(self: *Parser) CompilerError!CompValue {
        if (self.matchChar('+')) {
            return self.parseUnary();
        }
        if (self.matchChar('-')) {
            var sub = try self.parseUnary();
            errdefer sub.deinit(self.allocator);
            switch (sub) {
                .scalar => |*s| {
                    try s.append(self.allocator, .{ .Const = -1.0 });
                    try s.append(self.allocator, .Mul);
                },
                .vec2 => |*v| {
                    for (0..2) |k| {
                        try v[k].append(self.allocator, .{ .Const = -1.0 });
                        try v[k].append(self.allocator, .Mul);
                    }
                },
                .vec3 => |*v| {
                    for (0..3) |k| {
                        try v[k].append(self.allocator, .{ .Const = -1.0 });
                        try v[k].append(self.allocator, .Mul);
                    }
                },
            }
            return sub;
        }
        return self.parsePow();
    }

    fn parsePow(self: *Parser) CompilerError!CompValue {
        var base = try self.parsePostfix();
        errdefer base.deinit(self.allocator);

        if (self.matchChar('^')) {
            var exp = try self.parseUnary();
            defer exp.deinit(self.allocator);
            if (base != .scalar or exp != .scalar) return error.SyntaxError;
            const combined = try combineBinaryScalar(&base.scalar, &exp.scalar, .Pow, self.allocator);
            base.deinit(self.allocator);
            base = .{ .scalar = combined };
        }
        return base;
    }

    fn parsePostfix(self: *Parser) CompilerError!CompValue {
        var val = try self.parsePrimary();
        errdefer val.deinit(self.allocator);

        // Support postfix component extraction (.u, .v, .x, .y, .z) on any vector value
        while (self.pos < self.text.len and self.text[self.pos] == '.') {
            self.pos += 1;
            const m_start = self.pos;
            while (self.pos < self.text.len and (std.ascii.isAlphanumeric(self.text[self.pos]) or self.text[self.pos] == '_')) {
                self.pos += 1;
            }
            const member = self.text[m_start..self.pos];
            if (val == .vec2) {
                if (std.mem.eql(u8, member, "u") or std.mem.eql(u8, member, "x")) {
                    const keep = try cloneInstList(&val.vec2[0], self.allocator);
                    val.deinit(self.allocator);
                    val = .{ .scalar = keep };
                } else if (std.mem.eql(u8, member, "v") or std.mem.eql(u8, member, "y")) {
                    const keep = try cloneInstList(&val.vec2[1], self.allocator);
                    val.deinit(self.allocator);
                    val = .{ .scalar = keep };
                } else {
                    return error.ErrUndefinedRef;
                }
            } else if (val == .vec3) {
                if (std.mem.eql(u8, member, "x") or std.mem.eql(u8, member, "u")) {
                    const keep = try cloneInstList(&val.vec3[0], self.allocator);
                    val.deinit(self.allocator);
                    val = .{ .scalar = keep };
                } else if (std.mem.eql(u8, member, "y") or std.mem.eql(u8, member, "v")) {
                    const keep = try cloneInstList(&val.vec3[1], self.allocator);
                    val.deinit(self.allocator);
                    val = .{ .scalar = keep };
                } else if (std.mem.eql(u8, member, "z") or std.mem.eql(u8, member, "w")) {
                    const keep = try cloneInstList(&val.vec3[2], self.allocator);
                    val.deinit(self.allocator);
                    val = .{ .scalar = keep };
                } else {
                    return error.ErrUndefinedRef;
                }
            } else {
                return error.ErrUndefinedRef;
            }
        }

        return val;
    }

    fn makeScalarInst(self: *Parser, inst: Instruction) !CompValue {
        var list: std.ArrayList(Instruction) = .empty;
        try list.append(self.allocator, inst);
        return .{ .scalar = list };
    }

    fn resolveVariableOrVector(self: *Parser, name: []const u8) CompilerError!CompValue {
        // 1. Check predicate-only variables in field or residual contexts (§3.3.2)
        if (self.context != .predicate) {
            if (std.mem.eql(u8, name, "nx") or std.mem.eql(u8, name, "ny") or std.mem.eql(u8, name, "nz") or
                std.mem.eql(u8, name, "tx") or std.mem.eql(u8, name, "ty") or std.mem.eql(u8, name, "tz") or
                std.mem.eql(u8, name, "k_min") or std.mem.eql(u8, name, "k_max") or
                std.mem.eql(u8, name, "k_gauss") or std.mem.eql(u8, name, "k_mean") or
                std.mem.eql(u8, name, "area") or std.mem.eql(u8, name, "length") or
                std.mem.eql(u8, name, "from_id"))
            {
                return error.ErrExprContext;
            }
        }

        // 2. Constants
        if (std.mem.eql(u8, name, "PI")) {
            return self.makeScalarInst(.{ .Const = std.math.pi });
        }

        // 3. Check local <def> macro expansion first
        if (self.def_map) |dm| {
            if (dm.get(name)) |def_expr| {
                var sub_parser = Parser{
                    .allocator = self.allocator,
                    .text = def_expr,
                    .pos = 0,
                    .context = self.context,
                    .var_map = self.var_map,
                    .const_map = self.const_map,
                    .def_map = self.def_map,
                };
                return sub_parser.parseExpr();
            }
        }

        // 4. Check if var_map or const_map has direct scalar or vector component entries
        {
            var buf_x: [128]u8 = undefined;
            var buf_y: [128]u8 = undefined;
            var buf_z: [128]u8 = undefined;
            if (name.len + 2 < buf_x.len) {
                const kx = std.fmt.bufPrint(&buf_x, "{s}.x", .{name}) catch "";
                const ky = std.fmt.bufPrint(&buf_y, "{s}.y", .{name}) catch "";
                const kz = std.fmt.bufPrint(&buf_z, "{s}.z", .{name}) catch "";

                const vx = if (self.var_map) |vm| vm.get(kx) else null;
                const vy = if (self.var_map) |vm| vm.get(ky) else null;
                const vz = if (self.var_map) |vm| vm.get(kz) else null;
                const cx = if (self.const_map) |cm| cm.get(kx) else null;
                const cy = if (self.const_map) |cm| cm.get(ky) else null;
                const cz = if (self.const_map) |cm| cm.get(kz) else null;

                if ((vx != null or cx != null) and (vy != null or cy != null) and (vz != null or cz != null)) {
                    var c0: std.ArrayList(Instruction) = .empty;
                    errdefer c0.deinit(self.allocator);
                    var c1: std.ArrayList(Instruction) = .empty;
                    errdefer c1.deinit(self.allocator);
                    var c2: std.ArrayList(Instruction) = .empty;
                    errdefer c2.deinit(self.allocator);
                    try c0.append(self.allocator, if (vx) |ix| .{ .Var = ix } else .{ .Const = cx.? });
                    try c1.append(self.allocator, if (vy) |iy| .{ .Var = iy } else .{ .Const = cy.? });
                    try c2.append(self.allocator, if (vz) |iz| .{ .Var = iz } else .{ .Const = cz.? });
                    return .{ .vec3 = .{ c0, c1, c2 } };
                }

                // Check if name is a Vec2 in var_map/const_map (name.u, name.v)
                const ku = std.fmt.bufPrint(&buf_x, "{s}.u", .{name}) catch "";
                const kv = std.fmt.bufPrint(&buf_y, "{s}.v", .{name}) catch "";
                const vu = if (self.var_map) |vm| vm.get(ku) else null;
                const vv = if (self.var_map) |vm| vm.get(kv) else null;
                const cu = if (self.const_map) |cm| cm.get(ku) else null;
                const cv = if (self.const_map) |cm| cm.get(kv) else null;
                if ((vu != null or cu != null) and (vv != null or cv != null)) {
                    var c0: std.ArrayList(Instruction) = .empty;
                    errdefer c0.deinit(self.allocator);
                    var c1: std.ArrayList(Instruction) = .empty;
                    errdefer c1.deinit(self.allocator);
                    try c0.append(self.allocator, if (vu) |iu| .{ .Var = iu } else .{ .Const = cu.? });
                    try c1.append(self.allocator, if (vv) |iv| .{ .Var = iv } else .{ .Const = cv.? });
                    return .{ .vec2 = .{ c0, c1 } };
                }
            }

            if (self.var_map) |vm| {
                if (vm.get(name)) |v_idx| {
                    return self.makeScalarInst(.{ .Var = v_idx });
                }
            }
            if (self.const_map) |cm| {
                if (cm.get(name)) |c_val| {
                    return self.makeScalarInst(.{ .Const = c_val });
                }
            }
        }

        // 4. Built-in coordinate variables by context
        if (self.context == .predicate) {
            if (std.mem.eql(u8, name, "x")) return self.makeScalarInst(.{ .Var = 0 });
            if (std.mem.eql(u8, name, "y")) return self.makeScalarInst(.{ .Var = 1 });
            if (std.mem.eql(u8, name, "z")) return self.makeScalarInst(.{ .Var = 2 });
            if (std.mem.eql(u8, name, "nx")) return self.makeScalarInst(.{ .Var = 3 });
            if (std.mem.eql(u8, name, "ny")) return self.makeScalarInst(.{ .Var = 4 });
            if (std.mem.eql(u8, name, "nz")) return self.makeScalarInst(.{ .Var = 5 });
            if (std.mem.eql(u8, name, "tx")) return self.makeScalarInst(.{ .Var = 6 });
            if (std.mem.eql(u8, name, "ty")) return self.makeScalarInst(.{ .Var = 7 });
            if (std.mem.eql(u8, name, "tz")) return self.makeScalarInst(.{ .Var = 8 });
            if (std.mem.eql(u8, name, "k_min")) return self.makeScalarInst(.{ .Var = 9 });
            if (std.mem.eql(u8, name, "k_max")) return self.makeScalarInst(.{ .Var = 10 });
            if (std.mem.eql(u8, name, "k_gauss")) return self.makeScalarInst(.{ .Var = 11 });
            if (std.mem.eql(u8, name, "k_mean")) return self.makeScalarInst(.{ .Var = 12 });
            if (std.mem.eql(u8, name, "area")) return self.makeScalarInst(.{ .Var = 13 });
            if (std.mem.eql(u8, name, "length")) return self.makeScalarInst(.{ .Var = 14 });
        } else {
            if (std.mem.eql(u8, name, "x") or std.mem.eql(u8, name, "u") or std.mem.eql(u8, name, "t")) return self.makeScalarInst(.{ .Var = 0 });
            if (std.mem.eql(u8, name, "y") or std.mem.eql(u8, name, "v")) return self.makeScalarInst(.{ .Var = 1 });
            if (std.mem.eql(u8, name, "z") or std.mem.eql(u8, name, "w")) return self.makeScalarInst(.{ .Var = 2 });
        }

        // 5. Indexed scalar and vector variables:
        //    - x0, x1, q0, q1 -> Scalar Var(idx)
        //    - v0, v1, v2, v3 -> Vec2(Var(2*idx), Var(2*idx + 1))
        //    - e0, e1, e2, p0, p1, p2 -> Vec3(Var(3*idx), Var(3*idx + 1), Var(3*idx + 2))
        if (name.len > 1 and std.ascii.isDigit(name[1])) {
            if (name[0] == 'x' or name[0] == 'q') {
                if (std.fmt.parseInt(u32, name[1..], 10)) |idx| {
                    return self.makeScalarInst(.{ .Var = idx });
                } else |_| {}
            } else if (name[0] == 'v') {
                if (std.fmt.parseInt(u32, name[1..], 10)) |idx| {
                    var c0: std.ArrayList(Instruction) = .empty;
                    errdefer c0.deinit(self.allocator);
                    var c1: std.ArrayList(Instruction) = .empty;
                    errdefer c1.deinit(self.allocator);
                    try c0.append(self.allocator, .{ .Var = idx * 2 });
                    try c1.append(self.allocator, .{ .Var = idx * 2 + 1 });
                    return .{ .vec2 = .{ c0, c1 } };
                } else |_| {}
            } else if (name[0] == 'e' or name[0] == 'p') {
                if (std.fmt.parseInt(u32, name[1..], 10)) |idx| {
                    var c0: std.ArrayList(Instruction) = .empty;
                    errdefer c0.deinit(self.allocator);
                    var c1: std.ArrayList(Instruction) = .empty;
                    errdefer c1.deinit(self.allocator);
                    var c2: std.ArrayList(Instruction) = .empty;
                    errdefer c2.deinit(self.allocator);
                    try c0.append(self.allocator, .{ .Var = idx * 3 });
                    try c1.append(self.allocator, .{ .Var = idx * 3 + 1 });
                    try c2.append(self.allocator, .{ .Var = idx * 3 + 2 });
                    return .{ .vec3 = .{ c0, c1, c2 } };
                } else |_| {}
            }
        }

        return error.ErrUndefinedRef;
    }

    fn parseStringArg(self: *Parser) CompilerError![]const u8 {
        if (!self.matchChar('(')) return error.SyntaxError;
        self.skipWhitespace();
        var quote: u8 = 0;
        if (self.pos < self.text.len and (self.text[self.pos] == '\'' or self.text[self.pos] == '"')) {
            quote = self.text[self.pos];
            self.pos += 1;
        }
        const start = self.pos;
        while (self.pos < self.text.len) {
            const c = self.text[self.pos];
            if (quote != 0 and c == quote) break;
            if (quote == 0 and (c == ')' or std.ascii.isWhitespace(c))) break;
            self.pos += 1;
        }
        const slice = self.text[start..self.pos];
        if (quote != 0 and self.pos < self.text.len and self.text[self.pos] == quote) {
            self.pos += 1;
        }
        if (!self.matchChar(')')) return error.SyntaxError;
        return slice;
    }

    fn parsePrimary(self: *Parser) CompilerError!CompValue {
        self.skipWhitespace();
        if (self.pos >= self.text.len) return error.SyntaxError;

        const ch = self.text[self.pos];

        // Parenthesized expression
        if (ch == '(') {
            self.pos += 1;
            const inner = try self.parseExpr();
            if (!self.matchChar(')')) {
                var tmp = inner;
                tmp.deinit(self.allocator);
                return error.SyntaxError;
            }
            return inner;
        }

        // Number literal
        if (std.ascii.isDigit(ch) or (ch == '.' and self.pos + 1 < self.text.len and std.ascii.isDigit(self.text[self.pos + 1]))) {
            const start = self.pos;
            while (self.pos < self.text.len) {
                const c = self.text[self.pos];
                if (std.ascii.isDigit(c) or c == '.' or c == 'e' or c == 'E' or
                    ((c == '-' or c == '+') and (self.text[self.pos - 1] == 'e' or self.text[self.pos - 1] == 'E')))
                {
                    self.pos += 1;
                } else {
                    break;
                }
            }
            const num = std.fmt.parseFloat(f64, self.text[start..self.pos]) catch return error.SyntaxError;
            return self.makeScalarInst(.{ .Const = num });
        }

        // Identifier or function call
        if (std.ascii.isAlphabetic(ch) or ch == '_') {
            const start = self.pos;
            while (self.pos < self.text.len and (std.ascii.isAlphanumeric(self.text[self.pos]) or self.text[self.pos] == '_')) {
                self.pos += 1;
            }
            var name = self.text[start..self.pos];

            // Check if this is a prefixed identifier in var_map like `fs.bolt_d`
            if (self.pos < self.text.len and self.text[self.pos] == '.') {
                const dot_pos = self.pos;
                var scan = dot_pos + 1;
                while (scan < self.text.len and (std.ascii.isAlphanumeric(self.text[scan]) or self.text[scan] == '_')) {
                    scan += 1;
                }
                const full_candidate = self.text[start..scan];
                const in_vm = if (self.var_map) |vm| vm.contains(full_candidate) else false;
                const in_cm = if (self.const_map) |cm| cm.contains(full_candidate) else false;
                if (in_vm or in_cm) {
                    self.pos = scan;
                    name = full_candidate;
                }
            }

            // Check if followed by '(' -> Function call
            self.skipWhitespace();
            if (self.pos < self.text.len and self.text[self.pos] == '(') {
                if (std.mem.eql(u8, name, "ref")) {
                    const ref_id = try self.parseStringArg();
                    return self.resolveVariableOrVector(ref_id);
                }

                if (std.mem.eql(u8, name, "probe")) {
                    const probe_id = try self.parseStringArg();
                    const id_copy = try self.allocator.dupe(u8, probe_id);
                    return self.makeScalarInst(.{ .Probe = id_copy });
                }

                if (std.mem.eql(u8, name, "from_id")) {
                    if (self.context != .predicate) return error.ErrExprContext;
                    const target_id = try self.parseStringArg();
                    return self.makeScalarInst(.{ .FromId = h64(target_id) });
                }

                // Parse argument list
                self.pos += 1; // consume '('
                var args: std.ArrayList(CompValue) = .empty;
                defer {
                    for (args.items) |*a| a.deinit(self.allocator);
                    args.deinit(self.allocator);
                }

                if (!self.matchChar(')')) {
                    while (true) {
                        const arg = try self.parseExpr();
                        try args.append(self.allocator, arg);
                        if (self.matchChar(',')) continue;
                        if (self.matchChar(')')) break;
                        return error.SyntaxError;
                    }
                }

                // Vector constructors & operations (CDML §3.3.1)
                if (std.mem.eql(u8, name, "vec2")) {
                    if (args.items.len != 2 or args.items[0] != .scalar or args.items[1] != .scalar) return error.SyntaxError;
                    const c0 = try cloneInstList(&args.items[0].scalar, self.allocator);
                    errdefer {
                        var tmp = c0;
                        freeInstList(&tmp, self.allocator);
                    }
                    const c1 = try cloneInstList(&args.items[1].scalar, self.allocator);
                    return .{ .vec2 = .{ c0, c1 } };
                }

                if (std.mem.eql(u8, name, "vec3")) {
                    if (args.items.len != 3 or args.items[0] != .scalar or args.items[1] != .scalar or args.items[2] != .scalar) return error.SyntaxError;
                    const c0 = try cloneInstList(&args.items[0].scalar, self.allocator);
                    errdefer {
                        var tmp = c0;
                        freeInstList(&tmp, self.allocator);
                    }
                    const c1 = try cloneInstList(&args.items[1].scalar, self.allocator);
                    errdefer {
                        var tmp = c1;
                        freeInstList(&tmp, self.allocator);
                    }
                    const c2 = try cloneInstList(&args.items[2].scalar, self.allocator);
                    return .{ .vec3 = .{ c0, c1, c2 } };
                }

                if (std.mem.eql(u8, name, "dot")) {
                    if (args.items.len != 2) return error.SyntaxError;
                    const a = &args.items[0];
                    const b = &args.items[1];
                    if (a.* == .vec2 and b.* == .vec2) {
                        // a.u * b.u + a.v * b.v
                        var m0 = try combineBinaryScalar(&a.vec2[0], &b.vec2[0], .Mul, self.allocator);
                        defer freeInstList(&m0, self.allocator);
                        var m1 = try combineBinaryScalar(&a.vec2[1], &b.vec2[1], .Mul, self.allocator);
                        defer freeInstList(&m1, self.allocator);
                        const sum = try combineBinaryScalar(&m0, &m1, .Add, self.allocator);
                        return .{ .scalar = sum };
                    } else if (a.* == .vec3 and b.* == .vec3) {
                        // a.x * b.x + a.y * b.y + a.z * b.z
                        var m0 = try combineBinaryScalar(&a.vec3[0], &b.vec3[0], .Mul, self.allocator);
                        defer freeInstList(&m0, self.allocator);
                        var m1 = try combineBinaryScalar(&a.vec3[1], &b.vec3[1], .Mul, self.allocator);
                        defer freeInstList(&m1, self.allocator);
                        var m2 = try combineBinaryScalar(&a.vec3[2], &b.vec3[2], .Mul, self.allocator);
                        defer freeInstList(&m2, self.allocator);
                        var s01 = try combineBinaryScalar(&m0, &m1, .Add, self.allocator);
                        defer freeInstList(&s01, self.allocator);
                        const sum = try combineBinaryScalar(&s01, &m2, .Add, self.allocator);
                        return .{ .scalar = sum };
                    }
                    return error.SyntaxError;
                }

                if (std.mem.eql(u8, name, "cross")) {
                    if (args.items.len != 2) return error.SyntaxError;
                    const a = &args.items[0];
                    const b = &args.items[1];
                    if (a.* == .vec3 and b.* == .vec3) {
                        // cx = a.y*b.z - a.z*b.y
                        var ay_bz = try combineBinaryScalar(&a.vec3[1], &b.vec3[2], .Mul, self.allocator);
                        defer freeInstList(&ay_bz, self.allocator);
                        var az_by = try combineBinaryScalar(&a.vec3[2], &b.vec3[1], .Mul, self.allocator);
                        defer freeInstList(&az_by, self.allocator);
                        const cx = try combineBinaryScalar(&ay_bz, &az_by, .Sub, self.allocator);
                        errdefer {
                            var tmp = cx;
                            freeInstList(&tmp, self.allocator);
                        }

                        // cy = a.z*b.x - a.x*b.z
                        var az_bx = try combineBinaryScalar(&a.vec3[2], &b.vec3[0], .Mul, self.allocator);
                        defer freeInstList(&az_bx, self.allocator);
                        var ax_bz = try combineBinaryScalar(&a.vec3[0], &b.vec3[2], .Mul, self.allocator);
                        defer freeInstList(&ax_bz, self.allocator);
                        const cy = try combineBinaryScalar(&az_bx, &ax_bz, .Sub, self.allocator);
                        errdefer {
                            var tmp = cy;
                            freeInstList(&tmp, self.allocator);
                        }

                        // cz = a.x*b.y - a.y*b.x
                        var ax_by = try combineBinaryScalar(&a.vec3[0], &b.vec3[1], .Mul, self.allocator);
                        defer freeInstList(&ax_by, self.allocator);
                        var ay_bx = try combineBinaryScalar(&a.vec3[1], &b.vec3[0], .Mul, self.allocator);
                        defer freeInstList(&ay_bx, self.allocator);
                        const cz = try combineBinaryScalar(&ax_by, &ay_bx, .Sub, self.allocator);

                        return .{ .vec3 = .{ cx, cy, cz } };
                    } else if (a.* == .vec2 and b.* == .vec2) {
                        // 2D cross product (signed area): a.u*b.v - a.v*b.u
                        var au_bv = try combineBinaryScalar(&a.vec2[0], &b.vec2[1], .Mul, self.allocator);
                        defer freeInstList(&au_bv, self.allocator);
                        var av_bu = try combineBinaryScalar(&a.vec2[1], &b.vec2[0], .Mul, self.allocator);
                        defer freeInstList(&av_bu, self.allocator);
                        const cz = try combineBinaryScalar(&au_bv, &av_bu, .Sub, self.allocator);
                        return .{ .scalar = cz };
                    }
                    return error.SyntaxError;
                }

                if (std.mem.eql(u8, name, "norm")) {
                    // CDML §3.3.1: norm(a) expands to SQRT(dot(a, a))
                    if (args.items.len != 1) return error.SyntaxError;
                    const a = &args.items[0];
                    if (a.* == .vec2) {
                        var m0 = try combineBinaryScalar(&a.vec2[0], &a.vec2[0], .Mul, self.allocator);
                        defer freeInstList(&m0, self.allocator);
                        var m1 = try combineBinaryScalar(&a.vec2[1], &a.vec2[1], .Mul, self.allocator);
                        defer freeInstList(&m1, self.allocator);
                        var sum = try combineBinaryScalar(&m0, &m1, .Add, self.allocator);
                        errdefer freeInstList(&sum, self.allocator);
                        try sum.append(self.allocator, .Sqrt);
                        return .{ .scalar = sum };
                    } else if (a.* == .vec3) {
                        var m0 = try combineBinaryScalar(&a.vec3[0], &a.vec3[0], .Mul, self.allocator);
                        defer freeInstList(&m0, self.allocator);
                        var m1 = try combineBinaryScalar(&a.vec3[1], &a.vec3[1], .Mul, self.allocator);
                        defer freeInstList(&m1, self.allocator);
                        var m2 = try combineBinaryScalar(&a.vec3[2], &a.vec3[2], .Mul, self.allocator);
                        defer freeInstList(&m2, self.allocator);
                        var s01 = try combineBinaryScalar(&m0, &m1, .Add, self.allocator);
                        defer freeInstList(&s01, self.allocator);
                        var sum = try combineBinaryScalar(&s01, &m2, .Add, self.allocator);
                        errdefer freeInstList(&sum, self.allocator);
                        try sum.append(self.allocator, .Sqrt);
                        return .{ .scalar = sum };
                    } else if (a.* == .scalar) {
                        var out = try cloneInstList(&a.scalar, self.allocator);
                        errdefer freeInstList(&out, self.allocator);
                        try out.append(self.allocator, .Abs);
                        return .{ .scalar = out };
                    }
                    return error.SyntaxError;
                }

                if (std.mem.eql(u8, name, "field_scalar")) {
                    // field_scalar(slot, x, y, z, default) -> pushes 5 args + .FieldSample
                    if (args.items.len != 5) return error.SyntaxError;
                    var out: std.ArrayList(Instruction) = .empty;
                    errdefer freeInstList(&out, self.allocator);
                    for (args.items) |*arg| {
                        if (arg.* != .scalar) return error.SyntaxError;
                        try appendInstList(&out, &arg.scalar, self.allocator);
                    }
                    try out.append(self.allocator, .{ .FieldSample = 0 });
                    return .{ .scalar = out };
                }

                // 1-argument scalar functions
                if (std.mem.eql(u8, name, "sin") or std.mem.eql(u8, name, "cos") or
                    std.mem.eql(u8, name, "exp") or std.mem.eql(u8, name, "log") or
                    std.mem.eql(u8, name, "ln") or std.mem.eql(u8, name, "sqrt") or
                    std.mem.eql(u8, name, "abs"))
                {
                    if (args.items.len != 1 or args.items[0] != .scalar) return error.SyntaxError;
                    var out = try cloneInstList(&args.items[0].scalar, self.allocator);
                    errdefer freeInstList(&out, self.allocator);
                    if (std.mem.eql(u8, name, "sin")) try out.append(self.allocator, .Sin)
                    else if (std.mem.eql(u8, name, "cos")) try out.append(self.allocator, .Cos)
                    else if (std.mem.eql(u8, name, "exp")) try out.append(self.allocator, .Exp)
                    else if (std.mem.eql(u8, name, "log") or std.mem.eql(u8, name, "ln")) try out.append(self.allocator, .Log)
                    else if (std.mem.eql(u8, name, "sqrt")) try out.append(self.allocator, .Sqrt)
                    else if (std.mem.eql(u8, name, "abs")) try out.append(self.allocator, .Abs);
                    return .{ .scalar = out };
                }

                // 2-argument scalar functions
                if (std.mem.eql(u8, name, "abs_smooth") or std.mem.eql(u8, name, "r_union") or std.mem.eql(u8, name, "r_intersect")) {
                    if (args.items.len != 2 or args.items[0] != .scalar or args.items[1] != .scalar) return error.SyntaxError;
                    const op: Instruction = if (std.mem.eql(u8, name, "abs_smooth"))
                        .AbsSmooth
                    else if (std.mem.eql(u8, name, "r_union"))
                        .RUnion
                    else
                        .RIntersect;
                    const out = try combineBinaryScalar(&args.items[0].scalar, &args.items[1].scalar, op, self.allocator);
                    return .{ .scalar = out };
                }

                return error.ErrUndefinedRef;
            }

            return self.resolveVariableOrVector(name);
        }

        return error.SyntaxError;
    }
};

pub fn compileExpression(allocator: std.mem.Allocator, text: []const u8) !Expression {
    return compileExpressionWithContext(allocator, text, .residual, null);
}

pub fn compileExpressionWithContext(
    allocator: std.mem.Allocator,
    text: []const u8,
    context: ExprContext,
    var_map: ?*const std.StringHashMap(u32),
) !Expression {
    return compileExpressionFull(allocator, text, context, var_map, null, null);
}

pub fn compileExpressionFull(
    allocator: std.mem.Allocator,
    text: []const u8,
    context: ExprContext,
    var_map: ?*const std.StringHashMap(u32),
    const_map: ?*const std.StringHashMap(f64),
    def_map: ?*const std.StringHashMap([]const u8),
) !Expression {
    var parser = Parser{
        .allocator = allocator,
        .text = text,
        .pos = 0,
        .context = context,
        .var_map = var_map,
        .const_map = const_map,
        .def_map = def_map,
    };

    var res = try parser.parseExpr();
    errdefer res.deinit(allocator);

    parser.skipWhitespace();
    if (parser.pos < parser.text.len) {
        return error.SyntaxError;
    }

    if (res != .scalar) {
        return error.SyntaxError;
    }

    return Expression{
        .instructions = try res.scalar.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

pub fn registerCompiledExpression(expr: Expression) u64 {
    const handle: u64 = (@as(u64, 0b11) << 62) | next_expr_id;
    next_expr_id += 1;
    expr_store.put(handle, expr) catch return 0;
    return handle;
}

// ============================================================================
// Expression Global Registry & Exported ABI Functions
// ============================================================================

var next_expr_id: u64 = 1;
pub var expr_store: std.AutoHashMap(u64, Expression) = std.AutoHashMap(u64, Expression).init(memory.persistent_allocator);

pub fn expr_compile(ptr: [*]const u8, len: usize) u64 {
    const text = ptr[0..len];
    const real_expr = compileExpression(memory.persistent_allocator, text) catch |err| blk: {
        if (err == error.ErrExprContext) {
            break :blk compileExpressionWithContext(memory.persistent_allocator, text, .predicate, null) catch return 0;
        }
        return 0;
    };

    // Rule 4: bits [63:62] == 0b11 for Mathematical Expressions
    const handle: u64 = (@as(u64, 0b11) << 62) | next_expr_id;
    next_expr_id += 1;

    expr_store.put(handle, real_expr) catch return 0;
    return handle;
}

pub fn expr_compile_context(ptr: [*]const u8, len: usize, context: ExprContext) u64 {
    const text = ptr[0..len];
    const real_expr = compileExpressionWithContext(memory.persistent_allocator, text, context, null) catch return 0;

    const handle: u64 = (@as(u64, 0b11) << 62) | next_expr_id;
    next_expr_id += 1;

    expr_store.put(handle, real_expr) catch return 0;
    return handle;
}

pub fn expr_eval(expr_h: u64, vars_ptr: [*]const f64, var_count: u32, out_grad_ptr: ?[*]f64) f64 {
    const expr = expr_store.get(expr_h) orelse return 0.0;
    const vars = vars_ptr[0..var_count];
    const out_grad = if (out_grad_ptr) |gp| gp[0..var_count] else null;
    return expr.evalGrad(vars, out_grad);
}

pub fn expr_eval_interval(expr_h: u64, intervals: []const Interval) Interval {
    const expr = expr_store.get(expr_h) orelse return Interval.point(0.0);
    return expr.evalInterval(intervals);
}

pub fn expr_free(expr_h: u64) void {
    if (expr_store.fetchRemove(expr_h)) |kv| {
        var expr = kv.value;
        expr.deinit();
    }
}

test "Autodiff R-functions, vector scalarisation, norm(0) NaN check, and trilinear FieldSample" {
    const alloc = std.testing.allocator;

    // 1. R-Union and R-Intersect
    var expr_ru = try compileExpression(alloc, "r_union(x0, x1)");
    defer expr_ru.deinit();
    const val_ru = expr_ru.evalScalar(&[_]f64{ 3.0, 4.0 });
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), val_ru, 1e-10);

    var expr_ri = try compileExpression(alloc, "r_intersect(x0, x1)");
    defer expr_ri.deinit();
    const val_ri = expr_ri.evalScalar(&[_]f64{ 3.0, 4.0 });
    try std.testing.expectApproxEqAbs(@as(f64, 12.0), val_ri, 1e-10);

    // 2. Context enforcement: predicate variables forbidden in field/residual context
    try std.testing.expectError(error.ErrExprContext, compileExpressionWithContext(alloc, "x + nx", .field, null));
    try std.testing.expectError(error.ErrExprContext, compileExpressionWithContext(alloc, "x + area", .residual, null));

    // 3. Compile-time vector scalarisation: vec2, vec3, dot, cross, norm, member access
    // v0 = (x0, x1), v1 = (x2, x3)
    var expr_norm = try compileExpression(alloc, "norm(v1 - v0) - 5.0");
    defer expr_norm.deinit();
    var grad_norm: [4]f64 = undefined;
    const val_norm = try expr_norm.evalGradChecked(&[_]f64{ 1.0, 2.0, 4.0, 6.0 }, &grad_norm);
    // |(4-1, 6-2)| - 5 = |(3, 4)| - 5 = 0.0
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), val_norm, 1e-12);
    // d/dv0.u = -3/5 = -0.6, d/dv0.v = -4/5 = -0.8, d/dv1.u = 0.6, d/dv1.v = 0.8
    try std.testing.expectApproxEqAbs(@as(f64, -0.6), grad_norm[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, -0.8), grad_norm[1], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.6), grad_norm[2], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.8), grad_norm[3], 1e-12);

    // 4. norm(0) zero-length gradient singularity check -> ErrExprNanInf (§3.3.1)
    try std.testing.expectError(error.ErrExprNanInf, expr_norm.evalGradChecked(&[_]f64{ 2.0, 3.0, 2.0, 3.0 }, &grad_norm));

    // 5. 3D cross product and dot product scalarisation: dot(cross(e0, e1), vec3(0, 0, 1))
    var expr_cross = try compileExpression(alloc, "dot(cross(e0, e1), vec3(0, 0, 1))");
    defer expr_cross.deinit();
    // e0 = (1, 0, 0), e1 = (0, 1, 0) -> cross = (0, 0, 1) -> dot with (0,0,1) = 1.0
    const val_cross = expr_cross.evalScalar(&[_]f64{ 1.0, 0.0, 0.0, 0.0, 1.0, 0.0 });
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), val_cross, 1e-12);

    // 6. FieldSample: unallocated returns default with 0.0 derivative; allocated performs trilinear interpolation
    memory_map.initControlBlock();
    const field_bytes = memory_map.getMemorySlice(memory_map.FIELD_BUFFER_OFFSET, 64 * 64 * 24 * 4);
    @memset(field_bytes, 0);

    var expr_fs = try compileExpressionWithContext(alloc, "field_scalar(0, x, y, z, 42.5)", .field, null);
    defer expr_fs.deinit();
    var grad_fs: [3]f64 = undefined;
    const val_unalloc = expr_fs.evalGrad(&[_]f64{ 0.0, 0.0, 8.0 }, &grad_fs);
    try std.testing.expectApproxEqAbs(@as(f64, 42.5), val_unalloc, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), grad_fs[0], 1e-12);

    // Populate linear field f(x,y,z) = 100 + 2*x in slot 0 over [-45..45, -45..45, 0..16]
    configureFieldSlot(0, 64, 64, 24, -45.0, -45.0, 0.0, 45.0, 45.0, 16.0);
    for (0..24) |iz| {
        for (0..64) |iy| {
            for (0..64) |ix| {
                const wx = -45.0 + (@as(f64, @floatFromInt(ix)) / 63.0) * 90.0;
                const fv: f32 = @floatCast(100.0 + 2.0 * wx);
                const off = (iz * 64 * 64 + iy * 64 + ix) * 4;
                std.mem.writeInt(u32, field_bytes[off..][0..4], @bitCast(fv), .little);
            }
        }
    }
    const val_alloc = expr_fs.evalGrad(&[_]f64{ 10.0, 0.0, 8.0 }, &grad_fs);
    try std.testing.expectApproxEqAbs(@as(f64, 120.0), val_alloc, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), grad_fs[0], 1e-3);
    @memset(field_bytes, 0);
}
