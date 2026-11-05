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
    const face_offset: u32 = idx_offset + tri_count * 3 * 4;

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

/// Generates ISO-10303-21 STEP AP214 format into Shared Memory scratch buffer at 0x3F0000
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

    // 1. Output CARTESIAN_POINT (#20 .. #20+V-1) and VERTEX_POINT (#20+V .. #20+2V-1)
    const v_count = mesh.vertices.items.len;
    const cp_base: usize = 20;
    const vp_base: usize = cp_base + v_count;
    for (mesh.vertices.items, 0..) |v, idx| {
        out_buf.print(alloc, "#{d} = CARTESIAN_POINT('',({d:.6},{d:.6},{d:.6}));\n", .{ cp_base + idx, v.x, v.y, v.z }) catch return 0;
    }
    for (0..v_count) |idx| {
        out_buf.print(alloc, "#{d} = VERTEX_POINT('',#{d});\n", .{ vp_base + idx, cp_base + idx }) catch return 0;
    }

    // 2. Emit topological ADVANCED_FACE loops (bounded to fit 0x3F0000..0x4F0000 1 MB scratch window)
    const tri_count = mesh.indices.items.len / 3;
    const max_step_faces = @min(tri_count, 512);
    var next_ent: usize = vp_base + v_count;

    var face_ids: std.ArrayList(usize) = .empty;
    defer face_ids.deinit(alloc);

    for (0..max_step_faces) |t| {
        const idx0: usize = mesh.indices.items[t * 3 + 0];
        const idx1: usize = mesh.indices.items[t * 3 + 1];
        const idx2: usize = mesh.indices.items[t * 3 + 2];
        if (idx0 >= v_count or idx1 >= v_count or idx2 >= v_count) continue;

        const p0 = mesh.vertices.items[idx0];
        const p1 = mesh.vertices.items[idx1];
        const p2 = mesh.vertices.items[idx2];
        const e01 = p1.sub(p0);
        const e12 = p2.sub(p1);
        const e20 = p0.sub(p2);
        if (e01.length() < 1e-9 or e12.length() < 1e-9 or e20.length() < 1e-9) continue;

        const d01 = e01.normalize();
        const d12 = e12.normalize();
        const d20 = e20.normalize();
        const nrm = e01.cross(p2.sub(p0)).normalize();

        // Reserve 19 entity IDs for this face
        const id_dir01 = next_ent + 0;
        const id_dir12 = next_ent + 1;
        const id_dir20 = next_ent + 2;
        const id_vec01 = next_ent + 3;
        const id_vec12 = next_ent + 4;
        const id_vec20 = next_ent + 5;
        const id_ln01 = next_ent + 6;
        const id_ln12 = next_ent + 7;
        const id_ln20 = next_ent + 8;
        const id_ec01 = next_ent + 9;
        const id_ec12 = next_ent + 10;
        const id_ec20 = next_ent + 11;
        const id_oe01 = next_ent + 12;
        const id_oe12 = next_ent + 13;
        const id_oe20 = next_ent + 14;
        const id_loop = next_ent + 15;
        const id_fob = next_ent + 16;
        const id_dir_n = next_ent + 17;
        const id_ax2 = next_ent + 18;
        const id_pln = next_ent + 19;
        const id_face = next_ent + 20;
        next_ent += 21;

        out_buf.print(alloc, "#{d} = DIRECTION('',({d:.6},{d:.6},{d:.6}));\n", .{ id_dir01, d01.x, d01.y, d01.z }) catch return 0;
        out_buf.print(alloc, "#{d} = DIRECTION('',({d:.6},{d:.6},{d:.6}));\n", .{ id_dir12, d12.x, d12.y, d12.z }) catch return 0;
        out_buf.print(alloc, "#{d} = DIRECTION('',({d:.6},{d:.6},{d:.6}));\n", .{ id_dir20, d20.x, d20.y, d20.z }) catch return 0;
        out_buf.print(alloc, "#{d} = VECTOR('',#{d},1.0);\n", .{ id_vec01, id_dir01 }) catch return 0;
        out_buf.print(alloc, "#{d} = VECTOR('',#{d},1.0);\n", .{ id_vec12, id_dir12 }) catch return 0;
        out_buf.print(alloc, "#{d} = VECTOR('',#{d},1.0);\n", .{ id_vec20, id_dir20 }) catch return 0;
        out_buf.print(alloc, "#{d} = LINE('',#{d},#{d});\n", .{ id_ln01, cp_base + idx0, id_vec01 }) catch return 0;
        out_buf.print(alloc, "#{d} = LINE('',#{d},#{d});\n", .{ id_ln12, cp_base + idx1, id_vec12 }) catch return 0;
        out_buf.print(alloc, "#{d} = LINE('',#{d},#{d});\n", .{ id_ln20, cp_base + idx2, id_vec20 }) catch return 0;
        out_buf.print(alloc, "#{d} = EDGE_CURVE('',#{d},#{d},#{d},.T.);\n", .{ id_ec01, vp_base + idx0, vp_base + idx1, id_ln01 }) catch return 0;
        out_buf.print(alloc, "#{d} = EDGE_CURVE('',#{d},#{d},#{d},.T.);\n", .{ id_ec12, vp_base + idx1, vp_base + idx2, id_ln12 }) catch return 0;
        out_buf.print(alloc, "#{d} = EDGE_CURVE('',#{d},#{d},#{d},.T.);\n", .{ id_ec20, vp_base + idx2, vp_base + idx0, id_ln20 }) catch return 0;
        out_buf.print(alloc, "#{d} = ORIENTED_EDGE('',*,*,#{d},.T.);\n", .{ id_oe01, id_ec01 }) catch return 0;
        out_buf.print(alloc, "#{d} = ORIENTED_EDGE('',*,*,#{d},.T.);\n", .{ id_oe12, id_ec12 }) catch return 0;
        out_buf.print(alloc, "#{d} = ORIENTED_EDGE('',*,*,#{d},.T.);\n", .{ id_oe20, id_ec20 }) catch return 0;
        out_buf.print(alloc, "#{d} = EDGE_LOOP('',(#{d},#{d},#{d}));\n", .{ id_loop, id_oe01, id_oe12, id_oe20 }) catch return 0;
        out_buf.print(alloc, "#{d} = FACE_OUTER_BOUND('',#{d},.T.);\n", .{ id_fob, id_loop }) catch return 0;
        out_buf.print(alloc, "#{d} = DIRECTION('',({d:.6},{d:.6},{d:.6}));\n", .{ id_dir_n, nrm.x, nrm.y, nrm.z }) catch return 0;
        out_buf.print(alloc, "#{d} = AXIS2_PLACEMENT_3D('',#{d},#{d},#{d});\n", .{ id_ax2, cp_base + idx0, id_dir_n, id_dir01 }) catch return 0;
        out_buf.print(alloc, "#{d} = PLANE('',#{d});\n", .{ id_pln, id_ax2 }) catch return 0;
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

    const len = out_buf.items.len;
    export_step_len = len;

    // Copy to scratch memory at STEP_EXPORT_OFFSET (0x3F0000)
    const scratch = memory_map.getMemorySlice(STEP_EXPORT_OFFSET, len);
    @memcpy(scratch, out_buf.items);

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

    const len = out_buf.items.len;
    export_stl_len = len;

    // Copy to scratch memory at STL_EXPORT_OFFSET (0x4F0000)
    const scratch = memory_map.getMemorySlice(STL_EXPORT_OFFSET, len);
    @memcpy(scratch, out_buf.items);

    return @intCast(len);
}
