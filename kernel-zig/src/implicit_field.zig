const std = @import("std");
const memory = @import("memory.zig");
const autodiff = @import("autodiff.zig");
const constraint_sys = @import("constraint_sys.zig");
const surface_brep = @import("surface_brep.zig");
const nurbs = @import("geom/nurbs.zig");

pub const Vec3d = nurbs.Vec3d;
pub const Interval = autodiff.Interval;
pub const BRepSolid = surface_brep.BRepSolid;
pub const makeTopoId = surface_brep.makeTopoId;
pub const SUBSHAPE_FACE = surface_brep.SUBSHAPE_FACE;

pub const ERR_IMPLICIT_EMPTY_DOMAIN: u32 = 0x0501;
pub const ERR_IMPLICIT_GRAD_ZERO: u32 = 0x0502;

pub var active_octree_depth: u5 = 5; // Default 2^5 = 32^3 adaptive octree resolution
pub var active_qef_reg: f64 = 1e-4;
pub var last_implicit_status: u32 = 0;
pub var last_pruned_nodes: usize = 0;
pub var last_evaluated_leaves: usize = 0;

pub const ImplicitSolid = struct {
    solid_id: u32,
    scalar_expr_h: u64,
    bbox_min: Vec3d,
    bbox_max: Vec3d,
    octree_depth: u5 = 5,
    qef_reg: f64 = 1e-4,
};

var next_implicit_id: u32 = 1;
pub var implicit_store: std.AutoHashMap(u64, ImplicitSolid) = std.AutoHashMap(u64, ImplicitSolid).init(memory.persistent_allocator);

fn packGridKey(ix: usize, iy: usize, iz: usize) u64 {
    return (@as(u64, @intCast(ix)) << 40) | (@as(u64, @intCast(iy)) << 20) | @as(u64, @intCast(iz));
}

/// Implements solid_implicit_field using adaptive Octree Interval Arithmetic pruning
/// and QEF Dual Contouring driven by exact analytical Dual-Number gradients (§3.2, §8.3).
pub fn solid_implicit_field(
    scalar_expr_h: u64,
    bbox_ptr: [*]const f64,
) u64 {
    return solid_implicit_field_WithParams(scalar_expr_h, bbox_ptr, active_octree_depth, active_qef_reg);
}

pub fn solid_implicit_field_WithParams(
    scalar_expr_h: u64,
    bbox_ptr: [*]const f64,
    octree_depth: u5,
    qef_reg: f64,
) u64 {
    const alloc = memory.persistent_allocator;
    const solid_id = next_implicit_id;
    next_implicit_id += 1;

    const b_min = Vec3d.init(bbox_ptr[0], bbox_ptr[1], bbox_ptr[2]);
    const b_max = Vec3d.init(bbox_ptr[3], bbox_ptr[4], bbox_ptr[5]);

    const depth: u5 = if (octree_depth >= 2 and octree_depth <= 6) octree_depth else 5;
    const reg: f64 = if (qef_reg > 0.0) qef_reg else 1e-4;

    const solid = ImplicitSolid{
        .solid_id = solid_id,
        .scalar_expr_h = scalar_expr_h,
        .bbox_min = b_min,
        .bbox_max = b_max,
        .octree_depth = depth,
        .qef_reg = reg,
    };

    // Rule 4: bits [63:62] == 0b10 for Implicit / SDF Solids
    const handle: u64 = (@as(u64, 0b10) << 62) | @as(u64, solid_id);
    implicit_store.put(handle, solid) catch return 0;

    last_implicit_status = 0;
    meshImplicitSolidOctree(handle, solid_id, scalar_expr_h, b_min, b_max, depth, reg, alloc);
    if (last_implicit_status != 0) {
        _ = implicit_store.remove(handle);
        surface_brep.solid_free(handle);
        return 0;
    }

    return handle;
}

