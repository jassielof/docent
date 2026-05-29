//! Represents a diagnostic issue or warning generated during static analysis.

const std = @import("std");
const Severity = @import("Severity.zig");

/// What the diagnostic refers to, for consistent prose output across rules.
pub const SubjectKind = enum {
    module,
    source_file,
    function,
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
            .constant => "constant",
            .variable => "variable",
            .error_set => "error set",
            .enumeration => "enumeration",
            .field => "field",
            .enumerator => "enumerator",
            .doc_comment => "doc comment",
            .doctest => "doctest",
            .structure => "struct",
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

/// The identifier of the lint rule that triggered this diagnostic.
rule: []const u8,
/// The severity level of the diagnostic.
severity: Severity.Level,
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

/// Frees strings allocated by `cloneAlloc`.
pub fn deinitAlloc(diagnostic: @This(), allocator: std.mem.Allocator) void {
    allocator.free(diagnostic.rule);
    if (diagnostic.message.len > 0) allocator.free(diagnostic.message);
    if (diagnostic.detail) |d| allocator.free(d);
    allocator.free(diagnostic.file);
    if (diagnostic.source_line.len > 0) allocator.free(diagnostic.source_line);
    if (diagnostic.subject) |s| allocator.free(s.name);
}

/// Deep-copies string fields into `allocator` so the diagnostic outlives a per-file lint arena.
pub fn cloneAlloc(diagnostic: @This(), allocator: std.mem.Allocator) std.mem.Allocator.Error!@This() {
    const subject: ?Subject = if (diagnostic.subject) |s| .{
        .kind = s.kind,
        .name = try allocator.dupe(u8, s.name),
    } else null;

    return .{
        .rule = try allocator.dupe(u8, diagnostic.rule),
        .severity = diagnostic.severity,
        .message = try allocator.dupe(u8, diagnostic.message),
        .subject = subject,
        .detail = if (diagnostic.detail) |d| try allocator.dupe(u8, d) else null,
        .file = try allocator.dupe(u8, diagnostic.file),
        .line = diagnostic.line,
        .column = diagnostic.column,
        .source_line = try allocator.dupe(u8, diagnostic.source_line),
        .symbol_len = diagnostic.symbol_len,
    };
}
