const std = @import("std");
const memory = @import("memory.zig");
const topo_id_mod = @import("topo/topo_id.zig");
pub const TopoId = topo_id_mod.TopoId;
pub const h64 = topo_id_mod.h64;

// ============================================================================
// Dual Numbers for Exact Analytical Forward-Mode Automatic Differentiation
// ============================================================================

pub const Dual = struct {
    val: f64,
    der: f64,

    pub fn constant(v: f64) Dual {
        return .{ .val = v, .der = 0.0 };
    }

    pub fn variable(v: f64, is_seed: bool) Dual {
        return .{ .val = v, .der = if (is_seed) 1.0 else 0.0 };
    }

    pub fn add(a: Dual, b: Dual) Dual {
        return .{ .val = a.val + b.val, .der = a.der + b.der };
    }

    pub fn sub(a: Dual, b: Dual) Dual {
        return .{ .val = a.val - b.val, .der = a.der - b.der };
    }

    pub fn mul(a: Dual, b: Dual) Dual {
        return .{
            .val = a.val * b.val,
            .der = a.val * b.der + a.der * b.val,
        };
    }

    pub fn div(a: Dual, b: Dual) Dual {
        const inv_b = 1.0 / b.val;
        return .{
            .val = a.val * inv_b,
            .der = (a.der * b.val - a.val * b.der) * (inv_b * inv_b),
        };
    }

    pub fn neg(a: Dual) Dual {
        return .{ .val = -a.val, .der = -a.der };
    }

    pub fn sqr(a: Dual) Dual {
        return .{
            .val = a.val * a.val,
            .der = 2.0 * a.val * a.der,
        };
    }

    pub fn sqrt(a: Dual) Dual {
        const s = @sqrt(@max(0.0, a.val));
        return .{
            .val = s,
            .der = if (s > 1e-15) a.der / (2.0 * s) else 0.0,
        };
    }

    pub fn sin(a: Dual) Dual {
        return .{
            .val = @sin(a.val),
            .der = a.der * @cos(a.val),
        };
    }

    pub fn cos(a: Dual) Dual {
        return .{
            .val = @cos(a.val),
            .der = -a.der * @sin(a.val),
        };
    }

    pub fn exp(a: Dual) Dual {
        const v = @exp(a.val);
        return .{ .val = v, .der = v * a.der };
    }

    pub fn log(a: Dual) Dual {
        const v = @log(@max(1e-15, a.val));
        return .{ .val = v, .der = if (@abs(a.val) > 1e-15) a.der / a.val else 0.0 };
    }

    pub fn abs(a: Dual) Dual {
        const v = @abs(a.val);
        const d = if (a.val > 0.0) a.der else if (a.val < 0.0) -a.der else 0.0;
        return .{ .val = v, .der = d };
    }

    pub fn absSmooth(u: Dual, eps: Dual) Dual {
        const s = @sqrt(u.val * u.val + eps.val * eps.val);
        const d = if (s > 1e-15) (u.val * u.der + eps.val * eps.der) / s else 0.0;
        return .{ .val = s, .der = d };
    }

    pub fn rUnion(u: Dual, v: Dual) Dual {
        const s = @sqrt(u.val * u.val + v.val * v.val);
        const val = u.val + v.val - s;
        const der = if (s > 1e-15)
            u.der * (1.0 - u.val / s) + v.der * (1.0 - v.val / s)
        else
            u.der + v.der;
        return .{ .val = val, .der = der };
    }

    pub fn rIntersect(u: Dual, v: Dual) Dual {
        const s = @sqrt(u.val * u.val + v.val * v.val);
        const val = u.val + v.val + s;
        const der = if (s > 1e-15)
            u.der * (1.0 + u.val / s) + v.der * (1.0 + v.val / s)
        else
            u.der + v.der;
        return .{ .val = val, .der = der };
    }

    pub fn pow(a: Dual, p: f64) Dual {
        if (p == 2.0) return a.sqr();
        if (p == 0.5) return a.sqrt();
        if (p == 0.0) return constant(1.0);
        if (p == 1.0) return a;
        const val = std.math.pow(f64, a.val, p);
        const der = if (std.math.approxEqAbs(f64, a.val, 0.0, 1e-15))
            0.0
        else
            p * std.math.pow(f64, a.val, p - 1.0) * a.der;
        return .{ .val = val, .der = der };
    }
};

// ============================================================================
// Interval Arithmetic for Range Bounding (§3.2)
// ============================================================================

