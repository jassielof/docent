//! The `cyclomatic` namespace provides the implementation of the cyclomatic complexity rule.
//!
//! Cyclomatic complexity counts linearly independent paths through a function's control flow (McCabe,
//! 1976). The score starts at 1 and adds one for each decision point: `if`, loops, `catch`, logical
//! `and`/`or`, and each `switch` prong. Unlike cognitive complexity, `switch` arms are counted
//! individually rather than as a single structure.

const std = @import("std");
const Ast = std.zig.Ast;

const Diagnostic = @import("../../Diagnostic.zig");
const severity = @import("../../severity.zig");
const utils = @import("../utils.zig");

const rule_name = "cyclomatic_complexity";

/// Default McCabe-recommended limit on linearly independent paths.
pub const default_threshold: u32 = 10;

/// Walks `tree` and appends a diagnostic for each scanned function whose cyclomatic complexity exceeds `threshold`.
///
/// When `public_api_only` is set, only `pub` functions (at the container level) are measured; otherwise every
/// container-level function is measured.
pub fn check(
    tree: *const Ast,
    severity_level: severity.Level,
    file: []const u8,
    public_api_only: bool,
    threshold: u32,
    allocator: std.mem.Allocator,
    msg_allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) !void {
    if (!severity_level.isActive()) return;

    var fns: std.ArrayList(Ast.Node.Index) = .empty;
    defer fns.deinit(allocator);

    for (tree.rootDecls()) |decl| {
        try collectFunctions(tree, decl, public_api_only, allocator, &fns);
    }

    for (fns.items) |fn_node| {
        const score = functionComplexity(tree, fn_node);
        if (score <= threshold) continue;

        var buf: [1]Ast.Node.Index = undefined;
        const proto = tree.fullFnProto(&buf, fn_node) orelse continue;
        const name_tok = proto.name_token orelse continue;
        const name = tree.tokenSlice(name_tok);
        const loc = tree.tokenLocation(0, name_tok);

        try diagnostics.append(allocator, .{
            .rule = rule_name,
            .severity_level = severity_level,
            .subject = try utils.ownedSubject(msg_allocator, .function, name),
            .detail = try std.fmt.allocPrint(
                msg_allocator,
                "cyclomatic complexity {d} exceeds threshold {d}",
                .{ score, threshold },
            ),
            .file = file,
            .line = loc.line + 1,
            .column = loc.column + 1,
            .source_line = try utils.dupSourceLine(tree, name_tok, msg_allocator),
            .symbol_len = name.len,
        });
    }
}

fn collectFunctions(
    tree: *const Ast,
    node: Ast.Node.Index,
    public_api_only: bool,
    allocator: std.mem.Allocator,
    out: *std.ArrayList(Ast.Node.Index),
) !void {
    const tag = tree.nodeTag(node);

    if (tag == .fn_decl) {
        var buf: [1]Ast.Node.Index = undefined;
        if (tree.fullFnProto(&buf, node)) |proto| {
            const include = if (public_api_only) utils.isPubVisibility(tree, proto.visib_token) else true;
            if (include) try out.append(allocator, node);
        }
        return;
    }

    if (tree.fullVarDecl(node)) |var_decl| {
        if (var_decl.ast.init_node.unwrap()) |init_node| {
            if (utils.isContainerDecl(tree.nodeTag(init_node))) {
                var buf: [2]Ast.Node.Index = undefined;
                if (tree.fullContainerDecl(&buf, init_node)) |container| {
                    for (container.ast.members) |member| {
                        try collectFunctions(tree, member, public_api_only, allocator, out);
                    }
                }
            }
        }
        return;
    }

    if (utils.isContainerDecl(tag)) {
        var buf: [2]Ast.Node.Index = undefined;
        if (tree.fullContainerDecl(&buf, node)) |container| {
            for (container.ast.members) |member| {
                try collectFunctions(tree, member, public_api_only, allocator, out);
            }
        }
    }
}

fn functionComplexity(tree: *const Ast, fn_node: Ast.Node.Index) u32 {
    const body = tree.nodeData(fn_node).node_and_node[1];
    const body_first = tree.firstToken(body);
    const body_last = tree.lastToken(body);

    var score: u32 = 1;
    const node_count: u32 = @intCast(tree.nodes.len);
    var raw: u32 = 0;
    while (raw < node_count) : (raw += 1) {
        const node: Ast.Node.Index = @enumFromInt(raw);
        if (node == body) continue;
        const first = tree.firstToken(node);
        const last = tree.lastToken(node);
        if (first < body_first or last > body_last) continue;
        score += nodeIncrement(tree, node);
    }
    return score;
}

