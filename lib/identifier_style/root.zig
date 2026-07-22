//! Checking and converting between identifier naming conventions (`snake_case`, `camelCase`,
//! `PascalCase`, `kebab-case`).
//!
//! This module is deliberately split in two:
//!
//! - **Checking** (`Style.matches`, `isSnake`, `isCamel`, `isPascal`, `isKebab`) is exact: a name
//!   either satisfies a convention's character rules or it doesn't.
//! - **Converting** (`pascalCaseStemToSnake`, `pascalCaseStemToKebab`, `snakeOrKebabStemToPascal`,
//!   `identifierToFilenameStem`, `suggestFilenameStem`) is heuristic. Word-boundary detection from
//!   a single casing style is inherently ambiguous, so these functions can produce a spelling a
//!   human wouldn't pick. Callers that surface suggestions (e.g. `identifier_case`) should present
//!   them as advisory, not authoritative.
//!
//! ## Limitations of the case converters
//!
//! `pascalCaseStemToSnake` inserts a word boundary before an uppercase letter when the previous
//! character is lowercase, or when the previous character is uppercase and the *next* one is
//! lowercase (the classic acronym-then-word heuristic, e.g. `IOError` → `io_error`). This means:
//!
//! - Back-to-back acronym runs are merged: `XMLHTTPRequest` → `xmlhttp_request`, not
//!   `xml_http_request`, because there is no lowercase letter marking where one acronym ends and
//!   the next begins.
//! - A single trailing capital before a lowercase word is treated as starting that word, so
//!   `AString` → `a_string` even if `A` was meant to stand alone.
//! - Digits are passed through unchanged and never trigger a word boundary, so `Utf8Decoder` →
//!   `utf8_decoder` (no split between `8` and `Decoder`).
//!
//! `snakeOrKebabStemToPascal` / `snakeCaseStemToPascal` capitalize the letter following each `_`
//! or `-` and otherwise leave characters untouched, so round-tripping a converted name is not
//! guaranteed to reproduce the original spelling (`xmlhttp_request` → `XmlhttpRequest`, not
//! `XMLHTTPRequest`).
//!
//! These heuristics are good enough to *suggest* a filename or identifier rename, but a diagnostic
//! consumer must not treat the suggestion as the only correct answer.

const std = @import("std");

/// Naming convention checked against identifier strings.
pub const Style = enum {
    snake,
    camel,
    pascal,
    kebab,

    /// Config / diagnostic label for this convention.
    pub fn label(self: Style) []const u8 {
        return switch (self) {
            .snake => "snake_case",
            .camel => "camelCase",
            .pascal => "PascalCase",
            .kebab => "kebab-case",
        };
    }

    /// Returns whether `name` satisfies this convention.
    pub fn matches(self: Style, name: []const u8) bool {
        return switch (self) {
            .snake => isSnake(name),
            .camel => isCamel(name),
            .pascal => isPascal(name),
            .kebab => isKebab(name),
        };
    }

    /// Parses TOML / schema spellings (`snake_case`, `camelCase`, `PascalCase`, `kebab-case`, `@"kebab-case"`).
    pub fn fromConfigString(text: []const u8) ?Style {
        if (std.mem.eql(
            u8,
            text,
            "snake_case",
        )) return .snake;
        if (std.mem.eql(
            u8,
            text,
            "camelCase",
        )) return .camel;
        if (std.mem.eql(
            u8,
            text,
            "PascalCase",
        )) return .pascal;
        if (std.mem.eql(
            u8,
            text,
            "kebab-case",
        )) return .kebab;
        if (std.mem.eql(
            u8,
            text,
            "@\"kebab-case\"",
        )) return .kebab;
        return null;
    }
};

/// True when `name` contains no ASCII uppercase letters.
pub fn isSnake(name: []const u8) bool {
    for (name) |c| {
        if (c >= 'A' and c <= 'Z') return false;
    }
    return true;
}

test isSnake {
    try std.testing.expect(isSnake("foo_bar"));
    try std.testing.expect(isSnake("pi"));
    try std.testing.expect(!isSnake("fooBar"));
    try std.testing.expect(!isSnake("MAX"));
    try std.testing.expect(Style.snake.matches("foo_bar"));
}

/// True when `name` is empty or starts lowercase and contains no `_`.
pub fn isCamel(name: []const u8) bool {
    if (name.len == 0) return true;
    if (!(name[0] >= 'a' and name[0] <= 'z')) return false;
    for (name) |c| {
        if (c == '_') return false;
    }
    return true;
}

test isCamel {
    try std.testing.expect(isCamel("parseInt"));
    try std.testing.expect(isCamel("foo"));
    try std.testing.expect(!isCamel("parse_int"));
    try std.testing.expect(!isCamel("ParseInt"));
    try std.testing.expect(Style.camel.matches("parseInt"));
}

/// True when `name` is empty or starts uppercase and contains no `_`.
pub fn isPascal(name: []const u8) bool {
    if (name.len == 0) return true;
    if (!(name[0] >= 'A' and name[0] <= 'Z')) return false;
    for (name) |c| {
        if (c == '_') return false;
    }
    return true;
}

test isPascal {
    try std.testing.expect(isPascal("ArrayList"));
    try std.testing.expect(!isPascal("array_list"));
    try std.testing.expect(!isPascal("arrayList"));
    try std.testing.expect(Style.pascal.matches("ArrayList"));
}

