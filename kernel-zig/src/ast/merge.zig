const std = @import("std");
const types = @import("types.zig");

pub const MergeConflict = struct {
    node_name: []const u8,
    base_val: f64,
    ours_val: f64,
    theirs_val: f64,
    description: []const u8,
};

pub const SemanticMergeResult = struct {
    merged_tree: types.AstTree,
    conflicts: std.ArrayListUnmanaged(MergeConflict) = .empty,
    has_conflicts: bool = false,

    pub fn deinit(self: *SemanticMergeResult, alloc: std.mem.Allocator) void {
        self.merged_tree.deinit();
        self.conflicts.deinit(alloc);
    }
};

pub const AstSemanticMerger = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) AstSemanticMerger {
        return .{ .allocator = allocator };
    }

    /// Performs a 3-way semantic merge across base, ours, and theirs AST trees.
    pub fn merge(
        self: *AstSemanticMerger,
        base: *const types.AstTree,
        ours: *const types.AstTree,
        theirs: *const types.AstTree,
    ) !SemanticMergeResult {
        var merged = types.AstTree.init(self.allocator);
        errdefer merged.deinit();

        var conflicts: std.ArrayListUnmanaged(MergeConflict) = .empty;
        errdefer conflicts.deinit(self.allocator);

        const root_node = try merged.addNode(.Program);
        const root_id = root_node.id;
        merged.root_id = root_id;

        // Iterate through ours nodes and match against base and theirs
        for (ours.nodes.items) |our_node| {
            if (our_node.node_type == .Program) continue;

            // Find matching node by name in base and theirs
            var base_node: ?*const types.AstNode = null;
            for (base.nodes.items) |*bn| {
                if (std.mem.eql(u8, bn.name, our_node.name) and bn.node_type == our_node.node_type) {
                    base_node = bn;
                    break;
                }
            }

            var their_node: ?*const types.AstNode = null;
            for (theirs.nodes.items) |*tn| {
                if (std.mem.eql(u8, tn.name, our_node.name) and tn.node_type == our_node.node_type) {
                    their_node = tn;
                    break;
                }
            }

            const new_node = try merged.addNode(our_node.node_type);
            const new_id = new_node.id;
            new_node.name = our_node.name;
            new_node.string_value = our_node.string_value;
            new_node.number_value = our_node.number_value;

            if (base_node) |bn| {
                if (their_node) |tn| {
                    const ours_changed = our_node.number_value != bn.number_value;
                    const theirs_changed = tn.number_value != bn.number_value;

                    if (ours_changed and theirs_changed) {
                        if (our_node.number_value != tn.number_value) {
                            // Semantic conflict
                            try conflicts.append(self.allocator, .{
                                .node_name = our_node.name,
                                .base_val = bn.number_value,
                                .ours_val = our_node.number_value,
                                .theirs_val = tn.number_value,
                                .description = "Conflicting numeric parameter modifications on both branches",
                            });
                        }
                    } else if (theirs_changed) {
                        // Accept theirs modification cleanly
                        new_node.number_value = tn.number_value;
                    }
                }
            }
            if (merged.getNode(root_id)) |r| {
                try r.child_ids.append(self.allocator, new_id);
            }
        }

        return SemanticMergeResult{
            .merged_tree = merged,
            .conflicts = conflicts,
            .has_conflicts = conflicts.items.len > 0,
        };
    }
};

test "AstSemanticMerger 3-way non-conflicting merge" {
    var merger = AstSemanticMerger.init(std.testing.allocator);

    var base = types.AstTree.init(std.testing.allocator);
    defer base.deinit();
    const b_node = try base.addNode(.VariableDeclaration);
    b_node.name = "radius";
    b_node.number_value = 10.0;

    var ours = types.AstTree.init(std.testing.allocator);
    defer ours.deinit();
    const o_node = try ours.addNode(.VariableDeclaration);
    o_node.name = "radius";
    o_node.number_value = 10.0; // unchanged

    var theirs = types.AstTree.init(std.testing.allocator);
    defer theirs.deinit();
    const t_node = try theirs.addNode(.VariableDeclaration);
    t_node.name = "radius";
    t_node.number_value = 12.5; // changed on theirs

    var result = try merger.merge(&base, &ours, &theirs);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.has_conflicts);
    try std.testing.expectEqual(@as(f64, 12.5), result.merged_tree.nodes.items[1].number_value);
}
