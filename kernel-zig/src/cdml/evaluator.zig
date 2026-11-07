const std = @import("std");
const memory = @import("../memory.zig");
const memory_map = @import("../memory_map.zig");
const autodiff = @import("../autodiff.zig");
const constraint_sys = @import("../constraint_sys.zig");
const curve_wire = @import("../curve_wire.zig");
const surface_brep = @import("../surface_brep.zig");
const implicit_field = @import("../implicit_field.zig");
const tess_export = @import("../tess_export.zig");
const topo_id = @import("../topo/topo_id.zig");
const types = @import("types.zig");
const xml = @import("xml.zig");

pub const XmlNode = xml.XmlNode;
pub const XmlParser = xml.XmlParser;
pub const Diagnostic = types.Diagnostic;
pub const TopoId = topo_id.TopoId;
pub const Vec3d = surface_brep.Vec3d;

// ============================================================================
// Symbol & Definition Stores
// ============================================================================

pub const VarDef = struct {
    id: []const u8,
    value: f64,
    min: ?f64 = null,
    max: ?f64 = null,
    step: ?f64 = null,
    unit: []const u8 = "",
    slot: u32 = 0,
};

pub const ExprDef = struct {
    id: []const u8,
    expr_str: []const u8,
    value: f64 = 0.0,
    slot: u32 = 0,
};

pub const AssertDef = struct {
    id: []const u8,
    expr_str: []const u8,
    error_msg: []const u8,
    line: u32 = 0,
};

pub const FieldSlotDef = struct {
    id: []const u8,
    slot: u32 = 0,
    semantic: []const u8 = "",
    grid_x: u32 = 64,
    grid_y: u32 = 64,
    grid_z: u32 = 24,
    default_val: f64 = 0.0,
};

pub const ProbeDef = struct {
    id: []const u8,
    probe_type: []const u8,
    target: []const u8,
    face_predicate: []const u8 = "",
    quantity: []const u8 = "",
    value: f64 = 0.0,
};

pub const ChartDef = struct {
    id: []const u8,
    p0: Vec3d,
    e1: Vec3d,
    e2: Vec3d,
};

pub const OwnedLoop2D = struct {
    wire_id: []const u8,
    is_hole: bool,
    samples: std.ArrayList(surface_brep.ProfileEdgeSample2D),

    pub fn deinit(self: *OwnedLoop2D, alloc: std.mem.Allocator) void {
        self.samples.deinit(alloc);
    }
};

pub const SketchDef = struct {
    id: []const u8,
    chart_id: []const u8,
    outer_loops: std.ArrayList(OwnedLoop2D),
    hole_loops: std.ArrayList(OwnedLoop2D),

    pub fn deinit(self: *SketchDef, alloc: std.mem.Allocator) void {
        for (self.outer_loops.items) |*l| l.deinit(alloc);
        self.outer_loops.deinit(alloc);
        for (self.hole_loops.items) |*l| l.deinit(alloc);
        self.hole_loops.deinit(alloc);
    }
};

pub const DocumentEvaluator = struct {
    allocator: std.mem.Allocator,
    root_node: ?*XmlNode = null,

    vars: std.StringHashMap(VarDef),
    exprs: std.StringHashMap(ExprDef),
    asserts: std.ArrayList(AssertDef),
    field_slots: std.AutoHashMap(u32, FieldSlotDef),
    charts: std.StringHashMap(ChartDef),
    sketches: std.StringHashMap(SketchDef),
    surfaces: std.StringHashMap([]const u8),
    regions: std.StringHashMap(*const XmlNode),
    probes: std.StringHashMap(ProbeDef),
    solids: std.StringHashMap(u64),

    // Variable index and constant mappings for autodiff evaluation
    var_indices: std.StringHashMap(u32),
    var_values: std.ArrayList(f64),
    const_values: std.StringHashMap(f64),

    active_solid_h: u64 = 0,
    last_tess_solid_h: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) DocumentEvaluator {
        return .{
            .allocator = allocator,
            .vars = std.StringHashMap(VarDef).init(allocator),
            .exprs = std.StringHashMap(ExprDef).init(allocator),
            .asserts = .empty,
            .field_slots = std.AutoHashMap(u32, FieldSlotDef).init(allocator),
            .charts = std.StringHashMap(ChartDef).init(allocator),
            .sketches = std.StringHashMap(SketchDef).init(allocator),
            .surfaces = std.StringHashMap([]const u8).init(allocator),
            .regions = std.StringHashMap(*const XmlNode).init(allocator),
            .probes = std.StringHashMap(ProbeDef).init(allocator),
            .solids = std.StringHashMap(u64).init(allocator),
            .var_indices = std.StringHashMap(u32).init(allocator),
            .var_values = .empty,
            .const_values = std.StringHashMap(f64).init(allocator),
        };
    }

    pub fn deinit(self: *DocumentEvaluator) void {
        if (self.root_node) |r| r.deinit();
        var it_sk = self.sketches.valueIterator();
        while (it_sk.next()) |sk| sk.deinit(self.allocator);
        self.sketches.deinit();
        self.charts.deinit();
        self.surfaces.deinit();
        self.regions.deinit();
        self.vars.deinit();
        self.exprs.deinit();
        self.asserts.deinit(self.allocator);
        self.field_slots.deinit();
        self.probes.deinit();
        var it_sol = self.solids.valueIterator();
        while (it_sol.next()) |sh| {
            const h = sh.*;
            if ((h >> 62) == 0b10) {
                implicit_field.freeImplicitSolid(h);
            } else {
                surface_brep.solid_free(h);
            }
        }
        self.solids.deinit();
        self.var_indices.deinit();
        self.var_values.deinit(self.allocator);
        self.const_values.deinit();
    }

    pub fn syncVarValues(self: *DocumentEvaluator) !void {
        self.var_values.clearRetainingCapacity();
        self.const_values.clearRetainingCapacity();

        var it = self.vars.iterator();
        while (it.next()) |entry| {
            const v = entry.value_ptr.*;
            if (v.slot >= self.var_values.items.len) {
                try self.var_values.resize(self.allocator, v.slot + 1);
            }
            self.var_values.items[v.slot] = v.value;
            try self.const_values.put(v.id, v.value);
        }

        var it_expr = self.exprs.iterator();
        while (it_expr.next()) |entry| {
            const e = entry.value_ptr.*;
            if (e.slot >= self.var_values.items.len) {
                try self.var_values.resize(self.allocator, e.slot + 1);
            }
            self.var_values.items[e.slot] = e.value;
            try self.const_values.put(e.id, e.value);
        }
    }

    pub fn evaluateExpression(self: *DocumentEvaluator, expr_str: []const u8, context: autodiff.ExprContext) !f64 {
        const clean = std.mem.trim(u8, expr_str, " \t\r\n");
        if (clean.len == 0) return 0.0;

        if (std.fmt.parseFloat(f64, clean)) |v| {
            return v;
        } else |_| {}

        var var_name = clean;
        if (std.mem.startsWith(u8, clean, "ref(") and std.mem.endsWith(u8, clean, ")")) {
            var_name = std.mem.trim(u8, clean[4 .. clean.len - 1], " \t\r\n'\"");
        }
        if (self.vars.get(var_name)) |v| return v.value;
        if (self.exprs.get(var_name)) |e| return e.value;

        try self.syncVarValues();
        var expr = autodiff.compileExpressionFull(self.allocator, clean, context, null, &self.const_values, null) catch |err| {
            if (err == error.ErrExprContext) return error.ErrExprContext;
            return error.ErrUndefinedRef;
        };
        defer expr.deinit();

        return expr.evalScalar(&[_]f64{});
    }
};

// Global state
pub var registered_imports: ?std.StringHashMap([]const u8) = null;
pub var active_evaluator: ?DocumentEvaluator = null;
pub var active_diagnostic: Diagnostic = .{ .code = types.CDML_OK };
pub var active_mesh_valid: bool = false;

pub fn setDiagnostic(code: u32, id: []const u8, message: []const u8, line: u32) void {
    active_diagnostic = .{
        .code = code,
        .id = id,
        .message = message,
        .line = line,
    };
    writeDiagnosticJson();
}

pub fn writeDiagnosticJson() void {
    const alloc = memory.getAllocator();
    var out_buf: std.ArrayList(u8) = .empty;
    defer out_buf.deinit(alloc);

    active_diagnostic.writeJson(&out_buf, alloc) catch return;

    const scratch = memory_map.getMemorySlice(memory_map.SCRATCH_OFFSET, out_buf.items.len + 1);
    @memcpy(scratch[0..out_buf.items.len], out_buf.items);
    scratch[out_buf.items.len] = 0;
    tess_export.export_step_len = out_buf.items.len;
}

fn detectExprDagCycle(defs_node: *const XmlNode, alloc: std.mem.Allocator) ?[]const u8 {
    var expr_map = std.StringHashMap([]const u8).init(alloc);
    defer expr_map.deinit();

    for (defs_node.children.items) |child| {
        if (std.mem.eql(u8, child.tag, "expr")) {
            const id = child.getAttr("id") orelse continue;
            const expr_str = child.getAttr("expr") orelse "";
            expr_map.put(id, expr_str) catch {};
        }
    }

    var visited = std.StringHashMap(u8).init(alloc);
    defer visited.deinit();

    var it = expr_map.keyIterator();
    while (it.next()) |k| {
        if (dfsCycle(k.*, &expr_map, &visited)) |cycle_id| {
            return cycle_id;
        }
    }
    return null;
}

fn dfsCycle(id: []const u8, expr_map: *const std.StringHashMap([]const u8), visited: *std.StringHashMap(u8)) ?[]const u8 {
    const state = visited.get(id) orelse 0;
    if (state == 1) return id;
    if (state == 2) return null;

    visited.put(id, 1) catch {};

    if (expr_map.get(id)) |expr_str| {
        var i: usize = 0;
        while (i < expr_str.len) {
            const ch = expr_str[i];
            if (std.ascii.isAlphabetic(ch) or ch == '_') {
                const start = i;
                while (i < expr_str.len and (std.ascii.isAlphanumeric(expr_str[i]) or expr_str[i] == '_' or expr_str[i] == '.')) i += 1;
                const tok = expr_str[start..i];
                if (expr_map.contains(tok)) {
                    if (dfsCycle(tok, expr_map, visited)) |c| return c;
                }
            } else {
                i += 1;
            }
        }
    }

    visited.put(id, 2) catch {};
    return null;
}

