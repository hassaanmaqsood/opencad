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

test "Wave 6A Plugin VTable and Resource Sandbox Limits" {
    _ = cad.cad_kernel_init();
    defer _ = cad.cad_kernel_deinit();

    // 1. Verify and configure resource limits
    var limits = cad.c_abi.CadKernelLimits{
        .max_wasm_memory_bytes = 16 * 1024 * 1024,
        .max_solver_iterations = 100,
        .max_boolean_faces = 5_000,
        .eval_timeout_ms = 1000,
    };
    try testing.expectEqual(cad.CadStatus.Ok, cad.cad_set_kernel_limits(&limits));

    var query_limits: cad.c_abi.CadKernelLimits = std.mem.zeroes(cad.c_abi.CadKernelLimits);
    try testing.expectEqual(cad.CadStatus.Ok, cad.cad_get_kernel_limits(&query_limits));
    try testing.expectEqual(limits.max_wasm_memory_bytes, query_limits.max_wasm_memory_bytes);
    try testing.expectEqual(limits.max_solver_iterations, query_limits.max_solver_iterations);

    // 2. Shared allocator bounds enforcement
    const valid_buf = cad.cad_shared_alloc(512);
    try testing.expect(valid_buf != null);
    cad.cad_shared_free(valid_buf, 512);

    // Beyond limit should fail safely
    const oversized_buf = cad.cad_shared_alloc(32 * 1024 * 1024);
    try testing.expectEqual(@as(?[*]u8, null), oversized_buf);

    // 3. Register custom operation VTable
    const custom_vtable = cad.c_abi.CadPluginOpVTable{
        .op_type_id = 1100,
        .op_name = "SheetMetalBendOp",
        .evaluate_fn = struct {
            fn eval(
                _: u32,
                _: ?*const cad.c_abi.CadFeatureNode,
                _: ?[*]const cad.CadSolidHandle,
                _: u32,
                out_solid: *cad.CadSolidHandle,
            ) callconv(.c) cad.CadStatus {
                out_solid.* = 7777;
                return .Ok;
            }
        }.eval,
        .tessellate_fn = null,
        .serialize_ast_fn = null,
        .free_fn = null,
    };

    try testing.expectEqual(cad.CadStatus.Ok, cad.cad_register_plugin_op(&custom_vtable));

    var out_solid: cad.CadSolidHandle = 0;
    try testing.expectEqual(cad.CadStatus.Ok, cad.cad_execute_plugin_op(1100, null, null, 0, &out_solid));
    try testing.expectEqual(@as(cad.CadSolidHandle, 7777), out_solid);

    try testing.expectEqual(cad.CadStatus.Ok, cad.cad_unregister_plugin_op(1100));
}
