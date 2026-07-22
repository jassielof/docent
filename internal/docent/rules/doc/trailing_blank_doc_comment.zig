//! The `trailing_blank_doc_comment` namespace checks for doc comment blocks that end with blank lines.

const std = @import("std");
const Ast = std.zig.Ast;
const Diagnostic = @import("../../Diagnostic.zig");
const severity = @import("../../severity.zig");
const scan = @import("../../scan.zig");
const category = @import("../category.zig");
const utils = @import("../utils.zig");
const doc_comment = @import("doc_comment");

inline fn srcLoc() std.builtin.SourceLocation {
    return @src();
}

const rule_name = utils.ruleIdFromSrc(srcLoc());

/// The default_severity for the rule.
pub const default_severity: severity.Level = .warn;

/// Title for diagnostic prose (`Warning: {prose_title} on …`).
pub const prose_title = "Trailing blank doc comment";

/// Full configuration for `trailing_blank_doc_comment`: severity and scan mode, with no rule-specific options.
pub const Rule = category.Rule(
    default_severity,
    struct {},
    scan.RuleScanConfig.public_api_surface,
);

/// Walks `tree` and appends diagnostics for doc comments with trailing blank lines.
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

        if (doc_comment.comment.firstTrailingBlankLine(
            tree,
            block_start,
            block_end,
        )) |blank_tok| {
            const slice = tree.tokenSlice(blank_tok);
            const loc = tree.tokenLocation(0, blank_tok);
            const subject = if (tag == .container_doc_comment)
                try utils.ownedSubject(
                    msg_allocator,
                    .module,
                    utils.moduleDisplayName(file, module_name),
                )
            else
                utils.diagnosticSubjectFromDoc(try doc_comment.resolveDocCommentSubject(
                    tree,
                    documented_first,
                    file,
                    module_name,
                    msg_allocator,
                ));
            try diagnostics.append(allocator, .{
                .rule = rule_name,
                .severity_level = severity_level,
                .subject = subject,
                .file = file,
                .line = loc.line + 1,
                .column = loc.column + 1,
                .source_line = try utils.dupSourceLine(
                    tree,
                    blank_tok,
                    msg_allocator,
                ),
                .symbol_len = slice.len,
            });
        }
    }
}
