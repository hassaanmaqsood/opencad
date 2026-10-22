const std = @import("std");
const Allocator = std.mem.Allocator;
const Vec3 = @import("../math/vec3.zig").Vec3;
const topo = @import("../topo/mod.zig");
const c_abi = @import("../c_abi.zig");

const SoASolid = topo.SoASolid;
const CadTopoId = topo.CadTopoId;

pub const LinearPatternOp = struct {
    dir1: Vec3 = Vec3.init(1, 0, 0),
    count1: u32 = 2,
    spacing1: f32 = 10.0,
    dir2: Vec3 = Vec3.init(0, 1, 0),
    count2: u32 = 1,
    spacing2: f32 = 10.0,
};

pub const CircularPatternOp = struct {
    axis_origin: Vec3 = Vec3.init(0, 0, 0),
    axis_dir: Vec3 = Vec3.init(0, 0, 1),
    count: u32 = 4,
    total_angle_rad: f32 = 6.283185307179586, // 2*pi
};

/// Creates a linear array of a prototype solid along 1 or 2 directions.
pub fn applyLinearPattern(
    allocator: Allocator,
    solid: *const SoASolid,
    feature_id: u16,
    op: LinearPatternOp,
) !SoASolid {
    var out_solid = SoASolid.init();
    errdefer out_solid.deinit(allocator);

    const d1 = op.dir1.normalize();
    const d2 = op.dir2.normalize();

    var instance_idx: u32 = 0;
    var total_vol: f32 = 0.0;
    var total_area: f32 = 0.0;

    for (0..op.count1) |i| {
        for (0..op.count2) |j| {
            const offset = d1.scale(@as(f32, @floatFromInt(i)) * op.spacing1)
                .add(d2.scale(@as(f32, @floatFromInt(j)) * op.spacing2));

            const inst_topo = CadTopoId.init(feature_id, @intCast(instance_idx), 3, .Solid, 0, 0);
            const solid_id = try out_solid.addSolid(allocator, inst_topo);
            const shell_id = try out_solid.addShell(allocator, solid_id, true, inst_topo);

            const v_start: u32 = @intCast(out_solid.vertices.len);
            const v_slice = solid.vertices.slice();

            for (0..solid.vertices.len) |v_i| {
                const p = v_slice.items(.point)[v_i].add(offset);
                const vt = CadTopoId.init(feature_id, @intCast(instance_idx * 1000 + v_i), 3, .Vertex, 0, 0);
                _ = try out_solid.addVertex(allocator, p, vt);
            }

            const he_slice = solid.half_edges.slice();
            const f_slice = solid.faces.slice();

            for (0..solid.faces.len) |f_i| {
                const fnorm = f_slice.items(.normal)[f_i];
                const ft = CadTopoId.init(feature_id, @intCast(instance_idx * 100 + f_i), 3, .Face, 0, 0);
                const face_id = try out_solid.addFace(allocator, shell_id, fnorm, .Plane, ft);
                const loop_id = try out_solid.addLoop(allocator, face_id, true, ft);

                const src_loop = f_slice.items(.outer_loop)[f_i];
                if (src_loop == topo.INVALID_ID) continue;
                const src_start_he = solid.loops.slice().items(.half_edge)[src_loop];
                if (src_start_he == topo.INVALID_ID) continue;

                var cur_he = src_start_he;
                var prev_new_he: topo.HalfEdgeId = topo.INVALID_ID;
                var first_new_he: topo.HalfEdgeId = topo.INVALID_ID;

                while (true) {
                    const orig_v = he_slice.items(.origin)[cur_he];
                    const new_he = try out_solid.addHalfEdge(allocator, v_start + orig_v, loop_id, ft);

                    if (first_new_he == topo.INVALID_ID) first_new_he = new_he;
                    if (prev_new_he != topo.INVALID_ID) {
                        out_solid.half_edges.slice().items(.next)[prev_new_he] = new_he;
                        out_solid.half_edges.slice().items(.prev)[new_he] = prev_new_he;
                    }
                    prev_new_he = new_he;

                    cur_he = he_slice.items(.next)[cur_he];
                    if (cur_he == src_start_he or cur_he == topo.INVALID_ID) break;
                }

                if (first_new_he != topo.INVALID_ID and prev_new_he != topo.INVALID_ID) {
                    out_solid.half_edges.slice().items(.next)[prev_new_he] = first_new_he;
                    out_solid.half_edges.slice().items(.prev)[first_new_he] = prev_new_he;
                    out_solid.loops.slice().items(.half_edge)[loop_id] = first_new_he;
                    out_solid.faces.slice().items(.outer_loop)[face_id] = loop_id;
                }
            }

            total_vol += solid.volume;
            total_area += solid.surface_area;
            instance_idx += 1;
        }
    }

    out_solid.volume = total_vol;
    out_solid.surface_area = total_area;
    return out_solid;
}

