//! The `cyclomatic` namespace provides the implementation of the cyclomatic complexity rule.
//!
//! Cyclomatic complexity counts linearly independent paths through a function's control flow (McCabe, 1976). The score adds one for each decision point: `if`, loops, `catch`, logical `and`/`or`, and each `switch` prong. Unlike cognitive complexity, `switch` arms are counted individually rather than as a single structure.
//!
//! See NIST/McCabe guidance (_Structured Testing: A Testing Methodology Using the Cyclomatic Complexity Metric_).
//!
//! Unlike tools like [Lizard](https://github.com/terryyin/lizard/), which can be configured to treat an entire `switch` statement as a single branch, this tool enforces the traditional mathematical definition. While some teams modify it to act as a proxy for readability, it should be used strictly as a **testability metric** (mapping directly to the number of required unit tests). Readability and maintainability concerns are instead handled by _Cognitive Complexity_, which provides a much more reliable metric for human code comprehension.
//!
//! Therefore, exhaustive `switch` statements over `enum`s are still penalized, as each branch represents a real, testable path regardless of whether the compiler requires it.

const std = @import("std");
const Ast = std.zig.Ast;

const Diagnostic = @import("../../Diagnostic.zig");
const severity = @import("../../severity.zig");
const scan = @import("../../scan.zig");
const category = @import("../category.zig");
const utils = @import("../utils.zig");

const rule_name = utils.ruleIdWithName("cyclomatic_complexity");

/// Default severity `warn`: a high path count is a testability signal worth surfacing without failing a fresh build.
pub const default_severity: severity.Level = .warn;

/// Title for diagnostic prose (`Warning: {prose_title} on …`).
pub const prose_title = "Cyclomatic complexity";

/// The Options for the rule.
pub const Options = struct {
    /// The threshold for triggering the rule.
    threshold: u32 = default_threshold,
};

/// Full configuration for `cyclomatic_complexity`: severity, scan mode, and the documented `Options` sub-space.
pub const Rule = category.Rule(default_severity, Options, scan.Modes.reachability_traversal);

/// Number of linearly independent paths through a function control-flow graph (McCabe *V(G)*).
pub const Complexity = u32;

/// McCabe cyclomatic complexity from control-flow graph dimensions: *V(G) = E − N + 2P*.
pub fn formula(
    edges: u32,
    nodes: u32,
    connected_components: u32,
) Complexity {
    const result = @as(i64, edges) - @as(i64, nodes) + 2 * @as(i64, connected_components);

    return @intCast(result);
}

/// Default McCabe-recommended limit on linearly independent paths.
///
/// As suggested by McCabe, a score of 10–15 is considered _complex_, and anything above 15 is considered _risky_.
///
/// See § 2.5: _Limiting cyclomatic complexity to 10_.
pub const default_threshold: Complexity = 10;

/// Walks `tree` and appends a diagnostic for each scanned function whose cyclomatic complexity exceeds `threshold`.
///
/// When `public_api_only` is set, only `pub` functions (at the container level) are measured; otherwise every container-level function is measured.
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
    const public_api_only = rule.publicApiOnly();
    const threshold = rule.options.threshold;

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

const GraphMetrics = struct {
    nodes: u32,
    edges: u32,
    connected_components: u32,
};

fn functionComplexity(tree: *const Ast, fn_node: Ast.Node.Index) Complexity {
    const metrics = graphMetrics(tree, fn_node);
    return formula(metrics.edges, metrics.nodes, metrics.connected_components);
}

/// Derives *N* and *E* for a single-function graph from its decision-point count. For structured control flow with one connected component, *V(G) = 1 + d* where *d* is the number of decision points. That is equivalent to *V(G) = E − N + 2* when *N = d + 1*, *E = 2d*, and *P = 1*.
fn graphMetrics(tree: *const Ast, fn_node: Ast.Node.Index) GraphMetrics {
    const decision_points = countDecisionPoints(tree, fn_node);
    return .{
        .nodes = decision_points + 1,
        .edges = decision_points * 2,
        .connected_components = 1,
    };
}

fn countDecisionPoints(tree: *const Ast, fn_node: Ast.Node.Index) u32 {
    const body = tree.nodeData(fn_node).node_and_node[1];
    const body_first = tree.firstToken(body);
    const body_last = tree.lastToken(body);

    var points: u32 = 0;
    const node_count: u32 = @intCast(tree.nodes.len);
    var raw: u32 = 0;
    while (raw < node_count) : (raw += 1) {
        const node: Ast.Node.Index = @enumFromInt(raw);
        if (node == body) continue;
        const first = tree.firstToken(node);
        const last = tree.lastToken(node);
        if (first < body_first or last > body_last) continue;
        points += nodeIncrement(tree, node);
    }
    return points;
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

fn complexityOfFirstFn(source: [:0]const u8) !Complexity {
    const allocator = std.testing.allocator;
    var tree = try std.zig.Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);

    for (tree.rootDecls()) |decl| {
        if (tree.nodeTag(decl) == .fn_decl) return functionComplexity(&tree, decl);
    }

    return error.NoFunction;
}

test "formula computes V(G) = E - N + 2P" {
    try std.testing.expectEqual(@as(Complexity, 1), formula(0, 1, 1));
    try std.testing.expectEqual(@as(Complexity, 3), formula(4, 3, 1));
    try std.testing.expectEqual(@as(Complexity, 5), formula(8, 5, 1));
}

// TODO: This code-based tests need to be moved as integration tests.
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
