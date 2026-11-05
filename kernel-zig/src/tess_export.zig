const std = @import("std");
const memory = @import("memory.zig");
const memory_map = @import("memory_map.zig");
const surface_brep = @import("surface_brep.zig");
const c_abi = @import("c_abi.zig");
const nurbs = @import("geom/nurbs.zig");

pub const Vec3d = nurbs.Vec3d;
pub const BRepSolid = surface_brep.BRepSolid;

// Shared memory scratch export storage
pub var export_step_len: usize = 0;
pub var export_stl_len: usize = 0;
pub var last_chord_tol: f32 = 0.05;
pub var last_angle_tol: f32 = 0.1;
pub const STEP_EXPORT_OFFSET: usize = 0x3F0000;
pub const STL_EXPORT_OFFSET: usize = 0x4F0000;
pub const STEP_MAX_SCRATCH_BYTES: usize = STL_EXPORT_OFFSET - STEP_EXPORT_OFFSET;
pub const STL_MAX_SCRATCH_BYTES: usize = 0x5F0000 - STL_EXPORT_OFFSET;

pub fn getSolidMesh(solid_h: u64) ?*const BRepSolid {
    // Materialize lazy CSG handle on demand if not yet in solid_brep_store
    if ((solid_h >> 62) == 0b01 and !surface_brep.solid_brep_store.contains(solid_h)) {
        if (surface_brep.csg_store.get(solid_h)) |node| {
            surface_brep.materializeCsgNode(memory.persistent_allocator, solid_h, node) catch {};
        }
    }
    if (surface_brep.solid_brep_store.getPtr(solid_h)) |p| return p;

    // Fallback: search across all stores by lower 32 bits
    var it = surface_brep.solid_brep_store.iterator();
    while (it.next()) |entry| {
        if ((entry.key_ptr.* & 0xFFFFFFFF) == (solid_h & 0xFFFFFFFF)) {
            if (entry.value_ptr.indices.items.len > 0) {
                return entry.value_ptr;
            }
        }
    }
    return null;
}

/// Adaptively subdivides curved triangles of `solid` in-place when both chord sagitta
/// `L^2 * k_max / 8 > chord_tol` and vertex normal angle `acos(n0 . n1) > angle_tol`.
fn refineCurvedMeshToTolerance(solid: *BRepSolid, chord_tol: f32, angle_tol: f32) void {
    const c_tol: f64 = if (chord_tol > 1e-5) @floatCast(chord_tol) else 0.05;
    const a_tol: f64 = if (angle_tol > 1e-5) @floatCast(angle_tol) else 0.1;

    // Only subdivide when caller requests strict refinement and mesh fits comfortably in buffer
    if (c_tol >= 0.02 and a_tol >= 0.03) return;
    const orig_tri_count = solid.indices.items.len / 3;
    if (orig_tri_count == 0 or orig_tri_count > 2048) return;

    const alloc = solid.allocator;
    var t: usize = 0;
    while (t < orig_tri_count) : (t += 1) {
        const curv = solid.getCurvature(t);
        if (@abs(curv.k_max) < 1e-5) continue;

        const idx0 = solid.indices.items[t * 3 + 0];
        const idx1 = solid.indices.items[t * 3 + 1];
        const idx2 = solid.indices.items[t * 3 + 2];
        const p0 = solid.vertices.items[idx0];
        const p1 = solid.vertices.items[idx1];
        const p2 = solid.vertices.items[idx2];
        const n0 = solid.normals.items[idx0];
        const n1 = solid.normals.items[idx1];
        const n2 = solid.normals.items[idx2];

        // Find longest edge among (0,1), (1,2), (2,0)
        const l01 = p1.sub(p0).length();
        const l12 = p2.sub(p1).length();
        const l20 = p0.sub(p2).length();
        const max_l = @max(l01, @max(l12, l20));

        const sagitta = 0.125 * max_l * max_l * @abs(curv.k_max);
        const min_dot = @min(n0.dot(n1), @min(n1.dot(n2), n2.dot(n0)));
        const max_ang = std.math.acos(std.math.clamp(min_dot, -1.0, 1.0));

        if (sagitta <= c_tol and max_ang <= a_tol) continue;

        // Subdivide along longest edge with Phong/Hermite normal projection onto osculating surface
        var va = idx0;
        var vb = idx1;
        var vc = idx2;
        if (l12 >= l01 and l12 >= l20) {
            va = idx1;
            vb = idx2;
            vc = idx0;
        } else if (l20 >= l01 and l20 >= l12) {
            va = idx2;
            vb = idx0;
            vc = idx1;
        }

        const pa = solid.vertices.items[va];
        const pb = solid.vertices.items[vb];
        const na = solid.normals.items[va];
        const nb = solid.normals.items[vb];
        const n_mid = na.add(nb).normalize();
        const edge_len = pb.sub(pa).length();
        const sag = 0.125 * edge_len * edge_len * curv.k_max;
        const p_mid = pa.add(pb).scale(0.5).add(n_mid.scale(sag));

        const vm: u32 = @intCast(solid.vertices.items.len);
        solid.vertices.append(alloc, p_mid) catch break;
        solid.normals.append(alloc, n_mid) catch break;

        // Replace triangle t with (va, vm, vc) and append (vm, vb, vc)
        solid.indices.items[t * 3 + 0] = va;
        solid.indices.items[t * 3 + 1] = vm;
        solid.indices.items[t * 3 + 2] = vc;

        const tid = if (t < solid.triangle_to_topo_id.items.len)
            solid.triangle_to_topo_id.items[t]
        else
            surface_brep.makeTopoId(solid.solid_id, surface_brep.SUBSHAPE_FACE, 1);
        solid.addTriangle(vm, vb, vc, tid, curv) catch break;
    }
}

