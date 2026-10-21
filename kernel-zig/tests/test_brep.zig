const std = @import("std");
const testing = std.testing;
const cad = @import("cad_kernel");
const box = cad.BoxMod;
const cylinder = cad.CylinderMod;

test "B-Rep Box: Euler characteristic and leak check" {
    // testing.allocator enforces zero memory leaks on test completion
    var b = try box.createBox(testing.allocator, 1, 10.0, 20.0, 30.0);
    defer b.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 8), b.vertices.items.len);
    try testing.expectEqual(@as(usize, 12), b.edges.items.len);
    try testing.expectEqual(@as(usize, 6), b.shell.faces.items.len);

    const stats = b.getStats();
    // V - E + F = 8 - 12 + 6 = 2
    try testing.expectEqual(@as(i32, 2), stats.euler_characteristic);
    try testing.expectApproxEqAbs(@as(f32, 6000.0), stats.volume, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 2200.0), stats.surface_area, 1e-4);
}

test "B-Rep Cylinder: Topology and leak check" {
    var cyl = try cylinder.createCylinder(testing.allocator, 2, 5.0, 15.0);
    defer cyl.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), cyl.vertices.items.len);
    try testing.expectEqual(@as(usize, 3), cyl.edges.items.len);
    try testing.expectEqual(@as(usize, 3), cyl.shell.faces.items.len);

    const stats = cyl.getStats();
    try testing.expectEqual(@as(i32, 2), stats.euler_characteristic);
}

