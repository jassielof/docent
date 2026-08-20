//! The `cognitive` namespace provides the implementation of the cognitive complexity rule.
//!
//! Cognitive Complexity follows the Sonar specification (G. Ann Campbell, 2023). Instead of counting linearly independent paths (like Cyclomatic Complexity), it scores how hard a function's control flow is to *understand*. Three kinds of increments are accumulated per function body:
//!
//! - Structural: Control-flow structures that also receive a nesting increment (`if`, `for`, `while`, `switch`, `catch`). Each adds `1 + current_nesting`.
//! - Hybrid: `else` / `else if`, which add `1` but never receive a nesting increment (the cost of the `if` was already paid), yet still raise the nesting level for their body.
//! - Fundamental: breaks in linear flow that are independent of nesting: each new sequence of binary logical operators (`and` / `or`), labeled loop `break`/`continue`, and direct recursion.
//!
//! ## Zig-specific mappings
//!
//! - `catch` is treated like an exception `catch` clause (structural + nesting). `orelse` is the optional counterpart of null-coalescing and is intentionally ignored.
//! - Labeled `break`/`continue` only increment when the label targets a `for`/`while` loop; labeled block breaks (`break :blk value`) are value expressions and are not penalized.
//! - Only direct recursion (a function calling itself by name) is scored; indirect recursion is out of scope.
const std = @import("std");
const Ast = std.zig.Ast;

const lint = @import("lint");
const category = lint.category;
const complexity_breakdown = lint.complexity_breakdown;
const Increment = complexity_breakdown.Increment;
const Diagnostic = lint.Diagnostic;
const scan = lint.scan;
const severity = lint.severity;

/// Number of highest-scoring contributors shown as secondary spans in
/// pretty-mode output. Keeps the block readable for functions with many
/// contributors while still surfacing the ones worth fixing first.
const max_breakdown_spans = 4;

const rule_name = "cognitive_complexity";

/// Default severity `warn`: high cognitive complexity is a maintainability signal worth surfacing without failing a fresh build.
pub const default_severity: severity.Level = .warn;

/// Title for diagnostic prose (`Warning: {prose_title} on …`).
pub const prose_title = "Cognitive complexity";

/// Rule-specific knobs for `cognitive_complexity`, held in the `options` sub-space of `Rule`.
pub const Options = struct {
    /// Maximum cognitive complexity before a function is flagged; default `default_threshold` follows the Sonar recommendation.
    threshold: u32 = default_threshold,
};

/// Full configuration for `cognitive_complexity`: severity, scan mode, and the documented `Options` sub-space.
pub const Rule = category.Rule(
    default_severity,
    Options,
    scan.RuleScanConfig.all_declarations,
);

/// Default cognitive-complexity threshold recommended by Sonar Source; see <https://community.sonarsource.com/t/s3776-reason-for-the-current-default-value-of-15/127103/3>.
pub const default_threshold: u32 = 15;

