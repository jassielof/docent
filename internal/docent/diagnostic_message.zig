//! Shared prose formatting for diagnostics (TTY, tests, and JSON).
const std = @import("std");

const Diagnostic = @import("Diagnostic.zig");
const rule_metadata = @import("rule_metadata.zig");

/// Renders `Warning: Missing doc comment on field 'offset'.` into `buf`. Returns the written slice.
pub fn formatProse(
    diagnostic: Diagnostic,
    buf: []u8,
) ![]const u8 {
    var stream = std.Io.Writer.fixed(buf);
    try writeProse(&stream, diagnostic);
    return stream.buffered();
}

/// Writes the human-readable prose sentence for a diagnostic (no trailing newline).
pub fn writeProse(writer: *std.Io.Writer, diagnostic: Diagnostic) !void {
    const severity_label = proseSeverityLabel(diagnostic.severity_level);
    const rule_title = rule_metadata.proseTitle(diagnostic.rule) orelse diagnostic.rule;

    try writer.print("{s}: {s}", .{ severity_label, rule_title });

    if (diagnostic.subject) |subject| {
        if (subject.name.len > 0) {
            try writer.print(" on {s} '{s}'", .{ subject.kind.label(), subject.name });
        } else {
            try writer.print(" on {s}", .{subject.kind.label()});
        }
    }

    if (diagnostic.detail) |detail| {
        try writer.print(" ({s})", .{detail});
    }

    try writer.writeAll(".");
}

fn proseSeverityLabel(severity: @import("severity.zig").Level) []const u8 {
    return switch (severity) {
        .warn => "Warning",
        .deny, .forbid => "Error",
        .allow => "Note",
    };
}

test "prose with subject" {
    var buf: [128]u8 = undefined;
    const msg = try formatProse(.{
        .rule = "missing_doc_comment",
        .severity_level = .warn,
        .message = "",
        .subject = .{ .kind = .field, .name = "offset" },
        .file = "x.zig",
        .line = 1,
        .column = 1,
    }, &buf);
    try std.testing.expectEqualStrings("Warning: Missing doc comment on field 'offset'.", msg);
}

test "prose with detail" {
    var buf: [256]u8 = undefined;
    const msg = try formatProse(.{
        .rule = "missing_doc_comment",
        .severity_level = .warn,
        .message = "",
        .subject = .{ .kind = .function, .name = "foo" },
        .detail = "re-exported without documentation",
        .file = "x.zig",
        .line = 1,
        .column = 1,
    }, &buf);
    try std.testing.expectEqualStrings(
        "Warning: Missing doc comment on function 'foo' (re-exported without documentation).",
        msg,
    );
}