/// Creates a circular polar array of a prototype solid around an axis.
pub fn applyCircularPattern(
    allocator: Allocator,
    solid: *const SoASolid,
    feature_id: u16,
    op: CircularPatternOp,
) !SoASolid {
    var out_solid = SoASolid.init();
    errdefer out_solid.deinit(allocator);

    const axis = op.axis_dir.normalize();
    const count = if (op.count == 0) 1 else op.count;
    const step_angle = op.total_angle_rad / @as(f32, @floatFromInt(count));

    var total_vol: f32 = 0.0;
    var total_area: f32 = 0.0;

    for (0..count) |i| {
        const theta = @as(f32, @floatFromInt(i)) * step_angle;
        const cos_t = @cos(theta);
        const sin_t = @sin(theta);

        const inst_topo = CadTopoId.init(feature_id, @intCast(i), 2, .Solid, 0, 0);
        const solid_id = try out_solid.addSolid(allocator, inst_topo);
        const shell_id = try out_solid.addShell(allocator, solid_id, true, inst_topo);

        const v_start: u32 = @intCast(out_solid.vertices.len);
        const v_slice = solid.vertices.slice();

        // Rodrigues rotation: v_rot = v*cos + (axis x v)*sin + axis*(axis . v)*(1 - cos)
        for (0..solid.vertices.len) |v_i| {
            const rel_p = v_slice.items(.point)[v_i].sub(op.axis_origin);
            const rot_p = rel_p.scale(cos_t)
                .add(axis.cross(rel_p).scale(sin_t))
                .add(axis.scale(axis.dot(rel_p) * (1.0 - cos_t)));
            const final_p = rot_p.add(op.axis_origin);

            const vt = CadTopoId.init(feature_id, @intCast(i * 1000 + v_i), 2, .Vertex, 0, 0);
            _ = try out_solid.addVertex(allocator, final_p, vt);
        }

        const f_slice = solid.faces.slice();
        const he_slice = solid.half_edges.slice();

        for (0..solid.faces.len) |f_i| {
            const n = f_slice.items(.normal)[f_i];
            const rot_norm = n.scale(cos_t)
                .add(axis.cross(n).scale(sin_t))
                .add(axis.scale(axis.dot(n) * (1.0 - cos_t))).normalize();

            const ft = CadTopoId.init(feature_id, @intCast(i * 100 + f_i), 2, .Face, 0, 0);
            const face_id = try out_solid.addFace(allocator, shell_id, rot_norm, .Plane, ft);
            const loop_id = try out_solid.addLoop(allocator, face_id, true, ft);

            const src_loop = f_slice.items(.outer_loop)[f_i];
            if (src_loop == topo.INVALID_ID) continue;
            const src_start_he = solid.loops.slice().items(.half_edge)[src_loop];
            if (src_start_he == topo.INVALID_ID) continue;

            var cur_he = src_start_he;
            var prev_new_he: topo.HalfEdgeId = topo.INVALID_ID;
            var first_new_he: topo.HalfEdgeId = topo.INVALID_ID;

            while (true) {
                const orig_v = he_slice.items(.origin)[cur_he];
                const new_he = try out_solid.addHalfEdge(allocator, v_start + orig_v, loop_id, ft);

                if (first_new_he == topo.INVALID_ID) first_new_he = new_he;
                if (prev_new_he != topo.INVALID_ID) {
                    out_solid.half_edges.slice().items(.next)[prev_new_he] = new_he;
                    out_solid.half_edges.slice().items(.prev)[new_he] = prev_new_he;
                }
                prev_new_he = new_he;

                cur_he = he_slice.items(.next)[cur_he];
                if (cur_he == src_start_he or cur_he == topo.INVALID_ID) break;
            }

            if (first_new_he != topo.INVALID_ID and prev_new_he != topo.INVALID_ID) {
                out_solid.half_edges.slice().items(.next)[prev_new_he] = first_new_he;
                out_solid.half_edges.slice().items(.prev)[first_new_he] = prev_new_he;
                out_solid.loops.slice().items(.half_edge)[loop_id] = first_new_he;
                out_solid.faces.slice().items(.outer_loop)[face_id] = loop_id;
            }
        }

        total_vol += solid.volume;
        total_area += solid.surface_area;
    }

    out_solid.volume = total_vol;
    out_solid.surface_area = total_area;
    return out_solid;
}
