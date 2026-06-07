//! The `invalid_leading_phrase` namespace offers implementations and utilities for invalid leading phrases on doc comment summaries.
//!
//! This rule is inspired by [Go's documentation style guidelines](https://go.dev/doc/comment).
//!
//! ## Grammar
//!
//! The leading phrase grammar is:
//!
//! ```txt
//! [<article>] [<identifier kind>] <identifier> [<identifier kind>]...
//! ```
//!
//! Where:
//!
//! - `<article>` is an optional item from `article_words`.
//! - `<identifier kind>` is an optional item from `kindPhrases`, that is checked for validity with the declaration type, and can appear before or after the identifier for flexibility.
//! - `<identifier>` is the always required identifier of the documented declaration, that must match its name and casing (except for modules), and can be optionally enclosed in backticks.
//!
//! ## Examples
//!
//! ### Modules
//!
//! > Module Foo provides...
//!
//! The module name check is case-insensitive, so _"Module foo provides..."_ is also valid.
//!
//! > The `foo` module...
//! >
//! > Library Foo offers...
//!
//! Aside "Module", "Library" can be used, only when the module is truly a library, meaning it's not recognized as an executable, test, or build script module.
//!
//! ### Namespaces
//!
//! Namespaces can be categorized as a special case of modules, something like sub-modules, so they inherit (almost) the same checks and options.
//!
//! > Namespace JSON offers...
//! >
//! > The `json` namespace...
//!
//! Namespaces are restricted to only be called as "namespace". And to help differentiate them from modules, the kind here is always expected.
//!
//! ### Declarations
//!
//! > Function `foo` does...
//! >
//! > InitOptions represents...
//! >
//! > The ParseError error set lists...
//!
//! Whenever possible, for errors, specially sets (and possibly unions), the _"error set"_ part could be trimmed to just "set" or "union" to avoid redundancy, but it's still accepted when present.
//!
//! As a note on error values, if support for them to become rendered is added in the future, they can be expected to be referred as "tag", "value" or "member".
//!
//! > pi represents the mathematical constant...
//!
//! Where `pi` is a global constant.

const std = @import("std");
const Ast = std.zig.Ast;
const Diagnostic = @import("../../Diagnostic.zig");
const severity = @import("../../severity.zig");
const scanning = @import("../../scanning.zig");
const Config = @import("../../schemas/Config.zig");
const rule_opts = @import("../options.zig");
const utils = @import("../utils.zig");

inline fn srcLoc() std.builtin.SourceLocation {
    return @src();
}

const rule_name = utils.ruleIdFromSrc(srcLoc());

pub const Mode = Config.LeadingPhraseMode;

/// The Options resolved for the rule.
pub const Options = struct {
    /// Which declarations this rule inspects; inherits `[docs] scan_mode` unless overridden for this rule.
    scan_mode: scanning.Modes = scanning.Modes.public_api_surface,
    /// Leading-phrase strictness. `relaxed` accepts identifier-first summaries; `canonical` (default) allows kind-before or identifier-first; `strict` requires kind-before-identifier when phrases exist for the declaration type.
    mode: Mode = .canonical,
    /// When set, the summary must begin with an English article (`a`, `an`, `the`).
    require_article: bool = false,
    /// When set, the documented identifier must appear wrapped in backticks.
    require_backticks: bool = false,

    pub fn resolve(category_scan: scanning.Modes, rule: Config.InvalidLeadingPhraseRule) Options {
        return .{
            .scan_mode = rule_opts.scanModeFromInvalidLeadingPhrase(category_scan, rule),
            .mode = rule.mode orelse .canonical,
            .require_article = rule.require_article orelse false,
            .require_backticks = rule.require_backticks orelse false,
        };
    }

    pub fn publicApiOnly(self: Options) bool {
        return self.scan_mode.publicApiOnly();
    }
};

/// The default_severity for the rule.
pub const default_severity: severity.Level = .warn;

/// The article_words set contains the words considered as articles for leading phrases.
pub const article_words: []const []const u8 = &.{ "a", "an", "the" };

const KindPhrase = []const []const u8;

