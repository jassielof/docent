const std = @import("std");
const builtin = @import("builtin");
const Diagnostic = @import("Diagnostic.zig");
const carnaval = @import("carnaval");

pub const TextFormat = enum {
    pretty,
    minimal,
};

pub const ColorMode = enum {
    auto,
    always,
    never,
};

pub const TextOptions = struct {
    format: TextFormat = .pretty,
    color: ColorMode = .auto,
    tty_config: std.io.tty.Config = .no_color,
    color_profile: ?carnaval.ColorProfile = null,
    /// When set, absolute paths under this directory are printed relative to it (Cargo-style).
    path_display_root: ?[]const u8 = null,
};

pub const SummaryOptions = struct {
    color: ColorMode = .auto,
    tty_config: std.io.tty.Config = .no_color,
    color_profile: ?carnaval.ColorProfile = null,
    tool_name: []const u8 = "docent",
};

pub const Summary = struct {
    errors: usize = 0,
    warnings: usize = 0,

    pub fn observe(self: *Summary, diagnostic: Diagnostic) void {
        if (diagnostic.severity.isError()) {
            self.errors += 1;
        } else if (diagnostic.severity == .warn) {
            self.warnings += 1;
        }
    }

    pub fn hasErrors(self: Summary) bool {
        return self.errors > 0;
    }
};

const Style = struct {
    plain_bold: carnaval.Style,
    warning_style: carnaval.Style,
    error_style: carnaval.Style,
    dim: carnaval.Style,
    caret_warning: carnaval.Style,
    caret_error: carnaval.Style,
};

pub fn stderrTextOptions(format: TextFormat, color: ColorMode, path_display_root: ?[]const u8) TextOptions {
    return .{
        .format = format,
        .color = color,
        .tty_config = std.io.tty.detectConfig(std.fs.File.stderr()),
        .color_profile = carnaval.colorProfileForHandle(std.fs.File.stderr().handle),
        .path_display_root = path_display_root,
    };
}

pub fn stderrSummaryOptions(tool_name: []const u8, color: ColorMode) SummaryOptions {
    return .{
        .color = color,
        .tty_config = std.io.tty.detectConfig(std.fs.File.stderr()),
        .color_profile = carnaval.colorProfileForHandle(std.fs.File.stderr().handle),
        .tool_name = tool_name,
    };
}

pub fn writeDiagnostic(writer: anytype, diagnostic: Diagnostic, options: TextOptions) !void {
    switch (diagnostic.severity) {
        .allow => return,
        .warn, .deny, .forbid => {},
    }

    const style = resolveStyle();
    const color_profile = resolveProfile(options.color, options.tty_config, options.color_profile);
    switch (options.format) {
        .pretty => try writePrettyDiagnostic(writer, diagnostic, style, color_profile, options.path_display_root),
        .minimal => try writeMinimalDiagnostic(writer, diagnostic, style, color_profile, options.path_display_root),
    }
}

pub fn writeSummary(writer: anytype, summary: Summary, options: SummaryOptions) !void {
    if (summary.errors == 0 and summary.warnings == 0) return;

    const style = resolveStyle();
    const color_profile = resolveProfile(options.color, options.tty_config, options.color_profile);

    if (summary.errors > 0) {
        try style.error_style.renderWithProfile("error", writer, color_profile);
        try writer.print(": aborting due to {d} error(s)", .{summary.errors});
        if (summary.warnings > 0) {
            try writer.print(", {d} warning(s)\n", .{summary.warnings});
        } else {
            try writer.writeAll("\n");
        }
        return;
    }

    try style.plain_bold.renderWithProfile(options.tool_name, writer, color_profile);
    try writer.print(" generated {d} warning(s)\n", .{summary.warnings});
}

pub fn writeJson(writer: anytype, allocator: std.mem.Allocator, diagnostics: []const Diagnostic) !void {
    try writer.writeAll("[");
    for (diagnostics, 0..) |diagnostic, i| {
        if (i > 0) try writer.writeAll(",");

        const severity_str: []const u8 = switch (diagnostic.severity) {
            .allow => "allow",
            .warn => "warn",
            .deny => "deny",
            .forbid => "forbid",
        };

        const rule_json = try jsonEscape(allocator, diagnostic.rule);
        defer allocator.free(rule_json);
        const message_json = try jsonEscape(allocator, diagnostic.message);
        defer allocator.free(message_json);
        const file_json = try jsonEscape(allocator, diagnostic.file);
        defer allocator.free(file_json);

        try writer.print(
            "{{\"rule\":\"{s}\",\"severity\":\"{s}\",\"message\":\"{s}\",\"file\":\"{s}\",\"line\":{d},\"column\":{d}}}",
            .{
                rule_json,
                severity_str,
                message_json,
                file_json,
                diagnostic.line,
                diagnostic.column,
            },
        );
    }
    try writer.writeAll("]\n");
}

