const std = @import("std");

pub const AstNodeType = enum(u16) {
    Program = 1,
    FunctionDeclaration = 2,
    VariableDeclaration = 3,
    AssignmentExpression = 4,
    BinaryExpression = 5,
    UnaryExpression = 6,
    CallExpression = 7,
    Identifier = 8,
    NumericLiteral = 9,
    StringLiteral = 10,
    CadSketchNode = 11,
    CadExtrudeNode = 12,
    CadRevolveNode = 13,
    CadBooleanNode = 14,
    CadFilletNode = 15,
    CadChamferNode = 16,
    CadShellNode = 17,
    CadSheetMetalFlangeNode = 18,
    CadImplicitTpmsNode = 19,
    CadFeaStudyNode = 20,
    CadCamToolpathNode = 21,
};

pub const BinaryOp = enum {
    Add,
    Subtract,
    Multiply,
    Divide,
    Modulo,
    Equal,
    NotEqual,
    Less,
    Greater,
    LessEqual,
    GreaterEqual,
};

pub const AstNode = struct {
    id: u32,
    node_type: AstNodeType,
    parent_id: u32 = 0,
    source_line: u32 = 0,
    source_col: u32 = 0,
    name: []const u8 = "",
    number_value: f64 = 0.0,
    string_value: []const u8 = "",
    binary_op: ?BinaryOp = null,
    child_ids: std.ArrayListUnmanaged(u32) = .empty,
    property_names: std.ArrayListUnmanaged([]const u8) = .empty,
    property_values: std.ArrayListUnmanaged(f64) = .empty,

    pub fn deinit(self: *AstNode, alloc: std.mem.Allocator) void {
        self.child_ids.deinit(alloc);
        self.property_names.deinit(alloc);
        self.property_values.deinit(alloc);
    }
};

pub const AstTree = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayListUnmanaged(AstNode) = .empty,
    root_id: u32 = 0,
    next_id: u32 = 1,

    pub fn init(alloc: std.mem.Allocator) AstTree {
        return .{
            .allocator = alloc,
            .nodes = .empty,
        };
    }

    pub fn deinit(self: *AstTree) void {
        for (self.nodes.items) |*node| {
            node.deinit(self.allocator);
        }
        self.nodes.deinit(self.allocator);
    }

    pub fn addNode(self: *AstTree, node_type: AstNodeType) !*AstNode {
        const id = self.next_id;
        self.next_id += 1;
        const node = AstNode{
            .id = id,
            .node_type = node_type,
        };
        try self.nodes.append(self.allocator, node);
        return &self.nodes.items[self.nodes.items.len - 1];
    }

    pub fn getNode(self: *AstTree, id: u32) ?*AstNode {
        for (self.nodes.items) |*node| {
            if (node.id == id) return node;
        }
        return null;
    }
};
