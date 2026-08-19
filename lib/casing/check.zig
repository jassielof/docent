//! Exact convention checks: a name either satisfies a casing convention's character rules or it doesn't. No word-boundary guessing lives here — see `convert.zig` for the heuristic half.

const std = @import("std");
const ascii = std.ascii;

/// A recognized naming convention.
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
        const table = .{
            .{ "snake_case", Style.snake },
            .{ "camelCase", Style.camel },
            .{ "PascalCase", Style.pascal },
            .{ "kebab-case", Style.kebab },
            .{ "@\"kebab-case\"", Style.kebab },
        };
        inline for (table) |entry| {
            if (std.mem.eql(
                u8,
                text,
                entry[0],
            )) return entry[1];
        }
        return null;
    }
};

/// True when `name` contains no ASCII uppercase letters.
pub fn isSnake(name: []const u8) bool {
    for (name) |c| {
        if (ascii.isUpper(c)) return false;
    }
    return true;
}

test isSnake {
    try std.testing.expect(isSnake("foo_bar"));
    try std.testing.expect(isSnake("pi"));
    try std.testing.expect(isSnake(""));
    try std.testing.expect(isSnake("foo123"));
    try std.testing.expect(isSnake("__private"));
    try std.testing.expect(!isSnake("fooBar"));
    try std.testing.expect(!isSnake("MAX"));
    try std.testing.expect(Style.snake.matches("foo_bar"));
}

/// True when `name` is empty or starts lowercase and contains no `_`.
pub fn isCamel(name: []const u8) bool {
    if (name.len == 0) return true;
    if (!ascii.isLower(name[0])) return false;
    for (name) |c| {
        if (c == '_') return false;
    }
    return true;
}

test isCamel {
    try std.testing.expect(isCamel("parseInt"));
    try std.testing.expect(isCamel("foo"));
    try std.testing.expect(isCamel(""));
    try std.testing.expect(isCamel("a"));
    try std.testing.expect(isCamel("utf8Decoder"));
    try std.testing.expect(!isCamel("parse_int"));
    try std.testing.expect(!isCamel("ParseInt"));
    try std.testing.expect(!isCamel("1invalid"));
    try std.testing.expect(Style.camel.matches("parseInt"));
}

/// True when `name` is empty or starts uppercase and contains no `_`.
pub fn isPascal(name: []const u8) bool {
    if (name.len == 0) return true;
    if (!ascii.isUpper(name[0])) return false;
    for (name) |c| {
        if (c == '_') return false;
    }
    return true;
}

test isPascal {
    try std.testing.expect(isPascal("ArrayList"));
    try std.testing.expect(isPascal(""));
    try std.testing.expect(isPascal("A"));
    try std.testing.expect(isPascal("Utf8Decoder"));
    try std.testing.expect(!isPascal("array_list"));
    try std.testing.expect(!isPascal("arrayList"));
    try std.testing.expect(!isPascal("1Invalid"));
    try std.testing.expect(Style.pascal.matches("ArrayList"));
}

/// True when `name` is non-empty and only contains lowercase ASCII letters, digits, and `-`.
pub fn isKebab(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| {
        if (!(ascii.isLower(c) or ascii.isDigit(c) or c == '-')) return false;
    }
    return true;
}

test isKebab {
    try std.testing.expect(isKebab("docent-toml"));
    try std.testing.expect(isKebab("a"));
    try std.testing.expect(isKebab("v2-beta"));
    try std.testing.expect(!isKebab("DocentToml"));
    try std.testing.expect(!isKebab(""));
    try std.testing.expect(!isKebab("docent_toml"));
    try std.testing.expect(Style.kebab.matches("my-pkg"));
}

test "fromConfigString accepts schema spellings" {
    try std.testing.expectEqual(Style.snake, Style.fromConfigString("snake_case").?);
    try std.testing.expectEqual(Style.camel, Style.fromConfigString("camelCase").?);
    try std.testing.expectEqual(Style.pascal, Style.fromConfigString("PascalCase").?);
    try std.testing.expectEqual(Style.kebab, Style.fromConfigString("kebab-case").?);
    try std.testing.expectEqual(Style.kebab, Style.fromConfigString("@\"kebab-case\"").?);
}

test "fromConfigString rejects unknown spellings" {
    try std.testing.expectEqual(@as(?Style, null), Style.fromConfigString("SCREAMING_SNAKE"));
    try std.testing.expectEqual(@as(?Style, null), Style.fromConfigString(""));
}

test "label round-trips through fromConfigString" {
    inline for (@typeInfo(Style).@"enum".fields) |field| {
        const style: Style = @enumFromInt(field.value);
        try std.testing.expectEqual(style, Style.fromConfigString(style.label()).?);
    }
}