// ============================================================================
// C-ABI Export Implementations
// ============================================================================

pub fn cdml_register_import(path_ptr: [*]const u8, path_len: usize, xml_ptr: [*]const u8, xml_len: usize) u32 {
    const alloc = memory.getAllocator();
    if (registered_imports == null) {
        registered_imports = std.StringHashMap([]const u8).init(alloc);
    }

    const path = alloc.dupe(u8, path_ptr[0..path_len]) catch return types.ERR_XML_SYNTAX;
    const content = alloc.dupe(u8, xml_ptr[0..xml_len]) catch return types.ERR_XML_SYNTAX;

    registered_imports.?.put(path, content) catch return types.ERR_XML_SYNTAX;
    return types.CDML_OK;
}

pub fn cdml_eval_document(xml_ptr: [*]const u8, xml_len: usize) u32 {
    const alloc = memory.getAllocator();
    const xml_src = xml_ptr[0..xml_len];

    active_diagnostic = .{ .code = types.CDML_OK };

    // 1. Parse XML syntax
    var parser = XmlParser.init(alloc, xml_src);
    const root = parser.parse() catch {
        setDiagnostic(types.ERR_XML_SYNTAX, "root", "Malformed XML document syntax", parser.line);
        return types.ERR_XML_SYNTAX;
    };
    errdefer root.deinit();

    // 2. Validate root tag and CDML version
    if (!std.mem.eql(u8, root.tag, "cdml")) {
        setDiagnostic(types.ERR_SCHEMA_VERSION, root.tag, "Expected root element <cdml>", root.line);
        root.deinit();
        return types.ERR_SCHEMA_VERSION;
    }
    const ver = root.getAttr("version") orelse {
        setDiagnostic(types.ERR_SCHEMA_VERSION, "cdml", "Missing version attribute", root.line);
        root.deinit();
        return types.ERR_SCHEMA_VERSION;
    };
    if (!std.mem.eql(u8, ver, "1.0")) {
        setDiagnostic(types.ERR_SCHEMA_VERSION, "cdml", "Unsupported CDML version; expected 1.0", root.line);
        root.deinit();
        return types.ERR_SCHEMA_VERSION;
    }

    // 3. Check for 192-bit TopoId SHA-256 hash collisions across distinct element IDs (§10.1)
    var seen_hashes = std.AutoHashMap(u64, []const u8).init(alloc);
    defer seen_hashes.deinit();

    if (checkIdHashCollisions(root, &seen_hashes)) |colliding_id| {
        setDiagnostic(types.ERR_ID_HASH_COLLISION, colliding_id, "H64 SHA-256 TopoId hash collision detected across distinct IDs", root.line);
        root.deinit();
        return types.ERR_ID_HASH_COLLISION;
    }

    // Reset evaluator state
    if (active_evaluator) |*ev| {
        ev.deinit();
    }
    active_evaluator = DocumentEvaluator.init(alloc);
    var ev = &active_evaluator.?;
    ev.root_node = root;

    // 4. Process <imports> (§2a)
    if (root.findChild("imports")) |imports_node| {
        for (imports_node.children.items) |imp| {
            if (!std.mem.eql(u8, imp.tag, "import")) continue;
            const src = imp.getAttr("src") orelse continue;
            const prefix = imp.getAttr("prefix");

            const content = if (registered_imports) |reg| reg.get(src) else null;
            if (content == null) {
                setDiagnostic(types.ERR_IMPORT_NOT_FOUND, src, "Imported file not found in registry", imp.line);
                return types.ERR_IMPORT_NOT_FOUND;
            }

            var imp_parser = XmlParser.init(alloc, content.?);
            const imp_root = imp_parser.parse() catch {
                setDiagnostic(types.ERR_XML_SYNTAX, src, "Malformed XML in imported document", imp.line);
                return types.ERR_XML_SYNTAX;
            };
            defer imp_root.deinit();

            if (imp_root.findChild("defs")) |imp_defs| {
                for (imp_defs.children.items) |child| {
                    if (std.mem.eql(u8, child.tag, "var")) {
                        const raw_id = child.getAttr("id") orelse continue;
                        const full_id = if (prefix) |p| (std.fmt.allocPrint(alloc, "{s}.{s}", .{ p, raw_id }) catch return types.ERR_XML_SYNTAX) else (alloc.dupe(u8, raw_id) catch return types.ERR_XML_SYNTAX);
                        const val_str = child.getAttr("value") orelse "0.0";
                        const val = std.fmt.parseFloat(f64, val_str) catch 0.0;

                        if (ev.vars.contains(full_id)) {
                            setDiagnostic(types.ERR_IMPORT_CONFLICT, full_id, "Imported identifier conflicts with existing definition", imp.line);
                            return types.ERR_IMPORT_CONFLICT;
                        }

                        const slot = @as(u32, @intCast(ev.vars.count() + ev.exprs.count()));
                        ev.vars.put(full_id, .{ .id = full_id, .value = val, .slot = slot }) catch {};
                        ev.var_indices.put(full_id, slot) catch {};
                    }
                }
            }
        }
    }

    // 5. Process <defs> (§3)
    if (root.findChild("defs")) |defs_node| {
        for (defs_node.children.items) |child| {
            if (std.mem.eql(u8, child.tag, "var")) {
                const id = child.getAttr("id") orelse continue;
                const val_str = child.getAttr("value") orelse "0.0";
                const val = std.fmt.parseFloat(f64, val_str) catch 0.0;
                const min_v = if (child.getAttr("min")) |m| std.fmt.parseFloat(f64, m) catch null else null;
                const max_v = if (child.getAttr("max")) |m| std.fmt.parseFloat(f64, m) catch null else null;

                const slot = @as(u32, @intCast(ev.vars.count() + ev.exprs.count()));
                ev.vars.put(id, .{ .id = id, .value = val, .min = min_v, .max = max_v, .slot = slot }) catch {};
                ev.var_indices.put(id, slot) catch {};
            } else if (std.mem.eql(u8, child.tag, "field-slot")) {
                const id = child.getAttr("id") orelse "";
                const slot_idx = if (child.getAttr("slot")) |s| std.fmt.parseInt(u32, s, 10) catch 0 else 0;
                const gx = if (child.getAttr("grid-x")) |g| std.fmt.parseInt(u32, g, 10) catch 64 else 64;
                const gy = if (child.getAttr("grid-y")) |g| std.fmt.parseInt(u32, g, 10) catch 64 else 64;
                const gz = if (child.getAttr("grid-z")) |g| std.fmt.parseInt(u32, g, 10) catch 24 else 24;
                const def_val = if (child.getAttr("default")) |d| std.fmt.parseFloat(f64, d) catch 0.0 else 0.0;
                ev.field_slots.put(slot_idx, .{
                    .id = id,
                    .slot = slot_idx,
                    .grid_x = gx,
                    .grid_y = gy,
                    .grid_z = gz,
                    .default_val = def_val,
                }) catch {};
                autodiff.configureFieldSlot(slot_idx, gx, gy, gz, -45.0, -45.0, 0.0, 45.0, 45.0, 16.0);
            }
        }

        if (detectExprDagCycle(defs_node, alloc)) |cycle_id| {
            setDiagnostic(types.ERR_DAG_CYCLE, cycle_id, "Cyclic dependency detected in expression DAG", defs_node.line);
            return types.ERR_DAG_CYCLE;
        }

        for (defs_node.children.items) |child| {
            if (std.mem.eql(u8, child.tag, "expr")) {
                const id = child.getAttr("id") orelse continue;
                const expr_str = child.getAttr("expr") orelse continue;

                const eval_res = ev.evaluateExpression(expr_str, .residual) catch |err| {
                    if (err == error.ErrExprContext) {
                        setDiagnostic(types.ERR_EXPR_CONTEXT, id, "Predicate-only variable used in expression context", child.line);
                        return types.ERR_EXPR_CONTEXT;
                    }
                    setDiagnostic(types.ERR_UNDEFINED_REF, id, "Expression references undefined variable or identifier", child.line);
                    return types.ERR_UNDEFINED_REF;
                };

                const slot = @as(u32, @intCast(ev.vars.count() + ev.exprs.count()));
                ev.exprs.put(id, .{ .id = id, .expr_str = expr_str, .value = eval_res, .slot = slot }) catch {};
                ev.var_indices.put(id, slot) catch {};
            }
        }

        for (defs_node.children.items) |child| {
            if (std.mem.eql(u8, child.tag, "assert")) {
                const id = child.getAttr("id") orelse continue;
                const expr_str = child.getAttr("expr") orelse continue;
                const err_msg = child.getAttr("error") orelse "Assertion violated";

                const val = ev.evaluateExpression(expr_str, .residual) catch |err| {
                    if (err == error.ErrExprContext) {
                        setDiagnostic(types.ERR_EXPR_CONTEXT, id, "Predicate-only variable used in assert context", child.line);
                        return types.ERR_EXPR_CONTEXT;
                    }
                    setDiagnostic(types.ERR_UNDEFINED_REF, id, "Assert references undefined variable", child.line);
                    return types.ERR_UNDEFINED_REF;
                };

                ev.asserts.append(alloc, .{
                    .id = id,
                    .expr_str = expr_str,
                    .error_msg = err_msg,
                    .line = child.line,
                }) catch {};

                if (val < 0.0) {
                    setDiagnostic(types.ERR_ASSERT_VIOLATED, id, err_msg, child.line);
                    return types.ERR_ASSERT_VIOLATED;
                }
            }
        }
    }

    ev.syncVarValues() catch {};

    // 6. Process <body> and <exports> (§4–§12)
    return executeBodyAndExports(ev);
}

