pub const types = @import("types.zig");
pub const xml = @import("xml.zig");
pub const evaluator = @import("evaluator.zig");

pub const cdml_register_import = evaluator.cdml_register_import;
pub const cdml_eval_document = evaluator.cdml_eval_document;
pub const cdml_set_var = evaluator.cdml_set_var;
pub const cdml_get_probe_value = evaluator.cdml_get_probe_value;
