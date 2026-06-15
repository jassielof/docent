//! The `missing_summary_terminal_punctuation` namespace flags doc comment summaries without terminal punctuation.
//!
//! It'll check if the last character is a punctuation mark (e.g. period, exclamation/question mark).

const std = @import("std");
const Ast = std.zig.Ast;
const Diagnostic = @import("../../Diagnostic.zig");
const severity = @import("../../severity.zig");
const scanning = @import("../../scanning.zig");
const category = @import("../category.zig");
const utils = @import("../utils.zig");
const doc = @import("../../doc.zig");

inline fn srcLoc() std.builtin.SourceLocation {
    return @src();
}

const rule_name = utils.ruleIdFromSrc(srcLoc());

/// The default_severity for the rule.
pub const default_severity: severity.Level = .warn;

/// Full configuration for `missing_summary_terminal_punctuation`: severity and scan mode, with no rule-specific options.
pub const Rule = category.Rule(default_severity, struct {}, scanning.Modes.public_api_surface);

/// Walks `tree` and appends diagnostics when the first doc-comment paragraph lacks `.`, `!`, or `?`.
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

        const summary = try doc.comment.firstParagraph(tree, block_start, block_end, msg_allocator);
        defer msg_allocator.free(summary.text);
        if (summary.text.len == 0) continue;
        if (doc.comment.endsWithTerminalPunctuation(summary.text)) continue;

        const report_tok = summary.last_line_token orelse @as(Ast.TokenIndex, @intCast(block_start));
        const slice = tree.tokenSlice(report_tok);
        const loc = tree.tokenLocation(0, report_tok);
        const subject = if (tag == .container_doc_comment)
            try utils.ownedSubject(msg_allocator, .module, utils.moduleDisplayName(file, module_name))
        else
            try doc.resolveDocCommentSubject(tree, documented_first, file, module_name, msg_allocator);
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

    try check(&tree, .{}, "<test>", null, base, msg_arena.allocator(), &diagnostics);
    return .{ .msg_arena = msg_arena, .items = diagnostics };
}

test "detects missing terminal punctuation on /// comment" {
    var r = try runCheck("/// Does something\npub fn foo() void {}");
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 1), r.items.items.len);
    try std.testing.expectEqualStrings("foo", r.items.items[0].subject.?.name);
}

test "well-punctuated summary is clean" {
    var r = try runCheck("/// Does something.\npub fn foo() void {}");
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 0), r.items.items.len);
}

test "accepts exclamation and question marks" {
    const source =
        \\/// Watch out!
        \\pub fn a() void {}
        \\/// Really?
        \\pub fn b() void {}
    ++ "\x00";
    var r = try runCheck(source);
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 0), r.items.items.len);
}

test "only first paragraph is checked" {
    const source =
        \\/// Summary sentence.
        \\///
        \\/// Second paragraph without punctuation
        \\pub fn foo() void {}
    ++ "\x00";
    var r = try runCheck(source);
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 0), r.items.items.len);
}

test "multiline summary within first paragraph" {
    const source =
        \\/// Adds two integers and returns
        \\/// the sum
        \\pub fn add(a: u32, b: u32) u32 { return a + b; }
    ++ "\x00";
    var r = try runCheck(source);
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 1), r.items.items.len);
}

test "multiline summary with punctuation is clean" {
    const source =
        \\/// Adds two integers and returns
        \\/// the sum.
        \\pub fn add(a: u32, b: u32) u32 { return a + b; }
    ++ "\x00";
    var r = try runCheck(source);
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 0), r.items.items.len);
}

test "blank doc comment is skipped" {
    var r = try runCheck("///\npub fn foo() void {}");
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 0), r.items.items.len);
}

test "detects missing punctuation on //! module doc" {
    var r = try runCheck("//! Module overview\npub fn foo() void {}");
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 1), r.items.items.len);
    try std.testing.expectEqual(.module, r.items.items[0].subject.?.kind);
}

test "enum member summary punctuation" {
    const source =
        \\pub const Color = enum {
        \\    /// Primary red
        \\    red,
        \\};
    ++ "\x00";
    var r = try runCheck(source);
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 1), r.items.items.len);
    try std.testing.expectEqual(.enumerator, r.items.items[0].subject.?.kind);
}
