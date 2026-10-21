const std = @import("std");
const testing = std.testing;
const cad = @import("cad_kernel");
const box = cad.BoxMod;
const tessellator = cad.TessellatorMod;

test "Tessellator: Zero-copy flat buffers and face ID tagging" {
    var b = try box.createBox(testing.allocator, 1, 2.0, 3.0, 4.0);
    defer b.deinit(testing.allocator);

    var mesh = try tessellator.tessellateSolid(testing.allocator, &b, 0.1, 0.2);
    // freeMesh MUST reclaim all allocated flat memory slices cleanly
    defer tessellator.freeMesh(testing.allocator, &mesh);

    // Box has 6 faces * 4 vertices = 24 vertices
    try testing.expectEqual(@as(u32, 24), mesh.vertex_count);
    // Box has 6 faces * 2 triangles = 12 triangles
    try testing.expectEqual(@as(u32, 12), mesh.triangle_count);

    // Check pointers are non-null
    try testing.expect(mesh.positions != null);
    try testing.expect(mesh.normals != null);
    try testing.expect(mesh.indices != null);
    try testing.expect(mesh.triangle_to_face_id != null);
    try testing.expect(mesh.edge_vertices != null);

    // Verify triangle-to-face mapping: each face has 2 triangles tagged with face ID 1..6
    const face_ids = mesh.triangle_to_face_id.?[0..mesh.triangle_count];
    var face_counts = [_]u32{ 0, 0, 0, 0, 0, 0, 0 };
    for (face_ids) |fid| {
        try testing.expect(fid >= 1 and fid <= 6);
        face_counts[fid] += 1;
    }
    var fid: usize = 1;
    while (fid < 7) : (fid += 1) {
        try testing.expectEqual(@as(u32, 2), face_counts[fid]);
    }
}
