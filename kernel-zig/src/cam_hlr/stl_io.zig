const std = @import("std");

/// Compute unit outward normal vector for a triangular facet using right-hand rule.
pub fn computeFacetNormal(v1: [3]f32, v2: [3]f32, v3: [3]f32) [3]f32 {
    const ax = v2[0] - v1[0];
    const ay = v2[1] - v1[1];
    const az = v2[2] - v1[2];

    const bx = v3[0] - v1[0];
    const by = v3[1] - v1[1];
    const bz = v3[2] - v1[2];

    var nx = ay * bz - az * by;
    var ny = az * bx - ax * bz;
    var nz = ax * by - ay * bx;

    const len_sq = nx * nx + ny * ny + nz * nz;
    if (len_sq > 1e-12) {
        const inv_len = 1.0 / @sqrt(len_sq);
        nx *= inv_len;
        ny *= inv_len;
        nz *= inv_len;
    } else {
        nx = 0.0;
        ny = 0.0;
        nz = 0.0;
    }
    return .{ nx, ny, nz };
}

/// Export triangle mesh data into standard binary STL format.
/// Specification:
///   80-byte header
///   4-byte little-endian triangle count (N)
///   N * 50-byte facet records:
///     12 bytes: normal (nx, ny, nz as 32-bit floats)
///     12 bytes: vertex 1 (x, y, z)
///     12 bytes: vertex 2 (x, y, z)
///     12 bytes: vertex 3 (x, y, z)
///     2 bytes: attribute byte count (u16 = 0)
pub fn exportStlBinary(
    allocator: std.mem.Allocator,
    positions: []const f32,
    indices: []const u32,
    header_title: []const u8,
) ![]u8 {
    const tri_count: u32 = @intCast(indices.len / 3);
    const total_bytes: usize = 80 + 4 + (@as(usize, tri_count) * 50);

    const buffer = try allocator.alloc(u8, total_bytes);
    errdefer allocator.free(buffer);

    // 80-byte header
    @memset(buffer[0..80], 0);
    const title = if (header_title.len > 0) header_title else "OpenCAD Binary STL Export - Watertight Manifold";
    const title_len = @min(title.len, 80);
    @memcpy(buffer[0..title_len], title[0..title_len]);

    // 4-byte triangle count
    std.mem.writeInt(u32, buffer[80..][0..4], tri_count, .little);

    var offset: usize = 84;
    var t: usize = 0;
    while (t < tri_count) : (t += 1) {
        const idx0 = indices[t * 3];
        const idx1 = indices[t * 3 + 1];
        const idx2 = indices[t * 3 + 2];

        const v1 = [3]f32{ positions[idx0 * 3], positions[idx0 * 3 + 1], positions[idx0 * 3 + 2] };
        const v2 = [3]f32{ positions[idx1 * 3], positions[idx1 * 3 + 1], positions[idx1 * 3 + 2] };
        const v3 = [3]f32{ positions[idx2 * 3], positions[idx2 * 3 + 1], positions[idx2 * 3 + 2] };

        const normal = computeFacetNormal(v1, v2, v3);

        // Normal
        std.mem.writeInt(u32, buffer[offset..][0..4], @as(u32, @bitCast(normal[0])), .little);
        offset += 4;
        std.mem.writeInt(u32, buffer[offset..][0..4], @as(u32, @bitCast(normal[1])), .little);
        offset += 4;
        std.mem.writeInt(u32, buffer[offset..][0..4], @as(u32, @bitCast(normal[2])), .little);
        offset += 4;

        // Vertex 1
        std.mem.writeInt(u32, buffer[offset..][0..4], @as(u32, @bitCast(v1[0])), .little);
        offset += 4;
        std.mem.writeInt(u32, buffer[offset..][0..4], @as(u32, @bitCast(v1[1])), .little);
        offset += 4;
        std.mem.writeInt(u32, buffer[offset..][0..4], @as(u32, @bitCast(v1[2])), .little);
        offset += 4;

        // Vertex 2
        std.mem.writeInt(u32, buffer[offset..][0..4], @as(u32, @bitCast(v2[0])), .little);
        offset += 4;
        std.mem.writeInt(u32, buffer[offset..][0..4], @as(u32, @bitCast(v2[1])), .little);
        offset += 4;
        std.mem.writeInt(u32, buffer[offset..][0..4], @as(u32, @bitCast(v2[2])), .little);
        offset += 4;

        // Vertex 3
        std.mem.writeInt(u32, buffer[offset..][0..4], @as(u32, @bitCast(v3[0])), .little);
        offset += 4;
        std.mem.writeInt(u32, buffer[offset..][0..4], @as(u32, @bitCast(v3[1])), .little);
        offset += 4;
        std.mem.writeInt(u32, buffer[offset..][0..4], @as(u32, @bitCast(v3[2])), .little);
        offset += 4;

        // Attribute byte count (u16 = 0)
        std.mem.writeInt(u16, buffer[offset..][0..2], 0, .little);
        offset += 2;
    }

    return buffer;
}

