//! Converting between naming conventions. Unlike `check.zig`, this half is heuristic: word-boundary detection from a single casing style is inherently ambiguous, so these functions can produce a spelling a human wouldn't pick. Callers that surface suggestions (e.g. `identifier_case`) should present them as advisory, not authoritative.
//!
//! ## Limitations
//!
//! `pascalCaseStemToSnake` inserts a word boundary before an uppercase letter when the previous character is lowercase, or when the previous character is uppercase and the *next* one is lowercase (the classic acronym-then-word heuristic, e.g. `IOError` → `io_error`). This means:
//!
//! - Back-to-back acronym runs are merged: `XMLHTTPRequest` → `xmlhttp_request`, not `xml_http_request`, because there is no lowercase letter marking where one acronym ends and the next begins.
//! - A single trailing capital before a lowercase word is treated as starting that word, so `AString` → `a_string` even if `A` was meant to stand alone.
//! - Digits are passed through unchanged and never trigger a word boundary, so `Utf8Decoder` → `utf8decoder` (no split on either side of `8`, since a digit is neither upper- nor lowercase).
//!
//! `snakeOrKebabStemToPascal` / `snakeCaseStemToPascal` capitalize the letter following each `_` or `-` and otherwise leave characters untouched, so round-tripping a converted name is not guaranteed to reproduce the original spelling (`xmlhttp_request` → `XmlhttpRequest`, not `XMLHTTPRequest`).
//!
//! These heuristics are good enough to *suggest* a filename or identifier rename, but a diagnostic consumer must not treat the suggestion as the only correct answer.

const std = @import("std");
const ascii = std.ascii;
const Allocator = std.mem.Allocator;

const check = @import("check.zig");
const Style = check.Style;

/// Converts an identifier name to the filename stem implied by `case`.
///
/// Heuristic for `.snake` and `.kebab`; see the module docs for where the word-boundary guess can diverge from what a human would write.
pub fn identifierToFilenameStem(
    allocator: Allocator,
    name: []const u8,
    case: Style,
) Allocator.Error![]u8 {
    return switch (case) {
        .snake => pascalCaseStemToSnake(allocator, name),
        .pascal, .camel => allocator.dupe(u8, name),
        .kebab => pascalCaseStemToKebab(allocator, name),
    };
}

/// Suggests a filename stem for `stem` when it does not already match `case`.
///
/// Round-trips `stem` through a PascalCase intermediate, so this is a heuristic suggestion, not a guaranteed-correct rename; see the module docs.
pub fn suggestFilenameStem(
    allocator: Allocator,
    stem: []const u8,
    case: Style,
) Allocator.Error![]u8 {
    if (case.matches(stem)) return allocator.dupe(u8, stem);
    const pascal = try snakeOrKebabStemToPascal(allocator, stem);
    defer allocator.free(pascal);
    return identifierToFilenameStem(
        allocator,
        pascal,
        case,
    );
}

/// Converts a PascalCase or mixed-case stem to `snake_case`.
///
/// Word boundaries are inferred from case transitions only (see the module docs for the exact
/// heuristic and its failure modes with acronym runs and digits); this is not a lossless inverse
/// of `snakeCaseStemToPascal`.
pub fn pascalCaseStemToSnake(allocator: Allocator, stem: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacityPrecise(allocator, stem.len);

    for (stem, 0..) |c, i| {
        if (ascii.isUpper(c)) {
            if (i > 0 and startsNewWord(stem, i)) {
                try out.append(allocator, '_');
            }
            try out.append(allocator, ascii.toLower(c));
        } else {
            try out.append(allocator, c);
        }
    }

    return out.toOwnedSlice(allocator);
}

/// Returns whether the uppercase letter at `stem[i]` begins a new word, given the
/// acronym-then-word heuristic: a boundary exists when the previous character is lowercase, or
/// when the previous character is uppercase and the next one is lowercase.
fn startsNewWord(stem: []const u8, i: usize) bool {
    const prev = stem[i - 1];
    if (ascii.isLower(prev)) return true;
    if (!ascii.isUpper(prev)) return false;
    const next: u8 = if (i + 1 < stem.len) stem[i + 1] else 0;
    return ascii.isLower(next);
}

test "pascalCaseStemToSnake inserts word boundaries" {
    const stem = try pascalCaseStemToSnake(std.testing.allocator, "DiagnosticMessage");
    defer std.testing.allocator.free(stem);
    try std.testing.expectEqualStrings("diagnostic_message", stem);

    const reach = try pascalCaseStemToSnake(std.testing.allocator, "Reachability");
    defer std.testing.allocator.free(reach);
    try std.testing.expectEqualStrings("reachability", reach);

    const acronym = try pascalCaseStemToSnake(std.testing.allocator, "IOError");
    defer std.testing.allocator.free(acronym);
    try std.testing.expectEqualStrings("io_error", acronym);
}

test "pascalCaseStemToSnake handles empty input, digits, and lone letters" {
    const empty = try pascalCaseStemToSnake(std.testing.allocator, "");
    defer std.testing.allocator.free(empty);
    try std.testing.expectEqualStrings("", empty);

    const digits = try pascalCaseStemToSnake(std.testing.allocator, "Utf8Decoder");
    defer std.testing.allocator.free(digits);
    try std.testing.expectEqualStrings("utf8decoder", digits);

    const single = try pascalCaseStemToSnake(std.testing.allocator, "A");
    defer std.testing.allocator.free(single);
    try std.testing.expectEqualStrings("a", single);

    const already_snake = try pascalCaseStemToSnake(std.testing.allocator, "already_snake");
    defer std.testing.allocator.free(already_snake);
    try std.testing.expectEqualStrings("already_snake", already_snake);
}