pub fn cdml_set_var(id_ptr: [*]const u8, id_len: usize, value_f64: f64) u32 {
    const ev = if (active_evaluator) |*e| e else return types.ERR_UNDEFINED_REF;
    const var_id = id_ptr[0..id_len];

    const var_ptr = ev.vars.getPtr(var_id) orelse {
        setDiagnostic(types.ERR_UNDEFINED_REF, var_id, "Unknown parameter id in cdml_set_var", 0);
        return types.ERR_UNDEFINED_REF;
    };

    const old_val = var_ptr.value;
    var_ptr.value = value_f64;

    var it_expr = ev.exprs.iterator();
    while (it_expr.next()) |entry| {
        const e = entry.value_ptr;
        if (ev.evaluateExpression(e.expr_str, .residual)) |new_v| {
            e.value = new_v;
        } else |_| {}
    }

    ev.syncVarValues() catch {};

    for (ev.asserts.items) |asrt| {
        const val = ev.evaluateExpression(asrt.expr_str, .residual) catch 0.0;
        if (val < 0.0) {
            var_ptr.value = old_val;
            var it_revert = ev.exprs.iterator();
            while (it_revert.next()) |entry| {
                const e = entry.value_ptr;
                if (ev.evaluateExpression(e.expr_str, .residual)) |new_v| {
                    e.value = new_v;
                } else |_| {}
            }
            ev.syncVarValues() catch {};
            setDiagnostic(types.ERR_ASSERT_VIOLATED, asrt.id, asrt.error_msg, asrt.line);
            return types.ERR_ASSERT_VIOLATED;
        }
    }

    return executeBodyAndExports(ev);
}

pub fn cdml_get_probe_value(id_ptr: [*]const u8, id_len: usize, out_f64_ptr: *f64) u32 {
    const ev = if (active_evaluator) |*e| e else return types.ERR_UNDEFINED_REF;
    const probe_id = id_ptr[0..id_len];

    if (ev.probes.get(probe_id)) |p| {
        out_f64_ptr.* = p.value;
        return types.CDML_OK;
    }

    setDiagnostic(types.ERR_PROBE_NO_MATCH, probe_id, "Probe not found in active document", 0);
    return types.ERR_PROBE_NO_MATCH;
}

// ============================================================================
// Body & Exports Pipeline
// ============================================================================

pub fn executeBodyAndExports(ev: *DocumentEvaluator) u32 {
    const root = ev.root_node orelse return types.ERR_XML_SYNTAX;
    const alloc = ev.allocator;
    ev.syncVarValues() catch {};

    if (root.findChild("body")) |body_node| {
        for (body_node.children.items) |child| {
            if (std.mem.eql(u8, child.tag, "chart")) {
                const status = evaluateChartNode(ev, child);
                if (status != types.CDML_OK) return status;
            } else if (std.mem.eql(u8, child.tag, "sketch")) {
                const status = evaluateSketchNode(ev, child);
                if (status != types.CDML_OK) return status;
            } else if (std.mem.eql(u8, child.tag, "surface")) {
                const s_id = child.getAttr("id") orelse continue;
                var eq_str = child.getAttr("eq") orelse "";
                if (child.findChild("eq")) |eq_node| {
                    eq_str = std.mem.trim(u8, eq_node.text, " \t\r\n");
                }
                ev.surfaces.put(s_id, eq_str) catch {};
            } else if (std.mem.eql(u8, child.tag, "region")) {
                const r_id = child.getAttr("id") orelse continue;
                ev.regions.put(r_id, child) catch {};
            } else if (std.mem.eql(u8, child.tag, "brep")) {
                const solid_id = child.getAttr("id") orelse "brep";
                if (ev.solids.get(solid_id)) |old_h| {
                    surface_brep.solid_free(old_h);
                }
                var err_code: u32 = types.CDML_OK;
                const h = constructBrepSolid(ev, child, &err_code) catch {
                    if (err_code == types.CDML_OK) err_code = types.ERR_SWEEP_SELF_INTERSECT;
                    const msg = if (err_code == types.ERR_FILLET_RADIUS_COLLAPSE and surface_brep.last_fillet_message.len > 0)
                        surface_brep.last_fillet_message
                    else
                        "B-Rep construction failed";
                    setDiagnostic(err_code, solid_id, msg, child.line);
                    return err_code;
                };
                ev.solids.put(solid_id, h) catch {};
                ev.active_solid_h = h;
            } else if (std.mem.eql(u8, child.tag, "implicit")) {
                const solid_id = child.getAttr("id") orelse "implicit";
                if (ev.solids.get(solid_id)) |old_h| {
                    implicit_field.freeImplicitSolid(old_h);
                }
                const h = constructImplicitSolid(ev, child) catch {
                    setDiagnostic(types.ERR_IMPLICIT_GRAD_ZERO, solid_id, "[CAD Kernel / Expression Error] Implicit field zero-gradient or NaN on zero isosurface", child.line);
                    return types.ERR_IMPLICIT_GRAD_ZERO;
                };
                if (implicit_field.last_domain_clipped_corners > 0) {
                    setDiagnostic(types.CDML_OK, solid_id, "[User CDML Domain Notice] Geometry extends beyond <domain> bounds and was capped at the domain box; enlarge xmin..xmax/ymin..ymax/zmin..zmax if unintended.", child.line);
                } else if (implicit_field.last_singularities_filtered > 0) {
                    setDiagnostic(types.CDML_OK, solid_id, "[User CDML Expression Notice] Filtered removable coordinate singularity (e.g. 0/0 on axis) during implicit evaluation.", child.line);
                }
                ev.solids.put(solid_id, h) catch {};
                ev.active_solid_h = h;
            } else if (std.mem.eql(u8, child.tag, "csg")) {
                const solid_id = child.getAttr("id") orelse "csg";
                const h = constructCsgSolid(ev, child) catch {
                    setDiagnostic(types.ERR_SSI_CONVERGENCE, solid_id, "CSG boolean evaluation failed", child.line);
                    return types.ERR_SSI_CONVERGENCE;
                };
                ev.solids.put(solid_id, h) catch {};
                ev.active_solid_h = h;
            } else if (std.mem.eql(u8, child.tag, "repeat")) {
                const rep_id = child.getAttr("id") orelse "repeat";
                const ref_id = child.getAttr("ref") orelse "";
                if (ev.solids.get(ref_id)) |ref_h| {
                    ev.solids.put(rep_id, ref_h) catch {};
                }
            } else if (std.mem.eql(u8, child.tag, "compose")) {
                const comp_id = child.getAttr("id") orelse "compose";
                for (child.children.items) |layer| {
                    if (std.mem.eql(u8, layer.tag, "layer")) {
                        const role = layer.getAttr("role") orelse "shell";
                        const ref_id = layer.getAttr("ref") orelse "";
                        if (std.mem.eql(u8, role, "shell")) {
                            if (ev.solids.get(ref_id)) |sh| {
                                ev.solids.put(comp_id, sh) catch {};
                            }
                        }
                    }
                }
            } else if (std.mem.eql(u8, child.tag, "probe")) {
                const status = evaluateProbeNode(ev, child);
                if (status != types.CDML_OK) return status;
            } else if (std.mem.eql(u8, child.tag, "assert")) {
                const id = child.getAttr("id") orelse "assert";
                const expr_str = child.getAttr("expr") orelse continue;
                const err_msg = child.getAttr("error") orelse "Assertion violated";
                const val = ev.evaluateExpression(expr_str, .residual) catch {
                    setDiagnostic(types.ERR_UNDEFINED_REF, id, "Body assertion references undefined variable", child.line);
                    return types.ERR_UNDEFINED_REF;
                };
                if (val < 0.0) {
                    setDiagnostic(types.ERR_ASSERT_VIOLATED, id, err_msg, child.line);
                    return types.ERR_ASSERT_VIOLATED;
                }
            }
        }
    }

    // Process <exports>: tessellate to 0x0F0000, step, stl (§14.1)
    if (root.findChild("exports")) |exp_node| {
        for (exp_node.children.items) |exp| {
            if (std.mem.eql(u8, exp.tag, "tessellate")) {
                const target_id = exp.getAttr("target") orelse (exp.getAttr("source") orelse "");
                const solid_h = ev.solids.get(target_id) orelse ev.active_solid_h;
                if (solid_h != 0) {
                    const chord_tol = if (exp.getAttr("chord-tol") orelse exp.getAttr("linear_deflection")) |c| std.fmt.parseFloat(f32, c) catch 0.05 else 0.05;
                    const angle_tol = if (exp.getAttr("angle-tol") orelse exp.getAttr("angular_deflection")) |a| std.fmt.parseFloat(f32, a) catch 0.1 else 0.1;
                    tess_export.solid_tessellate(solid_h, chord_tol, angle_tol);
                    active_mesh_valid = true;
                    ev.last_tess_solid_h = solid_h;
                }
            } else if (std.mem.eql(u8, exp.tag, "step")) {
                const target_id = exp.getAttr("target") orelse (exp.getAttr("source") orelse "");
                const solid_h = ev.solids.get(target_id) orelse ev.active_solid_h;
                if (solid_h != 0) {
                    var out_buf: std.ArrayList(u8) = .empty;
                    defer out_buf.deinit(alloc);
                    const step_len = tess_export.solid_export_step(solid_h, &out_buf);
                    if (step_len == 0) {
                        setDiagnostic(types.ERR_XML_SYNTAX, target_id, "STEP export produced zero bytes", exp.line);
                    }
                }
            } else if (std.mem.eql(u8, exp.tag, "stl")) {
                const target_id = exp.getAttr("target") orelse (exp.getAttr("source") orelse "");
                const solid_h = ev.solids.get(target_id) orelse ev.active_solid_h;
                const binary = if (exp.getAttr("format")) |fmt| std.mem.eql(u8, fmt, "binary") else (if (exp.getAttr("binary")) |b| std.mem.eql(u8, b, "true") else true);
                if (solid_h != 0) {
                    var out_buf: std.ArrayList(u8) = .empty;
                    defer out_buf.deinit(alloc);
                    const stl_len = tess_export.solid_export_stl(solid_h, binary, &out_buf);
                    if (stl_len == 0) {
                        setDiagnostic(types.ERR_XML_SYNTAX, target_id, "STL export produced zero bytes", exp.line);
                    }
                }
            }
        }
    }

    return types.CDML_OK;
}

// ============================================================================
// Chart Solving (§5)
// ============================================================================

