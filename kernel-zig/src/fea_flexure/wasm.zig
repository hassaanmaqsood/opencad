const std = @import("std");
const mesh = @import("mesh.zig");
const solver = @import("solver.zig");
const compliance = @import("compliance.zig");
const flexure = @import("flexure.zig");

var wasm_allocator = std.heap.wasm_allocator;
var cached_mesh: ?mesh.TetMesh = null;
var cached_compliance: compliance.ComplianceMatrix6x6 = .{};

pub export fn cad_fea_generate_box_mesh(
    dx: f64,
    dy: f64,
    dz: f64,
    nx: u32,
    ny: u32,
    nz: u32,
) u32 {
    if (cached_mesh) |*m| {
        m.deinit();
        cached_mesh = null;
    }

    var m = mesh.TetMesh.init(wasm_allocator, .Tet4);
    m.generateBoxTetMesh(dx, dy, dz, nx, ny, nz) catch return 0;
    cached_mesh = m;

    return @intCast(m.elementCount());
}

pub export fn cad_fea_get_node_count() u32 {
    if (cached_mesh) |m| {
        return @intCast(m.nodeCount());
    }
    return 0;
}

pub export fn cad_flexure_calc_blade_stiffness(
    length: f64,
    width: f64,
    thickness: f64,
    youngs_modulus: f64,
) f64 {
    const blade = flexure.FlexureBlade{
        .length = length,
        .width = width,
        .thickness = thickness,
    };
    return blade.calcRotationalStiffness(youngs_modulus);
}

pub export fn cad_flexure_calc_notch_compliance(
    width: f64,
    min_thickness: f64,
    notch_radius: f64,
    youngs_modulus: f64,
) f64 {
    const hinge = flexure.CircularNotchHinge{
        .width = width,
        .min_thickness = min_thickness,
        .notch_radius = notch_radius,
    };
    return hinge.calcRotationalCompliance(youngs_modulus);
}