pub const Interval = struct {
    min: f64,
    max: f64,

    pub fn init(min: f64, max: f64) Interval {
        return .{ .min = @min(min, max), .max = @max(min, max) };
    }

    pub fn point(v: f64) Interval {
        return .{ .min = v, .max = v };
    }

    pub fn add(a: Interval, b: Interval) Interval {
        return .{ .min = a.min + b.min, .max = a.max + b.max };
    }

    pub fn sub(a: Interval, b: Interval) Interval {
        return .{ .min = a.min - b.max, .max = a.max - b.min };
    }

    pub fn mul(a: Interval, b: Interval) Interval {
        const p1 = a.min * b.min;
        const p2 = a.min * b.max;
        const p3 = a.max * b.min;
        const p4 = a.max * b.max;
        return .{
            .min = @min(@min(p1, p2), @min(p3, p4)),
            .max = @max(@max(p1, p2), @max(p3, p4)),
        };
    }

    pub fn sqr(a: Interval) Interval {
        if (a.min <= 0.0 and a.max >= 0.0) {
            return .{ .min = 0.0, .max = @max(a.min * a.min, a.max * a.max) };
        } else {
            const sq1 = a.min * a.min;
            const sq2 = a.max * a.max;
            return .{ .min = @min(sq1, sq2), .max = @max(sq1, sq2) };
        }
    }
};

// ============================================================================
// SSA Bytecode Instruction Set (CDML §3.3)
// ============================================================================

pub const OpCode = enum(u8) {
    Const = 0x01,
    Var = 0x02,
    Add = 0x10,
    Sub = 0x11,
    Mul = 0x12,
    Div = 0x13,
    Pow = 0x14,
    Sin = 0x20,
    Cos = 0x21,
    Exp = 0x22,
    Log = 0x23,
    Sqrt = 0x24,
    AbsSmooth = 0x25,
    Abs = 0x26,
    RUnion = 0x30,
    RIntersect = 0x31,
    Lt = 0x32,
    Gt = 0x33,
    And = 0x34,
    Or = 0x35,
    FieldSample = 0x40,
    Probe = 0x41,
    FromId = 0x42,
};

pub const Instruction = union(OpCode) {
    Const: f64,
    Var: u32,
    Add: void,
    Sub: void,
    Mul: void,
    Div: void,
    Pow: void,
    Sin: void,
    Cos: void,
    Exp: void,
    Log: void,
    Sqrt: void,
    AbsSmooth: void,
    Abs: void,
    RUnion: void,
    RIntersect: void,
    Lt: void,
    Gt: void,
    And: void,
    Or: void,
    FieldSample: u32,
    Probe: []const u8,
    FromId: u64,
};

pub const ExprContext = enum {
    field,
    residual,
    predicate,
};

// Active evaluation state
pub var current_topo_id: TopoId = TopoId.INVALID;
pub var global_probe_cache: std.StringHashMap(f64) = std.StringHashMap(f64).init(std.heap.page_allocator);

pub fn setCurrentTopoId(tid: TopoId) void {
    current_topo_id = tid;
}

pub fn setProbeValue(id: []const u8, val: f64) !void {
    try global_probe_cache.put(id, val);
}

pub fn getProbeValue(id: []const u8) ?f64 {
    return global_probe_cache.get(id);
}

