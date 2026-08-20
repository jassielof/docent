//! The `blank_doc_comment` namespace checks for doc comments that are blank or empty.
//!
//! For guidance on how to write good documentation comments, see <https://ziglang.org/documentation/0.16.0/#Doc-Comment-Guidance>.

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

/// The default_severity for the rule.
pub const default_severity: severity.Level = .warn;

/// Title for diagnostic prose (`Warning: {prose_title} on …`).
pub const prose_title = "Blank doc comment";

/// Full configuration for `blank_doc_comment`: severity and scan mode, with no rule-specific options.
pub const Rule = category.Rule(
    default_severity,
    struct {},
    scan.RuleScanConfig.public_declarations,
);

/// Walks `tree` and appends diagnostics for vacuous doc comments.
///
/// When `is_module_entry` is set, blank `//!` blocks on the file are reported as module doc comments.
pub fn check(
    tree: *const Ast,
    rule: Rule,
    file: []const u8,
    module_name: ?[]const u8,
    is_module_entry: bool,
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
        var all_empty = true;

        while (i < tags.len and tags[i] == tag) : (i += 1) {
            const tok: Ast.TokenIndex = @intCast(i);
            const slice = tree.tokenSlice(tok);
            if (!doc_comment.comment.isEmptyLine(slice)) all_empty = false;
        }

        if (all_empty) {
            const tok: Ast.TokenIndex = @intCast(block_start);
            const slice = tree.tokenSlice(tok);
            const loc = tree.tokenLocation(0, tok);
            const subject = if (tag == .container_doc_comment)
                try containerDocSubject(
                    tree,
                    file,
                    module_name,
                    is_module_entry,
                    msg_allocator,
                )
            else
                utils.diagnosticSubjectFromDoc(try doc_comment.resolveDocCommentSubject(
                    tree,
                    @intCast(i),
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
                    tok,
                    msg_allocator,
                ),
                .symbol_len = slice.len,
            });
        }
    }
}

fn containerDocSubject(
    tree: *const Ast,
    file: []const u8,
    module_name: ?[]const u8,
    is_module_entry: bool,
    msg_allocator: std.mem.Allocator,
) std.mem.Allocator.Error!Diagnostic.Subject {
    if (is_module_entry) {
        return try utils.ownedSubject(
            msg_allocator,
            .module,
            utils.moduleDisplayName(file, module_name),
        );
    }
    return try utils.ownedSubject(
        msg_allocator,
        utils.diagnosticSubjectKindFromDoc(doc_comment.exposedSourceFileSubjectKind(tree)),
        std.fs.path.basename(file),
    );
}

fn runCheck(
    source: [:0]const u8,
    rule: Rule,
    file: []const u8,
    is_module_entry: bool,
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
        file,
        null,
        is_module_entry,
        allocator,
        msg_allocator,
        diagnostics,
    );
}

const warn_rule: Rule = .{ .level = .warn };

test "detects blank /// comment" {
    const source =
        \\///
        \\pub fn foo() void {}
    ;

    var msg_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer msg_arena.deinit();
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    try runCheck(
        source,
        warn_rule,
        "<test>",
        false,
        &diagnostics,
        msg_arena.allocator(),
    );
    try std.testing.expectEqual(@as(usize, 1), diagnostics.items.len);
    try std.testing.expectEqual(.function, diagnostics.items[0].subject.?.kind);
    try std.testing.expectEqualStrings("foo", diagnostics.items[0].subject.?.name);
    try std.testing.expectEqual(@as(usize, 3), diagnostics.items[0].symbol_len);
}

test "detects blank /// on enum enumerator" {
    const source =
        \\pub const Color = enum {
        \\    ///
        \\    red,
        \\};
    ;

    var msg_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer msg_arena.deinit();
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    try runCheck(
        source,
        warn_rule,
        "<test>",
        false,
        &diagnostics,
        msg_arena.allocator(),
    );
    try std.testing.expectEqual(@as(usize, 1), diagnostics.items.len);
    try std.testing.expectEqual(.enumerator, diagnostics.items[0].subject.?.kind);
    try std.testing.expectEqualStrings("red", diagnostics.items[0].subject.?.name);
}

test "detects blank /// with spaces" {
    const source =
        \\///
        \\pub fn foo() void {}
    ;

    var msg_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer msg_arena.deinit();
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    try runCheck(
        source,
        warn_rule,
        "<test>",
        false,
        &diagnostics,
        msg_arena.allocator(),
    );
    try std.testing.expectEqual(@as(usize, 1), diagnostics.items.len);
}

test "no diagnostic for non-empty doc comment" {
    const source =
        \\/// Does something.
        \\pub fn foo() void {}
    ;

    var msg_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer msg_arena.deinit();
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    try runCheck(
        source,
        warn_rule,
        "<test>",
        false,
        &diagnostics,
        msg_arena.allocator(),
    );
    try std.testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}

test "detects blank //! comment on module entry" {
    const source =
        \\//!
    ;

    var msg_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer msg_arena.deinit();
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    try runCheck(
        source,
        warn_rule,
        "root.zig",
        true,
        &diagnostics,
        msg_arena.allocator(),
    );
    try std.testing.expectEqual(@as(usize, 1), diagnostics.items.len);
    try std.testing.expectEqual(.module, diagnostics.items[0].subject.?.kind);
}

test "blank //! on non-entry file uses namespace subject" {
    const source =
        \\//!
        \\pub const x = 1;
    ;

    var msg_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer msg_arena.deinit();
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    try runCheck(
        source,
        warn_rule,
        "<test>",
        false,
        &diagnostics,
        msg_arena.allocator(),
    );
    try std.testing.expectEqual(@as(usize, 1), diagnostics.items.len);
    try std.testing.expectEqual(.namespace, diagnostics.items[0].subject.?.kind);
}

test "detects fully blank multiline /// comment block once" {
    const source =
        \\///
        \\///
        \\pub fn add(x: i32, y: i32) i32 {
        \\    return x + y;
        \\}
    ;

    var msg_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer msg_arena.deinit();
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    try runCheck(
        source,
        warn_rule,
        "<test>",
        false,
        &diagnostics,
        msg_arena.allocator(),
    );
    try std.testing.expectEqual(@as(usize, 1), diagnostics.items.len);
}

test "no diagnostic for multiline block with at least one non-empty line" {
    const source =
        \\/// This should
        \\///
        \\/// be valid
        \\pub fn add(x: i32, y: i32) i32 {
        \\    return x + y;
        \\}
    ;

    var msg_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer msg_arena.deinit();
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    try runCheck(
        source,
        warn_rule,
        "<test>",
        false,
        &diagnostics,
        msg_arena.allocator(),
    );
    try std.testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}

test "member re-export does not trigger whole-module blank check" {
    const source =
        \\pub const Level = @import("severity.zig").Level;
    ;

    var msg_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer msg_arena.deinit();
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    try runCheck(
        source,
        warn_rule,
        "<test>",
        false,
        &diagnostics,
        msg_arena.allocator(),
    );
    try std.testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}

comptime {
    std.testing.refAllDecls(@This());
}