pub fn printDiagnosticStderr(diagnostic: Diagnostic, options: TextOptions) !void {
    var buffer: [4096]u8 = undefined;
    var stderr = std.fs.File.stderr().writer(&buffer);
    try writeDiagnostic(&stderr.interface, diagnostic, options);
    try stderr.interface.flush();
}

pub fn printSummaryStderr(summary: Summary, options: SummaryOptions) !void {
    var buffer: [512]u8 = undefined;
    var stderr = std.fs.File.stderr().writer(&buffer);
    try writeSummary(&stderr.interface, summary, options);
    try stderr.interface.flush();
}

pub fn printJsonStdout(allocator: std.mem.Allocator, diagnostics: []const Diagnostic) !void {
    var buffer: [8192]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&buffer);
    try writeJson(&stdout.interface, allocator, diagnostics);
    try stdout.interface.flush();
}

fn resolveStyle() Style {
    return .{
        .plain_bold = carnaval.Style.init().bolded(),
        .warning_style = carnaval.Style.init().fg(.{ .ansi16 = .yellow }).bolded(),
        .error_style = carnaval.Style.init().fg(.{ .ansi16 = .red }).bolded(),
        .dim = carnaval.Style.init().dimmed(),
        .caret_warning = carnaval.Style.init().fg(.{ .ansi16 = .yellow }),
        .caret_error = carnaval.Style.init().fg(.{ .ansi16 = .red }),
    };
}

fn resolveProfile(color_mode: ColorMode, tty_config: std.io.tty.Config, detected: ?carnaval.ColorProfile) carnaval.ColorProfile {
    return switch (color_mode) {
        .never => .none,
        .always => if (detected) |profile| switch (profile) {
            .none => .ansi16,
            else => profile,
        } else .ansi16,
        .auto => if (tty_config == .no_color) .none else (detected orelse .ansi16),
    };
}

fn writePrettyDiagnostic(
    writer: anytype,
    diagnostic: Diagnostic,
    style: Style,
    color_profile: carnaval.ColorProfile,
    path_display_root: ?[]const u8,
) !void {
    try writeHeader(writer, diagnostic, style, color_profile, path_display_root);

    if (diagnostic.source_line.len == 0) return;

    try writer.print("    {s}\n", .{diagnostic.source_line});

    const col0 = if (diagnostic.column > 0) diagnostic.column - 1 else 0;
    const span = if (diagnostic.symbol_len > 0) diagnostic.symbol_len else 1;

    var caret_buf: [512]u8 = undefined;
    var pos: usize = 0;

    var col: usize = 0;
    while (col < col0 and pos < caret_buf.len) : (col += 1) {
        caret_buf[pos] = ' ';
        pos += 1;
    }

    if (pos < caret_buf.len) {
        caret_buf[pos] = '^';
        pos += 1;
    }

    var idx: usize = 1;
    while (idx < span and pos < caret_buf.len) : (idx += 1) {
        caret_buf[pos] = '~';
        pos += 1;
    }

    try writer.writeAll("    ");
    try caretStyle(style, diagnostic).renderWithProfile(caret_buf[0..pos], writer, color_profile);
    try writer.writeAll("\n\n");
}

fn writeMinimalDiagnostic(
    writer: anytype,
    diagnostic: Diagnostic,
    style: Style,
    color_profile: carnaval.ColorProfile,
    path_display_root: ?[]const u8,
) !void {
    try writeHeader(writer, diagnostic, style, color_profile, path_display_root);
}

/// Shortens `file_path` when it is an absolute path under `path_display_root` (e.g. package root).
pub fn pathForDisplay(path_display_root: ?[]const u8, file_path: []const u8) []const u8 {
    const root = path_display_root orelse return file_path;
    if (root.len == 0) return file_path;
    if (!std.fs.path.isAbsolute(file_path)) return file_path;
    return stripAbsolutePrefix(root, file_path) orelse file_path;
}

fn stripAbsolutePrefix(root: []const u8, path: []const u8) ?[]const u8 {
    if (path.len < root.len) return null;

    if (path.len == root.len) {
        if (pathsEqualAbsoluteRoot(root, path)) return ".";
        return null;
    }

    if (!pathsEqualAbsoluteRoot(root, path[0..root.len])) return null;

    const sep_after = path[root.len];
    if (!isPathSeparatorAfterRoot(sep_after)) return null;

    return path[root.len + 1 ..];
}

fn isPathSeparatorAfterRoot(c: u8) bool {
    if (c == std.fs.path.sep) return true;
    if (builtin.os.tag == .windows and c == '/') return true;
    return false;
}

fn pathsEqualAbsoluteRoot(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    if (builtin.os.tag == .windows) {
        return std.ascii.eqlIgnoreCase(a, b);
    }
    return std.mem.eql(u8, a, b);
}