const OctreeContext = struct {
    expr_h: u64,
    solid_id: u32,
    b_min: Vec3d,
    b_max: Vec3d,
    dx: f64,
    dy: f64,
    dz: f64,
    max_depth: u5,
    grid_n: usize,
    qef_reg: f64,
    alloc: std.mem.Allocator,
    corner_cache: std.AutoHashMap(u64, f64),
    cell_vert_map: std.AutoHashMap(u64, u32),
    active_leaves: std.ArrayList([3]usize),
    brep: *BRepSolid,
    pruned_nodes: usize = 0,
    evaluated_leaves: usize = 0,
    grad_zero_detected: bool = false,
    any_negative_sampled: bool = false,

    fn evalCorner(self: *OctreeContext, ix: usize, iy: usize, iz: usize) f64 {
        const key = packGridKey(ix, iy, iz);
        if (self.corner_cache.get(key)) |v| return v;

        const x = self.b_min.x + @as(f64, @floatFromInt(ix)) * self.dx;
        const y = self.b_min.y + @as(f64, @floatFromInt(iy)) * self.dy;
        const z = self.b_min.z + @as(f64, @floatFromInt(iz)) * self.dz;
        const val = autodiff.expr_eval(self.expr_h, &[3]f64{ x, y, z }, 3, null);
        if (val <= 0.0) self.any_negative_sampled = true;
        self.corner_cache.put(key, val) catch {};
        return val;
    }

    fn cornerPos(self: *const OctreeContext, ix: usize, iy: usize, iz: usize) Vec3d {
        return Vec3d.init(
            self.b_min.x + @as(f64, @floatFromInt(ix)) * self.dx,
            self.b_min.y + @as(f64, @floatFromInt(iy)) * self.dy,
            self.b_min.z + @as(f64, @floatFromInt(iz)) * self.dz,
        );
    }

    /// Finds exact zero-crossing along edge [p_a, p_b] via secant + bisection refinement
    fn findEdgeZeroCrossing(self: *const OctreeContext, p_a: Vec3d, p_b: Vec3d, f_a: f64, f_b: f64) Vec3d {
        var lo_p = p_a;
        var hi_p = p_b;
        var lo_f = f_a;
        var hi_f = f_b;

        for (0..12) |_| {
            const denom = hi_f - lo_f;
            var t: f64 = if (@abs(denom) > 1e-15) -lo_f / denom else 0.5;
            t = std.math.clamp(t, 0.1, 0.9);
            const mid_p = Vec3d.init(
                lo_p.x + t * (hi_p.x - lo_p.x),
                lo_p.y + t * (hi_p.y - lo_p.y),
                lo_p.z + t * (hi_p.z - lo_p.z),
            );
            const mid_f = autodiff.expr_eval(self.expr_h, &[3]f64{ mid_p.x, mid_p.y, mid_p.z }, 3, null);
            if (@abs(mid_f) < 1e-14) return mid_p;
            if ((lo_f <= 0.0 and mid_f <= 0.0) or (lo_f > 0.0 and mid_f > 0.0)) {
                lo_p = mid_p;
                lo_f = mid_f;
            } else {
                hi_p = mid_p;
                hi_f = mid_f;
            }
        }

        const denom = hi_f - lo_f;
        const t = if (@abs(denom) > 1e-15) std.math.clamp(-lo_f / denom, 0.0, 1.0) else 0.5;
        return Vec3d.init(
            lo_p.x + t * (hi_p.x - lo_p.x),
            lo_p.y + t * (hi_p.y - lo_p.y),
            lo_p.z + t * (hi_p.z - lo_p.z),
        );
    }

    fn processLeafCell(self: *OctreeContext, ix: usize, iy: usize, iz: usize) void {
        self.evaluated_leaves += 1;

        const c_coords = [8][3]usize{
            .{ ix, iy, iz },
            .{ ix + 1, iy, iz },
            .{ ix, iy + 1, iz },
            .{ ix + 1, iy + 1, iz },
            .{ ix, iy, iz + 1 },
            .{ ix + 1, iy, iz + 1 },
            .{ ix, iy + 1, iz + 1 },
            .{ ix + 1, iy + 1, iz + 1 },
        };

        var c_vals: [8]f64 = undefined;
        var any_pos = false;
        var any_neg = false;
        for (0..8) |k| {
            const v = self.evalCorner(c_coords[k][0], c_coords[k][1], c_coords[k][2]);
            c_vals[k] = v;
            if (v > 0.0) any_pos = true else any_neg = true;
        }

        if (!(any_pos and any_neg)) return;

        // 12 cube edges (pairs of corner indices 0..7)
        const edges = [12][2]usize{
            .{ 0, 1 }, .{ 2, 3 }, .{ 4, 5 }, .{ 6, 7 }, // X-axis edges
            .{ 0, 2 }, .{ 1, 3 }, .{ 4, 6 }, .{ 5, 7 }, // Y-axis edges
            .{ 0, 4 }, .{ 1, 5 }, .{ 2, 6 }, .{ 3, 7 }, // Z-axis edges
        };

        var edge_pts: [12]Vec3d = undefined;
        var edge_nrms: [12]Vec3d = undefined;
        var crossing_count: usize = 0;
        var mass_pt = Vec3d.init(0.0, 0.0, 0.0);
        var avg_nrm = Vec3d.init(0.0, 0.0, 0.0);

        for (edges) |e| {
            const fa = c_vals[e[0]];
            const fb = c_vals[e[1]];
            if ((fa <= 0.0 and fb > 0.0) or (fa > 0.0 and fb <= 0.0)) {
                const pa = self.cornerPos(c_coords[e[0]][0], c_coords[e[0]][1], c_coords[e[0]][2]);
                const pb = self.cornerPos(c_coords[e[1]][0], c_coords[e[1]][1], c_coords[e[1]][2]);
                const pk = self.findEdgeZeroCrossing(pa, pb, fa, fb);

                // Evaluate exact analytical gradient via Dual Numbers
                var grad: [3]f64 = undefined;
                _ = autodiff.expr_eval(self.expr_h, &[3]f64{ pk.x, pk.y, pk.z }, 3, &grad);
                const grad_norm = @sqrt(grad[0] * grad[0] + grad[1] * grad[1] + grad[2] * grad[2]);

                // CDML §8.1 & §13.1: Reject fields with ||grad F|| < 1e-12 on the zero isosurface
                if (grad_norm < 1e-12 or std.math.isNan(grad_norm)) {
                    self.grad_zero_detected = true;
                    return;
                }

                const nk = Vec3d.init(grad[0] / grad_norm, grad[1] / grad_norm, grad[2] / grad_norm);
                edge_pts[crossing_count] = pk;
                edge_nrms[crossing_count] = nk;
                crossing_count += 1;

                mass_pt = mass_pt.add(pk);
                avg_nrm = avg_nrm.add(nk);
            }
        }

        if (crossing_count == 0) return;

        const inv_k = 1.0 / @as(f64, @floatFromInt(crossing_count));
        mass_pt = mass_pt.scale(inv_k);
        avg_nrm = avg_nrm.normalize();

        // Assemble regularized 3x3 QEF normal equations:
        // QEF(v) = sum_k (n_k . (v - p_k))^2 + lambda * ||v - mass_pt||^2
        // Let u = v - mass_pt -> (A + lambda*I) * u = sum_k (n_k . (p_k - mass_pt)) * n_k
        var A = [9]f64{
            self.qef_reg, 0.0,          0.0,
            0.0,          self.qef_reg, 0.0,
            0.0,          0.0,          self.qef_reg,
        };
        var rhs = [3]f64{ 0.0, 0.0, 0.0 };

        for (0..crossing_count) |k| {
            const nk = edge_nrms[k];
            const diff = edge_pts[k].sub(mass_pt);
            const d = nk.dot(diff);

            A[0] += nk.x * nk.x;
            A[1] += nk.x * nk.y;
            A[2] += nk.x * nk.z;
            A[3] += nk.y * nk.x;
            A[4] += nk.y * nk.y;
            A[5] += nk.y * nk.z;
            A[6] += nk.z * nk.x;
            A[7] += nk.z * nk.y;
            A[8] += nk.z * nk.z;

            rhs[0] += d * nk.x;
            rhs[1] += d * nk.y;
            rhs[2] += d * nk.z;
        }

        const cell_min = self.cornerPos(ix, iy, iz);
        const cell_max = self.cornerPos(ix + 1, iy + 1, iz + 1);
        var u_sol = [3]f64{ 0.0, 0.0, 0.0 };
        var dual_v = mass_pt;
        if (constraint_sys.solveLinearSystem(&A, &rhs, &u_sol, 3)) {
            dual_v = Vec3d.init(
                std.math.clamp(mass_pt.x + u_sol[0], cell_min.x, cell_max.x),
                std.math.clamp(mass_pt.y + u_sol[1], cell_min.y, cell_max.y),
                std.math.clamp(mass_pt.z + u_sol[2], cell_min.z, cell_max.z),
            );
        }

        // Project solved QEF vertex onto exact F(x,y,z) = 0 level set via damped Newton-Gradient steps
        for (0..4) |_| {
            var g_step: [3]f64 = undefined;
            const f_val = autodiff.expr_eval(self.expr_h, &[3]f64{ dual_v.x, dual_v.y, dual_v.z }, 3, &g_step);
            if (@abs(f_val) < 1e-9) break;
            const g_sq = g_step[0] * g_step[0] + g_step[1] * g_step[1] + g_step[2] * g_step[2];
            if (g_sq < 1e-18) break;
            const alpha = f_val / g_sq;
            dual_v = Vec3d.init(
                std.math.clamp(dual_v.x - alpha * g_step[0], cell_min.x, cell_max.x),
                std.math.clamp(dual_v.y - alpha * g_step[1], cell_min.y, cell_max.y),
                std.math.clamp(dual_v.z - alpha * g_step[2], cell_min.z, cell_max.z),
            );
        }

        // Re-evaluate exact Dual-Number normal at the solved QEF dual vertex
        var v_grad: [3]f64 = undefined;
        _ = autodiff.expr_eval(self.expr_h, &[3]f64{ dual_v.x, dual_v.y, dual_v.z }, 3, &v_grad);
        const vg_norm = @sqrt(v_grad[0] * v_grad[0] + v_grad[1] * v_grad[1] + v_grad[2] * v_grad[2]);
        const final_nrm = if (vg_norm > 1e-12)
            Vec3d.init(v_grad[0] / vg_norm, v_grad[1] / vg_norm, v_grad[2] / vg_norm)
        else
            avg_nrm;

        const v_idx: u32 = @intCast(self.brep.vertices.items.len);
        self.brep.vertices.append(self.alloc, dual_v) catch return;
        self.brep.normals.append(self.alloc, final_nrm) catch return;

        const cell_key = packGridKey(ix, iy, iz);
        self.cell_vert_map.put(cell_key, v_idx) catch return;
        self.active_leaves.append(self.alloc, .{ ix, iy, iz }) catch return;
    }

    fn subdivideOctree(self: *OctreeContext, depth: u5, ix: usize, iy: usize, iz: usize) void {
        if (self.grad_zero_detected) return;

        const scale: usize = @as(usize, 1) << (self.max_depth - depth);
        const x0 = self.b_min.x + @as(f64, @floatFromInt(ix * scale)) * self.dx;
        const y0 = self.b_min.y + @as(f64, @floatFromInt(iy * scale)) * self.dy;
        const z0 = self.b_min.z + @as(f64, @floatFromInt(iz * scale)) * self.dz;
        const x1 = self.b_min.x + @as(f64, @floatFromInt((ix + 1) * scale)) * self.dx;
        const y1 = self.b_min.y + @as(f64, @floatFromInt((iy + 1) * scale)) * self.dy;
        const z1 = self.b_min.z + @as(f64, @floatFromInt((iz + 1) * scale)) * self.dz;

        // Evaluate guaranteed Interval Arithmetic bounds [F_min, F_max] on cell box (§3.2, §8.3)
        const box_intervals = [3]Interval{
            Interval.init(x0, x1),
            Interval.init(y0, y1),
            Interval.init(z0, z1),
        };
        const f_bounds = autodiff.expr_eval_interval(self.expr_h, &box_intervals);
        if (f_bounds.min <= 0.0) self.any_negative_sampled = true;

        const tau: f64 = 1e-9;
        if (f_bounds.min > tau or f_bounds.max < -tau) {
            // O(1) Interval Arithmetic octree pruning: cell does not straddle F = 0!
            self.pruned_nodes += 1;
            return;
        }

        if (depth == self.max_depth) {
            self.processLeafCell(ix, iy, iz);
            return;
        }

        // Recurse into 8 children octants
        const next_d: u5 = depth + 1;
        for (0..2) |oz| {
            for (0..2) |oy| {
                for (0..2) |ox| {
                    self.subdivideOctree(next_d, ix * 2 + ox, iy * 2 + oy, iz * 2 + oz);
                }
            }
        }
    }
};