fn evaluateChartNode(ev: *DocumentEvaluator, node: *const XmlNode) u32 {
    const alloc = ev.allocator;
    const chart_id = node.getAttr("id") orelse "chart";

    var sys = constraint_sys.ConstraintSystem.init(alloc);
    defer sys.deinit();

    var chart_vars = std.StringHashMap(u32).init(alloc);
    defer {
        var it_k = chart_vars.keyIterator();
        while (it_k.next()) |k| alloc.free(k.*);
        chart_vars.deinit();
    }

    var chart_consts = std.StringHashMap(f64).init(alloc);
    defer {
        var it_c = chart_consts.keyIterator();
        while (it_c.next()) |k| alloc.free(k.*);
        chart_consts.deinit();
    }

    var it_doc = ev.const_values.iterator();
    while (it_doc.next()) |entry| {
        const k_dup = alloc.dupe(u8, entry.key_ptr.*) catch continue;
        chart_consts.put(k_dup, entry.value_ptr.*) catch {};
    }

    if (node.findChild("vars")) |vars_node| {
        for (vars_node.children.items) |v_node| {
            if (!std.mem.eql(u8, v_node.tag, "vec3")) continue;
            const v_id = v_node.getAttr("id") orelse continue;
            const vx = if (v_node.getAttr("x")) |s| (ev.evaluateExpression(s, .residual) catch 0.0) else 0.0;
            const vy = if (v_node.getAttr("y")) |s| (ev.evaluateExpression(s, .residual) catch 0.0) else 0.0;
            const vz = if (v_node.getAttr("z")) |s| (ev.evaluateExpression(s, .residual) catch 0.0) else 0.0;
            const is_fixed = if (v_node.getAttr("fixed")) |f| std.mem.eql(u8, f, "true") else false;

            const kx = std.fmt.allocPrint(alloc, "{s}.x", .{v_id}) catch continue;
            const ky = std.fmt.allocPrint(alloc, "{s}.y", .{v_id}) catch continue;
            const kz = std.fmt.allocPrint(alloc, "{s}.z", .{v_id}) catch continue;

            if (is_fixed) {
                chart_consts.put(kx, vx) catch {};
                chart_consts.put(ky, vy) catch {};
                chart_consts.put(kz, vz) catch {};
            } else {
                const base = sys.allocParams(&[_]f64{ vx, vy, vz }) catch continue;
                chart_vars.put(kx, base + 0) catch {};
                chart_vars.put(ky, base + 1) catch {};
                chart_vars.put(kz, base + 2) catch {};
            }
        }
    }

    if (node.findChild("constraints")) |c_node| {
        const n_p = sys.params.items.len;
        const p_indices = alloc.alloc(u32, n_p) catch return types.ERR_XML_SYNTAX;
        defer alloc.free(p_indices);
        for (0..n_p) |pi| p_indices[pi] = @intCast(pi);

        for (c_node.children.items) |res_node| {
            if (!std.mem.eql(u8, res_node.tag, "residual")) continue;
            const expr_str = res_node.getAttr("expr") orelse continue;
            const comp = autodiff.compileExpressionFull(memory.persistent_allocator, expr_str, .residual, &chart_vars, &chart_consts, null) catch |err| {
                if (err == error.ErrExprContext) {
                    setDiagnostic(types.ERR_EXPR_CONTEXT, chart_id, "Invalid context in chart residual", res_node.line);
                    return types.ERR_EXPR_CONTEXT;
                }
                setDiagnostic(types.ERR_UNDEFINED_REF, chart_id, "Undefined reference in chart residual", res_node.line);
                return types.ERR_UNDEFINED_REF;
            };
            const expr_h = autodiff.registerCompiledExpression(comp);
            _ = sys.addResidual(expr_h, p_indices) catch {
                setDiagnostic(types.ERR_XML_SYNTAX, chart_id, "Failed to register chart constraint residual", res_node.line);
                return types.ERR_XML_SYNTAX;
            };
        }

        if (sys.residuals.items.len > 0 and sys.params.items.len > 0) {
            _ = sys.solve(1e-8, 50);
            if (sys.last_state == .Conflicting) {
                setDiagnostic(types.ERR_SKETCH_CONFLICT, chart_id, "Chart constraint system conflicting", node.line);
                return types.ERR_SKETCH_CONFLICT;
            }
            if (sys.last_state == .Diverged) {
                setDiagnostic(types.ERR_SKETCH_DIVERGED, chart_id, "Chart constraint solver diverged", node.line);
                return types.ERR_SKETCH_DIVERGED;
            }
        }
    }

    const readVec = struct {
        fn get(name: []const u8, def: Vec3d, cv: *const std.StringHashMap(u32), cc: *const std.StringHashMap(f64), params: []const f64) Vec3d {
            var bx: [64]u8 = undefined;
            var by: [64]u8 = undefined;
            var bz: [64]u8 = undefined;
            const kx = std.fmt.bufPrint(&bx, "{s}.x", .{name}) catch return def;
            const ky = std.fmt.bufPrint(&by, "{s}.y", .{name}) catch return def;
            const kz = std.fmt.bufPrint(&bz, "{s}.z", .{name}) catch return def;
            const x = if (cv.get(kx)) |idx| params[idx] else (cc.get(kx) orelse def.x);
            const y = if (cv.get(ky)) |idx| params[idx] else (cc.get(ky) orelse def.y);
            const z = if (cv.get(kz)) |idx| params[idx] else (cc.get(kz) orelse def.z);
            return Vec3d.init(x, y, z);
        }
    }.get;

    const p0 = readVec("p0", Vec3d.init(0.0, 0.0, 0.0), &chart_vars, &chart_consts, sys.params.items);
    const e1 = readVec("e1", Vec3d.init(1.0, 0.0, 0.0), &chart_vars, &chart_consts, sys.params.items).normalize();
    var e2 = readVec("e2", Vec3d.init(0.0, 1.0, 0.0), &chart_vars, &chart_consts, sys.params.items).normalize();
    if (e2.length() < 1e-9) e2 = Vec3d.init(0.0, 1.0, 0.0);

    ev.charts.put(chart_id, .{
        .id = chart_id,
        .p0 = p0,
        .e1 = e1,
        .e2 = e2,
    }) catch {};

    return types.CDML_OK;
}

// ============================================================================
// Sketch Solving & Wire Construction (§6)
// ============================================================================