/// Tessellates solid directly into Shared Memory Tessellation Buffer at 0x0F0000
/// and increments tess_generation_counter at 0x001C.
pub fn solid_tessellate(
    solid_h: u64,
    chord_tol: f32,
    angle_tol: f32,
) void {
    last_chord_tol = if (chord_tol > 0.0) chord_tol else 0.05;
    last_angle_tol = if (angle_tol > 0.0) angle_tol else 0.1;

    if (surface_brep.solid_brep_store.getPtr(solid_h)) |mut_mesh| {
        refineCurvedMeshToTolerance(mut_mesh, last_chord_tol, last_angle_tol);
    }

    const mesh = getSolidMesh(solid_h) orelse return;
    const v_count: u32 = @intCast(mesh.vertices.items.len);
    const tri_count: u32 = @intCast(mesh.indices.items.len / 3);

    // Compute bounding box
    var min_x: f64 = 1e30;
    var min_y: f64 = 1e30;
    var min_z: f64 = 1e30;
    var max_x: f64 = -1e30;
    var max_y: f64 = -1e30;
    var max_z: f64 = -1e30;

    for (mesh.vertices.items) |v| {
        if (v.x < min_x) min_x = v.x;
        if (v.y < min_y) min_y = v.y;
        if (v.z < min_z) min_z = v.z;
        if (v.x > max_x) max_x = v.x;
        if (v.y > max_y) max_y = v.y;
        if (v.z > max_z) max_z = v.z;
    }

    if (v_count == 0) {
        min_x = 0; min_y = 0; min_z = 0;
        max_x = 0; max_y = 0; max_z = 0;
    }

    // Header layout at 0x0F0000 (128 bytes aligned)
    const pos_offset: u32 = 0x0F0080;
    const nrm_offset: u32 = pos_offset + v_count * 3 * 4;
    const idx_offset: u32 = nrm_offset + v_count * 3 * 4;
    const face_offset: u32 = (idx_offset + tri_count * 3 * 4 + 7) & ~@as(u32, 7);

    const total_len = (face_offset + tri_count * 24) - @as(u32, @intCast(memory_map.TESS_BUFFER_OFFSET));
    const mem_slice = memory_map.getMemorySlice(memory_map.TESS_BUFFER_OFFSET, total_len + 128);

    // Write header
    std.mem.writeInt(u32, mem_slice[0x00..0x04], @intCast(solid_h & 0xFFFFFFFF), .little);
    std.mem.writeInt(u32, mem_slice[0x04..0x08], v_count, .little);
    std.mem.writeInt(u32, mem_slice[0x08..0x0C], tri_count, .little);
    std.mem.writeInt(u32, mem_slice[0x0C..0x10], pos_offset, .little);
    std.mem.writeInt(u32, mem_slice[0x10..0x14], nrm_offset, .little);
    std.mem.writeInt(u32, mem_slice[0x14..0x18], idx_offset, .little);
    std.mem.writeInt(u32, mem_slice[0x18..0x1C], face_offset, .little);
    std.mem.writeInt(u32, mem_slice[0x1C..0x20], @as(u32, @intCast((solid_h >> 32) & 0xFFFFFFFF)), .little); // solid_h upper bits

    // Bounding box at 0x20 (6 * 8 = 48 bytes)
    const bbox = [_]f64{ min_x, min_y, min_z, max_x, max_y, max_z };
    for (bbox, 0..) |b, i| {
        std.mem.writeInt(u64, mem_slice[0x20 + i * 8 ..][0..8], @bitCast(b), .little);
    }

    // Write positions (f32)
    var p_cur: usize = pos_offset - @as(u32, @intCast(memory_map.TESS_BUFFER_OFFSET));
    for (mesh.vertices.items) |v| {
        const x_f32: f32 = @floatCast(v.x);
        const y_f32: f32 = @floatCast(v.y);
        const z_f32: f32 = @floatCast(v.z);
        std.mem.writeInt(u32, mem_slice[p_cur..][0..4], @bitCast(x_f32), .little);
        std.mem.writeInt(u32, mem_slice[p_cur + 4 ..][0..4], @bitCast(y_f32), .little);
        std.mem.writeInt(u32, mem_slice[p_cur + 8 ..][0..4], @bitCast(z_f32), .little);
        p_cur += 12;
    }

    // Write normals (f32)
    var n_cur: usize = nrm_offset - @as(u32, @intCast(memory_map.TESS_BUFFER_OFFSET));
    for (mesh.normals.items) |n| {
        const x_f32: f32 = @floatCast(n.x);
        const y_f32: f32 = @floatCast(n.y);
        const z_f32: f32 = @floatCast(n.z);
        std.mem.writeInt(u32, mem_slice[n_cur..][0..4], @bitCast(x_f32), .little);
        std.mem.writeInt(u32, mem_slice[n_cur + 4 ..][0..4], @bitCast(y_f32), .little);
        std.mem.writeInt(u32, mem_slice[n_cur + 8 ..][0..4], @bitCast(z_f32), .little);
        n_cur += 12;
    }

    // Write indices (u32)
    var i_cur: usize = idx_offset - @as(u32, @intCast(memory_map.TESS_BUFFER_OFFSET));
    for (mesh.indices.items) |idx| {
        std.mem.writeInt(u32, mem_slice[i_cur..][0..4], idx, .little);
        i_cur += 4;
    }

    // Write face IDs (192-bit / 3 * u64 TopoId per triangle)
    var f_cur: usize = face_offset - @as(u32, @intCast(memory_map.TESS_BUFFER_OFFSET));
    for (mesh.triangle_to_topo_id.items) |fid| {
        std.mem.writeInt(u64, mem_slice[f_cur..][0..8], fid.words[0], .little);
        std.mem.writeInt(u64, mem_slice[f_cur + 8 ..][0..8], fid.words[1], .little);
        std.mem.writeInt(u64, mem_slice[f_cur + 16 ..][0..8], fid.words[2], .little);
        f_cur += 24;
    }

    // Increment tess_generation_counter at 0x001C
    memory_map.incTessGenCounter();
}

