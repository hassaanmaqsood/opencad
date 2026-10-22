const std = @import("std");
const types = @import("types.zig");

pub const AstParser = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) AstParser {
        return .{ .allocator = allocator };
    }

    pub fn parse(self: *AstParser, source: []const u8) !types.AstTree {
        var tree = types.AstTree.init(self.allocator);
        errdefer tree.deinit();

        const root_node = try tree.addNode(.Program);
        const root_id = root_node.id;
        tree.root_id = root_id;

        var lines = std.mem.splitScalar(u8, source, '\n');
        var line_num: u32 = 1;
        while (lines.next()) |raw_line| : (line_num += 1) {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0 or std.mem.startsWith(u8, line, "//") or std.mem.startsWith(u8, line, "#")) {
                continue;
            }

            if (std.mem.startsWith(u8, line, "const ") or std.mem.startsWith(u8, line, "let ")) {
                const node = try tree.addNode(.VariableDeclaration);
                const node_id = node.id;
                node.source_line = line_num;
                node.parent_id = root_id;

                const eq_idx = std.mem.indexOfScalar(u8, line, '=');
                if (eq_idx) |idx| {
                    const name_part = std.mem.trim(u8, line[5..idx], " \t");
                    node.name = name_part;

                    const val_str = std.mem.trim(u8, line[idx + 1 ..], " \t;");
                    if (std.fmt.parseFloat(f64, val_str)) |fval| {
                        node.number_value = fval;
                    } else |_| {
                        node.string_value = val_str;
                    }
                }
                if (tree.getNode(root_id)) |r| {
                    try r.child_ids.append(self.allocator, node_id);
                }
            } else if (std.mem.indexOfScalar(u8, line, '(')) |paren_idx| {
                const call_name = std.mem.trim(u8, line[0..paren_idx], " \t");
                var ntype: types.AstNodeType = .CallExpression;
                if (std.mem.eql(u8, call_name, "sketch")) ntype = .CadSketchNode
                else if (std.mem.eql(u8, call_name, "extrude")) ntype = .CadExtrudeNode
                else if (std.mem.eql(u8, call_name, "revolve")) ntype = .CadRevolveNode
                else if (std.mem.eql(u8, call_name, "fillet")) ntype = .CadFilletNode
                else if (std.mem.eql(u8, call_name, "chamfer")) ntype = .CadChamferNode
                else if (std.mem.eql(u8, call_name, "sheetmetal_flange")) ntype = .CadSheetMetalFlangeNode
                else if (std.mem.eql(u8, call_name, "implicit_tpms")) ntype = .CadImplicitTpmsNode
                else if (std.mem.eql(u8, call_name, "cam_toolpath")) ntype = .CadCamToolpathNode;

                const call_node = try tree.addNode(ntype);
                const call_id = call_node.id;
                call_node.source_line = line_num;
                call_node.name = call_name;
                call_node.parent_id = root_id;
                if (tree.getNode(root_id)) |r| {
                    try r.child_ids.append(self.allocator, call_id);
                }
            }
        }

        return tree;
    }
};

test "AstParser basic parsing" {
    var parser = AstParser.init(std.testing.allocator);
    const code =
        \\const thickness = 2.5;
        \\const width = 100.0;
        \\extrude(thickness);
        \\fillet(1.0);
    ;
    var tree = try parser.parse(code);
    defer tree.deinit();

    try std.testing.expect(tree.nodes.items.len >= 5);
    try std.testing.expectEqual(types.AstNodeType.Program, tree.nodes.items[0].node_type);
}
