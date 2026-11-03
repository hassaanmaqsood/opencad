const std = @import("std");
const memory = @import("memory.zig");
const nurbs = @import("geom/nurbs.zig");
const constraint_sys = @import("constraint_sys.zig");

pub const Vec3d = nurbs.Vec3d;

// ============================================================================
// Rational B-Spline Curve Entity
// ============================================================================

pub const NurbsCurve = struct {
    sys_handle: u64,
    dim: u32,
    degree: u32,
    ctrl_param_indices: []u32,
    ctrl_count: u32,
    knots: []f64,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *NurbsCurve) void {
        self.allocator.free(self.ctrl_param_indices);
        self.allocator.free(self.knots);
    }

    /// Read control point coordinate and weight from constraint system parameter slots
    pub fn getControlPoint(self: *const NurbsCurve, i: usize) struct { p: Vec3d, w: f64 } {
        const sys = constraint_sys.sys_store.getPtr(self.sys_handle);
        const params = if (sys) |s| s.params.items else &[_]f64{};

        if (self.dim == 2) {
            // 2D Rational control point: (x, y, w) or (x, y) with w=1.0
            const base_idx = i * 3;
            var x: f64 = 0.0;
            var y: f64 = 0.0;
            var w: f64 = 1.0;

            if (base_idx < self.ctrl_param_indices.len) {
                const px = self.ctrl_param_indices[base_idx];
                if (px < params.len) x = params[px];
            }
            if (base_idx + 1 < self.ctrl_param_indices.len) {
                const py = self.ctrl_param_indices[base_idx + 1];
                if (py < params.len) y = params[py];
            }
            if (base_idx + 2 < self.ctrl_param_indices.len) {
                const pw = self.ctrl_param_indices[base_idx + 2];
                if (pw < params.len) w = params[pw];
            }
            return .{ .p = Vec3d.init(x, y, 0.0), .w = if (w == 0.0) 1.0 else w };
        } else {
            // 3D Rational control point: (x, y, z, w)
            const base_idx = i * 4;
            var x: f64 = 0.0;
            var y: f64 = 0.0;
            var z: f64 = 0.0;
            var w: f64 = 1.0;

            if (base_idx < self.ctrl_param_indices.len) {
                const px = self.ctrl_param_indices[base_idx];
                if (px < params.len) x = params[px];
            }
            if (base_idx + 1 < self.ctrl_param_indices.len) {
                const py = self.ctrl_param_indices[base_idx + 1];
                if (py < params.len) y = params[py];
            }
            if (base_idx + 2 < self.ctrl_param_indices.len) {
                const pz = self.ctrl_param_indices[base_idx + 2];
                if (pz < params.len) z = params[pz];
            }
            if (base_idx + 3 < self.ctrl_param_indices.len) {
                const pw = self.ctrl_param_indices[base_idx + 3];
                if (pw < params.len) w = params[pw];
            }
            return .{ .p = Vec3d.init(x, y, z), .w = if (w == 0.0) 1.0 else w };
        }
    }

    /// Evaluates C(t), C'(t), and C''(t) using exact rational quotient derivatives
    pub fn evalDerivs(self: *const NurbsCurve, t: f64) struct { point: Vec3d, d1: Vec3d, d2: Vec3d } {
        const p = self.degree;
        const n = self.ctrl_count - 1;
        const span = nurbs.findSpan(n, p, t, self.knots);

        var N0: [16]f64 = undefined;
        var N1: [16]f64 = undefined;
        var N2: [16]f64 = undefined;

        nurbs.evalBasisAndDerivs(span, t, p, self.knots, N0[0 .. p + 1], N1[0 .. p + 1], N2[0 .. p + 1]);

        var A = Vec3d.zero();
        var A_prime = Vec3d.zero();
        var A_double = Vec3d.zero();
        var w: f64 = 0.0;
        var w_prime: f64 = 0.0;
        var w_double: f64 = 0.0;

        for (0..p + 1) |j| {
            const idx = span - p + j;
            const cp = self.getControlPoint(idx);
            const Pw = cp.p.scale(cp.w);

            A = A.add(Pw.scale(N0[j]));
            A_prime = A_prime.add(Pw.scale(N1[j]));
            A_double = A_double.add(Pw.scale(N2[j]));

            w += cp.w * N0[j];
            w_prime += cp.w * N1[j];
            w_double += cp.w * N2[j];
        }

        const inv_w = if (@abs(w) > 1e-14) 1.0 / w else 1.0;
        const C = A.scale(inv_w);

        // C'(t) = (A' - w' * C) / w
        const C_prime = A_prime.sub(C.scale(w_prime)).scale(inv_w);

        // C''(t) = (A'' - 2*w'*C' - w''*C) / w
        const C_double = A_double.sub(C_prime.scale(2.0 * w_prime)).sub(C.scale(w_double)).scale(inv_w);

        return .{ .point = C, .d1 = C_prime, .d2 = C_double };
    }

    pub fn eval(self: *const NurbsCurve, t: f64) Vec3d {
        return self.evalDerivs(t).point;
    }

    pub fn evalDeriv1(self: *const NurbsCurve, t: f64) Vec3d {
        return self.evalDerivs(t).d1;
    }

    pub fn evalDeriv2(self: *const NurbsCurve, t: f64) Vec3d {
        return self.evalDerivs(t).d2;
    }
};