/// Walks `tree` and appends a diagnostic for each scanned function whose cognitive complexity exceeds `threshold`.
///
/// When `public_api_only` is set, only `pub` functions (at the container level) are measured; otherwise every
/// container-level function is measured. Functions nested inside another function body are not measured on their
/// own — they contribute to their enclosing function with a nesting increment, per the specification.
pub fn check(
    tree: *const Ast,
    rule: Rule,
    file: []const u8,
    allocator: std.mem.Allocator,
    msg_allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) !void {
    if (!rule.level.isActive()) return;
    const severity_level = rule.level;
    const public_api_only = rule.publicDeclarationsOnly();
    const threshold = rule.options.threshold;

    var fns: std.ArrayList(Ast.Node.Index) = .empty;
    defer fns.deinit(allocator);

    for (tree.rootDecls()) |decl| {
        try collectFunctions(
            tree,
            decl,
            public_api_only,
            allocator,
            &fns,
        );
    }

    for (fns.items) |fn_node| {
        const result = try functionComplexity(
            allocator,
            tree,
            fn_node,
        );
        defer allocator.free(result.increments);
        if (result.score <= threshold) continue;

        var buf: [1]Ast.Node.Index = undefined;
        const proto = tree.fullFnProto(&buf, fn_node) orelse continue;
        const name_tok = proto.name_token orelse continue;
        const name = tree.tokenSlice(name_tok);
        const loc = tree.tokenLocation(0, name_tok);

        const spans = try complexity_breakdown.buildSpans(
            msg_allocator,
            tree,
            result.increments,
            max_breakdown_spans,
        );
        const help: ?[]const u8 = if (complexity_breakdown.topLine(
            tree,
            result.increments,
        )) |top_line|
            try std.fmt.allocPrint(
                msg_allocator,
                "consider extracting the code near line {d} into a helper function",
                .{top_line},
            )
        else
            null;

        try diagnostics.append(allocator, .{
            .rule = rule_name,
            .severity_level = severity_level,
            .subject = try ownedSubject(
                msg_allocator,
                .function,
                name,
            ),
            .detail = try std.fmt.allocPrint(
                msg_allocator,
                "cognitive complexity {d} exceeds threshold {d}",
                .{ result.score, threshold },
            ),
            .file = file,
            .line = loc.line + 1,
            .column = loc.column + 1,
            .source_line = try dupSourceLine(
                tree,
                name_tok,
                msg_allocator,
            ),
            .symbol_len = name.len,
            .primary_label = try std.fmt.allocPrint(
                msg_allocator,
                "score: {d}",
                .{result.score},
            ),
            .spans = spans,
            .help = help,
        });
    }
}

/// Collects container-level function declarations, descending through container declarations but not function bodies.
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
            const include = if (public_api_only) isPubVisibility(tree, proto.visib_token) else true;
            if (include) try out.append(allocator, node);
        }
        return;
    }

    if (tree.fullVarDecl(node)) |var_decl| {
        if (var_decl.ast.init_node.unwrap()) |init_node| {
            if (isContainerDecl(tree.nodeTag(init_node))) {
                var buf: [2]Ast.Node.Index = undefined;
                if (tree.fullContainerDecl(&buf, init_node)) |container| {
                    for (container.ast.members) |member| {
                        try collectFunctions(
                            tree,
                            member,
                            public_api_only,
                            allocator,
                            out,
                        );
                    }
                }
            }
        }
        return;
    }

    if (isContainerDecl(tag)) {
        var buf: [2]Ast.Node.Index = undefined;
        if (tree.fullContainerDecl(&buf, node)) |container| {
            for (container.ast.members) |member| {
                try collectFunctions(
                    tree,
                    member,
                    public_api_only,
                    allocator,
                    out,
                );
            }
        }
    }
}

const FunctionScore = struct {
    score: u32,
    /// Owned by the allocator passed to `functionComplexity`.
    increments: []Increment,
};

