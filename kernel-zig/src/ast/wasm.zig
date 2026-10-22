const std = @import("std");
const types = @import("types.zig");
const parser = @import("parser.zig");
const formatter = @import("formatter.zig");
const merge = @import("merge.zig");

var wasm_allocator = std.heap.wasm_allocator;
var cached_format_buf: []const u8 = "";
var cached_merge_buf: []const u8 = "";
var last_conflict_count: u32 = 0;

pub export fn cad_ast_parse_count(source_ptr: [*]const u8, source_len: usize) u32 {
    if (source_len == 0) return 0;
    const src = source_ptr[0..source_len];
    var p = parser.AstParser.init(wasm_allocator);
    var tree = p.parse(src) catch return 0;
    defer tree.deinit();
    return @intCast(tree.nodes.items.len);
}

pub export fn cad_ast_format(source_ptr: [*]const u8, source_len: usize) ?[*]const u8 {
    if (cached_format_buf.len > 0) {
        wasm_allocator.free(cached_format_buf);
        cached_format_buf = "";
    }
    if (source_len == 0) return null;
    const src = source_ptr[0..source_len];
    var p = parser.AstParser.init(wasm_allocator);
    var tree = p.parse(src) catch return null;
    defer tree.deinit();

    var f = formatter.AstFormatter.init(wasm_allocator);
    cached_format_buf = f.format(&tree) catch return null;
    return cached_format_buf.ptr;
}

pub export fn cad_ast_get_format_len() usize {
    return cached_format_buf.len;
}

pub export fn cad_ast_merge_3way(
    base_ptr: [*]const u8,
    base_len: usize,
    ours_ptr: [*]const u8,
    ours_len: usize,
    theirs_ptr: [*]const u8,
    theirs_len: usize,
) ?[*]const u8 {
    if (cached_merge_buf.len > 0) {
        wasm_allocator.free(cached_merge_buf);
        cached_merge_buf = "";
    }
    last_conflict_count = 0;

    var p = parser.AstParser.init(wasm_allocator);
    var base_tree = p.parse(base_ptr[0..base_len]) catch return null;
    defer base_tree.deinit();
    var ours_tree = p.parse(ours_ptr[0..ours_len]) catch return null;
    defer ours_tree.deinit();
    var theirs_tree = p.parse(theirs_ptr[0..theirs_len]) catch return null;
    defer theirs_tree.deinit();

    var merger = merge.AstSemanticMerger.init(wasm_allocator);
    var result = merger.merge(&base_tree, &ours_tree, &theirs_tree) catch return null;
    defer result.deinit(wasm_allocator);

    last_conflict_count = @intCast(result.conflicts.items.len);

    var f = formatter.AstFormatter.init(wasm_allocator);
    cached_merge_buf = f.format(&result.merged_tree) catch return null;
    return cached_merge_buf.ptr;
}

pub export fn cad_ast_get_merge_len() usize {
    return cached_merge_buf.len;
}

pub export fn cad_ast_get_conflict_count() u32 {
    return last_conflict_count;
}
