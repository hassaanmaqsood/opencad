const std = @import("std");
const types = @import("types.zig");

pub const AstFormatter = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) AstFormatter {
        return .{ .allocator = allocator };
    }

    pub fn format(self: *AstFormatter, tree: *const types.AstTree) ![]const u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(self.allocator);

        for (tree.nodes.items) |node| {
            switch (node.node_type) {
                .VariableDeclaration => {
                    if (node.string_value.len > 0) {
                        const s = try std.fmt.allocPrint(self.allocator, "const {s} = \"{s}\";\n", .{ node.name, node.string_value });
                        defer self.allocator.free(s);
                        try buf.appendSlice(self.allocator, s);
                    } else {
                        const s = try std.fmt.allocPrint(self.allocator, "const {s} = {d};\n", .{ node.name, node.number_value });
                        defer self.allocator.free(s);
                        try buf.appendSlice(self.allocator, s);
                    }
                },
                .CadSketchNode, .CadExtrudeNode, .CadRevolveNode, .CadFilletNode, .CadChamferNode, .CadSheetMetalFlangeNode, .CadImplicitTpmsNode, .CadCamToolpathNode, .CallExpression => {
                    const s = try std.fmt.allocPrint(self.allocator, "{s}();\n", .{node.name});
                    defer self.allocator.free(s);
                    try buf.appendSlice(self.allocator, s);
                },
                else => {},
            }
        }

        return buf.toOwnedSlice(self.allocator);
    }
};

test "AstFormatter basic format" {
    var tree = types.AstTree.init(std.testing.allocator);
    defer tree.deinit();

    const root = try tree.addNode(.Program);
    tree.root_id = root.id;

    const var1 = try tree.addNode(.VariableDeclaration);
    var1.name = "depth";
    var1.number_value = 15.0;

    var fmt = AstFormatter.init(std.testing.allocator);
    const code = try fmt.format(&tree);
    defer std.testing.allocator.free(code);

    try std.testing.expect(std.mem.indexOf(u8, code, "const depth = 15;") != null);
}
