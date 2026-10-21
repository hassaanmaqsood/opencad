const std = @import("std");
const testing = std.testing;
const cad = @import("cad_kernel");

test "C ABI Lifecycle & Zero-Leak Verification with std.testing.allocator" {
    // 1. Initialize kernel
    const init_status = cad.cad_kernel_init();
    try testing.expectEqual(cad.CadStatus.Ok, init_status);

    // 2. Create Box solid
    var box_handle: cad.CadSolidHandle = 0;
    const box_status = cad.cad_primitive_box(5.0, 10.0, 15.0, &box_handle);
    try testing.expectEqual(cad.CadStatus.Ok, box_status);
    try testing.expect(box_handle != 0);

    // 3. Inspect Stats
    var stats: cad.CadBrepStats = undefined;
    const stats_status = cad.cad_solid_get_stats(box_handle, &stats);
    try testing.expectEqual(cad.CadStatus.Ok, stats_status);
    try testing.expectEqual(@as(u32, 8), stats.num_vertices);
    try testing.expectEqual(@as(u32, 12), stats.num_edges);
    try testing.expectEqual(@as(u32, 6), stats.num_faces);
    try testing.expectEqual(@as(i32, 2), stats.euler_characteristic);
    try testing.expectApproxEqAbs(@as(f32, 750.0), stats.volume, 1e-3);

    // 4. Tessellate Box into flat zero-copy mesh
    var mesh: cad.CadMesh = undefined;
    const tess_status = cad.cad_solid_tessellate(box_handle, 0.1, 0.2, &mesh);
    try testing.expectEqual(cad.CadStatus.Ok, tess_status);
    try testing.expectEqual(@as(u32, 24), mesh.vertex_count);
    try testing.expectEqual(@as(u32, 12), mesh.triangle_count);

    // 5. Free mesh flat memory buffers
    const free_mesh_status = cad.cad_mesh_free(&mesh);
    try testing.expectEqual(cad.CadStatus.Ok, free_mesh_status);

    // 6. Release solid handle
    const release_status = cad.cad_solid_release(box_handle);
    try testing.expectEqual(cad.CadStatus.Ok, release_status);

    // 7. Test Cylinder C ABI
    var cyl_handle: cad.CadSolidHandle = 0;
    const cyl_status = cad.cad_primitive_cylinder(3.0, 8.0, &cyl_handle);
    try testing.expectEqual(cad.CadStatus.Ok, cyl_status);
    try testing.expect(cyl_handle != 0);

    var cyl_mesh: cad.CadMesh = undefined;
    const cyl_tess_status = cad.cad_solid_tessellate(cyl_handle, 0.1, 0.2, &cyl_mesh);
    try testing.expectEqual(cad.CadStatus.Ok, cyl_tess_status);

    _ = cad.cad_mesh_free(&cyl_mesh);
    _ = cad.cad_solid_release(cyl_handle);

    // 8. Deinitialize kernel to free global registry
    const deinit_status = cad.cad_kernel_deinit();
    try testing.expectEqual(cad.CadStatus.Ok, deinit_status);
}
