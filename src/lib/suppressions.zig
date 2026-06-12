//! Parses `docent:ignore` / `docent:disable` line-comment pragmas and filters diagnostics.
//!
//! Suppressions are applied after all rules run in a lint pass. They are not configured in
//! `docent.toml`; use `//` line comments in source instead.
//!
//! ## Syntax
//!
//! Use `//` only — never `///` or `//!`, which are rendered as documentation.
//!
//! * `// docent:ignore <rule>` — same line as the comment
//! * `// docent:ignore-next <rule>` — following source line
//! * `// docent:ignore-start <rule>` … `// docent:ignore-end` — inclusive line block;
//!   an unclosed `-start` extends to EOF
//!
//! `<rule>` is one or more rule names (comma-separated). Omit `<rule>` or use `*` to suppress
//! every active rule on the matched span. `docent:disable` is a synonym for `docent:ignore`
//! (including `-next`, `-start`, and `-end` variants).
//!
//! Diagnostics at `forbid` severity are never suppressed.

const std = @import("std");
const Ast = std.zig.Ast;

const Diagnostic = @import("Diagnostic.zig");
const severity = @import("severity.zig");

const RuleSet = struct {
    all: bool = false,
    rules: std.StringHashMap(void),

    fn init(allocator: std.mem.Allocator) RuleSet {
        return .{ .rules = std.StringHashMap(void).init(allocator) };
    }

    fn deinit(self: *RuleSet, allocator: std.mem.Allocator) void {
        var it = self.rules.keyIterator();
        while (it.next()) |key| allocator.free(key.*);
        self.rules.deinit();
        self.* = .{ .rules = std.StringHashMap(void).init(allocator) };
    }

    fn clone(self: RuleSet, allocator: std.mem.Allocator) !RuleSet {
        var out = RuleSet.init(allocator);
        out.all = self.all;
        var it = self.rules.keyIterator();
        while (it.next()) |key| {
            try out.rules.put(try allocator.dupe(u8, key.*), {});
        }
        return out;
    }

    fn addRules(self: *RuleSet, allocator: std.mem.Allocator, names: []const u8) !void {
        const rest = std.mem.trim(u8, names, " \t");
        if (rest.len == 0) {
            self.all = true;
            return;
        }
        var it = std.mem.tokenizeAny(u8, rest, ",");
        while (it.next()) |raw| {
            const name = std.mem.trim(u8, raw, " \t");
            if (name.len == 0) continue;
            if (std.mem.eql(u8, name, "*")) {
                self.all = true;
                continue;
            }
            const gop = try self.rules.getOrPut(try allocator.dupe(u8, name));
            if (gop.found_existing) allocator.free(gop.key_ptr.*);
        }
    }

    fn contains(self: *const RuleSet, rule: []const u8) bool {
        if (self.all) return true;
        return self.rules.contains(rule);
    }
};

const Block = struct {
    start_line: usize,
    end_line: usize,
    rules: RuleSet,
};

const DirectiveKind = enum {
    ignore_line,
    ignore_next,
    ignore_start,
    ignore_end,
};

/// Parsed suppressions for one source file.
pub const Table = struct {
    line_rules: std.AutoHashMap(usize, RuleSet),
    blocks: std.ArrayList(Block),
    next_line_rules: std.AutoHashMap(usize, RuleSet),

    pub fn init(allocator: std.mem.Allocator) Table {
        return .{
            .line_rules = std.AutoHashMap(usize, RuleSet).init(allocator),
            .blocks = std.ArrayList(Block).empty,
            .next_line_rules = std.AutoHashMap(usize, RuleSet).init(allocator),
        };
    }

    pub fn deinit(self: *Table, allocator: std.mem.Allocator) void {
        var line_it = self.line_rules.valueIterator();
        while (line_it.next()) |set| set.deinit(allocator);
        self.line_rules.deinit();

        var next_it = self.next_line_rules.valueIterator();
        while (next_it.next()) |set| set.deinit(allocator);
        self.next_line_rules.deinit();

        for (self.blocks.items) |*block| block.rules.deinit(allocator);
        self.blocks.deinit(allocator);
    }

    /// Returns true when `rule` at `line` is suppressed. `forbid` diagnostics are never suppressed.
    pub fn isSuppressed(self: *const Table, rule: []const u8, line: usize, severity_level: severity.Level) bool {
        if (severity_level == .forbid) return false;
        if (self.line_rules.get(line)) |set| {
            if (set.contains(rule)) return true;
        }
        if (self.next_line_rules.get(line)) |set| {
            if (set.contains(rule)) return true;
        }
        for (self.blocks.items) |block| {
            if (line < block.start_line or line > block.end_line) continue;
            if (block.rules.contains(rule)) return true;
        }
        return false;
    }
};