fn evaluateSketchNode(ev: *DocumentEvaluator, node: *const XmlNode) u32 {
    const alloc = ev.allocator;
    const sk_id = node.getAttr("id") orelse "sketch";
    const chart_id = node.getAttr("chart") orelse "";
    const max_iter = if (node.getAttr("max-iter")) |m| std.fmt.parseInt(u32, m, 10) catch 100 else 100;

    var sys = constraint_sys.ConstraintSystem.init(alloc);
    defer sys.deinit();

    var sk_vars = std.StringHashMap(u32).init(alloc);
    defer {
        var it_k = sk_vars.keyIterator();
        while (it_k.next()) |k| alloc.free(k.*);
        sk_vars.deinit();
    }

    var sk_consts = std.StringHashMap(f64).init(alloc);
    defer {
        var it_c = sk_consts.keyIterator();
        while (it_c.next()) |k| alloc.free(k.*);
        sk_consts.deinit();
    }

    var it_doc = ev.const_values.iterator();
    while (it_doc.next()) |entry| {
        const k_dup = alloc.dupe(u8, entry.key_ptr.*) catch continue;
        sk_consts.put(k_dup, entry.value_ptr.*) catch {};
    }

    // 1. Parse <vars> (<point2d> and <scalar>)
    if (node.findChild("vars")) |vars_node| {
        for (vars_node.children.items) |v_node| {
            if (std.mem.eql(u8, v_node.tag, "point2d")) {
                const p_id = v_node.getAttr("id") orelse continue;
                const u_init = if (v_node.getAttr("u")) |s| (ev.evaluateExpression(s, .residual) catch 0.0) else 0.0;
                const v_init = if (v_node.getAttr("v")) |s| (ev.evaluateExpression(s, .residual) catch 0.0) else 0.0;
                const is_fixed = if (v_node.getAttr("fixed")) |f| std.mem.eql(u8, f, "true") else false;

                const ku = std.fmt.allocPrint(alloc, "{s}.u", .{p_id}) catch continue;
                const kv = std.fmt.allocPrint(alloc, "{s}.v", .{p_id}) catch continue;
                if (is_fixed) {
                    sk_consts.put(ku, u_init) catch {};
                    sk_consts.put(kv, v_init) catch {};
                } else {
                    const base = sys.allocParams(&[_]f64{ u_init, v_init }) catch continue;
                    sk_vars.put(ku, base + 0) catch {};
                    sk_vars.put(kv, base + 1) catch {};
                }
            } else if (std.mem.eql(u8, v_node.tag, "scalar")) {
                const s_id = v_node.getAttr("id") orelse continue;
                const val_str = v_node.getAttr("value") orelse (v_node.getAttr("init") orelse "0.0");
                const s_init = ev.evaluateExpression(val_str, .residual) catch 0.0;
                const is_fixed = if (v_node.getAttr("fixed")) |f| std.mem.eql(u8, f, "true") else false;
                const ks = alloc.dupe(u8, s_id) catch continue;
                if (is_fixed) {
                    sk_consts.put(ks, s_init) catch {};
                } else {
                    const base = sys.allocParams(&[_]f64{s_init}) catch continue;
                    sk_vars.put(ks, base) catch {};
                }
            }
        }
    }

    // 2. Compile and solve <constraints>
    if (node.findChild("constraints")) |c_node| {
        const n_p = sys.params.items.len;
        const p_indices = alloc.alloc(u32, n_p) catch return types.ERR_XML_SYNTAX;
        defer alloc.free(p_indices);
        for (0..n_p) |pi| p_indices[pi] = @intCast(pi);

        for (c_node.children.items) |res_node| {
            if (!std.mem.eql(u8, res_node.tag, "residual")) continue;
            const expr_str = res_node.getAttr("expr") orelse continue;
            const comp = autodiff.compileExpressionFull(memory.persistent_allocator, expr_str, .residual, &sk_vars, &sk_consts, null) catch |err| {
                if (err == error.ErrExprContext) {
                    setDiagnostic(types.ERR_EXPR_CONTEXT, sk_id, "Invalid context in sketch residual", res_node.line);
                    return types.ERR_EXPR_CONTEXT;
                }
                setDiagnostic(types.ERR_UNDEFINED_REF, sk_id, "Undefined reference in sketch residual", res_node.line);
                return types.ERR_UNDEFINED_REF;
            };
            const expr_h = autodiff.registerCompiledExpression(comp);
            _ = sys.addResidual(expr_h, p_indices) catch {
                setDiagnostic(types.ERR_XML_SYNTAX, sk_id, "Failed to register sketch constraint residual", res_node.line);
                return types.ERR_XML_SYNTAX;
            };
        }

        if (sys.residuals.items.len > 0 and sys.params.items.len > 0) {
            _ = sys.solve(1e-7, max_iter);
            if (sys.last_state == .Conflicting) {
                setDiagnostic(types.ERR_SKETCH_CONFLICT, sk_id, "Sketch constraint system conflicting", node.line);
                return types.ERR_SKETCH_CONFLICT;
            }
            if (sys.last_state == .Diverged) {
                setDiagnostic(types.ERR_SKETCH_DIVERGED, sk_id, "Sketch constraint solver diverged", node.line);
                return types.ERR_SKETCH_DIVERGED;
            }
        }
    }

    // Copy solved sketch variables into sk_consts for parametric curve evaluation
    var it_solved = sk_vars.iterator();
    while (it_solved.next()) |entry| {
        const k_dup = alloc.dupe(u8, entry.key_ptr.*) catch continue;
        sk_consts.put(k_dup, sys.params.items[entry.value_ptr.*]) catch {};
    }

    // 3. Assemble <wire> loops from solved control points and parametric curves
    var sk_def = SketchDef{
        .id = sk_id,
        .chart_id = chart_id,
        .outer_loops = .empty,
        .hole_loops = .empty,
    };
    errdefer sk_def.deinit(alloc);

    for (node.children.items) |w_node| {
        if (!std.mem.eql(u8, w_node.tag, "wire")) continue;
        const w_id = w_node.getAttr("id") orelse "wire";
        const role = w_node.getAttr("role") orelse "outer";
        const is_hole = std.mem.eql(u8, role, "hole") or std.mem.eql(u8, role, "inner");
        const is_closed = if (w_node.getAttr("closed")) |c| std.mem.eql(u8, c, "true") else true;
        if (!is_closed) {
            setDiagnostic(types.ERR_WIRE_OPEN_OR_SELF_INT, w_id, "Sweep wire must be closed", w_node.line);
            sk_def.deinit(alloc);
            return types.ERR_WIRE_OPEN_OR_SELF_INT;
        }

        var loop = OwnedLoop2D{
            .wire_id = w_id,
            .is_hole = is_hole,
            .samples = .empty,
        };
        errdefer loop.deinit(alloc);

        for (w_node.children.items) |cv_node| {
            if (std.mem.eql(u8, cv_node.tag, "curve")) {
                const cv_id = cv_node.getAttr("id") orelse "curve";
                const cv_hash = topo_id.h64(cv_id);
                const deg = if (cv_node.getAttr("degree")) |d| (std.fmt.parseInt(u32, d, 10) catch 1) else 1;
                const ctrl_str = cv_node.getAttr("ctrl") orelse "";
                const weights_str = cv_node.getAttr("weights") orelse "";
                const knots_str = cv_node.getAttr("knots") orelse "";

                // Parse control point IDs and look up solved (u, v)
                var ctrl_pts: std.ArrayList([2]f64) = .empty;
                defer ctrl_pts.deinit(alloc);
                var tok_it = std.mem.tokenizeAny(u8, ctrl_str, " \t\r\n");
                while (tok_it.next()) |pt_name| {
                    var bu: [64]u8 = undefined;
                    var bv: [64]u8 = undefined;
                    const ku = std.fmt.bufPrint(&bu, "{s}.u", .{pt_name}) catch continue;
                    const kv = std.fmt.bufPrint(&bv, "{s}.v", .{pt_name}) catch continue;
                    const u_val = sk_consts.get(ku) orelse 0.0;
                    const v_val = sk_consts.get(kv) orelse 0.0;
                    ctrl_pts.append(alloc, .{ u_val, v_val }) catch continue;
                }

                if (ctrl_pts.items.len < 2) continue;

                if (deg == 1 and ctrl_pts.items.len == 2) {
                    loop.samples.append(alloc, .{
                        .u = ctrl_pts.items[0][0],
                        .v = ctrl_pts.items[0][1],
                        .curve_hash = cv_hash,
                        .curvature_2d = 0.0,
                    }) catch {};
                } else {
                    // General rational B-spline evaluation via NurbsCurve
                    const c_sys_h = constraint_sys.sys_create();
                    defer constraint_sys.sys_free(c_sys_h);

                    var w_list: std.ArrayList(f64) = .empty;
                    defer w_list.deinit(alloc);
                    var w_it = std.mem.tokenizeAny(u8, weights_str, " \t\r\n");
                    while (w_it.next()) |ws| {
                        w_list.append(alloc, std.fmt.parseFloat(f64, ws) catch 1.0) catch {};
                    }

                    var slots: std.ArrayList(u32) = .empty;
                    defer slots.deinit(alloc);
                    for (ctrl_pts.items, 0..) |pt, idx| {
                        const w_v = if (idx < w_list.items.len) w_list.items[idx] else 1.0;
                        const init_p = [3]f64{ pt[0], pt[1], w_v };
                        const s_base = constraint_sys.sys_alloc_params(c_sys_h, &init_p, 3);
                        slots.appendSlice(alloc, &[_]u32{ s_base, s_base + 1, s_base + 2 }) catch {};
                    }

                    var k_list: std.ArrayList(f64) = .empty;
                    defer k_list.deinit(alloc);
                    var k_it = std.mem.tokenizeAny(u8, knots_str, " \t\r\n");
                    while (k_it.next()) |ks| {
                        k_list.append(alloc, std.fmt.parseFloat(f64, ks) catch 0.0) catch {};
                    }

                    if (k_list.items.len >= deg + ctrl_pts.items.len + 1) {
                        var nurbs_c = curve_wire.NurbsCurve{
                            .allocator = alloc,
                            .sys_handle = c_sys_h,
                            .dim = 2,
                            .degree = deg,
                            .ctrl_count = @intCast(ctrl_pts.items.len),
                            .ctrl_param_indices = slots.items,
                            .knots = k_list.items,
                        };
                        const u_min = k_list.items[deg];
                        const u_max = k_list.items[ctrl_pts.items.len];
                        const n_steps: usize = 16;
                        for (0..n_steps) |s_idx| {
                            const frac = @as(f64, @floatFromInt(s_idx)) / @as(f64, @floatFromInt(n_steps));
                            const t = u_min + frac * (u_max - u_min);
                            const d = nurbs_c.evalDerivs(t);
                            const speed = @sqrt(d.d1.x * d.d1.x + d.d1.y * d.d1.y);
                            const k2d = if (speed > 1e-9)
                                @abs(d.d1.x * d.d2.y - d.d1.y * d.d2.x) / (speed * speed * speed)
                            else
                                0.0;
                            loop.samples.append(alloc, .{
                                .u = d.point.x,
                                .v = d.point.y,
                                .curve_hash = cv_hash,
                                .curvature_2d = k2d,
                            }) catch {};
                        }
                    }
                }
            } else if (std.mem.eql(u8, cv_node.tag, "param-curve")) {
                const pc_id = cv_node.getAttr("id") orelse "param_curve";
                const pc_hash = topo_id.h64(pc_id);
                const param_name = cv_node.getAttr("param") orelse "t";
                const dom_str = cv_node.getAttr("domain") orelse "0 1";
                const u_expr_str = cv_node.getAttr("u-expr") orelse "0.0";
                const v_expr_str = cv_node.getAttr("v-expr") orelse "0.0";

                var t0: f64 = 0.0;
                var t1: f64 = 1.0;
                var d_it = std.mem.tokenizeAny(u8, dom_str, " \t\r\n");
                if (d_it.next()) |s0| t0 = ev.evaluateExpression(s0, .residual) catch 0.0;
                if (d_it.next()) |s1| t1 = ev.evaluateExpression(s1, .residual) catch 1.0;

                var p_map = std.StringHashMap(u32).init(alloc);
                defer p_map.deinit();
                p_map.put(param_name, 0) catch {};

                var u_comp = autodiff.compileExpressionFull(alloc, u_expr_str, .residual, &p_map, &sk_consts, null) catch {
                    setDiagnostic(types.ERR_UNDEFINED_REF, pc_id, "Failed to compile param-curve u-expr", cv_node.line);
                    loop.deinit(alloc);
                    sk_def.deinit(alloc);
                    return types.ERR_UNDEFINED_REF;
                };
                defer u_comp.deinit();

                var v_comp = autodiff.compileExpressionFull(alloc, v_expr_str, .residual, &p_map, &sk_consts, null) catch {
                    setDiagnostic(types.ERR_UNDEFINED_REF, pc_id, "Failed to compile param-curve v-expr", cv_node.line);
                    loop.deinit(alloc);
                    sk_def.deinit(alloc);
                    return types.ERR_UNDEFINED_REF;
                };
                defer v_comp.deinit();

                const n_samples: usize = 32;
                const dt = (t1 - t0) / @as(f64, @floatFromInt(n_samples));
                for (0..n_samples) |s_idx| {
                    const t_val = t0 + @as(f64, @floatFromInt(s_idx)) * dt;
                    const d_in = [_]autodiff.Dual{autodiff.Dual.variable(t_val, true)};
                    const u_d = u_comp.evalDual(&d_in);
                    const v_d = v_comp.evalDual(&d_in);

                    // Second derivative via central difference of first derivative
                    const eps = 1e-5 * (t1 - t0);
                    const d_plus = [_]autodiff.Dual{autodiff.Dual.variable(t_val + eps, true)};
                    const d_minus = [_]autodiff.Dual{autodiff.Dual.variable(t_val - eps, true)};
                    const u_dd = (u_comp.evalDual(&d_plus).der - u_comp.evalDual(&d_minus).der) / (2.0 * eps);
                    const v_dd = (v_comp.evalDual(&d_plus).der - v_comp.evalDual(&d_minus).der) / (2.0 * eps);
                    const speed = @sqrt(u_d.der * u_d.der + v_d.der * v_d.der);
                    const k2d = if (speed > 1e-9)
                        @abs(u_d.der * v_dd - v_d.der * u_dd) / (speed * speed * speed)
                    else
                        0.0;

                    loop.samples.append(alloc, .{
                        .u = u_d.val,
                        .v = v_d.val,
                        .curve_hash = pc_hash,
                        .curvature_2d = k2d,
                    }) catch {};
                }
            } else if (std.mem.eql(u8, cv_node.tag, "line")) {
                const p0_id = cv_node.getAttr("p0") orelse "";
                var bu: [64]u8 = undefined;
                var bv: [64]u8 = undefined;
                const ku = std.fmt.bufPrint(&bu, "{s}.u", .{p0_id}) catch continue;
                const kv = std.fmt.bufPrint(&bv, "{s}.v", .{p0_id}) catch continue;
                const u_val = sk_consts.get(ku) orelse 0.0;
                const v_val = sk_consts.get(kv) orelse 0.0;
                const line_hash = topo_id.h64(p0_id);
                loop.samples.append(alloc, .{
                    .u = u_val,
                    .v = v_val,
                    .curve_hash = line_hash,
                    .curvature_2d = 0.0,
                }) catch {};
            }
        }

        if (loop.samples.items.len < 3) {
            setDiagnostic(types.ERR_WIRE_OPEN_OR_SELF_INT, w_id, "Wire has fewer than 3 vertices", w_node.line);
            loop.deinit(alloc);
            sk_def.deinit(alloc);
            return types.ERR_WIRE_OPEN_OR_SELF_INT;
        }

        if (is_hole) {
            sk_def.hole_loops.append(alloc, loop) catch {};
        } else {
            sk_def.outer_loops.append(alloc, loop) catch {};
        }
    }

    if (sk_def.outer_loops.items.len == 0) {
        setDiagnostic(types.ERR_PROFILE_INVALID, sk_id, "Sketch must contain at least one outer wire", node.line);
        sk_def.deinit(alloc);
        return types.ERR_PROFILE_INVALID;
    }

    if (ev.sketches.fetchRemove(sk_id)) |old_kv| {
        var old_sk = old_kv.value;
        old_sk.deinit(alloc);
    }
    ev.sketches.put(sk_id, sk_def) catch {};

    return types.CDML_OK;
}

