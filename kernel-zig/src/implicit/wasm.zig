const std = @import("std");
const sdf = @import("sdf.zig");
const tpms = @import("tpms.zig");
const fields = @import("fields.zig");
const dual_contouring = @import("dual_contouring.zig");

var wasm_allocator = std.heap.wasm_allocator;
var cached_mesh: ?dual_contouring.DualContourMesh = null;

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

    var mesher = dual_contouring.DualContouringMesher.init(wasm_allocator, resolution);
    const bound = radius * 1.2;
    cached_mesh = mesher.meshSdf(sphere_eval.eval, .{ .x = -bound, .y = -bound, .z = -bound }, .{ .x = bound, .y = bound, .z = bound }) catch return 0;

    return @intCast(cached_mesh.?.vertices.items.len / 3);
}

pub export fn cad_implicit_get_vertex_count() u32 {
    if (cached_mesh) |m| {
        return @intCast(m.vertices.items.len / 3);
    }
    return 0;
}
