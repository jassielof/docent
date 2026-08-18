//! Represents a diagnostic issue or warning generated during static analysis.

const std = @import("std");

const severity = @import("severity.zig");

/// What the diagnostic refers to, for consistent prose output across rules.
pub const SubjectKind = enum {
    module,
    source_file,
    function,
    parameter,
    constant,
    variable,
    error_set,
    enumeration,
    field,
    enumerator,
    doc_comment,
    doctest,
    structure,
    namespace,
    @"union",
    error_value,
    type_alias,

    pub fn label(self: SubjectKind) []const u8 {
        return switch (self) {
            .module => "module",
            .source_file => "source file",
            .function => "function",
            .parameter => "parameter",
            .constant => "constant",
            .variable => "variable",
            .error_set => "error set",
            .enumeration => "enumeration",
            .field => "field",
            .enumerator => "enumerator",
            .doc_comment => "doc comment",
            .doctest => "doctest",
            .structure => "structure",
            .namespace => "namespace",
            .@"union" => "union",
            .error_value => "error value",
            .type_alias => "type",
        };
    }
};

/// Named declaration or artifact attached to a diagnostic.
pub const Subject = struct {
    kind: SubjectKind,
    name: []const u8,
};

/// A labeled secondary source location shown beneath the primary span in
/// pretty mode — e.g. one contributing increment of a complexity score.
/// Must be supplied in ascending `line` order; renderers don't re-sort.
pub const Span = struct {
    line: usize,
    column: usize,
    symbol_len: usize = 1,
    source_line: []const u8 = "",
    /// Short label rendered after the underline, e.g. "+2 (nested conditional)".
    label: []const u8 = "",
};

/// The identifier of the lint rule that triggered this diagnostic.
rule: []const u8,
/// The severity level of the diagnostic.
severity_level: severity.Level,
/// Optional legacy or rule-specific text; prose formatters prefer `subject` and `detail`.
message: []const u8 = "",
/// Primary subject for prose output (`Warning: … on kind 'name'.`).
subject: ?Subject = null,
/// Optional parenthetical detail appended before the closing period.
detail: ?[]const u8 = null,
/// The path to the file where the diagnostic was found.
file: []const u8,
/// The 1-based line number in the source file where the diagnostic occurs.
line: usize,
/// The 1-based column number in the source file where the diagnostic occurs.
column: usize,
/// The trimmed source line where the diagnostic occurs. Empty if unavailable.
source_line: []const u8 = "",
/// Length of the highlighted token for the ^~~~ span. Defaults to 1.
symbol_len: usize = 1,
/// Optional label rendered after the primary caret underline (e.g. "score: 29").
primary_label: ?[]const u8 = null,
/// Additional labeled spans shown beneath the primary one. Empty for the
/// vast majority of diagnostics; only multi-cause rules like complexity
/// checks populate this.
spans: []const Span = &.{},
/// Optional closing suggestion, rendered as a rustc-style `= help: ...`
/// line after the primary span (and any `spans`).
help: ?[]const u8 = null,

/// Frees strings allocated by `cloneAlloc`.
pub fn deinitAlloc(diagnostic: @This(), allocator: std.mem.Allocator) void {
    allocator.free(diagnostic.rule);
    if (diagnostic.message.len > 0) allocator.free(diagnostic.message);
    if (diagnostic.detail) |d| allocator.free(d);
    allocator.free(diagnostic.file);
    if (diagnostic.source_line.len > 0) allocator.free(diagnostic.source_line);
    if (diagnostic.subject) |s| allocator.free(s.name);
    if (diagnostic.primary_label) |l| allocator.free(l);
    for (diagnostic.spans) |span| {
        if (span.source_line.len > 0) allocator.free(span.source_line);
        if (span.label.len > 0) allocator.free(span.label);
    }
    if (diagnostic.spans.len > 0) allocator.free(diagnostic.spans);
    if (diagnostic.help) |h| allocator.free(h);
}

/// Deep-copies string fields into `allocator` so the diagnostic outlives a per-file lint arena.
pub fn cloneAlloc(
    diagnostic: @This(),
    allocator: std.mem.Allocator,
) std.mem.Allocator.Error!@This() {
    const subject: ?Subject = if (diagnostic.subject) |s| .{
        .kind = s.kind,
        .name = try allocator.dupe(u8, s.name),
    } else null;

    const spans = try allocator.alloc(Span, diagnostic.spans.len);
    for (diagnostic.spans, spans) |src, *dst| {
        dst.* = .{
            .line = src.line,
            .column = src.column,
            .symbol_len = src.symbol_len,
            .source_line = try allocator.dupe(u8, src.source_line),
            .label = try allocator.dupe(u8, src.label),
        };
    }

    return .{
        .rule = try allocator.dupe(u8, diagnostic.rule),
        .severity_level = diagnostic.severity_level,
        .message = try allocator.dupe(u8, diagnostic.message),
        .subject = subject,
        .detail = if (diagnostic.detail) |d| try allocator.dupe(u8, d) else null,
        .file = try allocator.dupe(u8, diagnostic.file),
        .line = diagnostic.line,
        .column = diagnostic.column,
        .source_line = try allocator.dupe(u8, diagnostic.source_line),
        .symbol_len = diagnostic.symbol_len,
        .primary_label = if (diagnostic.primary_label) |l| try allocator.dupe(u8, l) else null,
        .spans = spans,
        .help = if (diagnostic.help) |h| try allocator.dupe(u8, h) else null,
    };
}