/// Computes the cognitive complexity score of a single function declaration,
/// along with every individual node's contribution to it.
///
/// Collects nesting regions inside the function body first, then scores each
/// body node against that region list (O(n·r) in the body, not O(n²) over the
/// whole file AST). `increments` is allocated with `allocator` and owned by
/// the caller; the region list itself stays function-local scratch space.
fn functionComplexity(
    allocator: std.mem.Allocator,
    tree: *const Ast,
    fn_node: Ast.Node.Index,
) std.mem.Allocator.Error!FunctionScore {
    const body = tree.nodeData(fn_node).node_and_node[1];
    const body_first = tree.firstToken(body);
    const body_last = tree.lastToken(body);

    var buf: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buf, fn_node) orelse return .{ .score = 0, .increments = &.{} };
    const fn_name: []const u8 = if (proto.name_token) |nt| tree.tokenSlice(nt) else "";

    var sf = std.heap.stackFallback(4096, std.heap.page_allocator);
    const scratch = sf.get();
    var regions: std.ArrayList(Ast.Node.Index) = .empty;
    defer regions.deinit(scratch);

    const node_count: u32 = @intCast(tree.nodes.len);
    var raw: u32 = 0;
    while (raw < node_count) : (raw += 1) {
        const node: Ast.Node.Index = @enumFromInt(raw);
        if (node == body) continue;
        const first = tree.firstToken(node);
        const last = tree.lastToken(node);
        if (first < body_first or last > body_last) continue;
        if (isNestingRegionTag(tree.nodeTag(node))) {
            regions.append(scratch, node) catch {};
        }
    }

    var increments: std.ArrayList(Increment) = .empty;
    errdefer increments.deinit(allocator);

    raw = 0;
    while (raw < node_count) : (raw += 1) {
        const node: Ast.Node.Index = @enumFromInt(raw);
        if (node == body) continue;
        const first = tree.firstToken(node);
        const last = tree.lastToken(node);
        if (first < body_first or last > body_last) continue;
        try recordIncrements(
            tree,
            node,
            body_first,
            body_last,
            fn_name,
            regions.items,
            allocator,
            &increments,
        );
    }

    var score: u32 = 0;
    for (increments.items) |increment| score += increment.points;

    return .{
        .score = score,
        .increments = try increments.toOwnedSlice(allocator),
    };
}

fn isNestingRegionTag(tag: Ast.Node.Tag) bool {
    return switch (tag) {
        .if_simple,
        .@"if",
        .while_simple,
        .while_cont,
        .@"while",
        .for_simple,
        .@"for",
        .@"switch",
        .switch_comma,
        .@"catch",
        .fn_decl,
        => true,
        else => false,
    };
}

/// Coarse kind of a structural/nesting increment, used only to pick a
/// human-readable label — has no effect on the score itself.
const StructuralKind = enum { conditional, loop, switch_stmt, catch_stmt };

/// Returns a static label for a structural increment, distinguishing plain
/// from nested/deeply-nested so a pretty-mode breakdown reads naturally
/// (e.g. "nested conditional", "deeply nested loop") without formatting or
/// allocating a string per increment.
fn structuralLabel(kind: StructuralKind, nesting: u32) []const u8 {
    return switch (kind) {
        .conditional => switch (nesting) {
            0 => "conditional",
            1 => "nested conditional",
            else => "deeply nested conditional",
        },
        .loop => switch (nesting) {
            0 => "loop",
            1 => "nested loop",
            else => "deeply nested loop",
        },
        .switch_stmt => switch (nesting) {
            0 => "switch",
            1 => "nested switch",
            else => "deeply nested switch",
        },
        .catch_stmt => switch (nesting) {
            0 => "catch",
            1 => "nested catch",
            else => "deeply nested catch",
        },
    };
}

