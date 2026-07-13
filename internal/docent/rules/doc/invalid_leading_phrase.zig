//! The `invalid_leading_phrase` namespace offers implementations and utilities for invalid leading phrases on doc comment summaries.
//!
//! This rule is inspired by [Go's documentation style guidelines](https://go.dev/doc/comment),
//! adapted to Zig declaration kinds (functions, structs, error sets, namespaces, modules).
//!
//! ## Go → Zig mapping
//!
//! | Go convention | Docent rule / behavior |
//! |---|---|
//! | Doc comment starts with the name | `invalid_leading_phrase` (optional article/kind/`backticks`) |
//! | Package comment | Module `//!` / file-root docs via `missing_doc_comment` |
//! | Exported identifiers documented | `scan_mode = "public"` on the module reachability graph |
//! | Complete sentences | `missing_summary_terminal_punctuation` |
//! | No empty comments | `blank_doc_comment` / `trailing_blank_doc_comment` |
//! | Examples in docs | doctest rules (`missing_doctest`, …) |
//!
//! Zig-specific: kind words (`function`, `struct`, `error set`, `namespace`),
//! `Library` vs `Module` for roots, and namespaces requiring an explicit kind word.
//!
//! ## Grammar
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
const scan = @import("../../scan.zig");
const category = @import("../category.zig");
const utils = @import("../utils.zig");
const doc_comment = @import("doc_comment");

inline fn srcLoc() std.builtin.SourceLocation {
    return @src();
}

const rule_name = utils.ruleIdFromSrc(srcLoc());

/// Rule-specific knobs for `invalid_leading_phrase`, held in the `options` sub-space of `Rule`.
pub const Options = struct {
    /// When set, the summary must contain the declaration's kind word (e.g. "struct", "function"),
    /// either before or after the identifier. Default `false`.
    require_kind: bool = false,
    /// When set, the summary must begin with an English article (`a`, `an`, `the`); default `false`.
    require_article: bool = false,
    /// When set, the documented identifier must appear wrapped in backticks; default `false`.
    require_backticks: bool = false,
};

/// Default severity `allow`: by default, this style check is not enforced.
pub const default_severity: severity.Level = .allow;

/// Title for diagnostic prose (`Warning: {prose_title} on …`).
pub const prose_title = "Invalid leading phrase";

/// Full configuration for `invalid_leading_phrase`: severity, scan mode, and the documented `Options` sub-space.
pub const Rule = category.Rule(default_severity, Options, scan.RuleScanConfig.public_api_surface);

/// The article_words set contains the words considered as articles for leading phrases.
pub const article_words: []const []const u8 = &.{ "a", "an", "the" };

const KindPhrase = []const []const u8;

/// The check function Walks the AST and appends diagnostics for doc comment summaries with an invalid leading phrase.
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
    const options = rule.options;
    const public_api_only = rule.publicApiOnly();
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

        if (tag == .doc_comment and !doc_comment.shouldCheckDocCommentTarget(tree, documented_first, public_api_only)) {
            continue;
        }

        const subject = if (tag == .container_doc_comment)
            try utils.ownedSubject(msg_allocator, .module, utils.moduleDisplayName(file, module_name))
        else
            utils.diagnosticSubjectFromDoc(try doc_comment.resolveDocCommentSubject(tree, documented_first, file, module_name, msg_allocator));

        // Unresolved declarations or those without a usable name can't be validated.
        if (subject.name.len == 0) continue;

        var words = std.ArrayList([]const u8).empty;
        defer words.deinit(allocator);

        const report_tok = try doc_comment.comment.summaryWords(tree, block_start, block_end, allocator, &words);
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

fn hasLeadingPhrase(words: []const []const u8, subject: Diagnostic.Subject, options: Options) bool {
    var i: usize = 0;
    const has_article = i < words.len and isArticle(words[i]);
    if (has_article) i += 1;
    if (options.require_article and !has_article) return false;
    if (i >= words.len) return false;

    const rest = words[i..];

    // Case 1: Kind before identifier.
    // e.g. "Function `add` ..."
    const consumed_before = matchKindPhrase(rest, subject.kind);
    if (consumed_before > 0 and consumed_before < rest.len) {
        if (wordMatchesIdentifier(rest[consumed_before], subject, options)) {
            // Check that we don't have a kind phrase in both places.
            // e.g. "Function `add` function ..."
            const post_id = rest[consumed_before + 1 ..];
            if (matchKindPhrase(post_id, subject.kind) == 0) {
                return true;
            }
        }
    }

    // Case 2: Identifier first, with optional/required kind after.
    // e.g. "`add` function ..." or just "`add` ..."
    if (rest.len > 0 and wordMatchesIdentifier(rest[0], subject, options)) {
        const consumed_after = matchKindPhrase(rest[1..], subject.kind);
        if (consumed_after > 0) {
            // Kind is after the identifier (e.g. "`add` function ...")
            return true;
        } else if (!options.require_kind and subject.kind != .namespace) {
            // Kind is absent and not required (and not a namespace which always requires it)
            return true;
        }
    }

    return false;
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