fn emitQuad(brep: *BRepSolid, alloc: std.mem.Allocator, face_id: surface_brep.TopoId, v0: u32, v1: u32, v2: u32, v3: u32, flip: bool) void {
    if (!flip) {
        brep.indices.appendSlice(alloc, &[_]u32{ v0, v1, v2 }) catch return;
        brep.triangle_to_topo_id.append(alloc, face_id) catch return;
        brep.indices.appendSlice(alloc, &[_]u32{ v0, v2, v3 }) catch return;
        brep.triangle_to_topo_id.append(alloc, face_id) catch return;
    } else {
        brep.indices.appendSlice(alloc, &[_]u32{ v0, v2, v1 }) catch return;
        brep.triangle_to_topo_id.append(alloc, face_id) catch return;
        brep.indices.appendSlice(alloc, &[_]u32{ v0, v3, v2 }) catch return;
        brep.triangle_to_topo_id.append(alloc, face_id) catch return;
    }
}

fn meshImplicitSolidOctree(
    handle: u64,
    solid_id: u32,
    expr_h: u64,
    b_min: Vec3d,
    b_max: Vec3d,
    max_depth: u5,
    qef_reg: f64,
    alloc: std.mem.Allocator,
) void {
    const N: usize = @as(usize, 1) << max_depth;
    const dx = (b_max.x - b_min.x) / @as(f64, @floatFromInt(N));
    const dy = (b_max.y - b_min.y) / @as(f64, @floatFromInt(N));
    const dz = (b_max.z - b_min.z) / @as(f64, @floatFromInt(N));

    var brep = BRepSolid.init(alloc, solid_id);

    var ctx = OctreeContext{
        .expr_h = expr_h,
        .solid_id = solid_id,
        .b_min = b_min,
        .b_max = b_max,
        .dx = dx,
        .dy = dy,
        .dz = dz,
        .max_depth = max_depth,
        .grid_n = N,
        .qef_reg = qef_reg,
        .alloc = alloc,
        .corner_cache = std.AutoHashMap(u64, f64).init(alloc),
        .cell_vert_map = std.AutoHashMap(u64, u32).init(alloc),
        .active_leaves = .empty,
        .brep = &brep,
    };
    defer ctx.corner_cache.deinit();
    defer ctx.cell_vert_map.deinit();
    defer ctx.active_leaves.deinit(alloc);

    // 1. Adaptive Octree subdivision with Interval Arithmetic pruning
    ctx.subdivideOctree(0, 0, 0, 0);

    last_pruned_nodes = ctx.pruned_nodes;
    last_evaluated_leaves = ctx.evaluated_leaves;

    if (ctx.grad_zero_detected) {
        last_implicit_status = ERR_IMPLICIT_GRAD_ZERO;
        brep.deinit();
        return;
    }

    const face_id = makeTopoId(solid_id, SUBSHAPE_FACE, 1);

    // 2. Connect dual vertices across sign-changing interior grid edges along +X, +Y, +Z
    for (ctx.active_leaves.items) |leaf| {
        const ix = leaf[0];
        const iy = leaf[1];
        const iz = leaf[2];

        // +X edge at (ix..ix+1, iy, iz), shared by cells (ix, iy-1, iz-1), (ix, iy, iz-1), (ix, iy, iz), (ix, iy-1, iz)
        if (iy > 0 and iz > 0) {
            const f0 = ctx.evalCorner(ix, iy, iz);
            const f1 = ctx.evalCorner(ix + 1, iy, iz);
            if ((f0 <= 0.0 and f1 > 0.0) or (f0 > 0.0 and f1 <= 0.0)) {
                const c0 = ctx.cell_vert_map.get(packGridKey(ix, iy - 1, iz - 1));
                const c1 = ctx.cell_vert_map.get(packGridKey(ix, iy, iz - 1));
                const c2 = ctx.cell_vert_map.get(packGridKey(ix, iy, iz));
                const c3 = ctx.cell_vert_map.get(packGridKey(ix, iy - 1, iz));
                if (c0 != null and c1 != null and c2 != null and c3 != null) {
                    emitQuad(&brep, alloc, face_id, c0.?, c1.?, c2.?, c3.?, f0 > 0.0);
                }
            }
        }

        // +Y edge at (ix, iy..iy+1, iz), shared by cells (ix-1, iy, iz-1), (ix-1, iy, iz), (ix, iy, iz), (ix, iy, iz-1)
        if (ix > 0 and iz > 0) {
            const f0 = ctx.evalCorner(ix, iy, iz);
            const f1 = ctx.evalCorner(ix, iy + 1, iz);
            if ((f0 <= 0.0 and f1 > 0.0) or (f0 > 0.0 and f1 <= 0.0)) {
                const c0 = ctx.cell_vert_map.get(packGridKey(ix - 1, iy, iz - 1));
                const c1 = ctx.cell_vert_map.get(packGridKey(ix - 1, iy, iz));
                const c2 = ctx.cell_vert_map.get(packGridKey(ix, iy, iz));
                const c3 = ctx.cell_vert_map.get(packGridKey(ix, iy, iz - 1));
                if (c0 != null and c1 != null and c2 != null and c3 != null) {
                    emitQuad(&brep, alloc, face_id, c0.?, c1.?, c2.?, c3.?, f0 > 0.0);
                }
            }
        }

        // +Z edge at (ix, iy, iz..iz+1), shared by cells (ix-1, iy-1, iz), (ix, iy-1, iz), (ix, iy, iz), (ix-1, iy, iz)
        if (ix > 0 and iy > 0) {
            const f0 = ctx.evalCorner(ix, iy, iz);
            const f1 = ctx.evalCorner(ix, iy, iz + 1);
            if ((f0 <= 0.0 and f1 > 0.0) or (f0 > 0.0 and f1 <= 0.0)) {
                const c0 = ctx.cell_vert_map.get(packGridKey(ix - 1, iy - 1, iz));
                const c1 = ctx.cell_vert_map.get(packGridKey(ix, iy - 1, iz));
                const c2 = ctx.cell_vert_map.get(packGridKey(ix, iy, iz));
                const c3 = ctx.cell_vert_map.get(packGridKey(ix - 1, iy, iz));
                if (c0 != null and c1 != null and c2 != null and c3 != null) {
                    emitQuad(&brep, alloc, face_id, c0.?, c1.?, c2.?, c3.?, f0 > 0.0);
                }
            }
        }
    }

    // 3. Per-triangle principal curvatures of the level set F = 0 (CDML §10.2).
    //    Gradient is exact (forward-mode AD); the Hessian is the central difference of the exact gradient.
    const h_fd = 0.05 * @min(dx, @min(dy, dz));
    const tri_total = brep.indices.items.len / 3;
    brep.triangle_curvatures.ensureTotalCapacity(alloc, tri_total) catch {};
    for (0..tri_total) |t| {
        const p0 = brep.vertices.items[brep.indices.items[t * 3]];
        const p1 = brep.vertices.items[brep.indices.items[t * 3 + 1]];
        const p2 = brep.vertices.items[brep.indices.items[t * 3 + 2]];
        const c = p0.add(p1).add(p2).scale(1.0 / 3.0);
        brep.triangle_curvatures.append(alloc, levelSetCurvature(expr_h, c, h_fd)) catch {};
    }

    surface_brep.solid_brep_store.put(handle, brep) catch {};
}

