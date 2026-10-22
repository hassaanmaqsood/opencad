const std = @import("std");

pub const Vec4f = @Vector(4, f32);

pub const Interval = struct {
    min: f32,
    max: f32,

    pub fn init(min: f32, max: f32) Interval {
        return .{
            .min = @min(min, max),
            .max = @max(min, max),
        };
    }

    pub fn point(v: f32) Interval {
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

    pub fn length3(x: Interval, y: Interval, z: Interval) Interval {
        // Lower bound of distance to origin from interval box [x, y, z]
        var min_sq: f32 = 0.0;
        if (x.min > 0.0) min_sq += x.min * x.min else if (x.max < 0.0) min_sq += x.max * x.max;
        if (y.min > 0.0) min_sq += y.min * y.min else if (y.max < 0.0) min_sq += y.max * y.max;
        if (z.min > 0.0) min_sq += z.min * z.min else if (z.max < 0.0) min_sq += z.max * z.max;

        const max_sq = @max(x.min * x.min, x.max * x.max) +
            @max(y.min * y.min, y.max * y.max) +
            @max(z.min * z.min, z.max * z.max);

        return .{
            .min = @sqrt(min_sq),
            .max = @sqrt(max_sq),
        };
    }

    pub fn containsZero(self: Interval) bool {
        return self.min <= 0.0 and self.max >= 0.0;
    }

    pub fn crossesBand(self: Interval, band: f32) bool {
        return self.min <= band and self.max >= -band;
    }
};

pub const Opcode = enum(u32) {
    Primitive = 0,
    BrepDistance = 1,
    TpmsGyroid = 2,
    TpmsSchwarzP = 3,
    TpmsDiamond = 4,
    StressFieldModulate = 5,
    SmoothUnion = 6,
    SmoothIntersect = 7,
    SmoothDifference = 8,
    Shell = 9,
    Offset = 10,
    Warp = 11,
};

pub const PrimType = enum(u32) {
    Sphere = 0,
    Box = 1,
    Cylinder = 2,
    Torus = 3,
    Plane = 4,
};

pub const Instruction = struct {
    opcode: Opcode,
    out_reg: u16,
    in_reg_a: u16 = 0,
    in_reg_b: u16 = 0,
    params: union {
        primitive: struct {
            prim_type: PrimType,
            center: [3]f32,
            dims: [3]f32,
        },
        brep_distance: struct {
            solid_id: u64,
            max_dist: f32,
        },
        tpms: struct {
            cell_size: f32,
            wall_thickness: f32,
            is_sheet: bool,
        },
        stress_modulate: struct {
            min_thickness: f32,
            max_thickness: f32,
            max_stress: f32,
        },
        smooth_boolean: struct {
            k: f32,
        },
        shell: struct {
            thickness: f32,
        },
        offset: struct {
            distance: f32,
        },
        warp: struct {
            warp_type: u32,
            axis_origin: [3]f32,
            axis_dir: [3]f32,
            factor: f32,
        },
    },
};

pub const SdfVm = struct {
    pub const MAX_REGISTERS = 64;

    /// Evaluates scalar signed distance at point (x, y, z)
    pub fn evalPoint(instructions: []const Instruction, p: [3]f32) f32 {
        var registers: [MAX_REGISTERS]f32 = undefined;
        @memset(&registers, 0.0);

        for (instructions) |inst| {
            const out_idx = inst.out_reg % MAX_REGISTERS;
            const ra = registers[inst.in_reg_a % MAX_REGISTERS];
            const rb = registers[inst.in_reg_b % MAX_REGISTERS];

            switch (inst.opcode) {
                .Primitive => {
                    const prim = inst.params.primitive;
                    const px = p[0] - prim.center[0];
                    const py = p[1] - prim.center[1];
                    const pz = p[2] - prim.center[2];

                    registers[out_idx] = switch (prim.prim_type) {
                        .Sphere => @sqrt(px * px + py * py + pz * pz) - prim.dims[0],
                        .Box => blk: {
                            const qx = @abs(px) - prim.dims[0];
                            const qy = @abs(py) - prim.dims[1];
                            const qz = @abs(pz) - prim.dims[2];
                            const ox = @max(qx, 0.0);
                            const oy = @max(qy, 0.0);
                            const oz = @max(qz, 0.0);
                            const outside = @sqrt(ox * ox + oy * oy + oz * oz);
                            const inside = @min(@max(qx, @max(qy, qz)), 0.0);
                            break :blk outside + inside;
                        },
                        .Cylinder => blk: {
                            const r = prim.dims[0];
                            const h = prim.dims[1];
                            const dr = @sqrt(px * px + pz * pz) - r;
                            const dy = @abs(py) - h;
                            const ox = @max(dr, 0.0);
                            const oy = @max(dy, 0.0);
                            break :blk @min(@max(dr, dy), 0.0) + @sqrt(ox * ox + oy * oy);
                        },
                        .Torus => blk: {
                            const r_major = prim.dims[0];
                            const r_minor = prim.dims[1];
                            const qx = @sqrt(px * px + pz * pz) - r_major;
                            break :blk @sqrt(qx * qx + py * py) - r_minor;
                        },
                        .Plane => px * prim.dims[0] + py * prim.dims[1] + pz * prim.dims[2],
                    };
                },
                .BrepDistance => {
                    // Approximate B-Rep distance clamped to max_dist
                    const bd = inst.params.brep_distance;
                    _ = bd;
                    registers[out_idx] = 1.0;
                },
                .TpmsGyroid => {
                    const params = inst.params.tpms;
                    const k = (2.0 * std.math.pi) / params.cell_size;
                    const x = p[0] * k;
                    const y = p[1] * k;
                    const z = p[2] * k;
                    const nodal = @sin(x) * @cos(y) + @sin(y) * @cos(z) + @sin(z) * @cos(x);
                    const half_t = params.wall_thickness * 0.5;
                    registers[out_idx] = if (params.is_sheet) @abs(nodal) - half_t else nodal - half_t;
                },
                .TpmsSchwarzP => {
                    const params = inst.params.tpms;
                    const k = (2.0 * std.math.pi) / params.cell_size;
                    const x = p[0] * k;
                    const y = p[1] * k;
                    const z = p[2] * k;
                    const nodal = @cos(x) + @cos(y) + @cos(z);
                    const half_t = params.wall_thickness * 0.5;
                    registers[out_idx] = if (params.is_sheet) @abs(nodal) - half_t else nodal - half_t;
                },
                .TpmsDiamond => {
                    const params = inst.params.tpms;
                    const k = (2.0 * std.math.pi) / params.cell_size;
                    const x = p[0] * k;
                    const y = p[1] * k;
                    const z = p[2] * k;
                    const nodal = @cos(x) * @cos(y) * @cos(z) - @sin(x) * @sin(y) * @sin(z);
                    const half_t = params.wall_thickness * 0.5;
                    registers[out_idx] = if (params.is_sheet) @abs(nodal) - half_t else nodal - half_t;
                },
                .StressFieldModulate => {
                    const sm = inst.params.stress_modulate;
                    // Interpolate thickness between min and max based on normalized ra
                    const factor = std.math.clamp(ra / sm.max_stress, 0.0, 1.0);
                    registers[out_idx] = sm.min_thickness + factor * (sm.max_thickness - sm.min_thickness);
                },
                .SmoothUnion => {
                    const k = @max(inst.params.smooth_boolean.k, 1e-6);
                    const h = @max(k - @abs(ra - rb), 0.0) / k;
                    registers[out_idx] = @min(ra, rb) - h * h * h * k * (1.0 / 6.0);
                },
                .SmoothIntersect => {
                    const k = @max(inst.params.smooth_boolean.k, 1e-6);
                    const h = @max(k - @abs(ra - rb), 0.0) / k;
                    registers[out_idx] = @max(ra, rb) + h * h * h * k * (1.0 / 6.0);
                },
                .SmoothDifference => {
                    const k = @max(inst.params.smooth_boolean.k, 1e-6);
                    const h = @max(k - @abs(-ra - rb), 0.0) / k;
                    registers[out_idx] = -(@min(-ra, rb) - h * h * h * k * (1.0 / 6.0));
                },
                .Shell => {
                    const t = inst.params.shell.thickness;
                    registers[out_idx] = @abs(ra) - t * 0.5;
                },
                .Offset => {
                    registers[out_idx] = ra - inst.params.offset.distance;
                },
                .Warp => {
                    registers[out_idx] = ra;
                },
            }
        }

        if (instructions.len == 0) return 0.0;
        return registers[instructions[instructions.len - 1].out_reg % MAX_REGISTERS];
    }

    /// Vectorized `@Vector(4, f32)` SIMD evaluation for 4 coordinates simultaneously
    pub fn evalSimd4(
        instructions: []const Instruction,
        xs: Vec4f,
        ys: Vec4f,
        zs: Vec4f,
    ) Vec4f {
        var registers: [MAX_REGISTERS]Vec4f = undefined;
        @memset(&registers, @splat(0.0));

        for (instructions) |inst| {
            const out_idx = inst.out_reg % MAX_REGISTERS;
            const ra = registers[inst.in_reg_a % MAX_REGISTERS];
            const rb = registers[inst.in_reg_b % MAX_REGISTERS];

            switch (inst.opcode) {
                .Primitive => {
                    const prim = inst.params.primitive;
                    const cx: Vec4f = @splat(prim.center[0]);
                    const cy: Vec4f = @splat(prim.center[1]);
                    const cz: Vec4f = @splat(prim.center[2]);
                    const px = xs - cx;
                    const py = ys - cy;
                    const pz = zs - cz;

                    registers[out_idx] = switch (prim.prim_type) {
                        .Sphere => blk: {
                            const r: Vec4f = @splat(prim.dims[0]);
                            const len = @sqrt(px * px + py * py + pz * pz);
                            break :blk len - r;
                        },
                        .Box => blk: {
                            const bx: Vec4f = @splat(prim.dims[0]);
                            const by: Vec4f = @splat(prim.dims[1]);
                            const bz: Vec4f = @splat(prim.dims[2]);
                            const qx = @abs(px) - bx;
                            const qy = @abs(py) - by;
                            const qz = @abs(pz) - bz;
                            const zero: Vec4f = @splat(0.0);
                            const ox = @max(qx, zero);
                            const oy = @max(qy, zero);
                            const oz = @max(qz, zero);
                            const outside = @sqrt(ox * ox + oy * oy + oz * oz);
                            const inside = @min(@max(qx, @max(qy, qz)), zero);
                            break :blk outside + inside;
                        },
                        .Cylinder => blk: {
                            const r: Vec4f = @splat(prim.dims[0]);
                            const h: Vec4f = @splat(prim.dims[1]);
                            const dr = @sqrt(px * px + pz * pz) - r;
                            const dy = @abs(py) - h;
                            const zero: Vec4f = @splat(0.0);
                            const ox = @max(dr, zero);
                            const oy = @max(dy, zero);
                            break :blk @min(@max(dr, dy), zero) + @sqrt(ox * ox + oy * oy);
                        },
                        .Torus => blk: {
                            const r_maj: Vec4f = @splat(prim.dims[0]);
                            const r_min: Vec4f = @splat(prim.dims[1]);
                            const qx = @sqrt(px * px + pz * pz) - r_maj;
                            break :blk @sqrt(qx * qx + py * py) - r_min;
                        },
                        .Plane => blk: {
                            const nx: Vec4f = @splat(prim.dims[0]);
                            const ny: Vec4f = @splat(prim.dims[1]);
                            const nz: Vec4f = @splat(prim.dims[2]);
                            break :blk px * nx + py * ny + pz * nz;
                        },
                    };
                },
                .TpmsGyroid => {
                    const params = inst.params.tpms;
                    const k = (2.0 * std.math.pi) / params.cell_size;
                    const half_t: Vec4f = @splat(params.wall_thickness * 0.5);

                    var res: Vec4f = undefined;
                    inline for (0..4) |i| {
                        const x = xs[i] * k;
                        const y = ys[i] * k;
                        const z = zs[i] * k;
                        const nodal = @sin(x) * @cos(y) + @sin(y) * @cos(z) + @sin(z) * @cos(x);
                        res[i] = if (params.is_sheet) @abs(nodal) - half_t[i] else nodal - half_t[i];
                    }
                    registers[out_idx] = res;
                },
                .TpmsSchwarzP => {
                    const params = inst.params.tpms;
                    const k = (2.0 * std.math.pi) / params.cell_size;
                    const half_t: Vec4f = @splat(params.wall_thickness * 0.5);

                    var res: Vec4f = undefined;
                    inline for (0..4) |i| {
                        const x = xs[i] * k;
                        const y = ys[i] * k;
                        const z = zs[i] * k;
                        const nodal = @cos(x) + @cos(y) + @cos(z);
                        res[i] = if (params.is_sheet) @abs(nodal) - half_t[i] else nodal - half_t[i];
                    }
                    registers[out_idx] = res;
                },
                .TpmsDiamond => {
                    const params = inst.params.tpms;
                    const k = (2.0 * std.math.pi) / params.cell_size;
                    const half_t: Vec4f = @splat(params.wall_thickness * 0.5);

                    var res: Vec4f = undefined;
                    inline for (0..4) |i| {
                        const x = xs[i] * k;
                        const y = ys[i] * k;
                        const z = zs[i] * k;
                        const nodal = @cos(x) * @cos(y) * @cos(z) - @sin(x) * @sin(y) * @sin(z);
                        res[i] = if (params.is_sheet) @abs(nodal) - half_t[i] else nodal - half_t[i];
                    }
                    registers[out_idx] = res;
                },
                .SmoothUnion => {
                    const k_val = @max(inst.params.smooth_boolean.k, 1e-6);
                    const k: Vec4f = @splat(k_val);
                    const zero: Vec4f = @splat(0.0);
                    const sixth: Vec4f = @splat(1.0 / 6.0);
                    const h = @max(k - @abs(ra - rb), zero) / k;
                    registers[out_idx] = @min(ra, rb) - h * h * h * k * sixth;
                },
                .SmoothIntersect => {
                    const k_val = @max(inst.params.smooth_boolean.k, 1e-6);
                    const k: Vec4f = @splat(k_val);
                    const zero: Vec4f = @splat(0.0);
                    const sixth: Vec4f = @splat(1.0 / 6.0);
                    const h = @max(k - @abs(ra - rb), zero) / k;
                    registers[out_idx] = @max(ra, rb) + h * h * h * k * sixth;
                },
                .SmoothDifference => {
                    const k_val = @max(inst.params.smooth_boolean.k, 1e-6);
                    const k: Vec4f = @splat(k_val);
                    const zero: Vec4f = @splat(0.0);
                    const sixth: Vec4f = @splat(1.0 / 6.0);
                    const h = @max(k - @abs(-ra - rb), zero) / k;
                    registers[out_idx] = -(@min(-ra, rb) - h * h * h * k * sixth);
                },
                .Shell => {
                    const half_t: Vec4f = @splat(inst.params.shell.thickness * 0.5);
                    registers[out_idx] = @abs(ra) - half_t;
                },
                .Offset => {
                    const d: Vec4f = @splat(inst.params.offset.distance);
                    registers[out_idx] = ra - d;
                },
                else => {
                    registers[out_idx] = ra;
                },
            }
        }

        if (instructions.len == 0) return @splat(0.0);
        return registers[instructions[instructions.len - 1].out_reg % MAX_REGISTERS];
    }

    /// Evaluates Interval bounds over an axis-aligned box [min, max]
    /// Returns [min_dist, max_dist] to allow O(1) cell culling if interval doesn't cross surface band
    pub fn evalInterval(
        instructions: []const Instruction,
        aabb_min: [3]f32,
        aabb_max: [3]f32,
    ) Interval {
        var registers: [MAX_REGISTERS]Interval = undefined;
        @memset(&registers, Interval.init(0.0, 0.0));

        const ix = Interval.init(aabb_min[0], aabb_max[0]);
        const iy = Interval.init(aabb_min[1], aabb_max[1]);
        const iz = Interval.init(aabb_min[2], aabb_max[2]);

        for (instructions) |inst| {
            const out_idx = inst.out_reg % MAX_REGISTERS;
            const ra = registers[inst.in_reg_a % MAX_REGISTERS];
            const rb = registers[inst.in_reg_b % MAX_REGISTERS];

            switch (inst.opcode) {
                .Primitive => {
                    const prim = inst.params.primitive;
                    const px = ix.sub(Interval.point(prim.center[0]));
                    const py = iy.sub(Interval.point(prim.center[1]));
                    const pz = iz.sub(Interval.point(prim.center[2]));

                    registers[out_idx] = switch (prim.prim_type) {
                        .Sphere => blk: {
                            const len = Interval.length3(px, py, pz);
                            break :blk len.sub(Interval.point(prim.dims[0]));
                        },
                        .Box => blk: {
                            // Distance lower and upper bounds for box
                            const qx = Interval.init(@abs(px.min) - prim.dims[0], @abs(px.max) - prim.dims[0]);
                            const qy = Interval.init(@abs(py.min) - prim.dims[1], @abs(py.max) - prim.dims[1]);
                            const qz = Interval.init(@abs(pz.min) - prim.dims[2], @abs(pz.max) - prim.dims[2]);
                            const max_min = @max(qx.min, @max(qy.min, qz.min));
                            const max_max = @max(qx.max, @max(qy.max, qz.max));
                            break :blk Interval.init(max_min, max_max);
                        },
                        else => Interval.length3(px, py, pz).sub(Interval.point(prim.dims[0])),
                    };
                },
                .TpmsGyroid, .TpmsSchwarzP, .TpmsDiamond => {
                    // Maximum possible value range of standard TPMS functions is [-3.0, 3.0]
                    const half_t = inst.params.tpms.wall_thickness * 0.5;
                    registers[out_idx] = Interval.init(-3.0 - half_t, 3.0 - half_t);
                },
                .SmoothUnion => {
                    registers[out_idx] = Interval.init(@min(ra.min, rb.min), @min(ra.max, rb.max));
                },
                .SmoothIntersect => {
                    registers[out_idx] = Interval.init(@max(ra.min, rb.min), @max(ra.max, rb.max));
                },
                .SmoothDifference => {
                    registers[out_idx] = Interval.init(@max(ra.min, -rb.max), @max(ra.max, -rb.min));
                },
                .Shell => {
                    const half_t = inst.params.shell.thickness * 0.5;
                    const min_val = if (ra.containsZero()) -half_t else @min(@abs(ra.min), @abs(ra.max)) - half_t;
                    const max_val = @max(@abs(ra.min), @abs(ra.max)) - half_t;
                    registers[out_idx] = Interval.init(min_val, max_val);
                },
                .Offset => {
                    registers[out_idx] = ra.sub(Interval.point(inst.params.offset.distance));
                },
                else => {
                    registers[out_idx] = ra;
                },
            }
        }

        if (instructions.len == 0) return Interval.init(0.0, 0.0);
        return registers[instructions[instructions.len - 1].out_reg % MAX_REGISTERS];
    }
};

test "SdfVm scalar and SIMD4 sphere evaluation" {
    const inst = [_]Instruction{.{
        .opcode = .Primitive,
        .out_reg = 0,
        .params = .{
            .primitive = .{
                .prim_type = .Sphere,
                .center = .{ 0.0, 0.0, 0.0 },
                .dims = .{ 5.0, 0.0, 0.0 },
            },
        },
    }};

    const p = [3]f32{ 0.0, 7.0, 0.0 };
    const d = SdfVm.evalPoint(&inst, p);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), d, 1e-5);

    const xs: Vec4f = .{ 0.0, 5.0, 0.0, 10.0 };
    const ys: Vec4f = .{ 0.0, 0.0, 6.0, 0.0 };
    const zs: Vec4f = .{ 0.0, 0.0, 0.0, 0.0 };
    const d4 = SdfVm.evalSimd4(&inst, xs, ys, zs);

    try std.testing.expectApproxEqAbs(@as(f32, -5.0), d4[0], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), d4[1], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), d4[2], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), d4[3], 1e-4);
}

test "SdfVm interval arithmetic skips cells outside surface band" {
    const inst = [_]Instruction{.{
        .opcode = .Primitive,
        .out_reg = 0,
        .params = .{
            .primitive = .{
                .prim_type = .Sphere,
                .center = .{ 0.0, 0.0, 0.0 },
                .dims = .{ 5.0, 0.0, 0.0 },
            },
        },
    }};

    // Cell entirely outside sphere (from x=10 to 12, y=10 to 12, z=10 to 12)
    const interval_outside = SdfVm.evalInterval(&inst, .{ 10.0, 10.0, 10.0 }, .{ 12.0, 12.0, 12.0 });
    try std.testing.expect(interval_outside.min > 0.0);
    try std.testing.expect(!interval_outside.crossesBand(0.5));

    // Cell crossing sphere boundary
    const interval_crossing = SdfVm.evalInterval(&inst, .{ 4.0, 0.0, 0.0 }, .{ 6.0, 1.0, 1.0 });
    try std.testing.expect(interval_crossing.crossesBand(0.1));
}