/// Walks `tree` and appends diagnostics for doc comment summaries with an invalid leading phrase.
pub fn check(
    tree: *const Ast,
    severity_level: severity.Level,
    file: []const u8,
    module_name: ?[]const u8,
    options: Options,
    allocator: std.mem.Allocator,
    msg_allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) !void {
    if (!severity_level.isActive()) return;
    const public_api_only = options.publicApiOnly();
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

        if (hasLeadingPhrase(words.items, subject, options)) continue;

        const tok = report_tok.?;
        const slice = tree.tokenSlice(tok);
        const loc = tree.tokenLocation(0, tok);
        const detail = try std.fmt.allocPrint(msg_allocator, "expected the summary to begin with '{s}'", .{subject.name});
        try diagnostics.append(allocator, .{
            .rule = rule_name,
            .severity_level = severity_level,
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

fn hasLeadingPhrase(words: []const []const u8, subject: Diagnostic.Subject, options: Options) bool {
    var i: usize = 0;
    const has_article = i < words.len and isArticle(words[i]);
    if (has_article) i += 1;
    if (options.require_article and !has_article) return false;
    if (i >= words.len) return false;

    const namespace_requires_kind = subject.kind == .namespace;
    return switch (options.mode) {
        .relaxed => leadingPhraseRelaxed(words[i..], subject, options),
        .canonical => leadingPhraseCanonical(words[i..], subject, options, namespace_requires_kind),
        .strict => leadingPhraseStrict(words[i..], subject, options, namespace_requires_kind),
    };
}

/// Identifier-first or kind-then-identifier; kind phrases are optional.
fn leadingPhraseRelaxed(words: []const []const u8, subject: Diagnostic.Subject, options: Options) bool {
    const consumed = matchKindPhrase(words, subject.kind);
    if (consumed < words.len and wordMatchesIdentifier(words[consumed], subject, options)) return true;
    if (words.len > 0 and wordMatchesIdentifier(words[0], subject, options)) return true;
    return false;
}

/// Kind-before or identifier-first; namespaces must include a kind word.
fn leadingPhraseCanonical(
    words: []const []const u8,
    subject: Diagnostic.Subject,
    options: Options,
    namespace_requires_kind: bool,
) bool {
    const consumed = matchKindPhrase(words, subject.kind);
    const id_after_kind = consumed < words.len and wordMatchesIdentifier(words[consumed], subject, options);
    const id_first = words.len > 0 and wordMatchesIdentifier(words[0], subject, options);
    if (namespace_requires_kind and consumed == 0) return false;
    return id_after_kind or id_first;
}

/// Kind-before-identifier when kind phrases exist; identifier-first only as a fallback.
fn leadingPhraseStrict(
    words: []const []const u8,
    subject: Diagnostic.Subject,
    options: Options,
    namespace_requires_kind: bool,
) bool {
    const consumed = matchKindPhrase(words, subject.kind);
    if (consumed > 0) return consumed < words.len and wordMatchesIdentifier(words[consumed], subject, options);
    if (namespace_requires_kind or kindPhrases(subject.kind).len > 0) return false;
    return words.len > 0 and wordMatchesIdentifier(words[0], subject, options);
}

fn wordMatchesIdentifier(word: []const u8, subject: Diagnostic.Subject, options: Options) bool {
    if (options.require_backticks) {
        if (word.len < 2 or word[0] != '`' or word[word.len - 1] != '`') return false;
    }
    return identifierMatches(word, subject);
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
        .parameter => &.{ &.{"parameter"}, &.{"argument"} },
        .error_set => &.{ &.{ "error", "set" }, &.{"set"} },
        .enumeration => &.{ &.{"enum"}, &.{"enumeration"} },
        .constant => &.{ &.{"constant"}, &.{"struct"}, &.{"structure"}, &.{"union"}, &.{"type"} },
        .variable => &.{&.{"variable"}},
        .field => &.{&.{"field"}},
        .enumerator => &.{ &.{"enumerator"}, &.{"value"}, &.{"variant"}, &.{"tag"}, &.{"member"} },
        .structure => &.{ &.{"struct"}, &.{"structure"} },
        .namespace => &.{&.{"namespace"}},
        .@"union" => &.{&.{"union"}},
        .error_value => &.{ &.{ "error", "value" }, &.{ "error", "tag" }, &.{ "error", "member" }, &.{"value"} },
        .type_alias => &.{ &.{"type"}, &.{"alias"} },
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
    return runCheckOpts(source, null, .{ .scan_mode = .public_api_surface });
}

fn runCheckNamed(source: [:0]const u8, module_name: ?[]const u8) !TestResult {
    return runCheckOpts(source, module_name, .{ .scan_mode = .public_api_surface });
}

fn runCheckOpts(source: [:0]const u8, module_name: ?[]const u8, options: Options) !TestResult {
    const base = std.testing.allocator;
    var msg_arena = std.heap.ArenaAllocator.init(base);
    errdefer msg_arena.deinit();

    var tree = try std.zig.Ast.parse(base, source, .zig);
    defer tree.deinit(base);

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    errdefer diagnostics.deinit(base);

    try check(&tree, .warn, "<test>", module_name, options, base, msg_arena.allocator(), &diagnostics);
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
        ,
    );
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
    var r = try runCheckOpts("/// Returns something.\nfn hidden() void {}", null, .{ .scan_mode = .reachability_traversal });
    defer r.deinit();
    try std.testing.expectEqual(1, r.items.items.len);
}

test "strict mode rejects identifier-first function summary" {
    var r = try runCheckOpts(
        "/// add returns the sum.\npub fn add(a: i32, b: i32) i32 { return a + b; }",
        null,
        .{ .mode = .strict },
    );
    defer r.deinit();
    try std.testing.expectEqual(1, r.items.items.len);
}

test "strict mode accepts kind-before identifier summary" {
    var r = try runCheckOpts(
        "/// Function `add` returns the sum.\npub fn add(a: i32, b: i32) i32 { return a + b; }",
        null,
        .{ .mode = .strict },
    );
    defer r.deinit();
    try std.testing.expectEqual(0, r.items.items.len);
}

test "require_article rejects summary without article" {
    var r = try runCheckOpts(
        "/// Function `add` returns the sum.\npub fn add(a: i32, b: i32) i32 { return a + b; }",
        null,
        .{ .require_article = true },
    );
    defer r.deinit();
    try std.testing.expectEqual(1, r.items.items.len);
}

test "require_article accepts summary with article" {
    var r = try runCheckOpts(
        "/// The function `add` returns the sum.\npub fn add(a: i32, b: i32) i32 { return a + b; }",
        null,
        .{ .require_article = true },
    );
    defer r.deinit();
    try std.testing.expectEqual(0, r.items.items.len);
}

test "require_backticks rejects bare identifier" {
    var r = try runCheckOpts(
        "/// Function add returns the sum.\npub fn add(a: i32, b: i32) i32 { return a + b; }",
        null,
        .{ .require_backticks = true },
    );
    defer r.deinit();
    try std.testing.expectEqual(1, r.items.items.len);
}

test "require_backticks accepts backticked identifier" {
    var r = try runCheckOpts(
        "/// Function `add` returns the sum.\npub fn add(a: i32, b: i32) i32 { return a + b; }",
        null,
        .{ .require_backticks = true },
    );
    defer r.deinit();
    try std.testing.expectEqual(0, r.items.items.len);
}
