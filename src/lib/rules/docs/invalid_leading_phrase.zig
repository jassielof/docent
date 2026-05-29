//! The `invalid_leading_phrase` namespace warns when a doc comment summary does not begin with a valid leading phrase naming the documented identifier.
//!
//! The leading phrase grammar is `[<article>] [<identifier kind>] <identifier> [<identifier kind>]...`.
//! With the default options the article, identifier kind, and backticks are optional, while the
//! identifier itself is always required and must match the declaration's casing (modules and source
//! files are compared case-insensitively).

const std = @import("std");
const Ast = std.zig.Ast;
const Diagnostic = @import("../../Diagnostic.zig");
const Severity = @import("../../Severity.zig");
const utils = @import("../utils.zig");

const rule_name = "invalid_leading_phrase";

const article_words: []const []const u8 = &.{ "a", "an", "the" };

const KindPhrase = []const []const u8;
const root = @import("root");
const aaaaa = root.rules.docs.invalid_leading_phrase.check;
/// Walks `tree` and appends diagnostics for doc comment summaries with an invalid leading phrase.
pub fn check(
    tree: *const Ast,
    severity: Severity.Level,
    file: []const u8,
    module_name: ?[]const u8,
    public_api_only: bool,
    allocator: std.mem.Allocator,
    msg_allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) !void {
    if (!severity.isActive()) return;
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

        if (tag == .doc_comment and !utils.shouldCheckDocCommentTarget(tree, documented_first, public_api_only)) {
            continue;
        }

        const subject = if (tag == .container_doc_comment)
            try utils.ownedSubject(msg_allocator, .module, utils.moduleDisplayName(file, module_name))
        else
            try utils.resolveDocCommentSubject(tree, documented_first, file, module_name, msg_allocator);

        // Unresolved declarations or those without a usable name can't be validated.
        if (subject.name.len == 0) continue;

        var words = std.ArrayList([]const u8).empty;
        defer words.deinit(allocator);

        const report_tok = try collectSummaryWords(tree, block_start, block_end, allocator, &words);
        if (report_tok == null or words.items.len == 0) continue;

        if (hasLeadingPhrase(words.items, subject)) continue;

        const tok = report_tok.?;
        const slice = tree.tokenSlice(tok);
        const loc = tree.tokenLocation(0, tok);
        const detail = try std.fmt.allocPrint(msg_allocator, "expected the summary to begin with '{s}'", .{subject.name});
        try diagnostics.append(allocator, .{
            .rule = rule_name,
            .severity = severity,
            .subject = subject,
            .detail = detail,
            .file = file,
            .line = loc.line + 1,
            .column = loc.column + 1,
            .source_line = try utils.dupSourceLine(tree, tok, msg_allocator),
            .symbol_len = slice.len,
        });
    }
}

/// Collects whitespace-separated words from the first paragraph; returns its first token for reporting.
fn collectSummaryWords(
    tree: *const Ast,
    block_start: usize,
    block_end: usize,
    allocator: std.mem.Allocator,
    words: *std.ArrayList([]const u8),
) std.mem.Allocator.Error!?Ast.TokenIndex {
    var report_tok: ?Ast.TokenIndex = null;
    var tok: usize = block_start;
    while (tok < block_end) : (tok += 1) {
        const token: Ast.TokenIndex = @intCast(tok);
        const slice = tree.tokenSlice(token);
        if (utils.isEmptyDocCommentLine(slice)) break;

        const body = utils.docCommentLineBody(slice);
        if (body.len == 0) continue;
        if (report_tok == null) report_tok = token;

        var it = std.mem.tokenizeAny(u8, body, " \t");
        while (it.next()) |word| try words.append(allocator, word);
    }
    return report_tok;
}

fn hasLeadingPhrase(words: []const []const u8, subject: Diagnostic.Subject) bool {
    var i: usize = 0;
    if (i < words.len and isArticle(words[i])) i += 1;

    // Identifier kind before the identifier: "Module Foo", "Function `foo`".
    const consumed = matchKindPhrase(words[i..], subject.kind);
    const after_kind = i + consumed;
    if (after_kind < words.len and identifierMatches(words[after_kind], subject)) return true;

    // Identifier first, with an optional kind afterwards: "InitOptions", "ParseError error set".
    if (i < words.len and identifierMatches(words[i], subject)) return true;

    return false;
}

fn isArticle(word: []const u8) bool {
    const core = wordCore(word);
    for (article_words) |a| {
        if (std.ascii.eqlIgnoreCase(core, a)) return true;
    }
    return false;
}

/// Returns the number of words consumed by the longest matching identifier-kind phrase, or 0.
fn matchKindPhrase(words: []const []const u8, kind: Diagnostic.SubjectKind) usize {
    var best: usize = 0;
    for (kindPhrases(kind)) |phrase| {
        if (phrase.len == 0 or phrase.len > words.len or phrase.len <= best) continue;
        var ok = true;
        for (phrase, 0..) |pw, k| {
            if (!std.ascii.eqlIgnoreCase(wordCore(words[k]), pw)) {
                ok = false;
                break;
            }
        }
        if (ok) best = phrase.len;
    }
    return best;
}

fn kindPhrases(kind: Diagnostic.SubjectKind) []const KindPhrase {
    return switch (kind) {
        .module => &.{ &.{"module"}, &.{"library"} },
        .source_file => &.{ &.{"module"}, &.{"namespace"}, &.{"file"} },
        .function => &.{&.{"function"}},
        .error_set => &.{ &.{ "error", "set" }, &.{"set"} },
        .enumeration => &.{ &.{"enum"}, &.{"enumeration"} },
        .constant => &.{ &.{"constant"}, &.{"struct"}, &.{"structure"}, &.{"union"}, &.{"type"} },
        .variable => &.{&.{"variable"}},
        .field => &.{&.{"field"}},
        .enumerator => &.{ &.{"enumerator"}, &.{"value"}, &.{"variant"}, &.{"tag"}, &.{"member"} },
        .doc_comment, .doctest => &.{},
    };
}

