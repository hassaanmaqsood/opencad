const std = @import("std");

pub const Attribute = struct {
    key: []const u8,
    val: []const u8,
};

pub const XmlNode = struct {
    tag: []const u8,
    attrs: std.ArrayList(Attribute) = .empty,
    children: std.ArrayList(*XmlNode) = .empty,
    text: []const u8 = "",
    line: u32 = 1,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, tag: []const u8, line: u32) !*XmlNode {
        const node = try allocator.create(XmlNode);
        node.* = .{
            .tag = tag,
            .allocator = allocator,
            .line = line,
        };
        return node;
    }

    pub fn deinit(self: *XmlNode) void {
        for (self.children.items) |child| {
            child.deinit();
        }
        self.children.deinit(self.allocator);
        self.attrs.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn getAttr(self: *const XmlNode, key: []const u8) ?[]const u8 {
        for (self.attrs.items) |attr| {
            if (std.mem.eql(u8, attr.key, key)) {
                return attr.val;
            }
        }
        return null;
    }

    pub fn findChild(self: *const XmlNode, tag: []const u8) ?*XmlNode {
        for (self.children.items) |child| {
            if (std.mem.eql(u8, child.tag, tag)) {
                return child;
            }
        }
        return null;
    }
};

pub const XmlParser = struct {
    src: []const u8,
    cursor: usize = 0,
    line: u32 = 1,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, src: []const u8) XmlParser {
        return .{
            .src = src,
            .allocator = allocator,
        };
    }

    fn skipWhitespace(self: *XmlParser) void {
        while (self.cursor < self.src.len) {
            const ch = self.src[self.cursor];
            if (ch == '\n') self.line += 1;
            if (std.ascii.isWhitespace(ch)) {
                self.cursor += 1;
            } else if (self.cursor + 4 <= self.src.len and std.mem.eql(u8, self.src[self.cursor .. self.cursor + 4], "<!--")) {
                // Skip comment
                self.cursor += 4;
                while (self.cursor + 3 <= self.src.len) {
                    if (self.src[self.cursor] == '\n') self.line += 1;
                    if (std.mem.eql(u8, self.src[self.cursor .. self.cursor + 3], "-->")) {
                        self.cursor += 3;
                        break;
                    }
                    self.cursor += 1;
                }
            } else if (self.cursor + 2 <= self.src.len and std.mem.eql(u8, self.src[self.cursor .. self.cursor + 2], "<?")) {
                // Skip XML processing instruction (e.g. <?xml ... ?>)
                self.cursor += 2;
                while (self.cursor + 2 <= self.src.len) {
                    if (self.src[self.cursor] == '\n') self.line += 1;
                    if (std.mem.eql(u8, self.src[self.cursor .. self.cursor + 2], "?>")) {
                        self.cursor += 2;
                        break;
                    }
                    self.cursor += 1;
                }
            } else {
                break;
            }
        }
    }

    pub fn parse(self: *XmlParser) !*XmlNode {
        self.skipWhitespace();
        if (self.cursor >= self.src.len) return error.UnexpectedEof;
        if (self.src[self.cursor] != '<') return error.InvalidXmlSyntax;

        return try self.parseElement();
    }

    fn parseElement(self: *XmlParser) !*XmlNode {
        if (self.cursor >= self.src.len or self.src[self.cursor] != '<') return error.InvalidXmlSyntax;
        self.cursor += 1; // skip '<'

        // Parse tag name
        const tag_start = self.cursor;
        while (self.cursor < self.src.len and (std.ascii.isAlphanumeric(self.src[self.cursor]) or self.src[self.cursor] == '_' or self.src[self.cursor] == '-' or self.src[self.cursor] == ':')) {
            self.cursor += 1;
        }
        if (tag_start == self.cursor) return error.InvalidXmlSyntax;
        const tag = self.src[tag_start..self.cursor];

        const node = try XmlNode.init(self.allocator, tag, self.line);
        errdefer node.deinit();

        // Parse attributes
        while (self.cursor < self.src.len) {
            self.skipWhitespace();
            if (self.cursor >= self.src.len) return error.UnexpectedEof;

            const ch = self.src[self.cursor];
            if (ch == '/' or ch == '>') break;

            const key_start = self.cursor;
            while (self.cursor < self.src.len and (std.ascii.isAlphanumeric(self.src[self.cursor]) or self.src[self.cursor] == '_' or self.src[self.cursor] == '-' or self.src[self.cursor] == ':')) {
                self.cursor += 1;
            }
            if (key_start == self.cursor) return error.InvalidXmlSyntax;
            const key = self.src[key_start..self.cursor];

            self.skipWhitespace();
            if (self.cursor >= self.src.len or self.src[self.cursor] != '=') return error.InvalidXmlSyntax;
            self.cursor += 1; // skip '='

            self.skipWhitespace();
            if (self.cursor >= self.src.len) return error.UnexpectedEof;
            const quote = self.src[self.cursor];
            if (quote != '"' and quote != '\'') return error.InvalidXmlSyntax;
            self.cursor += 1; // skip quote

            const val_start = self.cursor;
            while (self.cursor < self.src.len and self.src[self.cursor] != quote) {
                if (self.src[self.cursor] == '\n') self.line += 1;
                self.cursor += 1;
            }
            if (self.cursor >= self.src.len) return error.UnexpectedEof;
            const val = self.src[val_start..self.cursor];
            self.cursor += 1; // skip closing quote

            try node.attrs.append(self.allocator, .{ .key = key, .val = val });
        }

        self.skipWhitespace();
        if (self.cursor >= self.src.len) return error.UnexpectedEof;

        // Self-closing tag <tag ... />
        if (self.src[self.cursor] == '/') {
            self.cursor += 1;
            if (self.cursor >= self.src.len or self.src[self.cursor] != '>') return error.InvalidXmlSyntax;
            self.cursor += 1;
            return node;
        }

        if (self.src[self.cursor] != '>') return error.InvalidXmlSyntax;
        self.cursor += 1; // skip '>'

        // Parse children and inner text
        var text_start: ?usize = null;
        var text_end: ?usize = null;

        while (self.cursor < self.src.len) {
            self.skipWhitespace();
            if (self.cursor >= self.src.len) return error.UnexpectedEof;

            if (self.src[self.cursor] == '<') {
                if (self.cursor + 1 < self.src.len and self.src[self.cursor + 1] == '/') {
                    // Closing tag </tag>
                    self.cursor += 2;
                    const close_start = self.cursor;
                    while (self.cursor < self.src.len and (std.ascii.isAlphanumeric(self.src[self.cursor]) or self.src[self.cursor] == '_' or self.src[self.cursor] == '-' or self.src[self.cursor] == ':')) {
                        self.cursor += 1;
                    }
                    const close_tag = self.src[close_start..self.cursor];
                    if (!std.mem.eql(u8, tag, close_tag)) return error.InvalidXmlSyntax;

                    self.skipWhitespace();
                    if (self.cursor >= self.src.len or self.src[self.cursor] != '>') return error.InvalidXmlSyntax;
                    self.cursor += 1;
                    break;
                } else if (self.cursor + 4 <= self.src.len and std.mem.eql(u8, self.src[self.cursor .. self.cursor + 4], "<!--")) {
                    self.skipWhitespace();
                    continue;
                } else {
                    // Child element
                    const child = try self.parseElement();
                    try node.children.append(self.allocator, child);
                }
            } else {
                // Accumulate text content
                if (text_start == null) text_start = self.cursor;
                while (self.cursor < self.src.len and self.src[self.cursor] != '<') {
                    if (self.src[self.cursor] == '\n') self.line += 1;
                    self.cursor += 1;
                }
                text_end = self.cursor;
            }
        }

        if (text_start) |ts| {
            if (text_end) |te| {
                const raw = self.src[ts..te];
                node.text = std.mem.trim(u8, raw, " \t\r\n");
            }
        }

        return node;
    }
};

test "XmlParser basic" {
    const xml =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<cdml version="1.0" units="mm">
        \\  <!-- Test comment -->
        \\  <defs>
        \\    <var id="R" value="25.0"/>
        \\    <expr id="r" expr="R - 4.0"/>
        \\  </defs>
        \\  <body/>
        \\</cdml>
    ;
    var parser = XmlParser.init(std.testing.allocator, xml);
    const root = try parser.parse();
    defer root.deinit();

    try std.testing.expectEqualStrings("cdml", root.tag);
    try std.testing.expectEqualStrings("1.0", root.getAttr("version").?);
    try std.testing.expectEqualStrings("mm", root.getAttr("units").?);
    try std.testing.expectEqual(@as(usize, 2), root.children.items.len);

    const defs = root.findChild("defs").?;
    try std.testing.expectEqual(@as(usize, 2), defs.children.items.len);
    try std.testing.expectEqualStrings("R", defs.children.items[0].getAttr("id").?);
    try std.testing.expectEqualStrings("25.0", defs.children.items[0].getAttr("value").?);
}
