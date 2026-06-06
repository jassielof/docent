//! The `missing_summary_terminal_punctuation` namespace flags doc comment summaries without terminal punctuation.
//!
//! It'll check if the last character is a punctuation mark (e.g. period, exclamation/question mark).

const std = @import("std");
const Ast = std.zig.Ast;
const Diagnostic = @import("../../Diagnostic.zig");
const severity = @import("../../severity.zig");
const utils = @import("../utils.zig");

inline fn srcLoc() std.builtin.SourceLocation {
    return @src();
}

const rule_name = utils.ruleIdFromSrc(srcLoc());

/// The default_severity for the rule.
pub const default_severity: severity.Level = .warn;

/// Walks `tree` and appends diagnostics when the first doc-comment paragraph lacks `.`, `!`, or `?`.
pub fn check(
    tree: *const Ast,
    severity_level: severity.Level,
    file: []const u8,
    module_name: ?[]const u8,
    allocator: std.mem.Allocator,
    msg_allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) !void {
    if (!severity_level.isActive()) return;
    const tags = tree.tokens.items(.tag);
    var i: usize = 0;
    while (i < tags.len) {
        const tag = tags[i];
        if (tag != .doc_comment and tag != .container_doc_comment) {
            i += 1;
            continue;
        }

        const block_start = i;
        while (i < tags.len and tags[i] == tag) : (i += 1) {}

        const block_end = i;
        const documented_first: Ast.TokenIndex = @intCast(block_end);

        const summary = try collectSummaryParagraph(tree, block_start, block_end, msg_allocator);
        if (summary.text.len == 0) continue;
        if (utils.endsWithTerminalPunctuation(summary.text)) continue;

        const report_tok = summary.last_line_token orelse @as(Ast.TokenIndex, @intCast(block_start));
        const slice = tree.tokenSlice(report_tok);
        const loc = tree.tokenLocation(0, report_tok);
        const subject = if (tag == .container_doc_comment)
            try utils.ownedSubject(msg_allocator, .module, utils.moduleDisplayName(file, module_name))
        else
            try utils.resolveDocCommentSubject(tree, documented_first, file, module_name, msg_allocator);
        try diagnostics.append(allocator, .{
            .rule = rule_name,
            .severity_level = severity_level,
            .subject = subject,
            .file = file,
            .line = loc.line + 1,
            .column = loc.column + 1,
            .source_line = try utils.dupSourceLine(tree, report_tok, msg_allocator),
            .symbol_len = slice.len,
        });
    }
}

const SummaryParagraph = struct {
    text: []const u8,
    last_line_token: ?Ast.TokenIndex,
};

fn collectSummaryParagraph(
    tree: *const Ast,
    block_start: usize,
    block_end: usize,
    allocator: std.mem.Allocator,
) std.mem.Allocator.Error!SummaryParagraph {
    var summary = std.ArrayList(u8).empty;
    defer summary.deinit(allocator);

    var last_line_token: ?Ast.TokenIndex = null;

    var tok: usize = block_start;
    while (tok < block_end) : (tok += 1) {
        const token: Ast.TokenIndex = @intCast(tok);
        const slice = tree.tokenSlice(token);
        if (utils.isEmptyDocCommentLine(slice)) break;

        const body = utils.docCommentLineBody(slice);
        if (body.len == 0) continue;

        if (summary.items.len > 0) try summary.append(allocator, ' ');
        try summary.appendSlice(allocator, body);
        last_line_token = token;
    }

    return .{
        .text = try summary.toOwnedSlice(allocator),
        .last_line_token = last_line_token,
    };
}

const TestResult = struct {
    msg_arena: std.heap.ArenaAllocator,
    items: std.ArrayList(Diagnostic),

    fn deinit(self: *TestResult) void {
        self.msg_arena.deinit();
        self.items.deinit(std.testing.allocator);
    }
};

fn runCheck(source: [:0]const u8) !TestResult {
    const base = std.testing.allocator;
    var msg_arena = std.heap.ArenaAllocator.init(base);
    errdefer msg_arena.deinit();

    var tree = try std.zig.Ast.parse(base, source, .zig);
    defer tree.deinit(base);

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    errdefer diagnostics.deinit(base);

    try check(&tree, .warn, "<test>", null, base, msg_arena.allocator(), &diagnostics);
    return .{ .msg_arena = msg_arena, .items = diagnostics };
}

test "detects missing terminal punctuation on /// comment" {
    var r = try runCheck("/// Does something\npub fn foo() void {}");
    defer r.deinit();
    try std.testing.expectEqual(1, r.items.items.len);
    try std.testing.expectEqualStrings(rule_name, r.items.items[0].rule);
    try std.testing.expectEqual(.function, r.items.items[0].subject.?.kind);
    try std.testing.expectEqualStrings("foo", r.items.items[0].subject.?.name);
}

test "no diagnostic when summary ends with period" {
    var r = try runCheck("/// Does something.\npub fn foo() void {}");
    defer r.deinit();
    try std.testing.expectEqual(0, r.items.items.len);
}

test "accepts exclamation and question marks" {
    var r = try runCheck(
        \\/// Watch out!
        \\pub fn a() void {}
        \\/// Really?
        \\pub fn b() void {}
        ,
    );
    defer r.deinit();
    try std.testing.expectEqual(0, r.items.items.len);
}

test "only checks the first paragraph" {
    var r = try runCheck(
        \\/// Summary sentence.
        \\///
        \\/// Second paragraph without punctuation
        \\pub fn foo() void {}
        ,
    );
    defer r.deinit();
    try std.testing.expectEqual(0, r.items.items.len);
}

test "detects missing punctuation on last line of multiline summary" {
    var r = try runCheck(
        \\/// Adds two integers and returns
        \\/// the sum
        \\pub fn add(a: i32, b: i32) i32 {
        \\    return a + b;
        \\}
        ,
    );
    defer r.deinit();
    try std.testing.expectEqual(1, r.items.items.len);
    try std.testing.expectEqual(@as(usize, 2), r.items.items[0].line);
}

test "multiline summary with terminal punctuation is valid" {
    var r = try runCheck(
        \\/// Adds two integers and returns
        \\/// the sum.
        \\pub fn add(a: i32, b: i32) i32 {
        \\    return a + b;
        \\}
        ,
    );
    defer r.deinit();
    try std.testing.expectEqual(0, r.items.items.len);
}

test "no diagnostic for fully blank block" {
    var r = try runCheck("///\npub fn foo() void {}");
    defer r.deinit();
    try std.testing.expectEqual(0, r.items.items.len);
}

test "detects missing punctuation on //! module doc" {
    var r = try runCheck("//! Module overview\npub fn foo() void {}");
    defer r.deinit();
    try std.testing.expectEqual(1, r.items.items.len);
    try std.testing.expectEqual(.module, r.items.items[0].subject.?.kind);
}

test "detects missing punctuation on enum enumerator doc" {
    var r = try runCheck(
        \\pub const Color = enum {
        \\    /// Primary red
        \\    red,
        \\};
        ,
    );
    defer r.deinit();
    try std.testing.expectEqual(1, r.items.items.len);
    try std.testing.expectEqual(.enumerator, r.items.items[0].subject.?.kind);
    try std.testing.expectEqualStrings("red", r.items.items[0].subject.?.name);
}
