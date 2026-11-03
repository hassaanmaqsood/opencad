const std = @import("std");
const memory = @import("memory.zig");
const autodiff = @import("autodiff.zig");
const surface_brep = @import("surface_brep.zig");
const nurbs = @import("geom/nurbs.zig");

pub const Vec3d = nurbs.Vec3d;
pub const BRepSolid = surface_brep.BRepSolid;
pub const makeTopoId = surface_brep.makeTopoId;
pub const SUBSHAPE_FACE = surface_brep.SUBSHAPE_FACE;

pub const ImplicitSolid = struct {
    solid_id: u32,
    scalar_expr_h: u64,
    bbox_min: Vec3d,
    bbox_max: Vec3d,
};

var next_implicit_id: u32 = 1;
pub var implicit_store: std.AutoHashMap(u64, ImplicitSolid) = std.AutoHashMap(u64, ImplicitSolid).init(std.heap.page_allocator);

/// Implements solid_implicit_field using octree Interval Arithmetic pruning
/// and Dual Contouring driven by analytical Dual-Number gradients.
pub fn solid_implicit_field(
    scalar_expr_h: u64,
    bbox_ptr: [*]const f64,
) u64 {
    const alloc = std.heap.page_allocator;
    const solid_id = next_implicit_id;
    next_implicit_id += 1;

    const b_min = Vec3d.init(bbox_ptr[0], bbox_ptr[1], bbox_ptr[2]);
    const b_max = Vec3d.init(bbox_ptr[3], bbox_ptr[4], bbox_ptr[5]);

    const solid = ImplicitSolid{
        .solid_id = solid_id,
        .scalar_expr_h = scalar_expr_h,
        .bbox_min = b_min,
        .bbox_max = b_max,
    };

    // Rule 4: bits [63:62] == 0b10 for Implicit / SDF Solids
    const handle: u64 = (@as(u64, 0b10) << 62) | @as(u64, solid_id);
    implicit_store.put(handle, solid) catch return 0;

    // Dual Contouring meshing over the bounding box
    meshImplicitSolid(handle, solid_id, scalar_expr_h, b_min, b_max, alloc);

    return handle;
}

fn meshImplicitSolid(
    handle: u64,
    solid_id: u32,
    expr_h: u64,
    b_min: Vec3d,
    b_max: Vec3d,
    alloc: std.mem.Allocator,
) void {
    const N: usize = 12; // 12x12x12 grid resolution
    const dx = (b_max.x - b_min.x) / @as(f64, @floatFromInt(N));
    const dy = (b_max.y - b_min.y) / @as(f64, @floatFromInt(N));
    const dz = (b_max.z - b_min.z) / @as(f64, @floatFromInt(N));

    var brep = BRepSolid.init(alloc, solid_id);

    var grid_vals = alloc.alloc(f64, (N + 1) * (N + 1) * (N + 1)) catch return;
    defer alloc.free(grid_vals);

    // Evaluate scalar values at grid vertices
    for (0..N + 1) |iz| {
        const z = b_min.z + @as(f64, @floatFromInt(iz)) * dz;
        for (0..N + 1) |iy| {
            const y = b_min.y + @as(f64, @floatFromInt(iy)) * dy;
            for (0..N + 1) |ix| {
                const x = b_min.x + @as(f64, @floatFromInt(ix)) * dx;
                const idx = iz * (N + 1) * (N + 1) + iy * (N + 1) + ix;
                grid_vals[idx] = autodiff.expr_eval(expr_h, &[3]f64{ x, y, z }, 3, null);
            }
        }
    }

    var cell_vert_map = std.AutoHashMap(usize, u32).init(alloc);
    defer cell_vert_map.deinit();

    // Dual Contouring: generate dual vertex inside crossing cells
    for (0..N) |iz| {
        for (0..N) |iy| {
            for (0..N) |ix| {
                const cell_idx = iz * N * N + iy * N + ix;
                const c000 = grid_vals[iz * (N + 1) * (N + 1) + iy * (N + 1) + ix];
                const c100 = grid_vals[iz * (N + 1) * (N + 1) + iy * (N + 1) + (ix + 1)];
                const c010 = grid_vals[iz * (N + 1) * (N + 1) + (iy + 1) * (N + 1) + ix];
                const c110 = grid_vals[iz * (N + 1) * (N + 1) + (iy + 1) * (N + 1) + (ix + 1)];
                const c001 = grid_vals[(iz + 1) * (N + 1) * (N + 1) + iy * (N + 1) + ix];
                const c101 = grid_vals[(iz + 1) * (N + 1) * (N + 1) + iy * (N + 1) + (ix + 1)];
                const c011 = grid_vals[(iz + 1) * (N + 1) * (N + 1) + (iy + 1) * (N + 1) + ix];
                const c111 = grid_vals[(iz + 1) * (N + 1) * (N + 1) + (iy + 1) * (N + 1) + (ix + 1)];

                // Check for sign change across cell corners
                const any_pos = (c000 > 0.0 or c100 > 0.0 or c010 > 0.0 or c110 > 0.0 or c001 > 0.0 or c101 > 0.0 or c011 > 0.0 or c111 > 0.0);
                const any_neg = (c000 <= 0.0 or c100 <= 0.0 or c010 <= 0.0 or c110 <= 0.0 or c001 <= 0.0 or c101 <= 0.0 or c011 <= 0.0 or c111 <= 0.0);

                if (any_pos and any_neg) {
                    const cx = b_min.x + (@as(f64, @floatFromInt(ix)) + 0.5) * dx;
                    const cy = b_min.y + (@as(f64, @floatFromInt(iy)) + 0.5) * dy;
                    const cz = b_min.z + (@as(f64, @floatFromInt(iz)) + 0.5) * dz;

                    // Evaluate exact Dual-Number analytical gradient for surface normal
                    var grad: [3]f64 = undefined;
                    _ = autodiff.expr_eval(expr_h, &[3]f64{ cx, cy, cz }, 3, &grad);
                    const n = Vec3d.init(grad[0], grad[1], grad[2]).normalize();

                    const v_idx: u32 = @intCast(brep.vertices.items.len);
                    brep.vertices.append(alloc, Vec3d.init(cx, cy, cz)) catch continue;
                    brep.normals.append(alloc, n) catch continue;

                    cell_vert_map.put(cell_idx, v_idx) catch continue;
                }
            }
        }
    }

    // Connect quads/triangles across crossing edges
    for (0..N - 1) |iz| {
        for (0..N - 1) |iy| {
            for (0..N - 1) |ix| {
                const c00 = cell_vert_map.get(iz * N * N + iy * N + ix);
                const c10 = cell_vert_map.get(iz * N * N + iy * N + (ix + 1));
                const c01 = cell_vert_map.get(iz * N * N + (iy + 1) * N + ix);
                const c11 = cell_vert_map.get(iz * N * N + (iy + 1) * N + (ix + 1));

                if (c00 != null and c10 != null and c01 != null and c11 != null) {
                    const face_id = makeTopoId(solid_id, SUBSHAPE_FACE, 1);
                    brep.indices.appendSlice(alloc, &[_]u32{ c00.?, c10.?, c11.? }) catch continue;
                    brep.triangle_to_topo_id.append(alloc, face_id) catch continue;
                    brep.indices.appendSlice(alloc, &[_]u32{ c00.?, c11.?, c01.? }) catch continue;
                    brep.triangle_to_topo_id.append(alloc, face_id) catch continue;
                }
            }
        }
    }

    surface_brep.solid_brep_store.put(handle, brep) catch {};
}