/// Curvature of the implicit surface through `p` (Goldman 2005):
///   K = gᵀ adj(H) g / |g|⁴,   H_m = (gᵀ H g − |g|² tr H) / (2 |g|³),   k_{1,2} = H_m ± sqrt(H_m² − K)
pub fn levelSetCurvature(expr_h: u64, p: Vec3d, h: f64) surface_brep.FaceCurvature {
    var g: [3]f64 = .{ 0, 0, 0 };
    _ = autodiff.expr_eval(expr_h, &[3]f64{ p.x, p.y, p.z }, 3, &g);
    var hess: [3][3]f64 = undefined;
    const base = [3]f64{ p.x, p.y, p.z };
    for (0..3) |i| {
        var xp = base;
        var xm = base;
        xp[i] += h;
        xm[i] -= h;
        var gp: [3]f64 = .{ 0, 0, 0 };
        var gm: [3]f64 = .{ 0, 0, 0 };
        _ = autodiff.expr_eval(expr_h, &xp, 3, &gp);
        _ = autodiff.expr_eval(expr_h, &xm, 3, &gm);
        for (0..3) |j| hess[i][j] = (gp[j] - gm[j]) / (2.0 * h);
    }
    // Symmetrise
    for (0..3) |i| for (i + 1..3) |j| {
        const s = 0.5 * (hess[i][j] + hess[j][i]);
        hess[i][j] = s;
        hess[j][i] = s;
    };
    const g2 = g[0] * g[0] + g[1] * g[1] + g[2] * g[2];
    if (!(g2 > 1e-24) or !std.math.isFinite(g2)) return .{};
    const gn = @sqrt(g2);

    const a = hess[0][0];
    const b = hess[0][1];
    const cc = hess[0][2];
    const d = hess[1][1];
    const e = hess[1][2];
    const f = hess[2][2];
    const A00 = d * f - e * e;
    const A11 = a * f - cc * cc;
    const A22 = a * d - b * b;
    const A01 = cc * e - b * f;
    const A02 = b * e - cc * d;
    const A12 = b * cc - a * e;
    const gadjg = g[0] * g[0] * A00 + g[1] * g[1] * A11 + g[2] * g[2] * A22 +
        2.0 * (g[0] * g[1] * A01 + g[0] * g[2] * A02 + g[1] * g[2] * A12);
    const k_gauss = gadjg / (g2 * g2);

    var gHg: f64 = 0.0;
    for (0..3) |i| for (0..3) |j| {
        gHg += g[i] * hess[i][j] * g[j];
    };
    const k_mean = (gHg - g2 * (a + d + f)) / (2.0 * g2 * gn);
    const disc = @sqrt(@max(0.0, k_mean * k_mean - k_gauss));
    if (!std.math.isFinite(k_gauss) or !std.math.isFinite(k_mean)) return .{};
    return .{ .k_min = k_mean - disc, .k_max = k_mean + disc, .k_gauss = k_gauss, .k_mean = k_mean };
}