/// Appends zero, one, or two `Increment`s (a node can independently score
/// for itself and, for `if`/`else`, for its `else` clause) for a single
/// node's contribution to its enclosing function's score.
fn recordIncrements(
    tree: *const Ast,
    node: Ast.Node.Index,
    body_first: Ast.TokenIndex,
    body_last: Ast.TokenIndex,
    fn_name: []const u8,
    regions: []const Ast.Node.Index,
    allocator: std.mem.Allocator,
    out: *std.ArrayList(Increment),
) !void {
    switch (tree.nodeTag(node)) {
        .if_simple, .@"if" => {
            const if_full = tree.fullIf(node).?;
            const if_token = if_full.ast.if_token;

            if (isElseIf(tree, if_full)) {
                try out.append(allocator, .{
                    .token = if_token,
                    .points = 1,
                    .reason = "else if",
                });
            } else {
                const nesting = nestingLevel(
                    tree,
                    node,
                    regions,
                );
                try out.append(allocator, .{
                    .token = if_token,
                    .points = 1 + nesting,
                    .reason = structuralLabel(.conditional, nesting),
                });
            }

            if (if_full.ast.else_expr.unwrap()) |else_node| {
                if (!isIfTag(tree.nodeTag(else_node))) {
                    try out.append(allocator, .{
                        .token = elseKeywordToken(tree, else_node),
                        .points = 1,
                        .reason = "else clause",
                    });
                }
            }
        },
        .while_simple, .while_cont, .@"while" => {
            const nesting = nestingLevel(
                tree,
                node,
                regions,
            );
            try out.append(allocator, .{
                .token = tree.nodeMainToken(node),
                .points = 1 + nesting,
                .reason = structuralLabel(.loop, nesting),
            });
        },
        .for_simple, .@"for" => {
            const nesting = nestingLevel(
                tree,
                node,
                regions,
            );
            try out.append(allocator, .{
                .token = tree.nodeMainToken(node),
                .points = 1 + nesting,
                .reason = structuralLabel(.loop, nesting),
            });
        },
        .@"switch", .switch_comma => {
            const nesting = nestingLevel(
                tree,
                node,
                regions,
            );
            try out.append(allocator, .{
                .token = tree.nodeMainToken(node),
                .points = 1 + nesting,
                .reason = structuralLabel(.switch_stmt, nesting),
            });
        },
        .@"catch" => {
            const nesting = nestingLevel(
                tree,
                node,
                regions,
            );
            try out.append(allocator, .{
                .token = tree.nodeMainToken(node),
                .points = 1 + nesting,
                .reason = structuralLabel(.catch_stmt, nesting),
            });
        },
        .bool_and, .bool_or => {
            if (isLogicalSequenceStart(
                tree,
                node,
                body_first,
                body_last,
            )) {
                const reason: []const u8 = if (tree.nodeTag(
                    node,
                ) == .bool_and) "`and` sequence" else "`or` sequence";
                try out.append(allocator, .{
                    .token = tree.nodeMainToken(node),
                    .points = 1,
                    .reason = reason,
                });
            }
        },
        .@"break", .@"continue" => {
            if (isLoopLabelJump(
                tree,
                node,
                body_first,
                body_last,
            )) {
                const reason: []const u8 = if (tree.nodeTag(
                    node,
                ) == .@"break") "labeled break" else "labeled continue";
                try out.append(allocator, .{
                    .token = tree.nodeMainToken(node),
                    .points = 1,
                    .reason = reason,
                });
            }
        },
        .call, .call_comma, .call_one, .call_one_comma => {
            if (isDirectRecursion(
                tree,
                node,
                fn_name,
            )) {
                try out.append(allocator, .{
                    .token = tree.nodeMainToken(node),
                    .points = 1,
                    .reason = "direct recursion",
                });
            }
        },
        else => {},
    }
}

/// Finds the `else` keyword token belonging to `else_node` (an `if`'s else
/// branch), scanning backward from its first token. Handles error-union
/// captures (`else |err| {...}`) where the branch's own first token isn't
/// the token immediately after `else`.
fn elseKeywordToken(tree: *const Ast, else_node: Ast.Node.Index) Ast.TokenIndex {
    var t = tree.firstToken(else_node);
    while (t > 0) {
        t -= 1;
        if (tree.tokenTag(t) == .keyword_else) return t;
    }
    return tree.firstToken(else_node);
}

/// Counts how many control-flow body regions strictly enclose `node`.
fn nestingLevel(
    tree: *const Ast,
    node: Ast.Node.Index,
    regions: []const Ast.Node.Index,
) u32 {
    const first = tree.firstToken(node);
    const last = tree.lastToken(node);

    var level: u32 = 0;
    for (regions) |ancestor| {
        if (ancestor == node) continue;
        if (regionContains(
            tree,
            ancestor,
            first,
            last,
        )) level += 1;
    }
    return level;
}

