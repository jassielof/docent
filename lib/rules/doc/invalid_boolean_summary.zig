//! The `invalid_boolean_summary` namespace flags doc comment summaries on functions returning `bool` that don't follow Go's boolean-function phrasing convention.
//!
//! Inspired by [Go's documentation style guidelines](https://go.dev/doc/comment):
//!
//! > Doc comments typically use the phrase "reports whether" to describe functions that return a boolean. The phrase "or not" is unnecessary.
//!
//! Only applies to functions whose declared return type is the plain `bool` identifier; error unions, optionals, and generic return types are left alone.

const std = @import("std");
const Ast = std.zig.Ast;

const doc_comment = @import("doc_comment");
const lint = @import("lint");
const category = lint.category;
const Diagnostic = lint.Diagnostic;
const scan = lint.scan;
const severity = lint.severity;

const utils = @import("../utils.zig");

inline fn srcLoc() std.builtin.SourceLocation {
    return @src();
}

const rule_name = utils.ruleIdFromSrc(srcLoc());

/// Default severity `allow`: by default, this style check is not enforced.
pub const default_severity: severity.Level = .allow;

/// Title for diagnostic prose (`Warning: {prose_title} on …`).
pub const prose_title = "Invalid boolean summary phrasing";

/// Full configuration for `invalid_boolean_summary`: severity and scan mode, with no rule-specific options.
pub const Rule = category.Rule(
    default_severity,
    struct {},
    scan.RuleScanConfig.public_declarations,
);

/// Walks `tree` and appends diagnostics for `bool`-returning functions whose summary omits "reports whether" or includes the redundant "or not".
pub fn check(
    tree: *const Ast,
    rule: Rule,
    file: []const u8,
    module_name: ?[]const u8,
    allocator: std.mem.Allocator,
    msg_allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) !void {
    if (!rule.level.isActive()) return;
    const severity_level = rule.level;
    const public_api_only = rule.publicDeclarationsOnly();
    const tags = tree.tokens.items(.tag);
    var i: usize = 0;
    while (i < tags.len) {
        // Only `///` doc comments can attach to a function; `//!` module docs never do.
        if (tags[i] != .doc_comment) {
            i += 1;
            continue;
        }

        const block_start = i;
        while (i < tags.len and tags[i] == .doc_comment) : (i += 1) {}
        const block_end = i;
        const documented_first: Ast.TokenIndex = @intCast(block_end);

        if (!doc_comment.shouldCheckDocCommentTarget(
            tree,
            documented_first,
            public_api_only,
        )) continue;

        const fn_node = doc_comment.resolveDocCommentFnDecl(
            tree,
            documented_first,
        ) orelse continue;
        if (!doc_comment.fnReturnsPlainBool(tree, fn_node)) continue;

        const paragraph = try doc_comment.comment.firstParagraph(
            tree,
            block_start,
            block_end,
            msg_allocator,
        );
        defer msg_allocator.free(paragraph.text);
        if (paragraph.text.len == 0) continue;

        const lower = try lowerAlloc(msg_allocator, paragraph.text);
        defer msg_allocator.free(lower);

        const has_reports_whether = std.mem.indexOf(
            u8,
            lower,
            "reports whether",
        ) != null;
        const has_or_not = std.mem.indexOf(
            u8,
            lower,
            "or not",
        ) != null;
        if (has_reports_whether and !has_or_not) continue;

        const report_tok = paragraph.last_line_token orelse @as(
            Ast.TokenIndex,
            @intCast(block_start),
        );
        const slice = tree.tokenSlice(report_tok);
        const loc = tree.tokenLocation(0, report_tok);
        const subject = utils.diagnosticSubjectFromDoc(try doc_comment.resolveDocCommentSubject(
            tree,
            documented_first,
            file,
            module_name,
            msg_allocator,
        ));
        const source_line = try utils.dupSourceLine(
            tree,
            report_tok,
            msg_allocator,
        );

        if (!has_reports_whether) {
            try diagnostics.append(allocator, .{
                .rule = rule_name,
                .severity_level = severity_level,
                .subject = subject,
                .detail = "expected the summary to use 'reports whether' to describe a function returning bool",
                .file = file,
                .line = loc.line + 1,
                .column = loc.column + 1,
                .source_line = source_line,
                .symbol_len = slice.len,
            });
        }

        if (has_or_not) {
            try diagnostics.append(allocator, .{
                .rule = rule_name,
                .severity_level = severity_level,
                .subject = subject,
                .detail = "the phrase 'or not' is unnecessary",
                .file = file,
                .line = loc.line + 1,
                .column = loc.column + 1,
                .source_line = source_line,
                .symbol_len = slice.len,
            });
        }
    }
}