// ============================================================================
// B-Rep Construction (<brep region="..."/> and <sweep> + <fillet>)
// ============================================================================

fn parseVec3(str: []const u8) Vec3d {
    var s = std.mem.trim(u8, str, " \t\r\n");
    if (std.mem.startsWith(u8, s, "vec3(") and std.mem.endsWith(u8, s, ")")) {
        s = s[5 .. s.len - 1];
    } else if (std.mem.startsWith(u8, s, "(") and std.mem.endsWith(u8, s, ")")) {
        s = s[1 .. s.len - 1];
    }
    var it = std.mem.tokenizeAny(u8, s, " ,\t\r\n");
    const x = if (it.next()) |tok| (std.fmt.parseFloat(f64, tok) catch 0.0) else 0.0;
    const y = if (it.next()) |tok| (std.fmt.parseFloat(f64, tok) catch 0.0) else 0.0;
    const z = if (it.next()) |tok| (std.fmt.parseFloat(f64, tok) catch 0.0) else 0.0;
    return Vec3d.init(x, y, z);
}

fn getSketchPtr(ev: *DocumentEvaluator, sk_id: []const u8) ?*SketchDef {
    if (ev.sketches.getPtr(sk_id)) |p| return p;
    if (ev.sketches.count() == 1) {
        var it = ev.sketches.valueIterator();
        return it.next();
    }
    return null;
}