/// Returns whether the body region of `ancestor` (then-branch, plain else, loop body, switch cases, catch handler,
/// or nested function body) strictly contains the token span `[first, last]`.
fn regionContains(
    tree: *const Ast,
    ancestor: Ast.Node.Index,
    first: Ast.TokenIndex,
    last: Ast.TokenIndex,
) bool {
    switch (tree.nodeTag(ancestor)) {
        .if_simple, .@"if" => {
            const if_full = tree.fullIf(ancestor).?;
            if (spanContains(
                tree,
                if_full.ast.then_expr,
                first,
                last,
            )) return true;
            if (if_full.ast.else_expr.unwrap()) |else_node| {
                // An `else if` does not open a new nesting region of its own here; the inner `if`
                // node contributes its own then-branch region instead.
                if (!isIfTag(tree.nodeTag(else_node)) and spanContains(
                    tree,
                    else_node,
                    first,
                    last,
                )) return true;
            }
            return false;
        },
        .while_simple, .while_cont, .@"while" => {
            const while_full = tree.fullWhile(ancestor).?;
            return spanContains(
                tree,
                while_full.ast.then_expr,
                first,
                last,
            );
        },
        .for_simple, .@"for" => {
            const for_full = tree.fullFor(ancestor).?;
            return spanContains(
                tree,
                for_full.ast.then_expr,
                first,
                last,
            );
        },
        .@"switch", .switch_comma => {
            const switch_full = tree.fullSwitch(ancestor).?;
            const cond_last = tree.lastToken(switch_full.ast.condition);
            return first > cond_last and first >= tree.firstToken(
                ancestor,
            ) and last <= tree.lastToken(ancestor);
        },
        .@"catch" => return spanContains(
            tree,
            tree.nodeData(ancestor).node_and_node[1],
            first,
            last,
        ),
        .fn_decl => return spanContains(
            tree,
            tree.nodeData(ancestor).node_and_node[1],
            first,
            last,
        ),
        else => return false,
    }
}

/// Returns whether the token span of `region` contains `[first, last]`.
fn spanContains(
    tree: *const Ast,
    region: Ast.Node.Index,
    first: Ast.TokenIndex,
    last: Ast.TokenIndex,
) bool {
    return tree.firstToken(region) <= first and last <= tree.lastToken(region);
}

fn isIfTag(tag: Ast.Node.Tag) bool {
    return tag == .if_simple or tag == .@"if";
}

/// Returns whether an `if` node is an `else if` (its `if` keyword is immediately preceded by `else`).
fn isElseIf(tree: *const Ast, if_full: Ast.full.If) bool {
    const if_token = if_full.ast.if_token;
    if (if_token == 0) return false;
    return tree.tokenTag(if_token - 1) == .keyword_else;
}

/// Returns whether a binary logical operator node starts a new sequence (no like-operator parent encloses it).
fn isLogicalSequenceStart(
    tree: *const Ast,
    node: Ast.Node.Index,
    body_first: Ast.TokenIndex,
    body_last: Ast.TokenIndex,
) bool {
    const node_tag = tree.nodeTag(node);

    const node_count: u32 = @intCast(tree.nodes.len);
    var raw: u32 = 0;
    while (raw < node_count) : (raw += 1) {
        const candidate: Ast.Node.Index = @enumFromInt(raw);
        if (candidate == node) continue;
        const parent_tag = tree.nodeTag(candidate);
        if (parent_tag != .bool_and and parent_tag != .bool_or) continue;
        const cf = tree.firstToken(candidate);
        const cl = tree.lastToken(candidate);
        if (cf < body_first or cl > body_last) continue;

        const operands = tree.nodeData(candidate).node_and_node;
        if (operands[0] == node or operands[1] == node) {
            return parent_tag != node_tag;
        }
    }
    return true;
}