/// True when `name` is non-empty and only contains lowercase letters, digits, and `-`.
pub fn isKebab(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| {
        if (!((c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '-')) return false;
    }
    return true;
}

test isKebab {
    try std.testing.expect(isKebab("docent-toml"));
    try std.testing.expect(!isKebab("DocentToml"));
    try std.testing.expect(!isKebab(""));
    try std.testing.expect(Style.kebab.matches("my-pkg"));
}

test "fromConfigString accepts schema spellings" {
    try std.testing.expectEqual(Style.snake, Style.fromConfigString("snake_case").?);
    try std.testing.expectEqual(Style.camel, Style.fromConfigString("camelCase").?);
    try std.testing.expectEqual(Style.pascal, Style.fromConfigString("PascalCase").?);
    try std.testing.expectEqual(Style.kebab, Style.fromConfigString("kebab-case").?);
    try std.testing.expectEqual(Style.kebab, Style.fromConfigString("@\"kebab-case\"").?);
}

/// Converts an identifier name to the filename stem implied by `case`.
///
/// Heuristic for `.snake` and `.kebab`; see the module docs for where the word-boundary guess can
/// diverge from what a human would write.
pub fn identifierToFilenameStem(
    allocator: std.mem.Allocator,
    name: []const u8,
    case: Style,
) std.mem.Allocator.Error![]u8 {
    return switch (case) {
        .snake => pascalCaseStemToSnake(allocator, name),
        .pascal => allocator.dupe(u8, name),
        .kebab => pascalCaseStemToKebab(allocator, name),
        .camel => allocator.dupe(u8, name),
    };
}

/// Suggests a filename stem for `stem` when it does not already match `case`.
///
/// Round-trips `stem` through a PascalCase intermediate, so this is a heuristic suggestion, not a
/// guaranteed-correct rename; see the module docs.
pub fn suggestFilenameStem(
    allocator: std.mem.Allocator,
    stem: []const u8,
    case: Style,
) std.mem.Allocator.Error![]u8 {
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
pub fn pascalCaseStemToSnake(allocator: std.mem.Allocator, stem: []const u8) std.mem.Allocator.Error![]u8 {
    if (stem.len == 0) return try allocator.dupe(u8, "");

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    for (stem, 0..) |c, i| {
        const is_upper = c >= 'A' and c <= 'Z';
        if (is_upper) {
            if (i > 0) {
                const prev = stem[i - 1];
                const next: u8 = if (i + 1 < stem.len) stem[i + 1] else 0;
                const prev_lower = prev >= 'a' and prev <= 'z';
                const next_lower = next >= 'a' and next <= 'z';
                const prev_upper = prev >= 'A' and prev <= 'Z';
                if (prev_lower or (prev_upper and next_lower)) {
                    try out.append(allocator, '_');
                }
            }
            try out.append(allocator, c + 32);
        } else {
            try out.append(allocator, c);
        }
    }

    return try out.toOwnedSlice(allocator);
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

test "pascalCaseStemToSnake merges back-to-back acronym runs (documented limitation)" {
    // XML and HTTP are both acronyms with no lowercase letter between them, so there is no
    // signal to split on: the heuristic only splits before the last capital of a run.
    const stem = try pascalCaseStemToSnake(std.testing.allocator, "XMLHTTPRequest");
    defer std.testing.allocator.free(stem);
    try std.testing.expectEqualStrings("xmlhttp_request", stem);
}

fn pascalCaseStemToKebab(allocator: std.mem.Allocator, stem: []const u8) std.mem.Allocator.Error![]u8 {
    const snake = try pascalCaseStemToSnake(allocator, stem);
    defer allocator.free(snake);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (snake) |c| {
        try out.append(allocator, if (c == '_') '-' else c);
    }
    return try out.toOwnedSlice(allocator);
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

fn snakeOrKebabStemToPascal(allocator: std.mem.Allocator, stem: []const u8) std.mem.Allocator.Error![]u8 {
    // Checked before isPascal/isCamel: a hyphenated stem like "diagnostic-message" starts
    // lowercase and contains no `_`, so it would otherwise spuriously satisfy isCamel and be
    // returned unconverted, leaving the hyphens in place.
    if (isKebab(stem)) {
        var snake: std.ArrayList(u8) = .empty;
        errdefer snake.deinit(allocator);
        for (stem) |c| try snake.append(allocator, if (c == '-') '_' else c);
        const snake_slice = try snake.toOwnedSlice(allocator);
        defer allocator.free(snake_slice);
        return snakeCaseStemToPascal(allocator, snake_slice);
    }
    if (isPascal(stem) or isCamel(stem)) return allocator.dupe(u8, stem);
    return snakeCaseStemToPascal(allocator, stem);
}

fn snakeCaseStemToPascal(allocator: std.mem.Allocator, stem: []const u8) std.mem.Allocator.Error![]u8 {
    if (stem.len == 0) return try allocator.dupe(u8, "");

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var capitalize_next = true;
    for (stem) |c| {
        if (c == '_') {
            capitalize_next = true;
            continue;
        }
        if (capitalize_next and c >= 'a' and c <= 'z') {
            try out.append(allocator, c - 32);
            capitalize_next = false;
        } else if (capitalize_next and c >= 'A' and c <= 'Z') {
            try out.append(allocator, c);
            capitalize_next = false;
        } else {
            try out.append(allocator, c);
            capitalize_next = false;
        }
    }

    return try out.toOwnedSlice(allocator);
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