pub const Expression = struct {
    instructions: []Instruction,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Expression) void {
        self.allocator.free(self.instructions);
    }

    pub fn evalScalar(self: *const Expression, vars: []const f64) f64 {
        var stack: [128]f64 = undefined;
        var sp: usize = 0;

        for (self.instructions) |inst| {
            switch (inst) {
                .Const => |c| {
                    stack[sp] = c;
                    sp += 1;
                },
                .Var => |idx| {
                    stack[sp] = if (idx < vars.len) vars[idx] else 0.0;
                    sp += 1;
                },
                .Add => {
                    sp -= 1;
                    stack[sp - 1] += stack[sp];
                },
                .Sub => {
                    sp -= 1;
                    stack[sp - 1] -= stack[sp];
                },
                .Mul => {
                    sp -= 1;
                    stack[sp - 1] *= stack[sp];
                },
                .Div => {
                    sp -= 1;
                    stack[sp - 1] /= stack[sp];
                },
                .Pow => {
                    sp -= 1;
                    stack[sp - 1] = std.math.pow(f64, stack[sp - 1], stack[sp]);
                },
                .Sin => {
                    stack[sp - 1] = @sin(stack[sp - 1]);
                },
                .Cos => {
                    stack[sp - 1] = @cos(stack[sp - 1]);
                },
                .Exp => {
                    stack[sp - 1] = @exp(stack[sp - 1]);
                },
                .Log => {
                    stack[sp - 1] = @log(@max(1e-15, stack[sp - 1]));
                },
                .Sqrt => {
                    stack[sp - 1] = @sqrt(@max(0.0, stack[sp - 1]));
                },
                .AbsSmooth => {
                    sp -= 1;
                    const eps = stack[sp];
                    const u = stack[sp - 1];
                    stack[sp - 1] = @sqrt(u * u + eps * eps);
                },
                .Abs => {
                    stack[sp - 1] = @abs(stack[sp - 1]);
                },
                .RUnion => {
                    sp -= 1;
                    const v = stack[sp];
                    const u = stack[sp - 1];
                    stack[sp - 1] = u + v - @sqrt(u * u + v * v);
                },
                .RIntersect => {
                    sp -= 1;
                    const v = stack[sp];
                    const u = stack[sp - 1];
                    stack[sp - 1] = u + v + @sqrt(u * u + v * v);
                },
                .Lt => {
                    sp -= 1;
                    stack[sp - 1] = if (stack[sp - 1] < stack[sp]) 1.0 else 0.0;
                },
                .Gt => {
                    sp -= 1;
                    stack[sp - 1] = if (stack[sp - 1] > stack[sp]) 1.0 else 0.0;
                },
                .And => {
                    sp -= 1;
                    stack[sp - 1] = if (stack[sp - 1] != 0.0 and stack[sp] != 0.0) 1.0 else 0.0;
                },
                .Or => {
                    sp -= 1;
                    stack[sp - 1] = if (stack[sp - 1] != 0.0 or stack[sp] != 0.0) 1.0 else 0.0;
                },
                .FieldSample => {
                    // Defaults to 40.0 if not populated
                    stack[sp] = 40.0;
                    sp += 1;
                },
                .Probe => |id| {
                    stack[sp] = getProbeValue(id) orelse 0.0;
                    sp += 1;
                },
                .FromId => |target_h64| {
                    const match = current_topo_id.matchesId(target_h64);
                    stack[sp] = if (match) 1.0 else 0.0;
                    sp += 1;
                },
            }
        }

        return if (sp > 0) stack[sp - 1] else 0.0;
    }

    pub fn evalDual(self: *const Expression, vars: []const Dual) Dual {
        var stack: [128]Dual = undefined;
        var sp: usize = 0;

        for (self.instructions) |inst| {
            switch (inst) {
                .Const => |c| {
                    stack[sp] = Dual.constant(c);
                    sp += 1;
                },
                .Var => |idx| {
                    stack[sp] = if (idx < vars.len) vars[idx] else Dual.constant(0.0);
                    sp += 1;
                },
                .Add => {
                    sp -= 1;
                    stack[sp - 1] = stack[sp - 1].add(stack[sp]);
                },
                .Sub => {
                    sp -= 1;
                    stack[sp - 1] = stack[sp - 1].sub(stack[sp]);
                },
                .Mul => {
                    sp -= 1;
                    stack[sp - 1] = stack[sp - 1].mul(stack[sp]);
                },
                .Div => {
                    sp -= 1;
                    stack[sp - 1] = stack[sp - 1].div(stack[sp]);
                },
                .Pow => {
                    sp -= 1;
                    stack[sp - 1] = stack[sp - 1].pow(stack[sp].val);
                },
                .Sin => {
                    stack[sp - 1] = stack[sp - 1].sin();
                },
                .Cos => {
                    stack[sp - 1] = stack[sp - 1].cos();
                },
                .Exp => {
                    stack[sp - 1] = stack[sp - 1].exp();
                },
                .Log => {
                    stack[sp - 1] = stack[sp - 1].log();
                },
                .Sqrt => {
                    stack[sp - 1] = stack[sp - 1].sqrt();
                },
                .AbsSmooth => {
                    sp -= 1;
                    stack[sp - 1] = stack[sp - 1].absSmooth(stack[sp]);
                },
                .Abs => {
                    stack[sp - 1] = stack[sp - 1].abs();
                },
                .RUnion => {
                    sp -= 1;
                    stack[sp - 1] = stack[sp - 1].rUnion(stack[sp]);
                },
                .RIntersect => {
                    sp -= 1;
                    stack[sp - 1] = stack[sp - 1].rIntersect(stack[sp]);
                },
                .Lt => {
                    sp -= 1;
                    const v: f64 = if (stack[sp - 1].val < stack[sp].val) 1.0 else 0.0;
                    stack[sp - 1] = Dual.constant(v);
                },
                .Gt => {
                    sp -= 1;
                    const v: f64 = if (stack[sp - 1].val > stack[sp].val) 1.0 else 0.0;
                    stack[sp - 1] = Dual.constant(v);
                },
                .And => {
                    sp -= 1;
                    const v: f64 = if (stack[sp - 1].val != 0.0 and stack[sp].val != 0.0) 1.0 else 0.0;
                    stack[sp - 1] = Dual.constant(v);
                },
                .Or => {
                    sp -= 1;
                    const v: f64 = if (stack[sp - 1].val != 0.0 or stack[sp].val != 0.0) 1.0 else 0.0;
                    stack[sp - 1] = Dual.constant(v);
                },
                .FieldSample => {
                    stack[sp] = Dual.constant(40.0);
                    sp += 1;
                },
                .Probe => |id| {
                    const v = getProbeValue(id) orelse 0.0;
                    stack[sp] = Dual.constant(v);
                    sp += 1;
                },
                .FromId => |target_h64| {
                    const match = current_topo_id.matchesId(target_h64);
                    stack[sp] = Dual.constant(if (match) 1.0 else 0.0);
                    sp += 1;
                },
            }
        }

        return if (sp > 0) stack[sp - 1] else Dual.constant(0.0);
    }

    pub fn evalGrad(self: *const Expression, vars: []const f64, out_grad: ?[]f64) f64 {
        const val = self.evalScalar(vars);
        if (out_grad) |grad| {
            var dual_vars: [64]Dual = undefined;
            const n = @min(vars.len, 64);

            for (0..grad.len) |target_var| {
                for (0..n) |i| {
                    dual_vars[i] = Dual.variable(vars[i], i == target_var);
                }
                const res = self.evalDual(dual_vars[0..n]);
                grad[target_var] = res.der;
            }
        }
        return val;
    }

    pub fn evalInterval(self: *const Expression, vars: []const Interval) Interval {
        var stack: [128]Interval = undefined;
        var sp: usize = 0;

        for (self.instructions) |inst| {
            switch (inst) {
                .Const => |c| {
                    stack[sp] = Interval.point(c);
                    sp += 1;
                },
                .Var => |idx| {
                    stack[sp] = if (idx < vars.len) vars[idx] else Interval.point(0.0);
                    sp += 1;
                },
                .Add => {
                    sp -= 1;
                    stack[sp - 1] = stack[sp - 1].add(stack[sp]);
                },
                .Sub => {
                    sp -= 1;
                    stack[sp - 1] = stack[sp - 1].sub(stack[sp]);
                },
                .Mul => {
                    sp -= 1;
                    stack[sp - 1] = stack[sp - 1].mul(stack[sp]);
                },
                .Div => {
                    sp -= 1;
                    const inv_b = if (stack[sp].min != 0.0) 1.0 / stack[sp].min else 1.0;
                    stack[sp - 1] = stack[sp - 1].mul(Interval.point(inv_b));
                },
                .Pow => {
                    sp -= 1;
                    stack[sp - 1] = stack[sp - 1].sqr();
                },
                .Sin, .Cos => {
                    stack[sp - 1] = Interval.init(-1.0, 1.0);
                },
                .Exp => {
                    stack[sp - 1] = Interval.init(@exp(stack[sp - 1].min), @exp(stack[sp - 1].max));
                },
                .Log => {
                    stack[sp - 1] = Interval.init(@log(@max(1e-15, stack[sp - 1].min)), @log(@max(1e-15, stack[sp - 1].max)));
                },
                .Sqrt => {
                    stack[sp - 1] = Interval.init(@sqrt(@max(0.0, stack[sp - 1].min)), @sqrt(@max(0.0, stack[sp - 1].max)));
                },
                .AbsSmooth => {
                    sp -= 1;
                    const u = stack[sp - 1];
                    const eps = stack[sp];
                    stack[sp - 1] = Interval.init(eps.min, @sqrt(u.max * u.max + eps.max * eps.max));
                },
                .Abs => {
                    const u = stack[sp - 1];
                    stack[sp - 1] = Interval.init(0.0, @max(@abs(u.min), @abs(u.max)));
                },
                .RUnion, .RIntersect => {
                    sp -= 1;
                    stack[sp - 1] = stack[sp - 1].add(stack[sp]);
                },
                .Lt, .Gt, .And, .Or => {
                    sp -= 1;
                    stack[sp - 1] = Interval.init(0.0, 1.0);
                },
                .FieldSample => {
                    stack[sp] = Interval.point(40.0);
                    sp += 1;
                },
                .Probe => |id| {
                    const v = getProbeValue(id) orelse 0.0;
                    stack[sp] = Interval.point(v);
                    sp += 1;
                },
                .FromId => {
                    stack[sp] = Interval.init(0.0, 1.0);
                    sp += 1;
                },
            }
        }

        return if (sp > 0) stack[sp - 1] else Interval.point(0.0);
    }
};