fn writeHeader(
    writer: anytype,
    diagnostic: Diagnostic,
    style: Style,
    color_profile: carnaval.ColorProfile,
    path_display_root: ?[]const u8,
) !void {
    const severity_label: []const u8 = switch (diagnostic.severity) {
        .warn => "warning",
        .deny, .forbid => "error",
        .allow => return,
    };

    const file_shown = pathForDisplay(path_display_root, diagnostic.file);
    try writer.print("{s}:{d}:{d}: ", .{ file_shown, diagnostic.line, diagnostic.column });
    try severityStyle(style, diagnostic).renderWithProfile(severity_label, writer, color_profile);
    try writer.writeAll("[");
    try style.dim.renderWithProfile(diagnostic.rule, writer, color_profile);
    try writer.writeAll("]: ");
    try style.plain_bold.renderWithProfile(diagnostic.message, writer, color_profile);
    try writer.writeAll("\n");
}

fn jsonEscape(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(allocator);

    for (input) |char| {
        switch (char) {
            '"' => try result.appendSlice(allocator, "\\\""),
            '\\' => try result.appendSlice(allocator, "\\\\"),
            '\n' => try result.appendSlice(allocator, "\\n"),
            '\r' => try result.appendSlice(allocator, "\\r"),
            '\t' => try result.appendSlice(allocator, "\\t"),
            else => try result.append(allocator, char),
        }
    }

    return try result.toOwnedSlice(allocator);
}

fn severityStyle(style: Style, diagnostic: Diagnostic) carnaval.Style {
    return if (diagnostic.severity.isError()) style.error_style else style.warning_style;
}

fn caretStyle(style: Style, diagnostic: Diagnostic) carnaval.Style {
    return if (diagnostic.severity.isError()) style.caret_error else style.caret_warning;
}

test "minimal formatter renders one line" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);

    var writer = out.writer(std.testing.allocator);
    try writeDiagnostic(&writer, .{
        .rule = "missing_doc_comment",
        .severity = .warn,
        .message = "missing doc comment for function 'main'",
        .file = "src/main.zig",
        .line = 5,
        .column = 8,
    }, .{
        .format = .minimal,
        .color = .never,
    });

    try std.testing.expectEqualStrings(
        "src/main.zig:5:8: warning[missing_doc_comment]: missing doc comment for function 'main'\n",
        out.items,
    );
}

test "pretty formatter renders source snippet" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);

    var writer = out.writer(std.testing.allocator);
    try writeDiagnostic(&writer, .{
        .rule = "missing_doc_comment",
        .severity = .warn,
        .message = "missing doc comment for function 'main'",
        .file = "src/main.zig",
        .line = 5,
        .column = 8,
        .source_line = "pub fn main() void {}",
        .symbol_len = 4,
    }, .{
        .format = .pretty,
        .color = .never,
    });

    try std.testing.expectEqualStrings(
        "src/main.zig:5:8: warning[missing_doc_comment]: missing doc comment for function 'main'\n" ++
            "    pub fn main() void {}\n" ++
            "           ^~~~\n\n",
        out.items,
    );
}

test "pathForDisplay shortens absolute path under root" {
    if (builtin.os.tag == .windows) {
        try std.testing.expectEqualStrings("src\\main.zig", pathForDisplay("C:\\proj", "C:\\proj\\src\\main.zig"));
        try std.testing.expectEqualStrings(".", pathForDisplay("D:\\repo", "D:\\repo"));
        try std.testing.expectEqualStrings("src\\main.zig", pathForDisplay("c:\\proj", "C:\\proj\\src\\main.zig"));
    } else {
        try std.testing.expectEqualStrings("src/main.zig", pathForDisplay("/proj", "/proj/src/main.zig"));
        try std.testing.expectEqualStrings(".", pathForDisplay("/repo", "/repo"));
    }
}

test "pathForDisplay leaves non-absolute and out-of-root paths unchanged" {
    try std.testing.expectEqualStrings("src/main.zig", pathForDisplay("/proj", "src/main.zig"));
    if (builtin.os.tag == .windows) {
        const p = "D:\\other\\main.zig";
        try std.testing.expectEqualStrings(p, pathForDisplay("C:\\proj", p));
    } else {
        try std.testing.expectEqualStrings("/other/main.zig", pathForDisplay("/proj", "/other/main.zig"));
    }
}

test "json formatter escapes message fields" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);

    const diagnostics = [_]Diagnostic{.{
        .rule = "missing_doc_comment",
        .severity = .warn,
        .message = "missing \"doc\" comment",
        .file = "src\\main.zig",
        .line = 1,
        .column = 1,
    }};

    var writer = out.writer(std.testing.allocator);
    try writeJson(&writer, std.testing.allocator, &diagnostics);

    try std.testing.expectEqualStrings(
        "[{\"rule\":\"missing_doc_comment\",\"severity\":\"warn\",\"message\":\"missing \\\"doc\\\" comment\",\"file\":\"src\\\\main.zig\",\"line\":1,\"column\":1}]\n",
        out.items,
    );
}
