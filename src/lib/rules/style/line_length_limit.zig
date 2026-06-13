//! The `line_length_limit` namespace enforces a maximum physical line length in source files.

const std = @import("std");

const Diagnostic = @import("../../Diagnostic.zig");
const severity = @import("../../severity.zig");
const scanning = @import("../../scanning.zig");
const category = @import("../category.zig");
const utils = @import("../utils.zig");

inline fn srcLoc() std.builtin.SourceLocation {
    return @src();
}

const rule_name = utils.ruleIdFromSrc(srcLoc());

/// Default severity `allow`: a hard column cap is a strong opinion many projects skip, so it ships off; opt in with `level = "warn"` or stricter in config.
pub const default_severity: severity.Level = .allow;

/// Default maximum line length in characters.
pub const default_max_length: u32 = 100;

/// Rule-specific knobs for `line_length_limit`, held in the `options` sub-space of `Rule`.
pub const Options = struct {
    /// Maximum physical line width in characters before the rule triggers; default `100` is a widely shared ceiling for side-by-side diffs.
    max_length: u32 = default_max_length,
    /// When set, trailing `//` comments are excluded from the measured width; default `false` counts them, matching most formatters.
    ignore_trailing_comments: bool = false,
    // TODO: Add option to ignore leading doc/comments.
};

/// Full configuration for `line_length_limit`: severity, scan mode, and the documented `Options` sub-space.
pub const Rule = category.Rule(default_severity, Options, scanning.Modes.reachability_traversal);

/// Walks `source` line by line and appends a diagnostic for every line wider than `options.max_length`.
pub fn check(
    source: [:0]const u8,
    rule: Rule,
    file: []const u8,
    allocator: std.mem.Allocator,
    msg_allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) !void {
    if (!rule.level.isActive()) return;
    const severity_level = rule.level;
    const options = rule.options;

    const max_length: usize = @intCast(options.max_length);
    var line_start: usize = 0;
    var line_number: usize = 1;

    while (line_start <= source.len) {
        const line_end = std.mem.indexOfScalar(u8, source[line_start..], '\n') orelse source.len - line_start;
        const raw_line = source[line_start .. line_start + line_end];
        const line = if (std.mem.endsWith(u8, raw_line, "\r"))
            raw_line[0 .. raw_line.len - 1]
        else
            raw_line;

        const effective_len = effectiveLineLength(line, options);
        if (effective_len > max_length) {
            const stem = fileStem(file);
            const detail = try std.fmt.allocPrint(
                msg_allocator,
                "line length {d} exceeds maximum {d}",
                .{ effective_len, max_length },
            );
            try diagnostics.append(allocator, .{
                .rule = rule_name,
                .severity_level = severity_level,
                .subject = try utils.ownedSubject(msg_allocator, .source_file, stem),
                .detail = detail,
                .file = file,
                .line = line_number,
                .column = max_length + 1,
                .source_line = try msg_allocator.dupe(u8, line),
                .symbol_len = effective_len - max_length,
            });
        }

        if (line_start + line_end >= source.len) break;
        line_start += line_end + 1;
        line_number += 1;
    }
}

fn fileStem(file: []const u8) []const u8 {
    const base = std.fs.path.basename(file);
    if (std.mem.endsWith(u8, base, ".zig")) return base[0 .. base.len - ".zig".len];
    return base;
}

fn effectiveLineLength(line: []const u8, options: Options) usize {
    if (!options.ignore_trailing_comments) return line.len;
    const comment_start = trailingCommentStart(line) orelse return line.len;
    return std.mem.trim(u8, line[0..comment_start], " \t").len;
}

fn trailingCommentStart(line: []const u8) ?usize {
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
        if (!in_string and c == '/' and line[i + 1] == '/') return i;
    }
    return null;
}

const TestResult = struct {
    msg_arena: std.heap.ArenaAllocator,
    items: std.ArrayList(Diagnostic),

    fn deinit(self: *TestResult) void {
        self.msg_arena.deinit();
        self.items.deinit(std.testing.allocator);
    }
};

fn runCheck(source: [:0]const u8, options: Options) !TestResult {
    const base = std.testing.allocator;
    var msg_arena = std.heap.ArenaAllocator.init(base);
    errdefer msg_arena.deinit();

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    errdefer diagnostics.deinit(base);

    try check(source, .{ .level = .warn, .options = options }, "<test>", base, msg_arena.allocator(), &diagnostics);
    return .{ .msg_arena = msg_arena, .items = diagnostics };
}

test "accepts lines within the limit" {
    var r = try runCheck("pub fn ok() void {}\n", .{});
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 0), r.items.items.len);
}

test "warns when a line exceeds max_length" {
    var r = try runCheck("////1234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890\n", .{ .max_length = 10 });
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 1), r.items.items.len);
    try std.testing.expectEqualStrings(rule_name, r.items.items[0].rule);
    try std.testing.expectEqual(@as(usize, 11), r.items.items[0].column);
}

test "ignore_trailing_comments excludes trailing // text" {
    const source =
        \\pub const x = 1; // aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
        \\
    ;
    var with_comments = try runCheck(source, .{ .max_length = 20 });
    defer with_comments.deinit();
    try std.testing.expectEqual(@as(usize, 1), with_comments.items.items.len);

    var ignored = try runCheck(source, .{ .max_length = 20, .ignore_trailing_comments = true });
    defer ignored.deinit();
    try std.testing.expectEqual(@as(usize, 0), ignored.items.items.len);
}

test "ignore_trailing_comments keeps // inside string literals" {
    const source =
        \\pub const s = "//aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        \\
    ;
    var r = try runCheck(source, .{ .max_length = 20, .ignore_trailing_comments = true });
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 1), r.items.items.len);
}