/// Returns the label identifier token of a `break`/`continue` node, if present.
fn jumpLabelToken(tree: *const Ast, node: Ast.Node.Index) ?Ast.TokenIndex {
    return tree.nodeData(node).opt_token_and_opt_node[0].unwrap();
}

/// Returns whether a labeled `break`/`continue` targets an enclosing `for`/`while` loop.
fn isLoopLabelJump(
    tree: *const Ast,
    node: Ast.Node.Index,
    body_first: Ast.TokenIndex,
    body_last: Ast.TokenIndex,
) bool {
    const label_tok = jumpLabelToken(tree, node) orelse return false;
    const label_name = tree.tokenSlice(label_tok);

    const node_first = tree.firstToken(node);
    const node_last = tree.lastToken(node);

    const node_count: u32 = @intCast(tree.nodes.len);
    var raw: u32 = 0;
    while (raw < node_count) : (raw += 1) {
        const loop: Ast.Node.Index = @enumFromInt(raw);
        const tag = tree.nodeTag(loop);
        const loop_label: ?Ast.TokenIndex = switch (tag) {
            .while_simple, .while_cont, .@"while" => tree.fullWhile(loop).?.label_token,
            .for_simple, .@"for" => tree.fullFor(loop).?.label_token,
            else => null,
        };
        const lt = loop_label orelse continue;
        const lf = tree.firstToken(loop);
        const ll = tree.lastToken(loop);
        if (lf < body_first or ll > body_last) continue;
        if (lf <= node_first and node_last <= ll and std.mem.eql(
            u8,
            tree.tokenSlice(lt),
            label_name,
        )) {
            return true;
        }
    }
    return false;
}

/// Returns whether a call node invokes `fn_name` directly (by identifier).
fn isDirectRecursion(
    tree: *const Ast,
    node: Ast.Node.Index,
    fn_name: []const u8,
) bool {
    if (fn_name.len == 0) return false;
    var buf: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buf, node) orelse return false;
    if (tree.nodeTag(call.ast.fn_expr) != .identifier) return false;
    return std.mem.eql(
        u8,
        tree.tokenSlice(tree.nodeMainToken(call.ast.fn_expr)),
        fn_name,
    );
}

// --- Tests ---

fn complexityOfFirstFn(source: [:0]const u8) !u32 {
    const allocator = std.testing.allocator;
    var tree = try std.zig.Ast.parse(
        allocator,
        source,
        .zig,
    );
    defer tree.deinit(allocator);

    for (tree.rootDecls()) |decl| {
        if (tree.nodeTag(decl) == .fn_decl) {
            const result = try functionComplexity(
                allocator,
                &tree,
                decl,
            );
            defer allocator.free(result.increments);
            return result.score;
        }
    }
    return error.NoFunction;
}

test "sumOfPrimes scores 7 per the Sonar specification" {
    const score = try complexityOfFirstFn(
        \\fn sumOfPrimes(max: u32) u32 {
        \\    var total: u32 = 0;
        \\    outer: for (1..max + 1) |i| {
        \\        for (2..i) |j| {
        \\            if (i % j == 0) {
        \\                continue :outer;
        \\            }
        \\        }
        \\        total += i;
        \\    }
        \\    return total;
        \\}
    );
    try std.testing.expectEqual(@as(u32, 7), score);
}

test "switch with several cases scores 1" {
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
    try std.testing.expectEqual(@as(u32, 1), score);
}