fn hashStepVertexPos(p: Vec3d) u64 {
    const qx: i64 = @intFromFloat(@round(p.x * 1e5));
    const qy: i64 = @intFromFloat(@round(p.y * 1e5));
    const qz: i64 = @intFromFloat(@round(p.z * 1e5));
    var buf: [24]u8 = undefined;
    std.mem.writeInt(i64, buf[0..8], qx, .little);
    std.mem.writeInt(i64, buf[8..16], qy, .little);
    std.mem.writeInt(i64, buf[16..24], qz, .little);
    return std.hash.Wyhash.hash(0, &buf);
}

fn hashStepPlane(nrm: Vec3d, dist: f64) u64 {
    const qnx: i64 = @intFromFloat(@round(nrm.x * 1e5));
    const qny: i64 = @intFromFloat(@round(nrm.y * 1e5));
    const qnz: i64 = @intFromFloat(@round(nrm.z * 1e5));
    const qd: i64 = @intFromFloat(@round(dist * 1e4));
    var buf: [32]u8 = undefined;
    std.mem.writeInt(i64, buf[0..8], qnx, .little);
    std.mem.writeInt(i64, buf[8..16], qny, .little);
    std.mem.writeInt(i64, buf[16..24], qnz, .little);
    std.mem.writeInt(i64, buf[24..32], qd, .little);
    return std.hash.Wyhash.hash(0, &buf);
}

