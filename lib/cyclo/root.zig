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

const lint = @import("lint");
const category = lint.category;
const Diagnostic = lint.Diagnostic;
const scan = lint.scan;
const severity = lint.severity;
const complexity_breakdown = lint.complexity_breakdown;
const Increment = complexity_breakdown.Increment;

/// Number of highest-scoring contributors shown as secondary spans in
/// pretty-mode output.
const max_breakdown_spans = 4;

const rule_name = "cyclomatic_complexity";

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
pub const Rule = category.Rule(
    default_severity,
    Options,
    scan.RuleScanConfig.reachability_traversal,
);

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
        try collectFunctions(
            tree,
            decl,
            public_api_only,
            allocator,
            &fns,
        );
    }

    for (fns.items) |fn_node| {
        const increments = try collectDecisionPoints(
            allocator,
            tree,
            fn_node,
        );
        defer allocator.free(increments);

        var points: u32 = 0;
        for (increments) |increment| points += increment.points;
        const score = formula(
            points * 2,
            points + 1,
            1,
        );
        if (score <= threshold) continue;

        var buf: [1]Ast.Node.Index = undefined;
        const proto = tree.fullFnProto(&buf, fn_node) orelse continue;
        const name_tok = proto.name_token orelse continue;
        const name = tree.tokenSlice(name_tok);
        const loc = tree.tokenLocation(0, name_tok);

        const spans = try complexity_breakdown.buildSpans(
            msg_allocator,
            tree,
            increments,
            max_breakdown_spans,
        );
        const help: ?[]const u8 = if (complexity_breakdown.topLine(tree, increments)) |top_line|
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
                "cyclomatic complexity {d} exceeds threshold {d}",
                .{ score, threshold },
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
                .{score},
            ),
            .spans = spans,
            .help = help,
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

/// Collects one `Increment` per decision point in `fn_node`'s body — each
/// worth exactly 1, since cyclomatic complexity (unlike cognitive) doesn't
/// weight by nesting depth. A `switch` contributes one increment per prong
/// beyond the first (its base path is "free"), each anchored at that
/// prong's own location, rather than one bulk increment for the whole
/// statement — this is what lets the pretty-mode breakdown point at
/// individual prongs. Caller owns the returned slice via `allocator`.
fn collectDecisionPoints(
    allocator: std.mem.Allocator,
    tree: *const Ast,
    fn_node: Ast.Node.Index,
) std.mem.Allocator.Error![]Increment {
    const body = tree.nodeData(fn_node).node_and_node[1];
    const body_first = tree.firstToken(body);
    const body_last = tree.lastToken(body);

    var increments: std.ArrayList(Increment) = .empty;
    errdefer increments.deinit(allocator);

    const node_count: u32 = @intCast(tree.nodes.len);
    var raw: u32 = 0;
    while (raw < node_count) : (raw += 1) {
        const node: Ast.Node.Index = @enumFromInt(raw);
        if (node == body) continue;
        const first = tree.firstToken(node);
        const last = tree.lastToken(node);
        if (first < body_first or last > body_last) continue;
        try recordDecisionPoints(tree, node, allocator, &increments);
    }

    return increments.toOwnedSlice(allocator);
}

fn recordDecisionPoints(
    tree: *const Ast,
    node: Ast.Node.Index,
    allocator: std.mem.Allocator,
    out: *std.ArrayList(Increment),
) !void {
    switch (tree.nodeTag(node)) {
        .if_simple, .@"if" => try out.append(allocator, .{ .token = tree.nodeMainToken(node), .points = 1, .reason = "if" }),
        .while_simple, .while_cont, .@"while" => try out.append(allocator, .{ .token = tree.nodeMainToken(node), .points = 1, .reason = "loop" }),
        .for_simple, .@"for" => try out.append(allocator, .{ .token = tree.nodeMainToken(node), .points = 1, .reason = "loop" }),
        .@"catch" => try out.append(allocator, .{ .token = tree.nodeMainToken(node), .points = 1, .reason = "catch" }),
        .bool_and => try out.append(allocator, .{ .token = tree.nodeMainToken(node), .points = 1, .reason = "`and`" }),
        .bool_or => try out.append(allocator, .{ .token = tree.nodeMainToken(node), .points = 1, .reason = "`or`" }),
        .@"switch", .switch_comma => {
            const switch_full = tree.fullSwitch(node) orelse return;
            const cases = switch_full.ast.cases;
            if (cases.len == 0) return;
            for (cases[1..]) |case_node| {
                try out.append(allocator, .{ .token = tree.firstToken(case_node), .points = 1, .reason = "switch prong" });
            }
        },
        else => {},
    }
}

test "formula computes V(G) = E - N + 2P" {
    try std.testing.expectEqual(@as(Complexity, 1), formula(
        0,
        1,
        1,
    ));
    try std.testing.expectEqual(@as(Complexity, 3), formula(
        4,
        3,
        1,
    ));
    try std.testing.expectEqual(@as(Complexity, 5), formula(
        8,
        5,
        1,
    ));
}

test "check populates primary_label and spans, capped and in source order" {
    const allocator = std.testing.allocator;
    const source =
        \\fn classify(x: u8) u8 {
        \\    switch (x) {
        \\        0 => return 0,
        \\        1 => return 1,
        \\        2 => return 2,
        \\        3 => return 3,
        \\        4 => return 4,
        \\        5 => return 5,
        \\        else => return 6,
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

    // Same convention as cogni's equivalent test: `check`'s diagnostics are
    // only safe to free via `deinitAlloc` after `cloneAlloc`, so a scratch
    // arena backs `msg_allocator` here instead.
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

    // 7 cases -> 6 decision points -> V(G) = 1 + 6 = 7, over threshold 5.
    try std.testing.expectEqual(@as(usize, 1), diagnostics.items.len);
    const diagnostic = diagnostics.items[0];
    try std.testing.expectEqualStrings("score: 7", diagnostic.primary_label orelse return error.MissingPrimaryLabel);

    // All 6 prongs are worth exactly 1 point each (cyclomatic doesn't
    // weight by nesting) — ties are broken by source position, so the
    // cap keeps the first `max_breakdown_spans` prongs in the switch.
    try std.testing.expectEqual(max_breakdown_spans, diagnostic.spans.len);
    var previous_line: usize = 0;
    for (diagnostic.spans) |span| {
        try std.testing.expect(span.line > previous_line);
        previous_line = span.line;
        try std.testing.expectEqualStrings("+1 (switch prong)", span.label);
    }
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