fn lineCommentBody(line: []const u8) ?[]const u8 {
    var in_string = false;
    var escape = false;
    var i: usize = 0;
    while (i + 1 < line.len) : (i += 1) {
        const c = line[i];
        if (escape) {
            escape = false;
            continue;
        }
        if (in_string and c == '\\') {
            escape = true;
            continue;
        }
        if (c == '"') {
            in_string = !in_string;
            continue;
        }
        if (in_string or c != '/' or line[i + 1] != '/') continue;
        if (i + 2 < line.len and line[i + 2] == '/') return null;
        if (i + 2 < line.len and line[i + 2] == '!') return null;
        return std.mem.trim(u8, line[i + 2 .. line.len], " \t");
    }
    return null;
}

fn parseDirective(body: []const u8) ?struct { kind: DirectiveKind, rules_text: []const u8 } {
    const prefixes = [_]struct { prefix: []const u8, kind: DirectiveKind }{
        .{ .prefix = "docent:ignore-next", .kind = .ignore_next },
        .{ .prefix = "docent:disable-next", .kind = .ignore_next },
        .{ .prefix = "docent:ignore-start", .kind = .ignore_start },
        .{ .prefix = "docent:disable-start", .kind = .ignore_start },
        .{ .prefix = "docent:ignore-end", .kind = .ignore_end },
        .{ .prefix = "docent:disable-end", .kind = .ignore_end },
        .{ .prefix = "docent:ignore", .kind = .ignore_line },
        .{ .prefix = "docent:disable", .kind = .ignore_line },
    };

    for (prefixes) |entry| {
        if (!std.mem.startsWith(u8, body, entry.prefix)) continue;
        var rules_text = body[entry.prefix.len..];
        if (rules_text.len > 0 and rules_text[0] == ' ') {
            rules_text = std.mem.trim(u8, rules_text[1..], " \t");
        } else {
            rules_text = std.mem.trim(u8, rules_text, " \t");
        }
        if (rules_text.len > 0 and rules_text[rules_text.len - 1] == 0) {
            rules_text = rules_text[0 .. rules_text.len - 1];
        }
        return .{ .kind = entry.kind, .rules_text = rules_text };
    }
    return null;
}

fn mergeRuleSet(into: *RuleSet, from: RuleSet, allocator: std.mem.Allocator) !void {
    if (from.all) into.all = true;
    var it = from.rules.keyIterator();
    while (it.next()) |key| {
        const gop = try into.rules.getOrPut(try allocator.dupe(u8, key.*));
        if (gop.found_existing) allocator.free(gop.key_ptr.*);
    }
}

fn putLineRules(
    map: *std.AutoHashMap(usize, RuleSet),
    allocator: std.mem.Allocator,
    line: usize,
    rules_text: []const u8,
) !void {
    var incoming = RuleSet.init(allocator);
    defer incoming.deinit(allocator);
    try incoming.addRules(allocator, rules_text);

    const gop = try map.getOrPut(line);
    if (!gop.found_existing) {
        gop.value_ptr.* = try incoming.clone(allocator);
        return;
    }
    try mergeRuleSet(gop.value_ptr, incoming, allocator);
}

/// Builds a suppression table from `tree`.
pub fn collectFromTree(allocator: std.mem.Allocator, tree: *const Ast) !Table {
    var table = Table.init(allocator);
    errdefer table.deinit(allocator);

    var open_blocks: std.ArrayList(struct {
        start_line: usize,
        rules: RuleSet,
    }) = .empty;
    defer {
        for (open_blocks.items) |*entry| entry.rules.deinit(allocator);
        open_blocks.deinit(allocator);
    }

    var line_start: usize = 0;
    var line_number: usize = 1;
    const source = tree.source;

    while (line_start <= source.len) {
        const line_end = std.mem.indexOfScalar(u8, source[line_start..], '\n') orelse source.len - line_start;
        const raw_line = source[line_start .. line_start + line_end];
        const line = if (std.mem.endsWith(u8, raw_line, "\r"))
            raw_line[0 .. raw_line.len - 1]
        else
            raw_line;

        if (lineCommentBody(line)) |body| {
            if (parseDirective(body)) |parsed| {
                switch (parsed.kind) {
                    .ignore_line => try putLineRules(&table.line_rules, allocator, line_number, parsed.rules_text),
                    .ignore_next => try putLineRules(&table.next_line_rules, allocator, line_number + 1, parsed.rules_text),
                    .ignore_start => {
                        var rules = RuleSet.init(allocator);
                        try rules.addRules(allocator, parsed.rules_text);
                        try open_blocks.append(allocator, .{ .start_line = line_number, .rules = rules });
                    },
                    .ignore_end => {
                        if (open_blocks.items.len > 0) {
                            const opened = open_blocks.pop().?;
                            try table.blocks.append(allocator, .{
                                .start_line = opened.start_line,
                                .end_line = line_number,
                                .rules = opened.rules,
                            });
                        }
                    },
                }
            }
        }

        if (line_start + line_end >= source.len) break;
        line_start += line_end + 1;
        line_number += 1;
    }

    const last_line = if (line_number > 1) line_number else 1;
    while (open_blocks.items.len > 0) {
        const opened = open_blocks.pop().?;
        try table.blocks.append(allocator, .{
            .start_line = opened.start_line,
            .end_line = last_line,
            .rules = opened.rules,
        });
    }

    return table;
}