// ============================================================================
// Expression Parser & Shunting-Yard Bytecode Compiler with Vector Scalarisation
// ============================================================================

const TokenType = enum {
    Number,
    Plus,
    Minus,
    Star,
    Slash,
    Caret,
    LParen,
    RParen,
    Comma,
    Lt,
    Gt,
    And,
    Or,
    Identifier,
};

const Token = struct {
    tok_type: TokenType,
    val_num: f64 = 0.0,
    ident: []const u8 = "",
};

pub fn compileExpression(allocator: std.mem.Allocator, text: []const u8) !Expression {
    return compileExpressionWithContext(allocator, text, .residual, null);
}

pub fn compileExpressionWithContext(
    allocator: std.mem.Allocator,
    text: []const u8,
    context: ExprContext,
    var_map: ?*const std.StringHashMap(u32),
) !Expression {
    var insts: std.ArrayList(Instruction) = .empty;
    errdefer insts.deinit(allocator);

    var op_stack: std.ArrayList(Token) = .empty;
    defer op_stack.deinit(allocator);

    var i: usize = 0;
    var expect_unary = true;

    while (i < text.len) {
        const ch = text[i];
        if (std.ascii.isWhitespace(ch)) {
            i += 1;
            continue;
        }

        // Numbers
        if (std.ascii.isDigit(ch) or (ch == '.' and i + 1 < text.len and std.ascii.isDigit(text[i + 1]))) {
            const start = i;
            while (i < text.len and (std.ascii.isDigit(text[i]) or text[i] == '.' or text[i] == 'e' or text[i] == 'E' or (text[i] == '-' and (text[i - 1] == 'e' or text[i - 1] == 'E')))) {
                i += 1;
            }
            const num = try std.fmt.parseFloat(f64, text[start..i]);
            try insts.append(allocator, .{ .Const = num });
            expect_unary = false;
            continue;
        }

        // Identifiers and functions
        if (std.ascii.isAlphabetic(ch) or ch == '_') {
            const start = i;
            while (i < text.len and (std.ascii.isAlphanumeric(text[i]) or text[i] == '_' or text[i] == '.')) {
                i += 1;
            }
            const name = text[start..i];

            // Check for predicate-only variables in field or residual contexts (§3.3.2)
            if (context != .predicate) {
                if (std.mem.eql(u8, name, "nx") or std.mem.eql(u8, name, "ny") or std.mem.eql(u8, name, "nz") or
                    std.mem.eql(u8, name, "tx") or std.mem.eql(u8, name, "ty") or std.mem.eql(u8, name, "tz") or
                    std.mem.eql(u8, name, "k_min") or std.mem.eql(u8, name, "k_max") or
                    std.mem.eql(u8, name, "k_gauss") or std.mem.eql(u8, name, "k_mean") or
                    std.mem.eql(u8, name, "area") or std.mem.eql(u8, name, "length") or
                    std.mem.eql(u8, name, "from_id"))
                {
                    return error.ErrExprContext;
                }
            }

            // Keyword constants
            if (std.mem.eql(u8, name, "PI")) {
                try insts.append(allocator, .{ .Const = std.math.pi });
                expect_unary = false;
                continue;
            }

            // Boolean logic keywords
            if (std.mem.eql(u8, name, "and")) {
                const prec = getPrecedence(.{ .tok_type = .And });
                while (op_stack.items.len > 0 and op_stack.items[op_stack.items.len - 1].tok_type != .LParen and getPrecedence(op_stack.items[op_stack.items.len - 1]) >= prec) {
                    try applyOpToken(&insts, allocator, op_stack.pop().?);
                }
                try op_stack.append(allocator, .{ .tok_type = .And });
                expect_unary = true;
                continue;
            }
            if (std.mem.eql(u8, name, "or")) {
                const prec = getPrecedence(.{ .tok_type = .Or });
                while (op_stack.items.len > 0 and op_stack.items[op_stack.items.len - 1].tok_type != .LParen and getPrecedence(op_stack.items[op_stack.items.len - 1]) >= prec) {
                    try applyOpToken(&insts, allocator, op_stack.pop().?);
                }
                try op_stack.append(allocator, .{ .tok_type = .Or });
                expect_unary = true;
                continue;
            }

            // Special functions: ref('id'), probe('id'), or from_id('id')
            if (std.mem.eql(u8, name, "ref")) {
                while (i < text.len and text[i] != '(') i += 1;
                if (i < text.len) i += 1; // skip '('
                while (i < text.len and (text[i] == ' ' or text[i] == '\'' or text[i] == '"')) i += 1;
                const ref_start = i;
                while (i < text.len and text[i] != '\'' and text[i] != '"' and text[i] != ')') i += 1;
                const ref_id = text[ref_start..i];
                while (i < text.len and text[i] != ')') i += 1;
                if (i < text.len) i += 1; // skip ')'

                if (var_map) |vm| {
                    if (vm.get(ref_id)) |v_idx| {
                        try insts.append(allocator, .{ .Var = v_idx });
                        expect_unary = false;
                        continue;
                    }
                }
                return error.ErrUndefinedRef;
            }

            if (std.mem.eql(u8, name, "probe")) {
                // Parse ('id')
                while (i < text.len and text[i] != '(') i += 1;
                if (i < text.len) i += 1; // skip '('
                while (i < text.len and (text[i] == ' ' or text[i] == '\'' or text[i] == '"')) i += 1;
                const id_start = i;
                while (i < text.len and text[i] != '\'' and text[i] != '"' and text[i] != ')') i += 1;
                const probe_id = text[id_start..i];
                while (i < text.len and text[i] != ')') i += 1;
                if (i < text.len) i += 1; // skip ')'
                const id_copy = try allocator.dupe(u8, probe_id);
                try insts.append(allocator, .{ .Probe = id_copy });
                expect_unary = false;
                continue;
            }

            if (std.mem.eql(u8, name, "from_id")) {
                while (i < text.len and text[i] != '(') i += 1;
                if (i < text.len) i += 1;
                while (i < text.len and (text[i] == ' ' or text[i] == '\'' or text[i] == '"')) i += 1;
                const id_start = i;
                while (i < text.len and text[i] != '\'' and text[i] != '"' and text[i] != ')') i += 1;
                const target_id = text[id_start..i];
                while (i < text.len and text[i] != ')') i += 1;
                if (i < text.len) i += 1;
                const target_hash = h64(target_id);
                try insts.append(allocator, .{ .FromId = target_hash });
                expect_unary = false;
                continue;
            }

            if (std.mem.eql(u8, name, "field_scalar")) {
                // field_scalar(slot, x, y, z, default)
                while (i < text.len and text[i] != ')') i += 1;
                if (i < text.len) i += 1;
                try insts.append(allocator, .{ .FieldSample = 0 });
                expect_unary = false;
                continue;
            }

            // Check if variable in var_map
            if (var_map) |vm| {
                if (vm.get(name)) |v_idx| {
                    try insts.append(allocator, .{ .Var = v_idx });
                    expect_unary = false;
                    continue;
                }
            }

            // Standard variables by coordinate naming
            if (context == .predicate) {
                if (std.mem.eql(u8, name, "x")) {
                    try insts.append(allocator, .{ .Var = 0 });
                    expect_unary = false;
                    continue;
                } else if (std.mem.eql(u8, name, "y")) {
                    try insts.append(allocator, .{ .Var = 1 });
                    expect_unary = false;
                    continue;
                } else if (std.mem.eql(u8, name, "z")) {
                    try insts.append(allocator, .{ .Var = 2 });
                    expect_unary = false;
                    continue;
                } else if (std.mem.eql(u8, name, "nx")) {
                    try insts.append(allocator, .{ .Var = 3 });
                    expect_unary = false;
                    continue;
                } else if (std.mem.eql(u8, name, "ny")) {
                    try insts.append(allocator, .{ .Var = 4 });
                    expect_unary = false;
                    continue;
                } else if (std.mem.eql(u8, name, "nz")) {
                    try insts.append(allocator, .{ .Var = 5 });
                    expect_unary = false;
                    continue;
                } else if (std.mem.eql(u8, name, "tx")) {
                    try insts.append(allocator, .{ .Var = 6 });
                    expect_unary = false;
                    continue;
                } else if (std.mem.eql(u8, name, "ty")) {
                    try insts.append(allocator, .{ .Var = 7 });
                    expect_unary = false;
                    continue;
                } else if (std.mem.eql(u8, name, "tz")) {
                    try insts.append(allocator, .{ .Var = 8 });
                    expect_unary = false;
                    continue;
                } else if (std.mem.eql(u8, name, "k_min")) {
                    try insts.append(allocator, .{ .Var = 9 });
                    expect_unary = false;
                    continue;
                } else if (std.mem.eql(u8, name, "k_max")) {
                    try insts.append(allocator, .{ .Var = 10 });
                    expect_unary = false;
                    continue;
                } else if (std.mem.eql(u8, name, "k_gauss")) {
                    try insts.append(allocator, .{ .Var = 11 });
                    expect_unary = false;
                    continue;
                } else if (std.mem.eql(u8, name, "k_mean")) {
                    try insts.append(allocator, .{ .Var = 12 });
                    expect_unary = false;
                    continue;
                } else if (std.mem.eql(u8, name, "area")) {
                    try insts.append(allocator, .{ .Var = 13 });
                    expect_unary = false;
                    continue;
                } else if (std.mem.eql(u8, name, "length")) {
                    try insts.append(allocator, .{ .Var = 14 });
                    expect_unary = false;
                    continue;
                }
            } else if (context == .field or context == .residual) {
                if (std.mem.eql(u8, name, "x") or std.mem.eql(u8, name, "u")) {
                    try insts.append(allocator, .{ .Var = 0 });
                    expect_unary = false;
                    continue;
                } else if (std.mem.eql(u8, name, "y") or std.mem.eql(u8, name, "v")) {
                    try insts.append(allocator, .{ .Var = 1 });
                    expect_unary = false;
                    continue;
                } else if (std.mem.eql(u8, name, "z") or std.mem.eql(u8, name, "w")) {
                    try insts.append(allocator, .{ .Var = 2 });
                    expect_unary = false;
                    continue;
                }
            }

            // Numeric variable indexing (e.g. x0, x1, q0, q1, v0.u)
            if ((std.mem.startsWith(u8, name, "q") or std.mem.startsWith(u8, name, "x")) and name.len > 1 and std.ascii.isDigit(name[1])) {
                const idx = try std.fmt.parseInt(u32, name[1..], 10);
                try insts.append(allocator, .{ .Var = idx });
                expect_unary = false;
                continue;
            }

            // Member access scalarisation: v0.u, v0.v, e1.x, etc.
            if (std.mem.indexOfScalar(u8, name, '.')) |dot_idx| {
                const prefix = name[0..dot_idx];
                const member = name[dot_idx + 1 ..];
                var base_idx: u32 = 0;
                if (prefix.len > 1 and std.ascii.isDigit(prefix[1])) {
                    base_idx = (std.fmt.parseInt(u32, prefix[1..], 10) catch 0) * 2;
                }
                if (std.mem.eql(u8, member, "u") or std.mem.eql(u8, member, "x")) {
                    try insts.append(allocator, .{ .Var = base_idx });
                    expect_unary = false;
                    continue;
                } else if (std.mem.eql(u8, member, "v") or std.mem.eql(u8, member, "y")) {
                    try insts.append(allocator, .{ .Var = base_idx + 1 });
                    expect_unary = false;
                    continue;
                } else if (std.mem.eql(u8, member, "z")) {
                    try insts.append(allocator, .{ .Var = base_idx + 2 });
                    expect_unary = false;
                    continue;
                }
            }

            // Function identifier or reference
            var is_func = false;
            var peek_idx = i;
            while (peek_idx < text.len and std.ascii.isWhitespace(text[peek_idx])) peek_idx += 1;
            if (peek_idx < text.len and text[peek_idx] == '(') {
                is_func = true;
            }

            if (!is_func and var_map != null) {
                return error.ErrUndefinedRef;
            }

            try op_stack.append(allocator, .{ .tok_type = .Identifier, .ident = name });
            expect_unary = true;
            continue;
        }

        if (ch == '(') {
            try op_stack.append(allocator, .{ .tok_type = .LParen });
            expect_unary = true;
            i += 1;
            continue;
        }

        if (ch == ',') {
            while (op_stack.items.len > 0 and op_stack.items[op_stack.items.len - 1].tok_type != .LParen) {
                try applyOpToken(&insts, allocator, op_stack.pop().?);
            }
            expect_unary = true;
            i += 1;
            continue;
        }

        if (ch == ')') {
            while (op_stack.items.len > 0 and op_stack.items[op_stack.items.len - 1].tok_type != .LParen) {
                try applyOpToken(&insts, allocator, op_stack.pop().?);
            }
            if (op_stack.items.len > 0 and op_stack.items[op_stack.items.len - 1].tok_type == .LParen) {
                _ = op_stack.pop();
            }
            if (op_stack.items.len > 0 and op_stack.items[op_stack.items.len - 1].tok_type == .Identifier) {
                const func = op_stack.pop().?;
                if (std.mem.eql(u8, func.ident, "sin")) {
                    try insts.append(allocator, .Sin);
                } else if (std.mem.eql(u8, func.ident, "cos")) {
                    try insts.append(allocator, .Cos);
                } else if (std.mem.eql(u8, func.ident, "exp")) {
                    try insts.append(allocator, .Exp);
                } else if (std.mem.eql(u8, func.ident, "log") or std.mem.eql(u8, func.ident, "ln")) {
                    try insts.append(allocator, .Log);
                } else if (std.mem.eql(u8, func.ident, "sqrt")) {
                    try insts.append(allocator, .Sqrt);
                } else if (std.mem.eql(u8, func.ident, "abs")) {
                    try insts.append(allocator, .Abs);
                } else if (std.mem.eql(u8, func.ident, "abs_smooth")) {
                    try insts.append(allocator, .AbsSmooth);
                } else if (std.mem.eql(u8, func.ident, "r_union")) {
                    try insts.append(allocator, .RUnion);
                } else if (std.mem.eql(u8, func.ident, "r_intersect")) {
                    try insts.append(allocator, .RIntersect);
                } else {
                    return error.ErrUndefinedRef;
                }
            }
            expect_unary = false;
            i += 1;
            continue;
        }

        // Operators
        var tok_type: TokenType = .Plus;
        var is_unary_minus = false;

        switch (ch) {
            '+' => {
                tok_type = .Plus;
            },
            '-' => {
                if (expect_unary) {
                    is_unary_minus = true;
                } else {
                    tok_type = .Minus;
                }
            },
            '*' => {
                tok_type = .Star;
            },
            '/' => {
                tok_type = .Slash;
            },
            '^' => {
                tok_type = .Caret;
            },
            '<' => {
                if (context != .predicate) return error.ErrExprContext;
                tok_type = .Lt;
            },
            '>' => {
                if (context != .predicate) return error.ErrExprContext;
                tok_type = .Gt;
            },
            else => {
                i += 1;
                continue;
            },
        }

        if (is_unary_minus) {
            try op_stack.append(allocator, .{ .tok_type = .Identifier, .ident = "neg" });
        } else {
            const prec = getPrecedence(.{ .tok_type = tok_type });
            while (op_stack.items.len > 0) {
                const top = op_stack.items[op_stack.items.len - 1];
                if (top.tok_type == .LParen) break;
                const top_prec = getPrecedence(top);
                if (top_prec >= prec and tok_type != .Caret) {
                    _ = op_stack.pop();
                    try applyOpToken(&insts, allocator, top);
                } else {
                    break;
                }
            }
            try op_stack.append(allocator, .{ .tok_type = tok_type });
        }

        expect_unary = true;
        i += 1;
    }

    while (op_stack.items.len > 0) {
        const top = op_stack.pop().?;
        if (top.tok_type != .LParen and top.tok_type != .RParen) {
            try applyOpToken(&insts, allocator, top);
        }
    }

    return Expression{
        .instructions = try insts.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

fn getPrecedence(tok: Token) u8 {
    return switch (tok.tok_type) {
        .Or => 1,
        .And => 2,
        .Lt, .Gt => 3,
        .Plus, .Minus => 4,
        .Star, .Slash => 5,
        .Caret => 6,
        .Identifier => 7,
        else => 0,
    };
}

fn applyOpToken(insts: *std.ArrayList(Instruction), allocator: std.mem.Allocator, tok: Token) !void {
    switch (tok.tok_type) {
        .Plus => try insts.append(allocator, .Add),
        .Minus => try insts.append(allocator, .Sub),
        .Star => try insts.append(allocator, .Mul),
        .Slash => try insts.append(allocator, .Div),
        .Caret => try insts.append(allocator, .Pow),
        .Lt => try insts.append(allocator, .Lt),
        .Gt => try insts.append(allocator, .Gt),
        .And => try insts.append(allocator, .And),
        .Or => try insts.append(allocator, .Or),
        .Identifier => {
            if (std.mem.eql(u8, tok.ident, "neg")) {
                try insts.append(allocator, .{ .Const = -1.0 });
                try insts.append(allocator, .Mul);
            } else {
                return error.ErrUndefinedRef;
            }
        },
        else => {},
    }
}

// ============================================================================
// Expression Global Registry & Exported ABI Functions
// ============================================================================

var next_expr_id: u64 = 1;
var expr_store: std.AutoHashMap(u64, Expression) = std.AutoHashMap(u64, Expression).init(std.heap.page_allocator);

pub fn expr_compile(ptr: [*]const u8, len: usize) u64 {
    const text = ptr[0..len];
    const real_expr = compileExpression(std.heap.page_allocator, text) catch return 0;

    // Rule 4: bits [63:62] == 0b11 for Mathematical Expressions
    const handle: u64 = (@as(u64, 0b11) << 62) | next_expr_id;
    next_expr_id += 1;

    expr_store.put(handle, real_expr) catch return 0;
    return handle;
}

pub fn expr_compile_context(ptr: [*]const u8, len: usize, context: ExprContext) u64 {
    const text = ptr[0..len];
    const real_expr = compileExpressionWithContext(std.heap.page_allocator, text, context, null) catch return 0;

    const handle: u64 = (@as(u64, 0b11) << 62) | next_expr_id;
    next_expr_id += 1;

    expr_store.put(handle, real_expr) catch return 0;
    return handle;
}

pub fn expr_eval(expr_h: u64, vars_ptr: [*]const f64, var_count: u32, out_grad_ptr: ?[*]f64) f64 {
    const expr = expr_store.get(expr_h) orelse return 0.0;
    const vars = vars_ptr[0..var_count];
    const out_grad = if (out_grad_ptr) |gp| gp[0..var_count] else null;
    return expr.evalGrad(vars, out_grad);
}

pub fn expr_free(expr_h: u64) void {
    if (expr_store.fetchRemove(expr_h)) |kv| {
        var expr = kv.value;
        expr.deinit();
    }
}

test "Autodiff R-functions and context enforcement" {
    const alloc = std.testing.allocator;

    // R-Union and R-Intersect
    var expr_ru = try compileExpression(alloc, "r_union(x0, x1)");
    defer expr_ru.deinit();
    const val_ru = expr_ru.evalScalar(&[_]f64{ 3.0, 4.0 });
    // 3 + 4 - sqrt(9+16) = 7 - 5 = 2.0
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), val_ru, 1e-10);

    var expr_ri = try compileExpression(alloc, "r_intersect(x0, x1)");
    defer expr_ri.deinit();
    const val_ri = expr_ri.evalScalar(&[_]f64{ 3.0, 4.0 });
    // 3 + 4 + 5 = 12.0
    try std.testing.expectApproxEqAbs(@as(f64, 12.0), val_ri, 1e-10);

    // Context enforcement: predicate variables forbidden in field context
    try std.testing.expectError(error.ErrExprContext, compileExpressionWithContext(alloc, "x + nx", .field, null));
    try std.testing.expectError(error.ErrExprContext, compileExpressionWithContext(alloc, "x + area", .residual, null));
}