fn identifierMatches(word: []const u8, subject: Diagnostic.Subject) bool {
    const core = wordCore(word);
    return switch (subject.kind) {
        .module, .source_file => std.ascii.eqlIgnoreCase(core, subject.name),
        else => std.mem.eql(u8, core, subject.name),
    };
}

/// Trims surrounding backticks and punctuation so `` `foo`, `` and `foo.` compare as `foo`.
fn wordCore(word: []const u8) []const u8 {
    return std.mem.trim(u8, word, "`.,;:!?()'\"");
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
    return runCheckOpts(source, null, true);
}

fn runCheckNamed(source: [:0]const u8, module_name: ?[]const u8) !TestResult {
    return runCheckOpts(source, module_name, true);
}

fn runCheckOpts(source: [:0]const u8, module_name: ?[]const u8, public_api_only: bool) !TestResult {
    const base = std.testing.allocator;
    var msg_arena = std.heap.ArenaAllocator.init(base);
    errdefer msg_arena.deinit();

    var tree = try std.zig.Ast.parse(base, source, .zig);
    defer tree.deinit(base);

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    errdefer diagnostics.deinit(base);

    try check(&tree, .warn, "<test>", module_name, public_api_only, base, msg_arena.allocator(), &diagnostics);
    return .{ .msg_arena = msg_arena, .items = diagnostics };
}

test "accepts identifier-first summary on a function" {
    var r = try runCheck("/// add returns the sum.\npub fn add(a: i32, b: i32) i32 {\n    return a + b;\n}");
    defer r.deinit();
    try std.testing.expectEqual(0, r.items.items.len);
}

test "accepts kind word before backticked identifier" {
    var r = try runCheck("/// Function `add` returns the sum.\npub fn add(a: i32, b: i32) i32 {\n    return a + b;\n}");
    defer r.deinit();
    try std.testing.expectEqual(0, r.items.items.len);
}

test "warns when summary omits the identifier" {
    var r = try runCheck("/// Returns the sum of two integers.\npub fn add(a: i32, b: i32) i32 {\n    return a + b;\n}");
    defer r.deinit();
    try std.testing.expectEqual(1, r.items.items.len);
    try std.testing.expectEqualStrings(rule_name, r.items.items[0].rule);
    try std.testing.expectEqual(.function, r.items.items[0].subject.?.kind);
    try std.testing.expectEqualStrings("add", r.items.items[0].subject.?.name);
}

test "warns on identifier case mismatch for declarations" {
    var r = try runCheck("/// Add returns the sum.\npub fn add(a: i32, b: i32) i32 {\n    return a + b;\n}");
    defer r.deinit();
    try std.testing.expectEqual(1, r.items.items.len);
}

test "accepts struct documented with article and trailing kind" {
    var r = try runCheck("/// The `InitOptions` struct configures setup.\npub const InitOptions = struct { a: i32 };");
    defer r.deinit();
    try std.testing.expectEqual(0, r.items.items.len);
}

test "accepts error set with article and trailing kind" {
    var r = try runCheck("/// The ParseError error set lists failures.\npub const ParseError = error{ Bad };");
    defer r.deinit();
    try std.testing.expectEqual(0, r.items.items.len);
}

test "accepts constant identifier first" {
    var r = try runCheck("/// pi represents the mathematical constant.\npub const pi = 3.14;");
    defer r.deinit();
    try std.testing.expectEqual(0, r.items.items.len);
}

test "module doc accepts case-insensitive name with kind word" {
    var r = try runCheckNamed("//! Module docent provides linting.\npub fn foo() void {}", "docent");
    defer r.deinit();
    try std.testing.expectEqual(0, r.items.items.len);
}

test "module doc warns when name is absent" {
    var r = try runCheckNamed("//! Provides linting utilities.\npub fn foo() void {}", "docent");
    defer r.deinit();
    try std.testing.expectEqual(1, r.items.items.len);
    try std.testing.expectEqual(.module, r.items.items[0].subject.?.kind);
}

test "no diagnostic for undocumented or unresolved blocks" {
    var r = try runCheck("/// add returns the sum.\n\npub fn add() void {}");
    defer r.deinit();
    // Blank line between doc and decl means the doc isn't attached; subject unresolved, so skipped.
    try std.testing.expectEqual(0, r.items.items.len);
}

test "accepts enumerator identifier first" {
    var r = try runCheck(
        \\pub const Color = enum {
        \\    /// red is the warm primary.
        \\    red,
        \\};
    ,);
    defer r.deinit();
    try std.testing.expectEqual(0, r.items.items.len);
}

test "no diagnostic for private function doc comment" {
    var r = try runCheck("/// Returns something.\nfn matchKindPhrase() void {}");
    defer r.deinit();
    try std.testing.expectEqual(0, r.items.items.len);
}

test "warns on public function when public_api_only" {
    var r = try runCheck("/// Returns something.\npub fn add(a: i32, b: i32) i32 { return a + b; }");
    defer r.deinit();
    try std.testing.expectEqual(1, r.items.items.len);
}

test "private function checked when public_api_only is false" {
    var r = try runCheckOpts("/// Returns something.\nfn hidden() void {}", null, false);
    defer r.deinit();
    try std.testing.expectEqual(1, r.items.items.len);
}
