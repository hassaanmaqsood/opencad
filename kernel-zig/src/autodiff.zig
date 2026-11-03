const std = @import("std");
const memory = @import("memory.zig");

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
// Interval Arithmetic for Range Bounding
// ============================================================================

pub const Interval = struct {
    min: f64,
    max: f64,

    pub fn init(min: f64, max: f64) Interval {
        return .{ .min = @min(min, max), .max = @max(min, max) };
    }

    pub fn point(p: f64) Interval {
        return .{ .min = p, .max = p };
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
            const s1 = a.min * a.min;
            const s2 = a.max * a.max;
            return .{ .min = @min(s1, s2), .max = @max(s1, s2) };
        }
    }

    pub fn contains(a: Interval, v: f64) bool {
        return v >= a.min and v <= a.max;
    }
};

// ============================================================================
// Bytecode Instruction Set
// ============================================================================

pub const OpCode = enum(u8) {
    Const,
    Var,
    Add,
    Sub,
    Mul,
    Div,
    Neg,
    Sqr,
    Sqrt,
    Sin,
    Cos,
    Pow,
};

pub const Instruction = union(OpCode) {
    Const: f64,
    Var: u32,
    Add: void,
    Sub: void,
    Mul: void,
    Div: void,
    Neg: void,
    Sqr: void,
    Sqrt: void,
    Sin: void,
    Cos: void,
    Pow: void,
};

pub const Expression = struct {
    instructions: []Instruction,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Expression) void {
        self.allocator.free(self.instructions);
    }

    pub fn evalScalar(self: *const Expression, vars: []const f64) f64 {
        var stack: [64]f64 = undefined;
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
                .Neg => {
                    stack[sp - 1] = -stack[sp - 1];
                },
                .Sqr => {
                    stack[sp - 1] = stack[sp - 1] * stack[sp - 1];
                },
                .Sqrt => {
                    stack[sp - 1] = @sqrt(@max(0.0, stack[sp - 1]));
                },
                .Sin => {
                    stack[sp - 1] = @sin(stack[sp - 1]);
                },
                .Cos => {
                    stack[sp - 1] = @cos(stack[sp - 1]);
                },
                .Pow => {
                    sp -= 1;
                    stack[sp - 1] = std.math.pow(f64, stack[sp - 1], stack[sp]);
                },
            }
        }

        return if (sp > 0) stack[sp - 1] else 0.0;
    }

    pub fn evalDual(self: *const Expression, vars: []const Dual) Dual {
        var stack: [64]Dual = undefined;
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
                .Neg => {
                    stack[sp - 1] = stack[sp - 1].neg();
                },
                .Sqr => {
                    stack[sp - 1] = stack[sp - 1].sqr();
                },
                .Sqrt => {
                    stack[sp - 1] = stack[sp - 1].sqrt();
                },
                .Sin => {
                    stack[sp - 1] = stack[sp - 1].sin();
                },
                .Cos => {
                    stack[sp - 1] = stack[sp - 1].cos();
                },
                .Pow => {
                    sp -= 1;
                    stack[sp - 1] = stack[sp - 1].pow(stack[sp].val);
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
        var stack: [64]Interval = undefined;
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
                    stack[sp - 1] = stack[sp - 1].mul(Interval.point(1.0 / stack[sp].min));
                },
                .Neg => {
                    stack[sp - 1] = Interval.init(-stack[sp - 1].max, -stack[sp - 1].min);
                },
                .Sqr => {
                    stack[sp - 1] = stack[sp - 1].sqr();
                },
                .Sqrt => {
                    stack[sp - 1] = Interval.init(@sqrt(@max(0.0, stack[sp - 1].min)), @sqrt(@max(0.0, stack[sp - 1].max)));
                },
                .Sin, .Cos => {
                    stack[sp - 1] = Interval.init(-1.0, 1.0);
                },
                .Pow => {
                    sp -= 1;
                    stack[sp - 1] = stack[sp - 1].sqr(); // conservative approximation for power
                },
            }
        }

        return if (sp > 0) stack[sp - 1] else Interval.point(0.0);
    }
};

// ============================================================================
// Expression Parser & Shunting-Yard Bytecode Compiler
// ============================================================================

const TokenType = enum {
    Number,
    Variable,
    Plus,
    Minus,
    Star,
    Slash,
    Caret,
    LParen,
    RParen,
    Identifier,
    End,
};

const Token = struct {
    tok_type: TokenType,
    val_num: f64 = 0.0,
    val_idx: u32 = 0,
    ident: []const u8 = "",
};