/// Removes diagnostics suppressed by `table`. Diagnostic strings remain in the result arena.
pub fn filterDiagnostics(
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
    table: *const Table,
) void {
    var index: usize = 0;
    while (index < diagnostics.items.len) {
        const diagnostic = diagnostics.items[index];
        if (table.isSuppressed(diagnostic.rule, diagnostic.line, diagnostic.severity_level)) {
            _ = diagnostics.orderedRemove(index);
            continue;
        }
        index += 1;
    }
    _ = allocator;
}

test "line docent:ignore suppresses on same line" {
    const source =
        \\pub fn ok() void {} // docent:ignore identifier_case
    ++ "\x00";
    var tree = try std.zig.Ast.parse(std.testing.allocator, source, .zig);
    defer tree.deinit(std.testing.allocator);

    var table = try collectFromTree(std.testing.allocator, &tree);
    defer table.deinit(std.testing.allocator);

    try std.testing.expect(table.isSuppressed("identifier_case", 1, .warn));
}

test "doc comment pragmas are not suppressions" {
    const source =
        \\/// docent:ignore identifier_case
        \\pub fn bad_name() void {}
    ++ "\x00";
    var tree = try std.zig.Ast.parse(std.testing.allocator, source, .zig);
    defer tree.deinit(std.testing.allocator);

    var table = try collectFromTree(std.testing.allocator, &tree);
    defer table.deinit(std.testing.allocator);

    try std.testing.expect(!table.isSuppressed("identifier_case", 2, .warn));
}

test "docent:ignore-next suppresses following line" {
    const source =
        \\// docent:ignore-next identifier_case
        \\pub fn bad_name() void {}
    ++ "\x00";
    var tree = try std.zig.Ast.parse(std.testing.allocator, source, .zig);
    defer tree.deinit(std.testing.allocator);

    var table = try collectFromTree(std.testing.allocator, &tree);
    defer table.deinit(std.testing.allocator);

    try std.testing.expect(table.isSuppressed("identifier_case", 2, .warn));
    try std.testing.expect(!table.isSuppressed("identifier_case", 1, .warn));
}

test "docent:ignore-start and docent:ignore-end define a block" {
    const source =
        \\// docent:ignore-start identifier_case
        \\pub fn one() void {}
        \\pub fn two() void {}
        \\// docent:ignore-end identifier_case
        \\pub fn three() void {}
    ++ "\x00";
    var tree = try std.zig.Ast.parse(std.testing.allocator, source, .zig);
    defer tree.deinit(std.testing.allocator);

    var table = try collectFromTree(std.testing.allocator, &tree);
    defer table.deinit(std.testing.allocator);

    try std.testing.expect(table.isSuppressed("identifier_case", 2, .warn));
    try std.testing.expect(table.isSuppressed("identifier_case", 3, .warn));
    try std.testing.expect(!table.isSuppressed("identifier_case", 5, .warn));
}

test "forbid severity is never suppressed" {
    const source =
        \\// docent:ignore missing_doc_comment
        \\pub fn foo() void {}
    ++ "\x00";
    var tree = try std.zig.Ast.parse(std.testing.allocator, source, .zig);
    defer tree.deinit(std.testing.allocator);

    var table = try collectFromTree(std.testing.allocator, &tree);
    defer table.deinit(std.testing.allocator);

    try std.testing.expect(!table.isSuppressed("missing_doc_comment", 2, .forbid));
}

test "docent:disable is an alias for docent:ignore" {
    const source =
        \\pub fn heavy() void {} // docent:disable cognitive_complexity
    ++ "\x00";
    var tree = try std.zig.Ast.parse(std.testing.allocator, source, .zig);
    defer tree.deinit(std.testing.allocator);

    var table = try collectFromTree(std.testing.allocator, &tree);
    defer table.deinit(std.testing.allocator);

    try std.testing.expect(table.isSuppressed("cognitive_complexity", 1, .warn));
}

test "filterDiagnostics removes suppressed entries" {
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);

    try diagnostics.append(std.testing.allocator, .{
        .rule = "identifier_case",
        .severity_level = .warn,
        .file = "file.zig",
        .line = 2,
        .column = 1,
    });
    try diagnostics.append(std.testing.allocator, .{
        .rule = "missing_doc_comment",
        .severity_level = .warn,
        .file = "file.zig",
        .line = 3,
        .column = 1,
    });

    var table = Table.init(std.testing.allocator);
    defer table.deinit(std.testing.allocator);
    {
        var set = RuleSet.init(std.testing.allocator);
        defer set.deinit(std.testing.allocator);
        try set.addRules(std.testing.allocator, "identifier_case");
        try table.line_rules.put(2, try set.clone(std.testing.allocator));
    }

    filterDiagnostics(std.testing.allocator, &diagnostics, &table);
    try std.testing.expectEqual(@as(usize, 1), diagnostics.items.len);
    try std.testing.expectEqualStrings("missing_doc_comment", diagnostics.items[0].rule);
}