test "levelSetCurvature: sphere K = 1/R^2, |H| = 1/R; cylinder K = 0" {
    const sph = autodiff.expr_compile("x^2 + y^2 + z^2 - 25.0", 22);
    defer autodiff.expr_free(sph);
    const ks = levelSetCurvature(sph, Vec3d.init(3.0, 0.0, 4.0), 1e-3);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0 / 25.0), ks.k_gauss, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0 / 5.0), @abs(ks.k_mean), 1e-6);

    const cyl = autodiff.expr_compile("x^2 + y^2 - 16.0", 16);
    defer autodiff.expr_free(cyl);
    const kc = levelSetCurvature(cyl, Vec3d.init(4.0, 0.0, 7.0), 1e-3);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), kc.k_gauss, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0 / 8.0), @abs(kc.k_mean), 1e-6);
}

test "Interval-pruned Octree Dual Contouring, QEF vertex placement, and ERR_IMPLICIT_GRAD_ZERO" {
    // 1. Sphere x^2 + y^2 + z^2 - 100 <= 0 (R = 10) inside [-15, 15]^3
    const sphere_expr = autodiff.expr_compile("x^2 + y^2 + z^2 - 100.0", 23);
    defer autodiff.expr_free(sphere_expr);

    const bbox = [_]f64{ -15.0, -15.0, -15.0, 15.0, 15.0, 15.0 };
    const h = solid_implicit_field_WithParams(sphere_expr, &bbox, 4, 1e-4);
    try std.testing.expect(h != 0);
    defer {
        _ = implicit_store.remove(h);
        if (surface_brep.solid_brep_store.fetchRemove(h)) |kv| {
            var s = kv.value;
            s.deinit();
        }
    }

    // Verify Interval Arithmetic pruned empty outer octants in O(1) time
    try std.testing.expect(last_pruned_nodes > 0);
    try std.testing.expect(last_evaluated_leaves < (16 * 16 * 16));

    // Verify QEF placed dual vertices accurately onto the sphere surface (r ~ 10.0)
    const mesh = surface_brep.solid_brep_store.getPtr(h).?;
    try std.testing.expect(mesh.vertices.items.len > 20);
    try std.testing.expect(mesh.indices.items.len > 60);

    for (mesh.vertices.items) |v| {
        const r = @sqrt(v.x * v.x + v.y * v.y + v.z * v.z);
        try std.testing.expectApproxEqAbs(@as(f64, 10.0), r, 0.35);
    }

    // 2. Degenerate zero-gradient field on zero isosurface x = 0 -> ERR_IMPLICIT_GRAD_ZERO (0x0502)
    // For F(x) = x^3 * x^2 = x^5, F(-1) = -1 < 0 and F(1) = +1 > 0, and at the zero crossing x = 0, ||grad F|| = 5*x^4 = 0 < 1e-12
    const degen_expr = autodiff.expr_compile("x^3 * x^2", 9);
    defer autodiff.expr_free(degen_expr);
    const bbox_degen = [_]f64{ -1.0, -1.0, -1.0, 1.0, 1.0, 1.0 };
    const h_degen = solid_implicit_field_WithParams(degen_expr, &bbox_degen, 3, 1e-4);
    try std.testing.expectEqual(@as(u64, 0), h_degen);
    try std.testing.expectEqual(ERR_IMPLICIT_GRAD_ZERO, last_implicit_status);
}
