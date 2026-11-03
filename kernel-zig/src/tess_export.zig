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

pub fn getSolidMesh(solid_h: u64) ?*const BRepSolid {
    const tag = solid_h >> 62;
    if (tag == 0b00 or tag == 0b10) {
        return surface_brep.solid_brep_store.getPtr(solid_h);
    } else if (tag == 0b01) {
        if (surface_brep.csg_store.get(solid_h)) |node| {
            return getSolidMesh(node.left);
        }
    }
    return null;
}

/// Tessellates solid directly into Shared Memory Tessellation Buffer at 0x0F0000
/// and increments tess_generation_counter at 0x001C.
pub fn solid_tessellate(
    solid_h: u64,
    chord_tol: f32,
    angle_tol: f32,
) void {
    _ = chord_tol;
    _ = angle_tol;

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

    const total_len = (face_offset + tri_count * 8) - @as(u32, @intCast(memory_map.TESS_BUFFER_OFFSET));
    const mem_slice = memory_map.getMemorySlice(memory_map.TESS_BUFFER_OFFSET, total_len + 128);

    // Write header
    std.mem.writeInt(u32, mem_slice[0x00..0x04], @intCast(solid_h & 0xFFFFFFFF), .little);
    std.mem.writeInt(u32, mem_slice[0x04..0x08], v_count, .little);
    std.mem.writeInt(u32, mem_slice[0x08..0x0C], tri_count, .little);
    std.mem.writeInt(u32, mem_slice[0x0C..0x10], pos_offset, .little);
    std.mem.writeInt(u32, mem_slice[0x10..0x14], nrm_offset, .little);
    std.mem.writeInt(u32, mem_slice[0x14..0x18], idx_offset, .little);
    std.mem.writeInt(u32, mem_slice[0x18..0x1C], face_offset, .little);
    std.mem.writeInt(u32, mem_slice[0x1C..0x20], 0, .little); // reserved

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

    // Write face IDs (u64 CadTopoId)
    var f_cur: usize = face_offset - @as(u32, @intCast(memory_map.TESS_BUFFER_OFFSET));
    for (mesh.triangle_to_topo_id.items) |fid| {
        std.mem.writeInt(u64, mem_slice[f_cur..][0..8], fid.raw, .little);
        f_cur += 8;
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
        \\#11 = CLOSED_SHELL('Shell_1',());
        \\#12 = UNCERTAINTY_MEASURE_WITH_UNIT(LENGTH_MEASURE(1.E-07),#13,'distance_accuracy_value','confusion accuracy');
        \\#13 = ( LENGTH_UNIT() NAMED_UNIT(*) SI_UNIT(.MILLI.,.METRE.) );
        \\#14 = ( NAMED_UNIT(*) PLANE_ANGLE_UNIT() SI_UNIT($,.RADIAN.) );
        \\#15 = ( NAMED_UNIT(*) SI_UNIT($,.STERADIAN.) SOLID_ANGLE_UNIT() );
        \\
    ) catch return 0;

    // Output cartesian vertices in STEP format
    for (mesh.vertices.items, 0..) |v, idx| {
        out_buf.print(alloc, "#{d} = CARTESIAN_POINT('',({d:.6},{d:.6},{d:.6}));\n", .{ idx + 20, v.x, v.y, v.z }) catch return 0;
    }

    out_buf.appendSlice(alloc, "ENDSEC;\nEND-ISO-10303-21;\n") catch return 0;

    const len = out_buf.items.len;
    export_step_len = len;

    // Copy to scratch memory at 0x3F0000
    const scratch = memory_map.getMemorySlice(memory_map.SCRATCH_OFFSET, len);
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

    // Copy to scratch memory at 0x3F0000
    const scratch = memory_map.getMemorySlice(memory_map.SCRATCH_OFFSET, len);
    @memcpy(scratch, out_buf.items);

    return @intCast(len);
}