fn lowerAlloc(allocator: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error![]u8 {
    const buf = try allocator.alloc(u8, text.len);
    for (text, 0..) |c, idx| buf[idx] = std.ascii.toLower(c);
    return buf;
}

fn runCheck(
    source: [:0]const u8,
    rule: Rule,
    diagnostics: *std.ArrayList(Diagnostic),
    msg_allocator: std.mem.Allocator,
) !void {
    const base = std.testing.allocator;
    var tree = try std.zig.Ast.parse(
        base,
        source,
        .zig,
    );
    defer tree.deinit(base);

    try check(
        &tree,
        rule,
        "<test>",
        null,
        base,
        msg_allocator,
        diagnostics,
    );
}

test "accepts 'reports whether' phrasing" {
    const source =
        \\/// hasPrefix reports whether s begins with prefix.
        \\pub fn hasPrefix(s: []const u8, prefix: []const u8) bool {
        \\    return true;
        \\}
    ;

    var msg_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer msg_arena.deinit();
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);

    try runCheck(
        source,
        .{ .level = .warn, .scan_mode = .public_declarations },
        &diagnostics,
        msg_arena.allocator(),
    );
    try std.testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}

test "warns when summary omits 'reports whether'" {
    const source =
        \\/// hasPrefix checks if s begins with prefix.
        \\pub fn hasPrefix(s: []const u8, prefix: []const u8) bool {
        \\    return true;
        \\}
    ;

    var msg_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer msg_arena.deinit();
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);

    try runCheck(
        source,
        .{ .level = .warn, .scan_mode = .public_declarations },
        &diagnostics,
        msg_arena.allocator(),
    );
    try std.testing.expectEqual(@as(usize, 1), diagnostics.items.len);
    try std.testing.expectEqual(.function, diagnostics.items[0].subject.?.kind);
    try std.testing.expectEqualStrings("hasPrefix", diagnostics.items[0].subject.?.name);
    try std.testing.expect(std.mem.indexOf(
        u8,
        diagnostics.items[0].detail.?,
        "reports whether",
    ) != null);
}

test "warns on redundant 'or not'" {
    const source =
        \\/// hasPrefix reports whether or not s begins with prefix.
        \\pub fn hasPrefix(s: []const u8, prefix: []const u8) bool {
        \\    return true;
        \\}
    ;

    var msg_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer msg_arena.deinit();
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);

    try runCheck(
        source,
        .{ .level = .warn, .scan_mode = .public_declarations },
        &diagnostics,
        msg_arena.allocator(),
    );
    try std.testing.expectEqual(@as(usize, 1), diagnostics.items.len);
    try std.testing.expect(std.mem.indexOf(
        u8,
        diagnostics.items[0].detail.?,
        "or not",
    ) != null);
}

test "reports both diagnostics when missing phrase and redundant 'or not' co-occur" {
    const source =
        \\/// hasPrefix checks whether or not s begins with prefix.
        \\pub fn hasPrefix(s: []const u8, prefix: []const u8) bool {
        \\    return true;
        \\}
    ;

    var msg_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer msg_arena.deinit();
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);

    try runCheck(
        source,
        .{ .level = .warn, .scan_mode = .public_declarations },
        &diagnostics,
        msg_arena.allocator(),
    );
    try std.testing.expectEqual(@as(usize, 2), diagnostics.items.len);
}

test "ignores functions that don't return plain bool" {
    const source =
        \\/// count returns the number of matches.
        \\pub fn count(s: []const u8, prefix: []const u8) usize {
        \\    return 0;
        \\}
    ;

    var msg_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer msg_arena.deinit();
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);

    try runCheck(
        source,
        .{ .level = .warn, .scan_mode = .public_declarations },
        &diagnostics,
        msg_arena.allocator(),
    );
    try std.testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}

test "no diagnostic for private function when public_api_only" {
    const source =
        \\/// hasPrefix checks if s begins with prefix.
        \\fn hasPrefix(s: []const u8, prefix: []const u8) bool {
        \\    return true;
        \\}
        \\
        \\pub fn use() bool {
        \\    return hasPrefix("a", "a");
        \\}
    ;

    var msg_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer msg_arena.deinit();
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);

    try runCheck(
        source,
        .{ .level = .warn, .scan_mode = .public_declarations },
        &diagnostics,
        msg_arena.allocator(),
    );
    try std.testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}

test "private function checked when public_api_only is false" {
    const source =
        \\/// hasPrefix checks if s begins with prefix.
        \\fn hasPrefix(s: []const u8, prefix: []const u8) bool {
        \\    return true;
        \\}
        \\
        \\pub fn use() bool {
        \\    return hasPrefix("a", "a");
        \\}
    ;

    var msg_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer msg_arena.deinit();
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);

    try runCheck(
        source,
        .{ .level = .warn, .scan_mode = .all_declarations },
        &diagnostics,
        msg_arena.allocator(),
    );
    try std.testing.expectEqual(@as(usize, 1), diagnostics.items.len);
}

comptime {
    std.testing.refAllDecls(@This());
}