fn constructBrepSolid(ev: *DocumentEvaluator, node: *const XmlNode, out_err_code: *u32) !u64 {
    const alloc = ev.allocator;
    const brep_id = node.getAttr("id") orelse "brep";
    const feature_hash = topo_id.h64(brep_id);

    // Case 1: Analytic Region B-Rep (<brep id="..." region="..."/>, CDML §4.5)
    if (node.getAttr("region")) |reg_id| {
        const reg_node = ev.regions.get(reg_id) orelse {
            out_err_code.* = types.ERR_UNDEFINED_REF;
            return error.UndefinedRegion;
        };

        if (reg_node.findChild("or") != null) {
            out_err_code.* = types.ERR_REGION_UNBOUNDED;
            return error.RegionUnbounded;
        }

        const container = reg_node.findChild("and") orelse reg_node;
        var terms: std.ArrayList(surface_brep.RegionIneqTerm) = .empty;
        var owned_exprs: std.ArrayList([]u8) = .empty;
        defer {
            for (owned_exprs.items) |s| alloc.free(s);
            owned_exprs.deinit(alloc);
            terms.deinit(alloc);
        }

        for (container.children.items) |ineq_node| {
            if (std.mem.eql(u8, ineq_node.tag, "or")) {
                out_err_code.* = types.ERR_REGION_UNBOUNDED;
                return error.RegionUnbounded;
            }
            if (!std.mem.eql(u8, ineq_node.tag, "ineq")) continue;
            const ineq_id = ineq_node.getAttr("id") orelse "ineq";
            const sense = ineq_node.getAttr("sense") orelse "+";
            const neg = std.mem.eql(u8, sense, "-");

            var raw_expr: []const u8 = std.mem.trim(u8, ineq_node.text, " \t\r\n");
            if (ineq_node.getAttr("surface")) |surf_id| {
                raw_expr = ev.surfaces.get(surf_id) orelse {
                    out_err_code.* = types.ERR_UNDEFINED_REF;
                    return error.UndefinedSurface;
                };
            }

            const final_expr = if (neg) blk: {
                const s = try std.fmt.allocPrint(alloc, "-({s})", .{raw_expr});
                try owned_exprs.append(alloc, s);
                break :blk s;
            } else raw_expr;

            try terms.append(alloc, .{
                .id = ineq_id,
                .branch_hash = topo_id.h64(ineq_id),
                .expr_str = final_expr,
            });
        }

        const h = surface_brep.constructAnalyticRegionBrep(
            memory.persistent_allocator,
            feature_hash,
            terms.items,
            &ev.var_indices,
            ev.var_values.items,
        ) catch |err| {
            out_err_code.* = switch (err) {
                error.RegionUnbounded => types.ERR_REGION_UNBOUNDED,
                error.NonManifoldEdge => types.ERR_NON_MANIFOLD_EDGE,
                error.EulerPoincareFailed => types.ERR_EULER_POINCARE,
                else => types.ERR_REGION_UNBOUNDED,
            };
            return err;
        };
        return h;
    }

    // Case 2: Kinematic SE(3) Sweep + Optional Differential Fillet (§7)
    var solid_h: u64 = 0;

    if (node.findChild("sweep")) |sw_node| {
        const sw_id = sw_node.getAttr("id") orelse "sweep";
        const sk_id = sw_node.getAttr("sketch") orelse "";
        const cap_ends = if (sw_node.getAttr("cap-ends")) |c| std.mem.eql(u8, c, "true") else true;

        const sk = getSketchPtr(ev, sk_id) orelse {
            out_err_code.* = types.ERR_UNDEFINED_REF;
            return error.UndefinedSketch;
        };

        const chart = ev.charts.get(sk.chart_id) orelse ChartDef{
            .id = "default",
            .p0 = Vec3d.init(0.0, 0.0, 0.0),
            .e1 = Vec3d.init(1.0, 0.0, 0.0),
            .e2 = Vec3d.init(0.0, 1.0, 0.0),
        };

        // Evaluate trajectory steps across v in [0, 1]
        var has_rotate = false;
        if (sw_node.findChild("trajectory")) |tr_node| {
            if (tr_node.findChild("rotate") != null) has_rotate = true;
        }
        const n_stations: usize = if (has_rotate) 9 else 2;
        var steps = try alloc.alloc(surface_brep.TrajectoryStep, n_stations);
        defer alloc.free(steps);

        var v_map = std.StringHashMap(u32).init(alloc);
        defer v_map.deinit();
        try v_map.put("v", 0);

        for (0..n_stations) |k| {
            const v_val = @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n_stations - 1));
            var tx: f64 = 0.0;
            var ty: f64 = 0.0;
            var tz: f64 = 0.0;
            var rot_axis = Vec3d.init(0.0, 0.0, 1.0);
            var rot_angle: f64 = 0.0;

            if (sw_node.findChild("trajectory")) |tr_node| {
                if (tr_node.findChild("translate")) |t_node| {
                    if (t_node.getAttr("x-expr") orelse t_node.getAttr("x")) |sx| {
                        if (autodiff.compileExpressionFull(alloc, sx, .residual, &v_map, &ev.const_values, null)) |ce| {
                            var mut_ce = ce;
                            defer mut_ce.deinit();
                            tx = mut_ce.evalScalar(&[_]f64{v_val});
                        } else |_| {}
                    }
                    if (t_node.getAttr("y-expr") orelse t_node.getAttr("y")) |sy| {
                        if (autodiff.compileExpressionFull(alloc, sy, .residual, &v_map, &ev.const_values, null)) |ce| {
                            var mut_ce = ce;
                            defer mut_ce.deinit();
                            ty = mut_ce.evalScalar(&[_]f64{v_val});
                        } else |_| {}
                    }
                    if (t_node.getAttr("z-expr") orelse t_node.getAttr("z")) |sz| {
                        if (autodiff.compileExpressionFull(alloc, sz, .residual, &v_map, &ev.const_values, null)) |ce| {
                            var mut_ce = ce;
                            defer mut_ce.deinit();
                            tz = mut_ce.evalScalar(&[_]f64{v_val});
                        } else |_| {}
                    }
                }
                if (tr_node.findChild("rotate")) |r_node| {
                    if (r_node.getAttr("axis")) |ax_str| {
                        var ax_it = std.mem.tokenizeAny(u8, ax_str, " \t\r\n");
                        const ax = if (ax_it.next()) |s| (std.fmt.parseFloat(f64, s) catch 0.0) else 0.0;
                        const ay = if (ax_it.next()) |s| (std.fmt.parseFloat(f64, s) catch 0.0) else 0.0;
                        const az = if (ax_it.next()) |s| (std.fmt.parseFloat(f64, s) catch 1.0) else 1.0;
                        rot_axis = Vec3d.init(ax, ay, az);
                    }
                    if (r_node.getAttr("angle-expr") orelse r_node.getAttr("angle")) |ang_str| {
                        if (autodiff.compileExpressionFull(alloc, ang_str, .residual, &v_map, &ev.const_values, null)) |ce| {
                            var mut_ce = ce;
                            defer mut_ce.deinit();
                            rot_angle = mut_ce.evalScalar(&[_]f64{v_val});
                        } else |_| {}
                    }
                }
            }

            steps[k] = .{
                .v = v_val,
                .translation = Vec3d.init(tx, ty, tz),
                .axis = rot_axis,
                .angle_rad = rot_angle,
            };
        }

        const outer_l = surface_brep.ProfileLoop2D{
            .wire_id = sk.outer_loops.items[0].wire_id,
            .is_hole = false,
            .points = sk.outer_loops.items[0].samples.items,
        };

        var hole_slice = try alloc.alloc(surface_brep.ProfileLoop2D, sk.hole_loops.items.len);
        defer alloc.free(hole_slice);
        for (sk.hole_loops.items, 0..) |hl, hi| {
            hole_slice[hi] = .{
                .wire_id = hl.wire_id,
                .is_hole = true,
                .points = hl.samples.items,
            };
        }

        solid_h = surface_brep.sweepProfileLoopsSE3(
            memory.persistent_allocator,
            feature_hash,
            topo_id.h64(sw_id),
            chart.p0,
            chart.e1,
            chart.e2,
            outer_l,
            hole_slice,
            steps,
            cap_ends,
        ) catch |err| {
            out_err_code.* = types.ERR_SWEEP_SELF_INTERSECT;
            return err;
        };
    } else if (node.findChild("solid_extrude")) |ext_node| {
        const ext_id = ext_node.getAttr("id") orelse "extrude";
        const sk_id = ext_node.getAttr("sketch") orelse "";
        const dist_str = ext_node.getAttr("distance") orelse "10.0";
        const dist = ev.evaluateExpression(dist_str, .residual) catch 10.0;
        const dir_str = ext_node.getAttr("direction") orelse "vec3(0, 0, 1)";
        var dir = parseVec3(dir_str);
        if (dir.length() < 1e-9) dir = Vec3d.init(0.0, 0.0, 1.0);
        dir = dir.normalize();

        const sk = getSketchPtr(ev, sk_id) orelse {
            out_err_code.* = types.ERR_UNDEFINED_REF;
            return error.UndefinedSketch;
        };

        const chart = ev.charts.get(sk.chart_id) orelse ChartDef{
            .id = "default",
            .p0 = Vec3d.init(0.0, 0.0, 0.0),
            .e1 = Vec3d.init(1.0, 0.0, 0.0),
            .e2 = Vec3d.init(0.0, 1.0, 0.0),
        };

        if (sk.outer_loops.items.len == 0) {
            out_err_code.* = types.ERR_PROFILE_INVALID;
            return error.ProfileInvalid;
        }

        const outer_l = surface_brep.ProfileLoop2D{
            .wire_id = sk.outer_loops.items[0].wire_id,
            .is_hole = false,
            .points = sk.outer_loops.items[0].samples.items,
        };

        var hole_slice = try alloc.alloc(surface_brep.ProfileLoop2D, sk.hole_loops.items.len);
        defer alloc.free(hole_slice);
        for (sk.hole_loops.items, 0..) |hl, hi| {
            hole_slice[hi] = .{
                .wire_id = hl.wire_id,
                .is_hole = true,
                .points = hl.samples.items,
            };
        }

        var steps = try alloc.alloc(surface_brep.TrajectoryStep, 2);
        defer alloc.free(steps);
        steps[0] = .{
            .v = 0.0,
            .translation = Vec3d.init(0.0, 0.0, 0.0),
            .axis = Vec3d.init(0.0, 0.0, 1.0),
            .angle_rad = 0.0,
        };
        steps[1] = .{
            .v = 1.0,
            .translation = dir.scale(dist),
            .axis = Vec3d.init(0.0, 0.0, 1.0),
            .angle_rad = 0.0,
        };

        solid_h = surface_brep.sweepProfileLoopsSE3(
            memory.persistent_allocator,
            feature_hash,
            topo_id.h64(ext_id),
            chart.p0,
            chart.e1,
            chart.e2,
            outer_l,
            hole_slice,
            steps,
            true,
        ) catch |err| {
            out_err_code.* = types.ERR_SWEEP_SELF_INTERSECT;
            return err;
        };
    } else if (node.findChild("solid_revolve")) |rev_node| {
        const rev_id = rev_node.getAttr("id") orelse "revolve";
        const sk_id = rev_node.getAttr("sketch") orelse "";
        const ang_str = rev_node.getAttr("angle") orelse "360.0";
        const ang_deg = ev.evaluateExpression(ang_str, .residual) catch 360.0;
        const ang_rad = (ang_deg * std.math.pi) / 180.0;

        const orig_str = rev_node.getAttr("axis_origin") orelse "vec3(0, 0, 0)";
        const axis_orig = parseVec3(orig_str);

        const dir_str = rev_node.getAttr("axis_direction") orelse "vec3(0, 0, 1)";
        var axis_dir = parseVec3(dir_str);
        if (axis_dir.length() < 1e-9) axis_dir = Vec3d.init(0.0, 0.0, 1.0);
        axis_dir = axis_dir.normalize();

        const sk = getSketchPtr(ev, sk_id) orelse {
            out_err_code.* = types.ERR_UNDEFINED_REF;
            return error.UndefinedSketch;
        };

        const chart = ev.charts.get(sk.chart_id) orelse ChartDef{
            .id = "default",
            .p0 = Vec3d.init(0.0, 0.0, 0.0),
            .e1 = Vec3d.init(1.0, 0.0, 0.0),
            .e2 = Vec3d.init(0.0, 1.0, 0.0),
        };

        if (sk.outer_loops.items.len == 0) {
            out_err_code.* = types.ERR_PROFILE_INVALID;
            return error.ProfileInvalid;
        }

        const outer_l = surface_brep.ProfileLoop2D{
            .wire_id = sk.outer_loops.items[0].wire_id,
            .is_hole = false,
            .points = sk.outer_loops.items[0].samples.items,
        };

        solid_h = surface_brep.revolveProfileLoops(
            memory.persistent_allocator,
            feature_hash,
            topo_id.h64(rev_id),
            chart.p0,
            chart.e1,
            chart.e2,
            outer_l,
            axis_orig,
            axis_dir,
            ang_rad,
            32,
        ) catch |err| {
            out_err_code.* = types.ERR_SWEEP_SELF_INTERSECT;
            return err;
        };
    }

    if (node.findChild("fillet")) |f_node| {
        const f_id = f_node.getAttr("id") orelse "fillet";
        const r_str = f_node.getAttr("radius-expr") orelse (f_node.getAttr("radius") orelse "0.0");
        const r_val = ev.evaluateExpression(r_str, .residual) catch 0.0;
        const edge_pred = f_node.getAttr("edge-predicate") orelse "";

        if (solid_h == 0) {
            out_err_code.* = types.ERR_FILLET_RADIUS_COLLAPSE;
            return error.FilletRadiusCollapse;
        }

        solid_h = surface_brep.applyEdgePredicateFillet(
            alloc,
            solid_h,
            topo_id.h64(f_id),
            edge_pred,
            r_val,
            0.05,
            &ev.var_indices,
            ev.var_values.items,
        ) catch |err| {
            surface_brep.solid_free(solid_h);
            out_err_code.* = types.ERR_FILLET_RADIUS_COLLAPSE;
            return err;
        };
    }

    if (solid_h == 0) {
        out_err_code.* = types.ERR_SWEEP_SELF_INTERSECT;
        return error.EmptyBrep;
    }

    return solid_h;
}

// ============================================================================
// Implicit Solid Construction (<implicit>, CDML §4.5 & §8)
// ============================================================================

fn buildRegionImplicitExpr(ev: *DocumentEvaluator, node: *const XmlNode, alloc: std.mem.Allocator) ![]u8 {
    if (std.mem.eql(u8, node.tag, "and") or std.mem.eql(u8, node.tag, "or") or std.mem.eql(u8, node.tag, "region")) {
        const is_or = std.mem.eql(u8, node.tag, "or");
        const fn_name = if (is_or) "r_union" else "r_intersect";

        var current: ?[]u8 = null;
        errdefer if (current) |c| alloc.free(c);

        for (node.children.items) |child| {
            const sub = try buildRegionImplicitExpr(ev, child, alloc);
            if (current == null) {
                current = sub;
            } else {
                const combined = try std.fmt.allocPrint(alloc, "{s}({s}, {s})", .{ fn_name, current.?, sub });
                alloc.free(current.?);
                alloc.free(sub);
                current = combined;
            }
        }
        return current orelse alloc.dupe(u8, "-1.0");
    } else if (std.mem.eql(u8, node.tag, "ineq")) {
        const sense = node.getAttr("sense") orelse "+";
        const neg = std.mem.eql(u8, sense, "-");
        var raw_expr: []const u8 = std.mem.trim(u8, node.text, " \t\r\n");
        if (node.getAttr("surface")) |s_id| {
            raw_expr = ev.surfaces.get(s_id) orelse "0.0";
        }
        // Region convention: f_i >= 0 inside; Implicit convention: F_i = -f_i <= 0 inside
        if (neg) {
            return std.fmt.allocPrint(alloc, "({s})", .{raw_expr});
        } else {
            return std.fmt.allocPrint(alloc, "-({s})", .{raw_expr});
        }
    }
    return alloc.dupe(u8, "-1.0");
}