pub fn compileExpression(allocator: std.mem.Allocator, text: []const u8) !Expression {
    var insts: std.ArrayList(Instruction) = .empty;
    errdefer insts.deinit(allocator);

    // Check for binary bytecode prefix
    if (text.len >= 4 and std.mem.eql(u8, text[0..4], "\x7fEXP")) {
        var cursor: usize = 4;
        while (cursor < text.len) {
            const op_byte = text[cursor];
            cursor += 1;
            const op: OpCode = @enumFromInt(op_byte);
            switch (op) {
                .Const => {
                    if (cursor + 8 > text.len) break;
                    const c = std.mem.readInt(u64, text[cursor..][0..8], .little);
                    cursor += 8;
                    try insts.append(allocator, .{ .Const = @bitCast(c) });
                },
                .Var => {
                    if (cursor + 4 > text.len) break;
                    const v = std.mem.readInt(u32, text[cursor..][0..4], .little);
                    cursor += 4;
                    try insts.append(allocator, .{ .Var = v });
                },
                .Add => try insts.append(allocator, .Add),
                .Sub => try insts.append(allocator, .Sub),
                .Mul => try insts.append(allocator, .Mul),
                .Div => try insts.append(allocator, .Div),
                .Neg => try insts.append(allocator, .Neg),
                .Sqr => try insts.append(allocator, .Sqr),
                .Sqrt => try insts.append(allocator, .Sqrt),
                .Sin => try insts.append(allocator, .Sin),
                .Cos => try insts.append(allocator, .Cos),
                .Pow => try insts.append(allocator, .Pow),
            }
        }
        return Expression{
            .instructions = try insts.toOwnedSlice(allocator),
            .allocator = allocator,
        };
    }

    // Infix Text Parser using Shunting-Yard Algorithm
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

        if (std.ascii.isAlphabetic(ch) or ch == '_') {
            const start = i;
            while (i < text.len and (std.ascii.isAlphanumeric(text[i]) or text[i] == '_')) {
                i += 1;
            }
            const name = text[start..i];

            // Check if variable (e.g. x0, x1, q0, q1, x, y, z, u, v)
            if (std.mem.startsWith(u8, name, "q") or std.mem.startsWith(u8, name, "x") or std.mem.startsWith(u8, name, "v") or std.mem.startsWith(u8, name, "p")) {
                if (name.len > 1 and std.ascii.isDigit(name[1])) {
                    const idx = try std.fmt.parseInt(u32, name[1..], 10);
                    try insts.append(allocator, .{ .Var = idx });
                    expect_unary = false;
                    continue;
                }
            }

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

            // Function identifier
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

        if (ch == ')') {
            while (op_stack.items.len > 0 and op_stack.items[op_stack.items.len - 1].tok_type != .LParen) {
                const top = op_stack.pop().?;
                try applyOpToken(&insts, allocator, top);
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
                } else if (std.mem.eql(u8, func.ident, "sqrt")) {
                    try insts.append(allocator, .Sqrt);
                } else if (std.mem.eql(u8, func.ident, "sqr")) {
                    try insts.append(allocator, .Sqr);
                }
            }
            expect_unary = false;
            i += 1;
            continue;
        }

        // Operators
        var tok_type: TokenType = .Plus;
        var prec: u8 = 1;
        var is_unary_minus = false;

        switch (ch) {
            '+' => {
                tok_type = .Plus;
                prec = 1;
            },
            '-' => {
                if (expect_unary) {
                    is_unary_minus = true;
                    prec = 4;
                } else {
                    tok_type = .Minus;
                    prec = 1;
                }
            },
            '*' => {
                tok_type = .Star;
                prec = 2;
            },
            '/' => {
                tok_type = .Slash;
                prec = 2;
            },
            '^' => {
                tok_type = .Caret;
                prec = 3;
            },
            else => {
                i += 1;
                continue;
            },
        }

        if (is_unary_minus) {
            try op_stack.append(allocator, .{ .tok_type = .Identifier, .ident = "neg" });
        } else {
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
        .Plus, .Minus => 1,
        .Star, .Slash => 2,
        .Caret => 3,
        .Identifier => 4,
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
        .Identifier => {
            if (std.mem.eql(u8, tok.ident, "neg")) {
                try insts.append(allocator, .Neg);
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

// ============================================================================
// Unit Tests
// ============================================================================

test "Dual numbers arithmetic and derivatives" {
    // f(x) = x^2 + 3*x + 5 at x = 2
    // f'(x) = 2*x + 3 = 7
    const x = Dual.variable(2.0, true);
    const res = x.sqr().add(Dual.constant(3.0).mul(x)).add(Dual.constant(5.0));
    try std.testing.expectApproxEqAbs(@as(f64, 15.0), res.val, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 7.0), res.der, 1e-12);
}

test "Interval arithmetic bounds" {
    const a = Interval.init(1.0, 3.0);
    const b = Interval.init(2.0, 4.0);
    const c = a.add(b);
    try std.testing.expect(c.min == 3.0 and c.max == 7.0);

    const d = a.mul(b);
    try std.testing.expect(d.min == 2.0 and d.max == 12.0);
}

test "Compile and evaluate expression with exact analytical gradient" {
    const alloc = std.testing.allocator;
    var expr = try compileExpression(alloc, "x0^2 + x1^2 - 25.0");
    defer expr.deinit();

    var grad: [2]f64 = undefined;
    const vars = [_]f64{ 3.0, 4.0 };
    const val = expr.evalGrad(&vars, &grad);

    // 3^2 + 4^2 - 25 = 0
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), val, 1e-12);
    // dF/dx0 = 2*x0 = 6
    try std.testing.expectApproxEqAbs(@as(f64, 6.0), grad[0], 1e-12);
    // dF/dx1 = 2*x1 = 8
    try std.testing.expectApproxEqAbs(@as(f64, 8.0), grad[1], 1e-12);
}