fn writeFmt(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(alloc, fmt, args);
    defer alloc.free(s);
    try buf.appendSlice(alloc, s);
}

/// Export triangle mesh data into standard ASCII STL format.
pub fn exportStlAscii(
    allocator: std.mem.Allocator,
    positions: []const f32,
    indices: []const u32,
    solid_name: []const u8,
) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);

    const name = if (solid_name.len > 0) solid_name else "opencad_model";
    try writeFmt(&list, allocator, "solid {s}\n", .{name});

    const tri_count: u32 = @intCast(indices.len / 3);
    var t: usize = 0;
    while (t < tri_count) : (t += 1) {
        const idx0 = indices[t * 3];
        const idx1 = indices[t * 3 + 1];
        const idx2 = indices[t * 3 + 2];

        const v1 = [3]f32{ positions[idx0 * 3], positions[idx0 * 3 + 1], positions[idx0 * 3 + 2] };
        const v2 = [3]f32{ positions[idx1 * 3], positions[idx1 * 3 + 1], positions[idx1 * 3 + 2] };
        const v3 = [3]f32{ positions[idx2 * 3], positions[idx2 * 3 + 1], positions[idx2 * 3 + 2] };

        const normal = computeFacetNormal(v1, v2, v3);

        try writeFmt(&list, allocator, "  facet normal {d:.6} {d:.6} {d:.6}\n", .{ normal[0], normal[1], normal[2] });
        try writeFmt(&list, allocator, "    outer loop\n", .{});
        try writeFmt(&list, allocator, "      vertex {d:.6} {d:.6} {d:.6}\n", .{ v1[0], v1[1], v1[2] });
        try writeFmt(&list, allocator, "      vertex {d:.6} {d:.6} {d:.6}\n", .{ v2[0], v2[1], v2[2] });
        try writeFmt(&list, allocator, "      vertex {d:.6} {d:.6} {d:.6}\n", .{ v3[0], v3[1], v3[2] });
        try writeFmt(&list, allocator, "    endloop\n", .{});
        try writeFmt(&list, allocator, "  endfacet\n", .{});
    }

    try writeFmt(&list, allocator, "endsolid {s}\n", .{name});
    return list.toOwnedSlice(allocator);
}

// ===========================================================================
// Tests
// ===========================================================================

test "stl_io: binary and ascii export validation" {
    const alloc = std.testing.allocator;

    // A simple quad split into 2 triangles
    const positions = [_]f32{
        0.0, 0.0, 0.0,
        10.0, 0.0, 0.0,
        10.0, 10.0, 0.0,
        0.0, 10.0, 0.0,
    };
    const indices = [_]u32{
        0, 1, 2,
        0, 2, 3,
    };

    // Test binary STL
    const binary_stl = try exportStlBinary(alloc, &positions, &indices, "TestSolid");
    defer alloc.free(binary_stl);

    try std.testing.expectEqual(@as(usize, 80 + 4 + 2 * 50), binary_stl.len);
    const tri_count = std.mem.readInt(u32, binary_stl[80..][0..4], .little);
    try std.testing.expectEqual(@as(u32, 2), tri_count);

    // Normal should point along +Z (0, 0, 1)
    const nz_raw = std.mem.readInt(u32, binary_stl[92..][0..4], .little);
    const nz: f32 = @bitCast(nz_raw);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), nz, 1e-4);

    // Test ASCII STL
    const ascii_stl = try exportStlAscii(alloc, &positions, &indices, "TestSolid");
    defer alloc.free(ascii_stl);

    try std.testing.expect(std.mem.startsWith(u8, ascii_stl, "solid TestSolid\n"));
    try std.testing.expect(std.mem.indexOf(u8, ascii_stl, "facet normal 0 0 1") != null or
        std.mem.indexOf(u8, ascii_stl, "facet normal 0.000000 0.000000 1.000000") != null);
    try std.testing.expect(std.mem.endsWith(u8, ascii_stl, "endsolid TestSolid\n"));
}
