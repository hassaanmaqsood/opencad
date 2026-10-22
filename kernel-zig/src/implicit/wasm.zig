const std = @import("std");
const sdf = @import("sdf.zig");
const tpms = @import("tpms.zig");
const fields = @import("fields.zig");
const dual_contour = @import("dual_contour.zig");
const sdf_vm = @import("sdf_vm.zig");

var wasm_allocator = std.heap.wasm_allocator;
var cached_mesh: ?dual_contour.DualContourMesh = null;
var cached_slice: ?dual_contour.Slice2D = null;

pub export fn cad_implicit_eval_tpms_gyroid(
    x: f64,
    y: f64,
    z: f64,
    cell_size: f64,
    wall_thickness: f64,
) f64 {
    const lattice = tpms.TpmsLattice{
        .tpms_type = .Gyroid,
        .cell_size = cell_size,
        .wall_thickness = wall_thickness,
    };
    return lattice.evalSdf(.{ .x = x, .y = y, .z = z }, null);
}

pub export fn cad_implicit_eval_tpms_schwarz_p(
    x: f64,
    y: f64,
    z: f64,
    cell_size: f64,
    wall_thickness: f64,
) f64 {
    const lattice = tpms.TpmsLattice{
        .tpms_type = .SchwarzP,
        .cell_size = cell_size,
        .wall_thickness = wall_thickness,
    };
    return lattice.evalSdf(.{ .x = x, .y = y, .z = z }, null);
}

pub export fn cad_implicit_eval_tpms_schwarz_d(
    x: f64,
    y: f64,
    z: f64,
    cell_size: f64,
    wall_thickness: f64,
) f64 {
    const lattice = tpms.TpmsLattice{
        .tpms_type = .SchwarzD,
        .cell_size = cell_size,
        .wall_thickness = wall_thickness,
    };
    return lattice.evalSdf(.{ .x = x, .y = y, .z = z }, null);
}

pub export fn cad_implicit_eval_tpms_lidinoid(
    x: f64,
    y: f64,
    z: f64,
    cell_size: f64,
    wall_thickness: f64,
) f64 {
    const lattice = tpms.TpmsLattice{
        .tpms_type = .Lidinoid,
        .cell_size = cell_size,
        .wall_thickness = wall_thickness,
    };
    return lattice.evalSdf(.{ .x = x, .y = y, .z = z }, null);
}

pub export fn cad_implicit_eval_tpms_neovius(
    x: f64,
    y: f64,
    z: f64,
    cell_size: f64,
    wall_thickness: f64,
) f64 {
    const lattice = tpms.TpmsLattice{
        .tpms_type = .Neovius,
        .cell_size = cell_size,
        .wall_thickness = wall_thickness,
    };
    return lattice.evalSdf(.{ .x = x, .y = y, .z = z }, null);
}

pub export fn cad_implicit_eval_strut_bcc(
    x: f64,
    y: f64,
    z: f64,
    cell_size: f64,
    strut_radius: f64,
) f64 {
    const lattice = tpms.StrutLattice{
        .lattice_type = .BCC,
        .cell_size = cell_size,
        .strut_radius = strut_radius,
    };
    return lattice.evalSdf(.{ .x = x, .y = y, .z = z }, null);
}

pub export fn cad_implicit_eval_strut_fcc(
    x: f64,
    y: f64,
    z: f64,
    cell_size: f64,
    strut_radius: f64,
) f64 {
    const lattice = tpms.StrutLattice{
        .lattice_type = .FCC,
        .cell_size = cell_size,
        .strut_radius = strut_radius,
    };
    return lattice.evalSdf(.{ .x = x, .y = y, .z = z }, null);
}

pub export fn cad_implicit_eval_strut_octet(
    x: f64,
    y: f64,
    z: f64,
    cell_size: f64,
    strut_radius: f64,
) f64 {
    const lattice = tpms.StrutLattice{
        .lattice_type = .OctetTruss,
        .cell_size = cell_size,
        .strut_radius = strut_radius,
    };
    return lattice.evalSdf(.{ .x = x, .y = y, .z = z }, null);
}

