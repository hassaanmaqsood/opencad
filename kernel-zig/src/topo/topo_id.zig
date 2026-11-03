const std = @import("std");

// ============================================================================
// CDML v1.0 192-Bit TopoId & SHA-256 H64 Topo Hashing (§10.1)
// ============================================================================

pub const SubshapeType = enum(u4) {
    None = 0,
    Vertex = 1,
    Edge = 2,
    Wire = 3,
    Face = 4,
    Shell = 5,
    Solid = 6,
};

pub const TopoFlags = struct {
    pub const PRESERVE: u8 = 1 << 0;
    pub const BOUNDARY: u8 = 1 << 1;
    pub const ANALYTIC: u8 = 1 << 2;
    pub const IMPLICIT_INTERFACE: u8 = 1 << 3;
};

pub const TopoId = extern struct {
    words: [3]u64 = [_]u64{ 0, 0, 0 },

    pub const INVALID: TopoId = .{ .words = [_]u64{ 0, 0, 0 } };

    pub fn init(feature_hash: u64, branch_hash: u64, subshape_type: u8, flags: u8, split_gen: u32) TopoId {
        const w2: u64 = @as(u64, subshape_type & 0xF) |
            (@as(u64, flags & 0xFF) << 4) |
            (@as(u64, split_gen) << 12);
        return .{
            .words = [_]u64{ feature_hash, branch_hash, w2 },
        };
    }

    pub fn fromHashes(feature_hash: u64, branch_hash: u64, subshape: SubshapeType) TopoId {
        return init(feature_hash, branch_hash, @intFromEnum(subshape), 0, 0);
    }

    pub fn getFeatureHash(self: TopoId) u64 {
        return self.words[0];
    }

    pub fn getBranchHash(self: TopoId) u64 {
        return self.words[1];
    }

    pub fn getSubshapeType(self: TopoId) SubshapeType {
        const raw: u4 = @intCast(self.words[2] & 0xF);
        return @enumFromInt(raw);
    }

    pub fn getTopoFlags(self: TopoId) u8 {
        return @intCast((self.words[2] >> 4) & 0xFF);
    }

    pub fn getSplitGeneration(self: TopoId) u32 {
        return @intCast((self.words[2] >> 12) & 0xFFFFFFFF);
    }

    pub fn matchesId(self: TopoId, target_hash: u64) bool {
        return self.words[0] == target_hash or self.words[1] == target_hash;
    }

    pub fn eql(self: TopoId, other: TopoId) bool {
        return self.words[0] == other.words[0] and
            self.words[1] == other.words[1] and
            self.words[2] == other.words[2];
    }
};

/// Computes H64: first 8 bytes of SHA-256 digest of UTF-8 string read as big-endian u64 (CDML §10.1.1)
pub fn h64(id_str: []const u8) u64 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(id_str, &digest, .{});
    return std.mem.readInt(u64, digest[0..8], .big);
}

test "h64 and TopoId encoding" {
    const h1 = h64("solid_flange");
    const h2 = h64("c_bore");
    try std.testing.expect(h1 != 0);
    try std.testing.expect(h2 != 0);
    try std.testing.expect(h1 != h2);

    const tid = TopoId.init(h1, h2, @intFromEnum(SubshapeType.Face), TopoFlags.ANALYTIC, 1);
    try std.testing.expectEqual(h1, tid.getFeatureHash());
    try std.testing.expectEqual(h2, tid.getBranchHash());
    try std.testing.expectEqual(SubshapeType.Face, tid.getSubshapeType());
    try std.testing.expectEqual(TopoFlags.ANALYTIC, tid.getTopoFlags());
    try std.testing.expectEqual(@as(u32, 1), tid.getSplitGeneration());
    try std.testing.expect(tid.matchesId(h1));
    try std.testing.expect(tid.matchesId(h2));
}
