//! The `missing_summary_terminal_punctuation` namespace flags doc comment summaries without terminal punctuation.
//!
//! It'll check if the last character is a punctuation mark (e.g. period, exclamation/question mark).

const std = @import("std");
const Ast = std.zig.Ast;
const Diagnostic = @import("../../Diagnostic.zig");
const severity = @import("../../severity.zig");
const scan = @import("../../scan.zig");
const category = @import("../category.zig");
const utils = @import("../utils.zig");
const doc = @import("../../doc.zig");

inline fn srcLoc() std.builtin.SourceLocation {
    return @src();
}

const rule_name = utils.ruleIdFromSrc(srcLoc());

/// The default_severity for the rule.
pub const default_severity: severity.Level = .warn;

/// Title for diagnostic prose (`Warning: {prose_title} on …`).
pub const prose_title = "Missing summary terminal punctuation";

/// Full configuration for `missing_summary_terminal_punctuation`: severity and scan mode, with no rule-specific options.
pub const Rule = category.Rule(default_severity, struct {}, scan.RuleScanConfig.public_api_surface);

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