fn nodeIncrement(tree: *const Ast, node: Ast.Node.Index) u32 {
    switch (tree.nodeTag(node)) {
        .if_simple, .@"if" => return 1,
        .while_simple, .while_cont, .@"while" => return 1,
        .for_simple, .@"for" => return 1,
        .@"catch" => return 1,
        .bool_and, .bool_or => return 1,
        .@"switch", .switch_comma => {
            const switch_full = tree.fullSwitch(node) orelse return 0;
            return @intCast(switch_full.ast.cases.len);
        },
        .switch_case_one,
        .switch_case_inline_one,
        .switch_case,
        .switch_case_inline,
        => return 0,
        else => return 0,
    }
}

fn complexityOfFirstFn(source: [:0]const u8) !u32 {
    const allocator = std.testing.allocator;
    var tree = try std.zig.Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);

    for (tree.rootDecls()) |decl| {
        if (tree.nodeTag(decl) == .fn_decl) return functionComplexity(&tree, decl);
    }
    return error.NoFunction;
}

const TestResult = struct {
    msg_arena: std.heap.ArenaAllocator,
    items: std.ArrayList(Diagnostic),

    fn deinit(self: *TestResult) void {
        self.msg_arena.deinit();
        self.items.deinit(std.testing.allocator);
    }
};

fn runCheck(source: [:0]const u8, threshold: u32) !TestResult {
    const base = std.testing.allocator;
    var msg_arena = std.heap.ArenaAllocator.init(base);
    errdefer msg_arena.deinit();

    var tree = try std.zig.Ast.parse(base, source, .zig);
    defer tree.deinit(base);

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    errdefer diagnostics.deinit(base);

    try check(&tree, .warn, "<test>", true, threshold, base, msg_arena.allocator(), &diagnostics);
    return .{ .msg_arena = msg_arena, .items = diagnostics };
}

test "empty function scores 1" {
    const score = try complexityOfFirstFn(
        \\fn f() void {}
    );
    try std.testing.expectEqual(@as(u32, 1), score);
}

test "if / else if / else chain scores 3 per McCabe" {
    const score = try complexityOfFirstFn(
        \\fn g(x: i32) i32 {
        \\    if (x == 1) {
        \\        return 1;
        \\    } else if (x == 2) {
        \\        return 2;
        \\    } else {
        \\        return 3;
        \\    }
        \\}
    );
    try std.testing.expectEqual(@as(u32, 3), score);
}

test "switch counts each prong" {
    const score = try complexityOfFirstFn(
        \\fn getWords(number: u32) []const u8 {
        \\    switch (number) {
        \\        1 => return "one",
        \\        2 => return "a couple",
        \\        3 => return "a few",
        \\        else => return "lots",
        \\    }
        \\}
    );
    try std.testing.expectEqual(@as(u32, 5), score);
}

test "logical operators add decision points" {
    const score = try complexityOfFirstFn(
        \\fn f(a: bool, b: bool, c: bool) bool {
        \\    return a and b or c;
        \\}
    );
    try std.testing.expectEqual(@as(u32, 3), score);
}

test "catch adds a decision point" {
    const score = try complexityOfFirstFn(
        \\fn k() void {
        \\    foo() catch {
        \\        bar();
        \\    };
        \\}
    );
    try std.testing.expectEqual(@as(u32, 2), score);
}

test "orelse is ignored" {
    const score = try complexityOfFirstFn(
        \\fn k(x: ?u32) u32 {
        \\    return x orelse 0;
        \\}
    );
    try std.testing.expectEqual(@as(u32, 1), score);
}

test "emits a diagnostic only above the threshold" {
    const source =
        \\pub fn complex(x: i32) i32 {
        \\    if (x == 1) {
        \\        return 1;
        \\    } else if (x == 2) {
        \\        return 2;
        \\    } else {
        \\        return 3;
        \\    }
        \\}
    ;
    var at = try runCheck(source, 3);
    defer at.deinit();
    try std.testing.expectEqual(@as(usize, 0), at.items.items.len);

    var above = try runCheck(source, 2);
    defer above.deinit();
    try std.testing.expectEqual(@as(usize, 1), above.items.items.len);
    try std.testing.expectEqualStrings(rule_name, above.items.items[0].rule);
    try std.testing.expectEqualStrings("complex", above.items.items[0].subject.?.name);
}

test "private functions are skipped under public_api_only" {
    const source =
        \\fn complex(x: i32) i32 {
        \\    if (x == 1) {
        \\        return 1;
        \\    } else if (x == 2) {
        \\        return 2;
        \\    } else {
        \\        return 3;
        \\    }
        \\}
    ;
    var result = try runCheck(source, 1);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), result.items.items.len);
}