pub export fn cad_implicit_mesh_sphere(radius: f64, resolution: u32) u32 {
    if (cached_mesh) |*m| {
        m.deinit();
        cached_mesh = null;
    }

    const sphere_eval = struct {
        var r: f64 = 5.0;
        fn eval(p: sdf.Vec3) f64 {
            return sdf.SdfPrimitive.sphere(p, r);
        }
    };
    sphere_eval.r = radius;

    var mesher = dual_contour.AdaptiveDualContouring.init(wasm_allocator, resolution);
    const bound = radius * 1.2;
    cached_mesh = mesher.mesh(sphere_eval.eval, .{ .x = -bound, .y = -bound, .z = -bound }, .{ .x = bound, .y = bound, .z = bound }) catch return 0;

    return @intCast(cached_mesh.?.vertices.items.len / 3);
}

pub export fn cad_implicit_dual_contour_tpms(
    tpms_type_val: u8,
    cell_size: f64,
    wall_thickness: f64,
    bound_x: f64,
    bound_y: f64,
    bound_z: f64,
    octree_depth: u32,
) u32 {
    if (cached_mesh) |*m| {
        m.deinit();
        cached_mesh = null;
    }

    const tpms_eval = struct {
        var lattice: tpms.TpmsLattice = .{};
        fn eval(p: sdf.Vec3) f64 {
            return lattice.evalSdf(p, null);
        }
    };
    tpms_eval.lattice = .{
        .tpms_type = @enumFromInt(tpms_type_val % 5),
        .cell_size = cell_size,
        .wall_thickness = wall_thickness,
    };

    var mesher = dual_contour.AdaptiveDualContouring.init(wasm_allocator, octree_depth);
    cached_mesh = mesher.mesh(
        tpms_eval.eval,
        .{ .x = -bound_x, .y = -bound_y, .z = -bound_z },
        .{ .x = bound_x, .y = bound_y, .z = bound_z },
    ) catch return 0;

    return @intCast(cached_mesh.?.vertices.items.len / 3);
}

pub export fn cad_implicit_slice_2d_tpms(
    tpms_type_val: u8,
    cell_size: f64,
    wall_thickness: f64,
    bound: f64,
    z_height: f64,
    res_xy: u32,
) u32 {
    if (cached_slice) |*s| {
        s.deinit();
        cached_slice = null;
    }

    const tpms_eval = struct {
        var lattice: tpms.TpmsLattice = .{};
        fn eval(p: sdf.Vec3) f64 {
            return lattice.evalSdf(p, null);
        }
    };
    tpms_eval.lattice = .{
        .tpms_type = @enumFromInt(tpms_type_val % 5),
        .cell_size = cell_size,
        .wall_thickness = wall_thickness,
    };

    var mesher = dual_contour.AdaptiveDualContouring.init(wasm_allocator, 4);
    cached_slice = mesher.slice2d(
        tpms_eval.eval,
        .{ -bound, -bound },
        .{ bound, bound },
        z_height,
        res_xy,
    ) catch return 0;

    if (cached_slice.?.contours.items.len > 0) {
        return @intCast(cached_slice.?.contours.items[0].points.items.len / 2);
    }
    return 0;
}

pub export fn cad_implicit_get_vertex_count() u32 {
    if (cached_mesh) |m| {
        return @intCast(m.vertices.items.len / 3);
    }
    return 0;
}

pub export fn cad_implicit_get_vertex_ptr() ?[*]const f32 {
    if (cached_mesh) |m| {
        return m.vertices.items.ptr;
    }
    return null;
}

pub export fn cad_implicit_get_normal_ptr() ?[*]const f32 {
    if (cached_mesh) |m| {
        return m.normals.items.ptr;
    }
    return null;
}

pub export fn cad_implicit_get_index_count() u32 {
    if (cached_mesh) |m| {
        return @intCast(m.indices.items.len);
    }
    return 0;
}

pub export fn cad_implicit_get_index_ptr() ?[*]const u32 {
    if (cached_mesh) |m| {
        return m.indices.items.ptr;
    }
    return null;
}

pub export fn cad_implicit_get_slice_point_count() u32 {
    if (cached_slice) |s| {
        if (s.contours.items.len > 0) {
            return @intCast(s.contours.items[0].points.items.len / 2);
        }
    }
    return 0;
}

pub export fn cad_implicit_get_slice_point_ptr() ?[*]const f32 {
    if (cached_slice) |s| {
        if (s.contours.items.len > 0) {
            return s.contours.items[0].points.items.ptr;
        }
    }
    return null;
}

pub export fn cad_implicit_get_slice_area() f64 {
    if (cached_slice) |s| {
        return s.total_area;
    }
    return 0.0;
}