/// Generates topologically welded ISO-10303-21 STEP AP214 format into Shared Memory scratch buffer at 0x3F0000
pub fn solid_export_step(solid_h: u64, out_buf: *std.ArrayList(u8)) u32 {
    const mesh = getSolidMesh(solid_h) orelse return 0;
    const alloc = memory.getAllocator();

    out_buf.clearRetainingCapacity();

    out_buf.appendSlice(alloc,
        \\ISO-10303-21;
        \\HEADER;
        \\FILE_DESCRIPTION(('OpenCAD Pure-Math B-Rep Model'),'2;1');
        \\FILE_NAME('model.step','2026-11-03',('OpenCAD'),('DeepMind'),'OpenCAD Math Kernel','OpenCAD','');
        \\FILE_SCHEMA(('AUTOMOTIVE_DESIGN { 1 0 10303 214 1 1 1 1 }'));
        \\ENDSEC;
        \\DATA;
        \\#1 = APPLICATION_CONTEXT('core data for automotive mechanical design processes');
        \\#2 = APPLICATION_PROTOCOL_DEFINITION('international standard','automotive_design',2000,#1);
        \\#3 = PRODUCT_DEFINITION_CONTEXT('part definition',#1,'design');
        \\#4 = PRODUCT('OpenCAD_Part','OpenCAD_Part','',(#3));
        \\#5 = PRODUCT_DEFINITION_FORMATION('','',#4);
        \\#6 = PRODUCT_DEFINITION('design','',#5,#3);
        \\#7 = PRODUCT_DEFINITION_SHAPE('','',#6);
        \\#8 = SHAPE_REPRESENTATION('OpenCAD_Rep',(#9),#10);
        \\#9 = MANIFOLD_SOLID_BREP('Solid_1',#11);
        \\#10 = ( GEOMETRIC_REPRESENTATION_CONTEXT(3) GLOBAL_UNCERTAINTY_ASSIGNED_CONTEXT((#12)) GLOBAL_UNIT_ASSIGNED_CONTEXT((#13,#14,#15)) REPRESENTATION_CONTEXT('Context #1','3D') );
        \\#12 = UNCERTAINTY_MEASURE_WITH_UNIT(LENGTH_MEASURE(1.E-07),#13,'distance_accuracy_value','confusion accuracy');
        \\#13 = ( LENGTH_UNIT() NAMED_UNIT(*) SI_UNIT(.MILLI.,.METRE.) );
        \\#14 = ( NAMED_UNIT(*) PLANE_ANGLE_UNIT() SI_UNIT($,.RADIAN.) );
        \\#15 = ( NAMED_UNIT(*) SI_UNIT($,.STERADIAN.) SOLID_ANGLE_UNIT() );
        \\
    ) catch return 0;

    // 1. Weld coincident vertices (1e-5 mm grid) so adjacent faces share topological VERTEX_POINTs
    const raw_v_count = mesh.vertices.items.len;
    var raw_to_welded = alloc.alloc(u32, raw_v_count) catch return 0;
    defer alloc.free(raw_to_welded);

    var welded_verts: std.ArrayList(Vec3d) = .empty;
    defer welded_verts.deinit(alloc);

    var vert_map = std.AutoHashMap(u64, u32).init(alloc);
    defer vert_map.deinit();

    for (mesh.vertices.items, 0..) |v, i| {
        const key = hashStepVertexPos(v);
        if (vert_map.get(key)) |w_idx| {
            raw_to_welded[i] = w_idx;
        } else {
            const w_idx: u32 = @intCast(welded_verts.items.len);
            welded_verts.append(alloc, v) catch return 0;
            vert_map.put(key, w_idx) catch return 0;
            raw_to_welded[i] = w_idx;
        }
    }

    const w_count = welded_verts.items.len;
    const cp_base: usize = 20;
    const vp_base: usize = cp_base + w_count;
    for (welded_verts.items, 0..) |v, idx| {
        out_buf.print(alloc, "#{d} = CARTESIAN_POINT('',({d:.6},{d:.6},{d:.6}));\n", .{ cp_base + idx, v.x, v.y, v.z }) catch return 0;
    }
    for (0..w_count) |idx| {
        out_buf.print(alloc, "#{d} = VERTEX_POINT('',#{d});\n", .{ vp_base + idx, cp_base + idx }) catch return 0;
    }

    // 2. Emit shared EDGE_CURVE, shared coplanar PLANE, and connected ADVANCED_FACE loops
    const tri_count = mesh.indices.items.len / 3;
    var next_ent: usize = vp_base + w_count;

    var edge_map = std.AutoHashMap(u64, usize).init(alloc);
    defer edge_map.deinit();

    var plane_map = std.AutoHashMap(u64, usize).init(alloc);
    defer plane_map.deinit();

    var face_ids: std.ArrayList(usize) = .empty;
    defer face_ids.deinit(alloc);

    const getOrEmitEdgeCurve = struct {
        fn call(
            a_alloc: std.mem.Allocator,
            buf: *std.ArrayList(u8),
            emap: *std.AutoHashMap(u64, usize),
            wverts: []const Vec3d,
            c_base: usize,
            v_base: usize,
            n_ent: *usize,
            u: u32,
            v: u32,
        ) !usize {
            const u_min = @min(u, v);
            const u_max = @max(u, v);
            const key = (@as(u64, u_min) << 32) | @as(u64, u_max);
            if (emap.get(key)) |existing_ec| return existing_ec;

            const p_start = wverts[u_min];
            const p_end = wverts[u_max];
            const d = p_end.sub(p_start).normalize();

            const id_dir = n_ent.* + 0;
            const id_vec = n_ent.* + 1;
            const id_ln = n_ent.* + 2;
            const id_ec = n_ent.* + 3;
            n_ent.* += 4;

            try buf.print(a_alloc, "#{d} = DIRECTION('',({d:.6},{d:.6},{d:.6}));\n", .{ id_dir, d.x, d.y, d.z });
            try buf.print(a_alloc, "#{d} = VECTOR('',#{d},1.0);\n", .{ id_vec, id_dir });
            try buf.print(a_alloc, "#{d} = LINE('',#{d},#{d});\n", .{ id_ln, c_base + u_min, id_vec });
            try buf.print(a_alloc, "#{d} = EDGE_CURVE('',#{d},#{d},#{d},.T.);\n", .{ id_ec, v_base + u_min, v_base + u_max, id_ln });

            try emap.put(key, id_ec);
            return id_ec;
        }
    }.call;

    for (0..tri_count) |t| {
        // Reserve 128 bytes at the end for CLOSED_SHELL + ENDSEC if approaching STEP_MAX_SCRATCH_BYTES
        if (out_buf.items.len + 2048 + face_ids.items.len * 10 >= STEP_MAX_SCRATCH_BYTES) break;

        const r0: usize = mesh.indices.items[t * 3 + 0];
        const r1: usize = mesh.indices.items[t * 3 + 1];
        const r2: usize = mesh.indices.items[t * 3 + 2];
        if (r0 >= raw_v_count or r1 >= raw_v_count or r2 >= raw_v_count) continue;

        const w0 = raw_to_welded[r0];
        const w1 = raw_to_welded[r1];
        const w2 = raw_to_welded[r2];
        if (w0 == w1 or w1 == w2 or w2 == w0) continue;

        const p0 = welded_verts.items[w0];
        const p1 = welded_verts.items[w1];
        const p2 = welded_verts.items[w2];
        const e01 = p1.sub(p0);
        const e12 = p2.sub(p1);
        const e20 = p0.sub(p2);
        if (e01.length() < 1e-9 or e12.length() < 1e-9 or e20.length() < 1e-9) continue;

        const cr = e01.cross(p2.sub(p0));
        if (cr.length() < 1e-12) continue;
        const nrm = cr.normalize();
        const ref_dir = e01.normalize();

        const ec01 = getOrEmitEdgeCurve(alloc, out_buf, &edge_map, welded_verts.items, cp_base, vp_base, &next_ent, w0, w1) catch return 0;
        const ec12 = getOrEmitEdgeCurve(alloc, out_buf, &edge_map, welded_verts.items, cp_base, vp_base, &next_ent, w1, w2) catch return 0;
        const ec20 = getOrEmitEdgeCurve(alloc, out_buf, &edge_map, welded_verts.items, cp_base, vp_base, &next_ent, w2, w0) catch return 0;

        const p_key = hashStepPlane(nrm, nrm.dot(p0));
        const id_pln = if (plane_map.get(p_key)) |existing_pln| existing_pln else blk: {
            const id_dir_n = next_ent + 0;
            const id_dir_r = next_ent + 1;
            const id_ax2 = next_ent + 2;
            const id_p = next_ent + 3;
            next_ent += 4;
            out_buf.print(alloc, "#{d} = DIRECTION('',({d:.6},{d:.6},{d:.6}));\n", .{ id_dir_n, nrm.x, nrm.y, nrm.z }) catch return 0;
            out_buf.print(alloc, "#{d} = DIRECTION('',({d:.6},{d:.6},{d:.6}));\n", .{ id_dir_r, ref_dir.x, ref_dir.y, ref_dir.z }) catch return 0;
            out_buf.print(alloc, "#{d} = AXIS2_PLACEMENT_3D('',#{d},#{d},#{d});\n", .{ id_ax2, cp_base + w0, id_dir_n, id_dir_r }) catch return 0;
            out_buf.print(alloc, "#{d} = PLANE('',#{d});\n", .{ id_p, id_ax2 }) catch return 0;
            plane_map.put(p_key, id_p) catch return 0;
            break :blk id_p;
        };

        const id_oe01 = next_ent + 0;
        const id_oe12 = next_ent + 1;
        const id_oe20 = next_ent + 2;
        const id_loop = next_ent + 3;
        const id_fob = next_ent + 4;
        const id_face = next_ent + 5;
        next_ent += 6;

        const s01 = if (w0 < w1) ".T." else ".F.";
        const s12 = if (w1 < w2) ".T." else ".F.";
        const s20 = if (w2 < w0) ".T." else ".F.";

        out_buf.print(alloc, "#{d} = ORIENTED_EDGE('',*,*,#{d},{s});\n", .{ id_oe01, ec01, s01 }) catch return 0;
        out_buf.print(alloc, "#{d} = ORIENTED_EDGE('',*,*,#{d},{s});\n", .{ id_oe12, ec12, s12 }) catch return 0;
        out_buf.print(alloc, "#{d} = ORIENTED_EDGE('',*,*,#{d},{s});\n", .{ id_oe20, ec20, s20 }) catch return 0;
        out_buf.print(alloc, "#{d} = EDGE_LOOP('',(#{d},#{d},#{d}));\n", .{ id_loop, id_oe01, id_oe12, id_oe20 }) catch return 0;
        out_buf.print(alloc, "#{d} = FACE_OUTER_BOUND('',#{d},.T.);\n", .{ id_fob, id_loop }) catch return 0;
        out_buf.print(alloc, "#{d} = ADVANCED_FACE('',(#{d}),#{d},.T.);\n", .{ id_face, id_fob, id_pln }) catch return 0;

        face_ids.append(alloc, id_face) catch return 0;
    }

    // Emit #11 = CLOSED_SHELL('Shell_1', (#...)) referencing all emitted ADVANCED_FACE entities
    out_buf.appendSlice(alloc, "#11 = CLOSED_SHELL('Shell_1',(") catch return 0;
    for (face_ids.items, 0..) |fid, idx| {
        if (idx > 0) out_buf.appendSlice(alloc, ",") catch return 0;
        out_buf.print(alloc, "#{d}", .{fid}) catch return 0;
    }
    out_buf.appendSlice(alloc, "));\n") catch return 0;

    out_buf.appendSlice(alloc, "ENDSEC;\nEND-ISO-10303-21;\n") catch return 0;

    const len = @min(out_buf.items.len, STEP_MAX_SCRATCH_BYTES);
    export_step_len = len;

    // Copy to scratch memory at STEP_EXPORT_OFFSET (0x3F0000)
    const scratch = memory_map.getMemorySlice(STEP_EXPORT_OFFSET, len);
    @memcpy(scratch, out_buf.items[0..len]);

    return @intCast(len);
}