test "if / else if / else chain scores 3" {
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

test "successively nested ifs accumulate nesting increments" {
    const score = try complexityOfFirstFn(
        \\fn h(a: bool, b: bool, c: bool) void {
        \\    if (a) {
        \\        if (b) {
        \\            if (c) {}
        \\        }
        \\    }
        \\}
    );
    try std.testing.expectEqual(@as(u32, 6), score);
}

test "a sequence of like logical operators counts once" {
    const score = try complexityOfFirstFn(
        \\fn f(a: bool, b: bool, c: bool) bool {
        \\    return a and b and c;
        \\}
    );
    try std.testing.expectEqual(@as(u32, 1), score);
}

test "mixed logical operators count each sequence" {
    const score = try complexityOfFirstFn(
        \\fn f(a: bool, b: bool, c: bool) bool {
        \\    return a and b or c;
        \\}
    );
    try std.testing.expectEqual(@as(u32, 2), score);
}

test "catch is a structural increment" {
    const score = try complexityOfFirstFn(
        \\fn k() void {
        \\    foo() catch {
        \\        bar();
        \\    };
        \\}
    );
    try std.testing.expectEqual(@as(u32, 1), score);
}

test "orelse is ignored" {
    const score = try complexityOfFirstFn(
        \\fn k(x: ?u32) u32 {
        \\    return x orelse 0;
        \\}
    );
    try std.testing.expectEqual(@as(u32, 0), score);
}

test "direct recursion increments per call site" {
    const score = try complexityOfFirstFn(
        \\fn fib(n: u32) u32 {
        \\    if (n < 2) return n;
        \\    return fib(n - 1) + fib(n - 2);
        \\}
    );
    try std.testing.expectEqual(@as(u32, 3), score);
}

test "labeled block break is not penalized" {
    const score = try complexityOfFirstFn(
        \\fn b(x: u32) u32 {
        \\    const y = blk: {
        \\        break :blk x + 1;
        \\    };
        \\    return y;
        \\}
    );
    try std.testing.expectEqual(@as(u32, 0), score);
}

test "check populates primary_label and spans for an over-threshold function" {
    const allocator = std.testing.allocator;
    const source =
        \\fn tooComplex(a: bool, b: bool, c: bool, d: bool, e: bool, f: bool) void {
        \\    if (a) {
        \\        if (b) {
        \\            if (c) {
        \\                if (d) {
        \\                    if (e) {
        \\                        if (f) {}
        \\                    }
        \\                }
        \\            }
        \\        }
        \\    }
        \\}
        \\
    ;
    var tree = try std.zig.Ast.parse(
        allocator,
        source,
        .zig,
    );
    defer tree.deinit(allocator);

    // `check` allocates diagnostic strings (subject, detail, spans, ...)
    // with `msg_allocator`, matching production use where those need to
    // outlive a per-file scratch arena — an arena here too, per the
    // convention other rule tests use, since `Diagnostic.deinitAlloc` is
    // only valid after `cloneAlloc`, not on `check`'s raw output (`.rule`
    // is a static string literal, never allocator-owned).
    var msg_arena = std.heap.ArenaAllocator.init(allocator);
    defer msg_arena.deinit();

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);

    try check(
        &tree,
        .{ .level = .warn, .options = .{ .threshold = 5 } },
        "<test>",
        allocator,
        msg_arena.allocator(),
        &diagnostics,
    );

    try std.testing.expectEqual(@as(usize, 1), diagnostics.items.len);
    const diagnostic = diagnostics.items[0];

    const label = diagnostic.primary_label orelse return error.MissingPrimaryLabel;
    try std.testing.expect(std.mem.startsWith(
        u8,
        label,
        "score: ",
    ));

    // 6 nested `if`s: not all of them fit in `max_breakdown_spans`, so only
    // the highest-scoring ones are kept — but always in ascending source
    // order for display, and never more than the cap.
    try std.testing.expect(diagnostic.spans.len > 0);
    try std.testing.expect(diagnostic.spans.len <= max_breakdown_spans);

    var previous_line: usize = 0;
    for (diagnostic.spans) |span| {
        try std.testing.expect(span.line > previous_line);
        previous_line = span.line;
        try std.testing.expect(span.label.len > 0);
        try std.testing.expect(std.mem.indexOfScalar(
            u8,
            span.label,
            '+',
        ) != null);
    }

    // The deepest `if` (line 7) scores the most and must survive the cap.
    try std.testing.expectEqualStrings(
        "+6 (deeply nested conditional)",
        diagnostic.spans[diagnostic.spans.len - 1].label,
    );
}

