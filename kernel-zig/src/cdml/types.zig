const std = @import("std");

// ============================================================================
// CDML v1.0 Status Codes & Diagnostic Payloads (§13.1)
// ============================================================================

pub const CDML_OK: u32 = 0x0000;

// Parser & Schema (0x01xx)
pub const ERR_XML_SYNTAX: u32 = 0x0101;
pub const ERR_SCHEMA_VERSION: u32 = 0x0102;
pub const ERR_DAG_CYCLE: u32 = 0x0103;
pub const ERR_UNDEFINED_REF: u32 = 0x0104;
pub const ERR_IMPORT_CONFLICT: u32 = 0x0105;
pub const ERR_IMPORT_NOT_FOUND: u32 = 0x0106;
pub const ERR_ID_HASH_COLLISION: u32 = 0x0107;

// Autodiff & Expression (0x02xx)
pub const ERR_EXPR_DIV_ZERO: u32 = 0x0201;
pub const ERR_EXPR_NAN_INF: u32 = 0x0202;
pub const ERR_ASSERT_VIOLATED: u32 = 0x0203;
pub const ERR_EXPR_CONTEXT: u32 = 0x0204;

// Solver & Sketch (0x03xx)
pub const ERR_SKETCH_CONFLICT: u32 = 0x0301;
pub const ERR_SKETCH_DIVERGED: u32 = 0x0302;
pub const ERR_WIRE_OPEN_OR_SELF_INT: u32 = 0x0303;
pub const ERR_PROFILE_INVALID: u32 = 0x0304;

// B-Rep & Topology (0x04xx)
pub const ERR_SWEEP_SELF_INTERSECT: u32 = 0x0401;
pub const ERR_FILLET_RADIUS_COLLAPSE: u32 = 0x0402;
pub const ERR_SSI_CONVERGENCE: u32 = 0x0403;
pub const ERR_EULER_POINCARE: u32 = 0x0404;
pub const ERR_NON_MANIFOLD_EDGE: u32 = 0x0405;
pub const ERR_REGION_UNBOUNDED: u32 = 0x0406;
pub const ERR_TOPOID_OVERFLOW: u32 = 0x0407;

// Implicit & Field / Probes (0x05xx)
pub const ERR_IMPLICIT_EMPTY_DOMAIN: u32 = 0x0501;
pub const ERR_IMPLICIT_GRAD_ZERO: u32 = 0x0502;
pub const ERR_PROBE_INVALID_TARGET: u32 = 0x0503;
pub const ERR_PROBE_NO_MATCH: u32 = 0x0504;

pub fn getErrorName(code: u32) []const u8 {
    return switch (code) {
        CDML_OK => "CDML_OK",
        ERR_XML_SYNTAX => "ERR_XML_SYNTAX",
        ERR_SCHEMA_VERSION => "ERR_SCHEMA_VERSION",
        ERR_DAG_CYCLE => "ERR_DAG_CYCLE",
        ERR_UNDEFINED_REF => "ERR_UNDEFINED_REF",
        ERR_IMPORT_CONFLICT => "ERR_IMPORT_CONFLICT",
        ERR_IMPORT_NOT_FOUND => "ERR_IMPORT_NOT_FOUND",
        ERR_ID_HASH_COLLISION => "ERR_ID_HASH_COLLISION",
        ERR_EXPR_DIV_ZERO => "ERR_EXPR_DIV_ZERO",
        ERR_EXPR_NAN_INF => "ERR_EXPR_NAN_INF",
        ERR_ASSERT_VIOLATED => "ERR_ASSERT_VIOLATED",
        ERR_EXPR_CONTEXT => "ERR_EXPR_CONTEXT",
        ERR_SKETCH_CONFLICT => "ERR_SKETCH_CONFLICT",
        ERR_SKETCH_DIVERGED => "ERR_SKETCH_DIVERGED",
        ERR_WIRE_OPEN_OR_SELF_INT => "ERR_WIRE_OPEN_OR_SELF_INT",
        ERR_PROFILE_INVALID => "ERR_PROFILE_INVALID",
        ERR_SWEEP_SELF_INTERSECT => "ERR_SWEEP_SELF_INTERSECT",
        ERR_FILLET_RADIUS_COLLAPSE => "ERR_FILLET_RADIUS_COLLAPSE",
        ERR_SSI_CONVERGENCE => "ERR_SSI_CONVERGENCE",
        ERR_EULER_POINCARE => "ERR_EULER_POINCARE",
        ERR_NON_MANIFOLD_EDGE => "ERR_NON_MANIFOLD_EDGE",
        ERR_REGION_UNBOUNDED => "ERR_REGION_UNBOUNDED",
        ERR_TOPOID_OVERFLOW => "ERR_TOPOID_OVERFLOW",
        ERR_IMPLICIT_EMPTY_DOMAIN => "ERR_IMPLICIT_EMPTY_DOMAIN",
        ERR_IMPLICIT_GRAD_ZERO => "ERR_IMPLICIT_GRAD_ZERO",
        ERR_PROBE_INVALID_TARGET => "ERR_PROBE_INVALID_TARGET",
        ERR_PROBE_NO_MATCH => "ERR_PROBE_NO_MATCH",
        else => "ERR_UNKNOWN",
    };
}

pub const Diagnostic = struct {
    code: u32,
    id: []const u8 = "",
    message: []const u8 = "",
    line: u32 = 0,

    pub fn writeJson(self: Diagnostic, out_buf: *std.ArrayList(u8), alloc: std.mem.Allocator) !void {
        out_buf.clearRetainingCapacity();
        var buf: [32]u8 = undefined;
        const code_hex = std.fmt.bufPrint(&buf, "0x{X:0>4}", .{self.code}) catch "0x0000";
        try out_buf.print(alloc,
            \\{{"code":"{s}","name":"{s}","id":"{s}","message":"{s}","line":{d}}}
        , .{
            code_hex,
            getErrorName(self.code),
            self.id,
            self.message,
            self.line,
        });
    }
};
