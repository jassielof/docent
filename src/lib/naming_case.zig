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

    /// Parses TOML / schema spellings (`snake_case`, `camelCase`, `PascalCase`, `kebab-case`, `@"kebab-case"`).
    pub fn fromConfigString(text: []const u8) ?Style {
        if (std.mem.eql(u8, text, "snake_case")) return .snake;
        if (std.mem.eql(u8, text, "camelCase")) return .camel;
        if (std.mem.eql(u8, text, "PascalCase")) return .pascal;
        if (std.mem.eql(u8, text, "kebab-case")) return .kebab;
        if (std.mem.eql(u8, text, "@\"kebab-case\"")) return .kebab;
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
pub fn identifierToFilenameStem(allocator: std.mem.Allocator, name: []const u8, case: Style) std.mem.Allocator.Error![]u8 {
    return switch (case) {
        .snake => pascalCaseStemToSnake(allocator, name),
        .pascal => allocator.dupe(u8, name),
        .kebab => pascalCaseStemToKebab(allocator, name),
        .camel => allocator.dupe(u8, name),
    };
}

/// Suggests a filename stem for `stem` when it does not already match `case`.
pub fn suggestFilenameStem(allocator: std.mem.Allocator, stem: []const u8, case: Style) std.mem.Allocator.Error![]u8 {
    if (case.matches(stem)) return allocator.dupe(u8, stem);
    const pascal = try snakeOrKebabStemToPascal(allocator, stem);
    defer allocator.free(pascal);
    return identifierToFilenameStem(allocator, pascal, case);
}

/// Converts a PascalCase or mixed-case stem to `snake_case`.
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

fn snakeOrKebabStemToPascal(allocator: std.mem.Allocator, stem: []const u8) std.mem.Allocator.Error![]u8 {
    if (isPascal(stem) or isCamel(stem)) return allocator.dupe(u8, stem);
    if (isKebab(stem)) {
        var snake: std.ArrayList(u8) = .empty;
        errdefer snake.deinit(allocator);
        for (stem) |c| try snake.append(allocator, if (c == '-') '_' else c);
        const snake_slice = try snake.toOwnedSlice(allocator);
        defer allocator.free(snake_slice);
        return snakeCaseStemToPascal(allocator, snake_slice);
    }
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