/// Generates Watertight Binary or ASCII STL format into Shared Memory scratch buffer at 0x3F0000
pub fn solid_export_stl(solid_h: u64, binary: bool, out_buf: *std.ArrayList(u8)) u32 {
    const mesh = getSolidMesh(solid_h) orelse return 0;
    const alloc = memory.getAllocator();

    out_buf.clearRetainingCapacity();

    const tri_count = mesh.indices.items.len / 3;

    if (binary) {
        // Standard Binary STL: 80-byte header + u32 tri_count + 50 * tri_count bytes
        const total_size = 84 + tri_count * 50;
        out_buf.resize(alloc, total_size) catch return 0;

        var header = std.mem.zeroes([80]u8);
        const msg = "OpenCAD Watertight Binary STL Export (Pure-Math Kernel)";
        @memcpy(header[0..msg.len], msg);
        @memcpy(out_buf.items[0..80], &header);

        std.mem.writeInt(u32, out_buf.items[80..][0..4], @intCast(tri_count), .little);

        var cur: usize = 84;
        for (0..tri_count) |t| {
            const idx0 = mesh.indices.items[t * 3];
            const idx1 = mesh.indices.items[t * 3 + 1];
            const idx2 = mesh.indices.items[t * 3 + 2];

            const p0 = mesh.vertices.items[idx0];
            const p1 = mesh.vertices.items[idx1];
            const p2 = mesh.vertices.items[idx2];

            // Face normal
            const e1 = p1.sub(p0);
            const e2 = p2.sub(p0);
            const n = e1.cross(e2).normalize();

            // Normal (12 bytes)
            std.mem.writeInt(u32, out_buf.items[cur..][0..4], @bitCast(@as(f32, @floatCast(n.x))), .little);
            std.mem.writeInt(u32, out_buf.items[cur + 4 ..][0..4], @bitCast(@as(f32, @floatCast(n.y))), .little);
            std.mem.writeInt(u32, out_buf.items[cur + 8 ..][0..4], @bitCast(@as(f32, @floatCast(n.z))), .little);
            cur += 12;

            // V1 (12 bytes)
            std.mem.writeInt(u32, out_buf.items[cur..][0..4], @bitCast(@as(f32, @floatCast(p0.x))), .little);
            std.mem.writeInt(u32, out_buf.items[cur + 4 ..][0..4], @bitCast(@as(f32, @floatCast(p0.y))), .little);
            std.mem.writeInt(u32, out_buf.items[cur + 8 ..][0..4], @bitCast(@as(f32, @floatCast(p0.z))), .little);
            cur += 12;

            // V2 (12 bytes)
            std.mem.writeInt(u32, out_buf.items[cur..][0..4], @bitCast(@as(f32, @floatCast(p1.x))), .little);
            std.mem.writeInt(u32, out_buf.items[cur + 4 ..][0..4], @bitCast(@as(f32, @floatCast(p1.y))), .little);
            std.mem.writeInt(u32, out_buf.items[cur + 8 ..][0..4], @bitCast(@as(f32, @floatCast(p1.z))), .little);
            cur += 12;

            // V3 (12 bytes)
            std.mem.writeInt(u32, out_buf.items[cur..][0..4], @bitCast(@as(f32, @floatCast(p2.x))), .little);
            std.mem.writeInt(u32, out_buf.items[cur + 4 ..][0..4], @bitCast(@as(f32, @floatCast(p2.y))), .little);
            std.mem.writeInt(u32, out_buf.items[cur + 8 ..][0..4], @bitCast(@as(f32, @floatCast(p2.z))), .little);
            cur += 12;

            // Attribute byte count = 0 (2 bytes)
            std.mem.writeInt(u16, out_buf.items[cur..][0..2], 0, .little);
            cur += 2;
        }
    } else {
        // Standard ASCII STL
        out_buf.appendSlice(alloc, "solid OpenCAD_Model\n") catch return 0;

        for (0..tri_count) |t| {
            const idx0 = mesh.indices.items[t * 3];
            const idx1 = mesh.indices.items[t * 3 + 1];
            const idx2 = mesh.indices.items[t * 3 + 2];

            const p0 = mesh.vertices.items[idx0];
            const p1 = mesh.vertices.items[idx1];
            const p2 = mesh.vertices.items[idx2];

            const e1 = p1.sub(p0);
            const e2 = p2.sub(p0);
            const n = e1.cross(e2).normalize();

            out_buf.print(alloc, "  facet normal {d:.6} {d:.6} {d:.6}\n", .{ n.x, n.y, n.z }) catch return 0;
            out_buf.appendSlice(alloc, "    outer loop\n") catch return 0;
            out_buf.print(alloc, "      vertex {d:.6} {d:.6} {d:.6}\n", .{ p0.x, p0.y, p0.z }) catch return 0;
            out_buf.print(alloc, "      vertex {d:.6} {d:.6} {d:.6}\n", .{ p1.x, p1.y, p1.z }) catch return 0;
            out_buf.print(alloc, "      vertex {d:.6} {d:.6} {d:.6}\n", .{ p2.x, p2.y, p2.z }) catch return 0;
            out_buf.appendSlice(alloc, "    endloop\n  endfacet\n") catch return 0;
        }

        out_buf.appendSlice(alloc, "endsolid OpenCAD_Model\n") catch return 0;
    }

    const len = @min(out_buf.items.len, STL_MAX_SCRATCH_BYTES);
    export_stl_len = len;

    // Copy to scratch memory at STL_EXPORT_OFFSET (0x670000)
    const scratch = memory_map.getMemorySlice(STL_EXPORT_OFFSET, len);
    @memcpy(scratch, out_buf.items[0..len]);

    return @intCast(len);
}