// ============================================================================
// 1-Manifold Closed Wire Entity
// ============================================================================

pub const Wire = struct {
    sys_handle: u64,
    frame_origin: Vec3d,
    frame_u: Vec3d,
    frame_v: Vec3d,
    curve_handles: []u64,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Wire) void {
        self.allocator.free(self.curve_handles);
    }

    /// Discretizes the 1-manifold wire into 3D world space points
    pub fn sampleWorldPoints(self: *const Wire, samples_per_curve: u32, out_points: *std.ArrayList(Vec3d)) !void {
        for (self.curve_handles) |ch| {
            if (curve_store.get(ch)) |curve| {
                const u_min = curve.knots[curve.degree];
                const u_max = curve.knots[curve.ctrl_count];
                const n_steps = @max(2, samples_per_curve);

                for (0..n_steps) |s| {
                    const frac = @as(f64, @floatFromInt(s)) / @as(f64, @floatFromInt(n_steps));
                    const t = u_min + frac * (u_max - u_min);
                    const local_p = curve.eval(t);

                    // Transform via 2-Manifold Chart Frame: Phi(u, v) = p0 + u*e1 + v*e2
                    const world_p = self.frame_origin.add(self.frame_u.scale(local_p.x)).add(self.frame_v.scale(local_p.y));
                    try out_points.append(self.allocator, world_p);
                }
            }
        }
    }
};

// ============================================================================
// Registry & C-ABI Exports
// ============================================================================

var next_curve_id: u64 = 1;
pub var curve_store: std.AutoHashMap(u64, NurbsCurve) = std.AutoHashMap(u64, NurbsCurve).init(std.heap.page_allocator);

var next_wire_id: u64 = 1;
pub var wire_store: std.AutoHashMap(u64, Wire) = std.AutoHashMap(u64, Wire).init(std.heap.page_allocator);

pub fn curve_define_nurbs(
    sys_h: u64,
    dim: u32,
    degree: u32,
    ctrl_ids_ptr: [*]const u32,
    ctrl_count: u32,
    knots_ptr: [*]const f64,
    knot_count: u32,
) u64 {
    const alloc = std.heap.page_allocator;
    const num_indices = ctrl_count * (dim + 1);
    const ctrl_copy = alloc.dupe(u32, ctrl_ids_ptr[0..num_indices]) catch return 0;
    const knots_copy = alloc.dupe(f64, knots_ptr[0..knot_count]) catch {
        alloc.free(ctrl_copy);
        return 0;
    };

    const curve = NurbsCurve{
        .sys_handle = sys_h,
        .dim = dim,
        .degree = degree,
        .ctrl_param_indices = ctrl_copy,
        .ctrl_count = ctrl_count,
        .knots = knots_copy,
        .allocator = alloc,
    };

    // Rule 4: bits [63:62] == 0b11 for Mathematical Curves
    const handle: u64 = (@as(u64, 0b11) << 62) | next_curve_id;
    next_curve_id += 1;

    curve_store.put(handle, curve) catch return 0;
    return handle;
}

pub fn wire_assemble(
    sys_h: u64,
    frame_origin_u_v_ptr: [*]const f64,
    curve_handles_ptr: [*]const u64,
    curve_count: u32,
) u64 {
    const alloc = std.heap.page_allocator;
    const curves_copy = alloc.dupe(u64, curve_handles_ptr[0..curve_count]) catch return 0;

    const p0 = Vec3d.init(frame_origin_u_v_ptr[0], frame_origin_u_v_ptr[1], frame_origin_u_v_ptr[2]);
    const e1 = Vec3d.init(frame_origin_u_v_ptr[3], frame_origin_u_v_ptr[4], frame_origin_u_v_ptr[5]);
    const e2 = Vec3d.init(frame_origin_u_v_ptr[6], frame_origin_u_v_ptr[7], frame_origin_u_v_ptr[8]);

    const wire = Wire{
        .sys_handle = sys_h,
        .frame_origin = p0,
        .frame_u = e1,
        .frame_v = e2,
        .curve_handles = curves_copy,
        .allocator = alloc,
    };

    // Rule 4: bits [63:62] == 0b11 for Wires
    const handle: u64 = (@as(u64, 0b11) << 62) | (next_wire_id + 0x10000000);
    next_wire_id += 1;

    wire_store.put(handle, wire) catch return 0;
    return handle;
}

pub fn curve_free(h: u64) void {
    if (curve_store.fetchRemove(h)) |kv| {
        var c = kv.value;
        c.deinit();
    }
}

pub fn wire_free(h: u64) void {
    if (wire_store.fetchRemove(h)) |kv| {
        var w = kv.value;
        w.deinit();
    }
}