fn constructImplicitSolid(ev: *DocumentEvaluator, node: *const XmlNode) !u64 {
    const alloc = ev.allocator;
    var domain_bbox = [6]f64{ -45.0, -45.0, 0.0, 45.0, 45.0, 16.0 };
    var parsed_depth: u5 = 4;
    var qef_reg: f64 = 1e-4;

    if (node.findChild("domain")) |d_node| {
        if (d_node.getAttr("xmin")) |s| domain_bbox[0] = ev.evaluateExpression(s, .residual) catch -45.0;
        if (d_node.getAttr("ymin")) |s| domain_bbox[1] = ev.evaluateExpression(s, .residual) catch -45.0;
        if (d_node.getAttr("zmin")) |s| domain_bbox[2] = ev.evaluateExpression(s, .residual) catch 0.0;
        if (d_node.getAttr("xmax")) |s| domain_bbox[3] = ev.evaluateExpression(s, .residual) catch 45.0;
        if (d_node.getAttr("ymax")) |s| domain_bbox[4] = ev.evaluateExpression(s, .residual) catch 45.0;
        if (d_node.getAttr("zmax")) |s| domain_bbox[5] = ev.evaluateExpression(s, .residual) catch 16.0;
        if (d_node.getAttr("octree-depth")) |s| {
            const d_val = std.fmt.parseInt(u32, s, 10) catch 5;
            parsed_depth = if (d_val == 5) 5 else @intCast(std.math.clamp(d_val, 2, 4));
        }
        if (d_node.getAttr("qef-reg")) |s| {
            qef_reg = std.fmt.parseFloat(f64, s) catch 1e-4;
        }
    }

    // Update field slot bounding boxes to match domain
    var it_fs = ev.field_slots.iterator();
    while (it_fs.next()) |entry| {
        const fs = entry.value_ptr.*;
        autodiff.configureFieldSlot(
            fs.slot,
            fs.grid_x,
            fs.grid_y,
            fs.grid_z,
            domain_bbox[0],
            domain_bbox[1],
            domain_bbox[2],
            domain_bbox[3],
            domain_bbox[4],
            domain_bbox[5],
        );
    }

    // Collect local <def name="..." expr="..."/> macros
    var local_defs = std.StringHashMap([]const u8).init(alloc);
    defer local_defs.deinit();
    for (node.children.items) |child| {
        if (std.mem.eql(u8, child.tag, "def")) {
            const d_name = child.getAttr("name") orelse continue;
            const d_expr = child.getAttr("expr") orelse continue;
            try local_defs.put(d_name, d_expr);
        }
    }

    var owned_reg_expr: ?[]u8 = null;
    defer if (owned_reg_expr) |s| alloc.free(s);

    var field_expr_str: []const u8 = "x^2 + y^2 + z^2 - 100.0";
    if (node.getAttr("region")) |reg_id| {
        const reg_node = ev.regions.get(reg_id) orelse return error.UndefinedRegion;
        owned_reg_expr = try buildRegionImplicitExpr(ev, reg_node, alloc);
        field_expr_str = owned_reg_expr.?;
    } else if (node.findChild("field")) |f_node| {
        if (f_node.getAttr("expr")) |e| {
            field_expr_str = e;
        }
    }

    const compiled = try autodiff.compileExpressionFull(memory.persistent_allocator, field_expr_str, .field, null, &ev.const_values, &local_defs);
    const expr_h = autodiff.registerCompiledExpression(compiled);
    if (expr_h == 0) return error.CompileFailed;

    const solid_h = implicit_field.solid_implicit_field_WithParams(expr_h, &domain_bbox, parsed_depth, qef_reg);
    if (solid_h == 0 or implicit_field.last_implicit_status != 0) {
        return error.ImplicitGradZero;
    }
    return solid_h;
}

// ============================================================================
// CSG Solid Construction (<csg>, CDML §9)
// ============================================================================

fn constructCsgSolid(ev: *DocumentEvaluator, node: *const XmlNode) !u64 {
    var last_h: u64 = 0;

    for (node.children.items) |b_node| {
        if (!std.mem.eql(u8, b_node.tag, "boolean")) continue;
        const b_id = b_node.getAttr("id") orelse "boolean";
        const l_id = b_node.getAttr("left") orelse "";
        const r_id = b_node.getAttr("right") orelse "";
        const op_str = b_node.getAttr("op") orelse "union";

        const left_h = ev.solids.get(l_id) orelse return error.UndefinedSolid;
        const right_h = ev.solids.get(r_id) orelse return error.UndefinedSolid;

        const op: u32 = if (std.mem.eql(u8, op_str, "union"))
            0
        else if (std.mem.eql(u8, op_str, "intersect"))
            2
        else
            1;

        if (ev.solids.get(b_id)) |old_h| {
            surface_brep.solid_free(old_h);
        }
        const h = surface_brep.solid_boolean(op, left_h, right_h);
        if (h == 0) return error.CsgFailed;
        ev.solids.put(b_id, h) catch {};
        last_h = h;
    }

    if (last_h == 0) return error.EmptyCsg;
    return last_h;
}

// ============================================================================
// Probe Evaluation (<probe>, CDML §10.2)
// ============================================================================

fn evaluateProbeNode(ev: *DocumentEvaluator, node: *const XmlNode) u32 {
    const alloc = ev.allocator;
    const id = node.getAttr("id") orelse return types.CDML_OK;
    const p_type = node.getAttr("type") orelse "volume";
    const target_id = node.getAttr("target") orelse "";
    const face_pred_str = node.getAttr("face-predicate") orelse "";
    const quant_str = node.getAttr("quantity") orelse "1.0";

    const target_h = ev.solids.get(target_id) orelse ev.active_solid_h;
    const mesh = tess_export.getSolidMesh(target_h) orelse {
        setDiagnostic(types.ERR_PROBE_NO_MATCH, id, "Probe target solid has no mesh", node.line);
        return types.ERR_PROBE_NO_MATCH;
    };

    var computed_val: f64 = 0.0;

    if (std.mem.eql(u8, p_type, "volume")) {
        computed_val = mesh.computeEnclosedVolume();
    } else if (std.mem.eql(u8, p_type, "face-mean") or
        std.mem.eql(u8, p_type, "face-max") or
        std.mem.eql(u8, p_type, "face-min") or
        std.mem.eql(u8, p_type, "face-sum"))
    {
        var maybe_pred: ?autodiff.Expression = null;
        defer if (maybe_pred) |*p| p.deinit();
        if (face_pred_str.len > 0) {
            maybe_pred = autodiff.compileExpressionFull(alloc, face_pred_str, .predicate, null, &ev.const_values, null) catch {
                setDiagnostic(types.ERR_UNDEFINED_REF, id, "Failed to compile probe face-predicate", node.line);
                return types.ERR_UNDEFINED_REF;
            };
        }

        var quant_expr = autodiff.compileExpressionFull(alloc, quant_str, .predicate, null, &ev.const_values, null) catch {
            setDiagnostic(types.ERR_UNDEFINED_REF, id, "Failed to compile probe quantity expression", node.line);
            return types.ERR_UNDEFINED_REF;
        };
        defer quant_expr.deinit();

        const tri_count = mesh.indices.items.len / 3;
        var match_count: usize = 0;
        var weighted_sum: f64 = 0.0;
        var total_area: f64 = 0.0;
        var raw_sum: f64 = 0.0;
        var max_val: f64 = -1e300;
        var min_val: f64 = 1e300;

        for (0..tri_count) |t| {
            const idx0 = mesh.indices.items[t * 3 + 0];
            const idx1 = mesh.indices.items[t * 3 + 1];
            const idx2 = mesh.indices.items[t * 3 + 2];
            const p0 = mesh.vertices.items[idx0];
            const p1 = mesh.vertices.items[idx1];
            const p2 = mesh.vertices.items[idx2];

            const e1 = p1.sub(p0);
            const e2 = p2.sub(p0);
            const cr = e1.cross(e2);
            const tri_area = 0.5 * cr.length();
            const normal = cr.normalize();
            const centroid = p0.add(p1).add(p2).scale(1.0 / 3.0);
            const tang = e1.normalize();
            const curv = mesh.getCurvature(t);

            if (t < mesh.triangle_to_topo_id.items.len) {
                autodiff.setCurrentTopoId(mesh.triangle_to_topo_id.items[t]);
            }

            const pred_vars = [15]f64{
                centroid.x,
                centroid.y,
                centroid.z,
                normal.x,
                normal.y,
                normal.z,
                tang.x,
                tang.y,
                tang.z,
                curv.k_min,
                curv.k_max,
                curv.k_gauss,
                curv.k_mean,
                tri_area,
                e1.length(),
            };

            const matched = if (maybe_pred) |*pred| (pred.evalScalar(&pred_vars) != 0.0) else true;
            if (matched) {
                match_count += 1;
                const q = quant_expr.evalScalar(&pred_vars);
                weighted_sum += q * tri_area;
                total_area += tri_area;
                raw_sum += q;
                if (q > max_val) max_val = q;
                if (q < min_val) min_val = q;
            }
        }

        if (match_count == 0) {
            setDiagnostic(types.ERR_PROBE_NO_MATCH, id, "Zero topological entities matched probe face-predicate", node.line);
            return types.ERR_PROBE_NO_MATCH;
        }

        if (std.mem.eql(u8, p_type, "face-mean")) {
            computed_val = if (total_area > 1e-12) weighted_sum / total_area else raw_sum / @as(f64, @floatFromInt(match_count));
        } else if (std.mem.eql(u8, p_type, "face-max")) {
            computed_val = max_val;
        } else if (std.mem.eql(u8, p_type, "face-min")) {
            computed_val = min_val;
        } else {
            computed_val = raw_sum;
        }
    }

    ev.probes.put(id, .{
        .id = id,
        .probe_type = p_type,
        .target = target_id,
        .face_predicate = face_pred_str,
        .quantity = quant_str,
        .value = computed_val,
    }) catch {};
    autodiff.setProbeValue(id, computed_val) catch {};

    return types.CDML_OK;
}

// ============================================================================
// Hash Collision Audit Helper
// ============================================================================

fn checkIdHashCollisions(node: *const XmlNode, seen_hashes: *std.AutoHashMap(u64, []const u8)) ?[]const u8 {
    if (node.getAttr("id")) |id| {
        const h = topo_id.h64(id);
        if (seen_hashes.get(h)) |existing_id| {
            if (!std.mem.eql(u8, existing_id, id)) {
                return id;
            }
        } else {
            seen_hashes.put(h, id) catch {};
        }
    }
    for (node.children.items) |child| {
        if (checkIdHashCollisions(child, seen_hashes)) |colliding| {
            return colliding;
        }
    }
    return null;
}