fn runCheck(
    source: [:0]const u8,
    rule: Rule,
    diagnostics: *std.ArrayList(Diagnostic),
    msg_allocator: std.mem.Allocator,
) !void {
    const allocator = std.testing.allocator;
    var tree = try std.zig.Ast.parse(
        allocator,
        source,
        .zig,
    );
    defer tree.deinit(allocator);

    try check(
        &tree,
        rule,
        "<test>",
        allocator,
        msg_allocator,
        diagnostics,
    );
}

test "emits a diagnostic only above the threshold" {
    const source =
        \\pub fn complex(a: bool, b: bool, c: bool) void {
        \\    if (a) {
        \\        if (b) {
        \\            if (c) {}
        \\        }
        \\    }
        \\}
    ;

    var equal_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer equal_arena.deinit();
    var equal_to_threshold: std.ArrayList(Diagnostic) = .empty;
    defer equal_to_threshold.deinit(std.testing.allocator);
    try runCheck(
        source,
        .{ .level = .warn, .options = .{ .threshold = 6 } },
        &equal_to_threshold,
        equal_arena.allocator(),
    );
    try std.testing.expectEqual(@as(usize, 0), equal_to_threshold.items.len);

    var above_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer above_arena.deinit();
    var above_threshold: std.ArrayList(Diagnostic) = .empty;
    defer above_threshold.deinit(std.testing.allocator);
    try runCheck(
        source,
        .{ .level = .warn, .options = .{ .threshold = 5 } },
        &above_threshold,
        above_arena.allocator(),
    );
    try std.testing.expectEqual(@as(usize, 1), above_threshold.items.len);
    try std.testing.expectEqualStrings("complex", above_threshold.items[0].subject.?.name);
}

test "private functions are skipped under public_api_only" {
    const source =
        \\fn complex(a: bool, b: bool, c: bool) void {
        \\    if (a) {
        \\        if (b) {
        \\            if (c) {}
        \\        }
        \\    }
        \\}
    ;

    var msg_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer msg_arena.deinit();
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    try runCheck(
        source,
        .{
            .level = .warn,
            .scan_mode = .public_declarations,
            .options = .{ .threshold = 1 },
        },
        &diagnostics,
        msg_arena.allocator(),
    );
    try std.testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}

comptime {
    std.testing.refAllDecls(@This());
}

fn isPubVisibility(tree: *const Ast, visib_token: ?Ast.TokenIndex) bool {
    const token = visib_token orelse return false;
    return tree.tokenTag(token) == .keyword_pub;
}

fn isContainerDecl(tag: Ast.Node.Tag) bool {
    return switch (tag) {
        .container_decl,
        .container_decl_trailing,
        .container_decl_two,
        .container_decl_two_trailing,
        .container_decl_arg,
        .container_decl_arg_trailing,
        .tagged_union,
        .tagged_union_trailing,
        .tagged_union_two,
        .tagged_union_two_trailing,
        .tagged_union_enum_tag,
        .tagged_union_enum_tag_trailing,
        => true,
        else => false,
    };
}

fn ownedSubject(
    allocator: std.mem.Allocator,
    kind: Diagnostic.SubjectKind,
    name: []const u8,
) !Diagnostic.Subject {
    return .{ .kind = kind, .name = try allocator.dupe(u8, name) };
}

fn dupSourceLine(
    tree: *const Ast,
    token: Ast.TokenIndex,
    allocator: std.mem.Allocator,
) ![]const u8 {
    const loc = tree.tokenLocation(0, token);
    var end = loc.line_start;
    while (end < tree.source.len and tree.source[end] != '\n') end += 1;
    return allocator.dupe(u8, std.mem.trimEnd(
        u8,
        tree.source[loc.line_start..end],
        "\r",
    ));
}