test "pascalCaseStemToSnake merges back-to-back acronym runs (documented limitation)" {
    // XML and HTTP are both acronyms with no lowercase letter between them, so there is no signal to split on: the heuristic only splits before the last capital of a run.
    const stem = try pascalCaseStemToSnake(std.testing.allocator, "XMLHTTPRequest");
    defer std.testing.allocator.free(stem);
    try std.testing.expectEqualStrings("xmlhttp_request", stem);
}

fn pascalCaseStemToKebab(allocator: Allocator, stem: []const u8) Allocator.Error![]u8 {
    const snake = try pascalCaseStemToSnake(allocator, stem);
    defer allocator.free(snake);

    const out = try allocator.dupe(u8, snake);
    for (out) |*c| {
        if (c.* == '_') c.* = '-';
    }
    return out;
}

test "pascalCaseStemToKebab mirrors the snake_case split with hyphens" {
    const stem = try identifierToFilenameStem(
        std.testing.allocator,
        "DiagnosticMessage",
        .kebab,
    );
    defer std.testing.allocator.free(stem);
    try std.testing.expectEqualStrings("diagnostic-message", stem);
}

test "identifierToFilenameStem leaves pascal and camel names unchanged" {
    const pascal = try identifierToFilenameStem(
        std.testing.allocator,
        "DiagnosticMessage",
        .pascal,
    );
    defer std.testing.allocator.free(pascal);
    try std.testing.expectEqualStrings("DiagnosticMessage", pascal);

    const camel = try identifierToFilenameStem(
        std.testing.allocator,
        "diagnosticMessage",
        .camel,
    );
    defer std.testing.allocator.free(camel);
    try std.testing.expectEqualStrings("diagnosticMessage", camel);
}

fn snakeOrKebabStemToPascal(allocator: Allocator, stem: []const u8) Allocator.Error![]u8 {
    // Checked before isPascal/isCamel: a hyphenated stem like "diagnostic-message" starts
    // lowercase and contains no `_`, so it would otherwise spuriously satisfy isCamel and be
    // returned unconverted, leaving the hyphens in place.
    if (check.isKebab(stem)) {
        const snake = try allocator.dupe(u8, stem);
        defer allocator.free(snake);
        for (snake) |*c| {
            if (c.* == '-') c.* = '_';
        }
        return snakeCaseStemToPascal(allocator, snake);
    }
    if (check.isPascal(stem) or check.isCamel(stem)) return allocator.dupe(u8, stem);
    return snakeCaseStemToPascal(allocator, stem);
}

fn snakeCaseStemToPascal(allocator: Allocator, stem: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacityPrecise(allocator, stem.len);

    var capitalize_next = true;
    for (stem) |c| {
        if (c == '_') {
            capitalize_next = true;
            continue;
        }
        try out.append(allocator, if (capitalize_next) ascii.toUpper(c) else c);
        capitalize_next = false;
    }

    return out.toOwnedSlice(allocator);
}

test "snakeCaseStemToPascal capitalizes each underscore-delimited word" {
    const stem = try snakeOrKebabStemToPascal(std.testing.allocator, "diagnostic_message");
    defer std.testing.allocator.free(stem);
    try std.testing.expectEqualStrings("DiagnosticMessage", stem);
}

test "snakeCaseStemToPascal handles empty, leading, and repeated underscores" {
    const empty = try snakeOrKebabStemToPascal(std.testing.allocator, "");
    defer std.testing.allocator.free(empty);
    try std.testing.expectEqualStrings("", empty);

    const leading = try snakeOrKebabStemToPascal(std.testing.allocator, "_private");
    defer std.testing.allocator.free(leading);
    try std.testing.expectEqualStrings("Private", leading);

    const repeated = try snakeOrKebabStemToPascal(std.testing.allocator, "foo__bar");
    defer std.testing.allocator.free(repeated);
    try std.testing.expectEqualStrings("FooBar", repeated);
}

test "suggestFilenameStem round-trips through snake_case and kebab-case" {
    const from_pascal = try suggestFilenameStem(
        std.testing.allocator,
        "DiagnosticMessage",
        .snake,
    );
    defer std.testing.allocator.free(from_pascal);
    try std.testing.expectEqualStrings("diagnostic_message", from_pascal);

    const from_kebab = try suggestFilenameStem(
        std.testing.allocator,
        "diagnostic-message",
        .pascal,
    );
    defer std.testing.allocator.free(from_kebab);
    try std.testing.expectEqualStrings("DiagnosticMessage", from_kebab);

    // Already matching: returned unchanged rather than re-derived.
    const unchanged = try suggestFilenameStem(
        std.testing.allocator,
        "already_snake",
        .snake,
    );
    defer std.testing.allocator.free(unchanged);
    try std.testing.expectEqualStrings("already_snake", unchanged);
}

test "suggestFilenameStem does not losslessly round-trip acronyms (documented limitation)" {
    // Converting an acronym-heavy PascalCase name to snake_case and back does not reproduce the
    // original casing, since snakeCaseStemToPascal only capitalizes the first letter of each
    // underscore-delimited word.
    const snake = try pascalCaseStemToSnake(std.testing.allocator, "IOError");
    defer std.testing.allocator.free(snake);
    try std.testing.expectEqualStrings("io_error", snake);

    const back = try suggestFilenameStem(
        std.testing.allocator,
        snake,
        .pascal,
    );
    defer std.testing.allocator.free(back);
    try std.testing.expectEqualStrings("IoError", back);
}
