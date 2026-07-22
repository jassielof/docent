//! The `line_length_limit` namespace enforces a maximum physical line length in source files.

const std = @import("std");

const Diagnostic = @import("../../Diagnostic.zig");
const scan = @import("../../scan.zig");
const severity = @import("../../severity.zig");
const category = @import("../category.zig");
const utils = @import("../utils.zig");

inline fn srcLoc() std.builtin.SourceLocation {
    return @src();
}

const rule_name = utils.ruleIdFromSrc(srcLoc());

/// Default severity `allow`: a hard column cap is a strong opinion many projects skip, so it ships off; opt in with `level = "warn"` or stricter in config.
pub const default_severity: severity.Level = .allow;

/// Title for diagnostic prose (`Warning: {prose_title} on …`).
pub const prose_title = "Line length limit";

/// Default maximum line length in characters.
pub const default_max_length: u32 = 100;

/// Rule-specific knobs for `line_length_limit`, held in the `options` sub-space of `Rule`.
pub const Options = struct {
    /// Maximum physical line width in characters before the rule triggers; default `100` is a widely shared ceiling for side-by-side diffs.
    max_length: u32 = default_max_length,
    /// When set, trailing `//` comments are excluded from the measured width; default `false` counts them, matching most formatters.
    ignore_trailing_comments: bool = false,
    /// When set, lines that are only leading whitespace plus `//`, `///`, or `//!` are excluded from measurement.
    ignore_leading_comments: bool = false,
};

/// Full configuration for `line_length_limit`: severity, scan mode, and the documented `Options` sub-space.
pub const Rule = category.Rule(
    default_severity,
    Options,
    scan.RuleScanConfig.reachability_traversal,
);

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
        const line_end = std.mem.indexOfScalar(
            u8,
            source[line_start..],
            '\n',
        ) orelse source.len - line_start;
        const raw_line = source[line_start .. line_start + line_end];
        const line = if (std.mem.endsWith(
            u8,
            raw_line,
            "\r",
        ))
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
                .subject = try utils.ownedSubject(
                    msg_allocator,
                    .source_file,
                    stem,
                ),
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
    if (std.mem.endsWith(
        u8,
        base,
        ".zig",
    )) return base[0 .. base.len - ".zig".len];
    return base;
}

fn effectiveLineLength(line: []const u8, options: Options) usize {
    if (options.ignore_leading_comments and isLeadingCommentLine(line)) return 0;

    if (!options.ignore_trailing_comments) return line.len;
    const comment_start = trailingCommentStart(line) orelse return line.len;
    return std.mem.trim(
        u8,
        line[0..comment_start],
        " \t",
    ).len;
}

fn isLeadingCommentLine(line: []const u8) bool {
    const content = std.mem.trim(
        u8,
        line,
        " \t",
    );
    if (content.len == 0) return true;
    return std.mem.startsWith(
        u8,
        content,
        "//!",
    ) or
        std.mem.startsWith(
            u8,
            content,
            "///",
        ) or
        std.mem.startsWith(
            u8,
            content,
            "//",
        );
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
