//! The naming_case namespace provides utilities related to naming case conventions and styles .

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
