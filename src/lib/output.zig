//! Formats and prints lint diagnostics to stderr, stdout, or arbitrary writers.

const std = @import("std");
const builtin = @import("builtin");

const carnaval = @import("carnaval");

const Diagnostic = @import("Diagnostic.zig");
const diagnostic_message = @import("diagnostic_message.zig");
const severity = @import("severity.zig");

/// Text layout for a single diagnostic line.
pub const TextFormat = enum {
    /// Multi-line rustc-style blocks with source snippet and caret underline.
    pretty,
    /// Single-line `severity [rule] file:line:col` output with grid-aligned columns.
    minimal,
};

/// When ANSI colors and styling are applied to formatted output.
pub const ColorMode = enum {
    /// Use color when stderr is a TTY and the terminal supports it.
    auto,
    /// Force color even when not attached to a TTY.
    always,
    /// Never emit ANSI color or style sequences.
    never,
};

/// Options passed to diagnostic formatters.
pub const TextOptions = struct {
    /// Layout style for each diagnostic.
    format: TextFormat = .pretty,
    /// Color policy for styled output.
    color: ColorMode = .auto,
    /// Detected terminal capabilities for the output stream.
    tty_config: std.Io.Terminal.Mode = .no_color,
    /// Optional detected color profile for the output stream.
    color_profile: ?carnaval.ColorProfile = null,
    /// When set, absolute paths under this directory are printed relative to it (Cargo-style).
    path_display_root: ?[]const u8 = null,
};

/// Options for the final error/warning summary line.
pub const SummaryOptions = struct {
    /// Color policy for the summary line.
    color: ColorMode = .auto,
    /// Detected terminal capabilities for stderr.
    tty_config: std.Io.Terminal.Mode = .no_color,
    /// Optional detected color profile for stderr.
    color_profile: ?carnaval.ColorProfile = null,
    /// Tool name shown in the summary (e.g. `docent generated N warnings`).
    tool_name: []const u8 = "docent",
};

/// Running counts of errors and warnings observed while linting.
pub const Summary = struct {
    /// Number of diagnostics with error severity.
    errors: usize = 0,
    /// Number of diagnostics with warning severity.
    warnings: usize = 0,

    /// Updates counts from a single diagnostic.
    pub fn observe(self: *Summary, diagnostic: Diagnostic) void {
        if (diagnostic.severity_level.isError()) {
            self.errors += 1;
        } else if (diagnostic.severity_level == .warn) {
            self.warnings += 1;
        }
    }

    /// Returns whether any error-level diagnostic was observed.
    pub fn hasErrors(self: Summary) bool {
        return self.errors > 0;
    }
};

const Style = struct {
    plain_bold: carnaval.Style,
    emphasis: carnaval.Style,
    warning_style: carnaval.Style,
    error_style: carnaval.Style,
    allow_style: carnaval.Style,
    rule_style: carnaval.Style,
    caret_warning: carnaval.Style,
    caret_error: carnaval.Style,
};

/// Builds `TextOptions` for stderr using detected TTY and color profile.
pub fn stderrTextOptions(io: std.Io, format: TextFormat, color: ColorMode, path_display_root: ?[]const u8) TextOptions {
    return .{
        .format = format,
        .color = color,
        .tty_config = detectTerminalMode(io, std.Io.File.stderr()),
        .color_profile = carnaval.colorProfileForHandle(std.Io.File.stderr().handle),
        .path_display_root = path_display_root,
    };
}

/// Builds `SummaryOptions` for stderr using detected TTY and color profile.
pub fn stderrSummaryOptions(io: std.Io, tool_name: []const u8, color: ColorMode) SummaryOptions {
    return .{
        .color = color,
        .tty_config = detectTerminalMode(io, std.Io.File.stderr()),
        .color_profile = carnaval.colorProfileForHandle(std.Io.File.stderr().handle),
        .tool_name = tool_name,
    };
}

/// Writes one diagnostic to `writer` according to `options`. Skips `.allow` severities.
pub fn writeDiagnostic(writer: *std.Io.Writer, diagnostic: Diagnostic, options: TextOptions) !void {
    switch (diagnostic.severity_level) {
        .allow => return,
        .warn, .deny, .forbid => {},
    }

    const style = resolveStyle();
    const color_profile = resolveProfile(options.color, options.tty_config, options.color_profile);
    switch (options.format) {
        .pretty => try writePrettyDiagnostic(writer, diagnostic, style, color_profile, options.path_display_root),
        .minimal => try writeMinimalDiagnostic(writer, diagnostic, color_profile, options.path_display_root),
    }
}

/// Writes diagnostics with blank lines between pretty blocks.
pub fn writeDiagnostics(writer: *std.Io.Writer, diagnostics: []const Diagnostic, options: TextOptions) !void {
    var index: usize = 0;
    while (index < diagnostics.len) : (index += 1) {
        const diagnostic = diagnostics[index];
        if (diagnostic.severity_level == .allow) continue;

        try writeDiagnostic(writer, diagnostic, options);

        if (options.format == .pretty) {
            var has_following = false;
            var j = index + 1;
            while (j < diagnostics.len) : (j += 1) {
                if (diagnostics[j].severity_level != .allow) {
                    has_following = true;
                    break;
                }
            }
            if (has_following) try writer.writeAll("\n");
        }
    }
}

/// Writes a trailing summary line when `summary` has errors or warnings.
pub fn writeSummary(writer: *std.Io.Writer, summary: Summary, options: SummaryOptions) !void {
    writeSummaryWithPrefix(writer, summary, options, false);
}

/// Like `writeSummary` but inserts a leading newline when `leading_newline` is set.
pub fn writeSummaryWithPrefix(
    writer: *std.Io.Writer,
    summary: Summary,
    options: SummaryOptions,
    leading_newline: bool,
) !void {
    if (summary.errors == 0 and summary.warnings == 0) return;

    if (leading_newline) try writer.writeAll("\n");

    const style = resolveStyle();
    const color_profile = resolveProfile(options.color, options.tty_config, options.color_profile);

    if (summary.errors > 0) {
        try style.error_style.renderWithProfile("error", writer, color_profile);
        try writer.print(": aborting due to {d} {s}", .{ summary.errors, countNoun(summary.errors, "error", "errors") });
        if (summary.warnings > 0) {
            try writer.print(", {d} {s}\n", .{ summary.warnings, countNoun(summary.warnings, "warning", "warnings") });
        } else {
            try writer.writeAll("\n");
        }

        return;
    }

    try style.plain_bold.renderWithProfile(options.tool_name, writer, color_profile);
    try writer.print(" generated {d} {s}\n", .{ summary.warnings, countNoun(summary.warnings, "warning", "warnings") });
}

fn countNoun(count: usize, singular: []const u8, plural: []const u8) []const u8 {
    if (count == 1) return singular;
    return plural;
}

/// Writes diagnostics as a JSON array to `writer`.
pub fn writeJson(writer: *std.Io.Writer, allocator: std.mem.Allocator, diagnostics: []const Diagnostic) !void {
    try writer.writeAll("[");
    for (diagnostics, 0..) |diagnostic, i| {
        if (i > 0) try writer.writeAll(",");

        const severity_str: []const u8 = switch (diagnostic.severity_level) {
            .allow => "allow",
            .warn => "warn",
            .deny => "deny",
            .forbid => "forbid",
        };

        var prose_buf: [512]u8 = undefined;
        const prose = diagnostic_message.formatProse(diagnostic, &prose_buf) catch prose_buf[0..0];

        const rule_json = try jsonEscape(allocator, diagnostic.rule);
        defer allocator.free(rule_json);
        const message_json = try jsonEscape(allocator, if (prose.len > 0) prose else diagnostic.message);
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

/// Formats and prints one diagnostic to stderr.
pub fn printDiagnosticStderr(io: std.Io, diagnostic: Diagnostic, options: TextOptions) !void {
    var buffer: [4096]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &buffer);
    try writeDiagnostic(&stderr.interface, diagnostic, options);
    try stderr.interface.flush();
}

/// Prints multiple diagnostics to stderr.
pub fn printDiagnosticsStderr(io: std.Io, diagnostics: []const Diagnostic, options: TextOptions) !void {
    var buffer: [8192]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &buffer);
    try writeDiagnostics(&stderr.interface, diagnostics, options);
    try stderr.interface.flush();
}

/// Prints the lint summary line to stderr when there are errors or warnings.
pub fn printSummaryStderr(io: std.Io, summary: Summary, options: SummaryOptions, leading_newline: bool) !void {
    var buffer: [512]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &buffer);
    try writeSummaryWithPrefix(&stderr.interface, summary, options, leading_newline);
    try stderr.interface.flush();
}

/// Writes diagnostics as JSON to stdout.
pub fn printJsonStdout(io: std.Io, allocator: std.mem.Allocator, diagnostics: []const Diagnostic) !void {
    var buffer: [8192]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buffer);
    try writeJson(&stdout.interface, allocator, diagnostics);
    try stdout.interface.flush();
}

fn resolveStyle() Style {
    return .{
        .plain_bold = carnaval.Style.init().bolded(),
        .emphasis = carnaval.Style.init().italicized(),
        .warning_style = carnaval.Style.init().fg(.{ .ansi16 = .yellow }).bolded(),
        .error_style = carnaval.Style.init().fg(.{ .ansi16 = .red }).bolded(),
        .allow_style = carnaval.Style.init().dimmed(),
        .rule_style = carnaval.Style.init().fg(.{ .ansi16 = .cyan }).bolded(),
        .caret_warning = carnaval.Style.init().fg(.{ .ansi16 = .yellow }),
        .caret_error = carnaval.Style.init().fg(.{ .ansi16 = .red }),
    };
}

fn resolveProfile(color_mode: ColorMode, tty_config: std.Io.Terminal.Mode, detected: ?carnaval.ColorProfile) carnaval.ColorProfile {
    return switch (color_mode) {
        .never => .none,
        .always => if (detected) |profile| switch (profile) {
            .none => .ansi16,
            else => profile,
        } else .ansi16,
        .auto => if (tty_config == .no_color) .none else (detected orelse .ansi16),
    };
}

fn detectTerminalMode(io: std.Io, file: std.Io.File) std.Io.Terminal.Mode {
    return std.Io.Terminal.Mode.detect(io, file, false, false) catch .no_color;
}

/// Tag text for a severity level (`warning`, `error`, or `allow`).
pub fn severityDisplayTag(level: severity.Level) []const u8 {
    return switch (level) {
        .allow => "allow",
        .warn => "warning",
        .deny, .forbid => "error",
    };
}

/// Writes `warning[rule_id]` with diagnostic-style coloring.
pub fn writeSeverityRuleTag(
    writer: *std.Io.Writer,
    level: severity.Level,
    rule: []const u8,
    color_profile: carnaval.ColorProfile,
) !void {
    const style = resolveStyle();
    try severityLevelStyle(style, level).renderWithProfile(severityDisplayTag(level), writer, color_profile);
    try writer.writeAll("[");
    try style.rule_style.renderWithProfile(rule, writer, color_profile);
    try writer.writeAll("]");
}

fn writePrettyDiagnostic(
    writer: *std.Io.Writer,
    diagnostic: Diagnostic,
    style: Style,
    color_profile: carnaval.ColorProfile,
    path_display_root: ?[]const u8,
) !void {
    const gutter = lineNumberWidth(diagnostic.line);

    try writeSeverityRuleTag(writer, diagnostic.severity_level, diagnostic.rule, color_profile);
    try writer.writeAll("\n");

    try writeProseLine(writer, diagnostic, style, color_profile);

    var path_bufs: [2][std.Io.Dir.max_path_bytes]u8 = undefined;
    const file_shown = pathForDisplay(path_display_root, diagnostic.file, &path_bufs[0], &path_bufs[1]);

    try writeArrowPadding(writer, gutter);
    try writer.print("--> {s}:{d}:{d}\n", .{ file_shown, diagnostic.line, diagnostic.column });

    try writeGutterPipe(writer, gutter);
    try writer.writeAll("\n");

    if (diagnostic.source_line.len > 0) {
        try writeSourceRow(writer, gutter, diagnostic.line, diagnostic.source_line);
        try writeCaretRow(writer, gutter, diagnostic, style, color_profile);
    }
}

fn writeMinimalDiagnostic(
    writer: *std.Io.Writer,
    diagnostic: Diagnostic,
    color_profile: carnaval.ColorProfile,
    path_display_root: ?[]const u8,
) !void {
    var path_bufs: [2][std.Io.Dir.max_path_bytes]u8 = undefined;
    const file_shown = pathForDisplay(path_display_root, diagnostic.file, &path_bufs[0], &path_bufs[1]);
    const style = resolveStyle();
    try severityLevelStyle(style, diagnostic.severity_level).renderWithProfile(severityDisplayTag(diagnostic.severity_level), writer, color_profile);
    try writer.writeAll("[");
    try style.rule_style.renderWithProfile(diagnostic.rule, writer, color_profile);
    try writer.writeAll("] ");
    try writer.print("{s}:{d}:{d}\n", .{ file_shown, diagnostic.line, diagnostic.column });
}

fn writeProseLine(
    writer: *std.Io.Writer,
    diagnostic: Diagnostic,
    style: Style,
    color_profile: carnaval.ColorProfile,
) !void {
    var buf: [512]u8 = undefined;
    const prose = diagnostic_message.formatProse(diagnostic, &buf) catch {
        try style.plain_bold.renderWithProfile(diagnostic.message, writer, color_profile);
        try writer.writeAll("\n");
        return;
    };

    if (diagnostic.subject) |subject| {
        const subject_start = std.mem.indexOf(u8, prose, subject.name) orelse {
            try style.plain_bold.renderWithProfile(prose, writer, color_profile);
            try writer.writeAll("\n");
            return;
        };
        const subject_end = subject_start + subject.name.len;

        try style.plain_bold.renderWithProfile(prose[0..subject_start], writer, color_profile);
        try style.emphasis.renderWithProfile(prose[subject_start..subject_end], writer, color_profile);
        try style.plain_bold.renderWithProfile(prose[subject_end..], writer, color_profile);
    } else {
        try style.plain_bold.renderWithProfile(prose, writer, color_profile);
    }

    try writer.writeAll("\n");
}

fn lineNumberWidth(line: usize) usize {
    if (line == 0) return 1;
    return std.fmt.count("{d}", .{line});
}

fn writeArrowPadding(writer: *std.Io.Writer, gutter: usize) !void {
    var i: usize = 0;
    while (i < gutter) : (i += 1) {
        try writer.writeByte(' ');
    }
}

fn writeGutterPipe(writer: *std.Io.Writer, gutter: usize) !void {
    var i: usize = 0;
    while (i < gutter + 1) : (i += 1) {
        try writer.writeByte(' ');
    }
    try writer.writeByte('|');
}

fn writeSourceRow(writer: *std.Io.Writer, gutter: usize, line: usize, source_line: []const u8) !void {
    const digits = lineNumberWidth(line);
    const pad = gutter - digits;
    var i: usize = 0;
    while (i < pad) : (i += 1) {
        try writer.writeByte(' ');
    }
    try writer.print("{d} | {s}\n", .{ line, source_line });
}

fn writeCaretRow(
    writer: *std.Io.Writer,
    gutter: usize,
    diagnostic: Diagnostic,
    style: Style,
    color_profile: carnaval.ColorProfile,
) !void {
    try writeGutterPipe(writer, gutter);
    try writer.writeAll(" ");

    const col0 = if (diagnostic.column > 0) diagnostic.column - 1 else 0;
    const span = if (diagnostic.symbol_len > 0) diagnostic.symbol_len else 1;

    var i: usize = 0;
    while (i < col0) : (i += 1) {
        try writer.writeByte(' ');
    }

    var caret_buf: [512]u8 = undefined;
    var pos: usize = 0;

    if (pos < caret_buf.len) {
        caret_buf[pos] = '^';
        pos += 1;
    }

    var idx: usize = 1;
    while (idx < span and pos < caret_buf.len) : (idx += 1) {
        caret_buf[pos] = '~';
        pos += 1;
    }

    try caretStyle(style, diagnostic).renderWithProfile(caret_buf[0..pos], writer, color_profile);
    try writer.writeAll("\n");
}

/// Shortens `file_path` when it is an absolute path under `path_display_root` (e.g. package root).
pub fn pathForDisplay(
    path_display_root: ?[]const u8,
    file_path: []const u8,
    file_buf: []u8,
    root_buf: []u8,
) []const u8 {
    if (file_path.len > file_buf.len) return file_path;

    const file_slice = file_buf[0..normalizeSeparatorsInPlace(file_buf, file_path)];

    const root = path_display_root orelse return file_slice;
    if (root.len == 0) return file_slice;
    if (!std.fs.path.isAbsolute(file_slice)) return file_slice;

    if (root.len > root_buf.len) return stripAbsolutePrefix(root, file_slice) orelse file_slice;

    const root_slice = root_buf[0..normalizeSeparatorsInPlace(root_buf, root)];
    return stripAbsolutePrefix(root_slice, file_slice) orelse file_slice;
}

fn normalizeSeparatorsInPlace(buf: []u8, path: []const u8) usize {
    const len = @min(path.len, buf.len);
    for (path[0..len], 0..) |c, i| {
        buf[i] = if (c == '\\') '/' else c;
    }
    return len;
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

fn severityLevelStyle(style: Style, level: severity.Level) carnaval.Style {
    return switch (level) {
        .warn => style.warning_style,
        .deny, .forbid => style.error_style,
        .allow => style.allow_style,
    };
}

fn caretStyle(style: Style, diagnostic: Diagnostic) carnaval.Style {
    return if (diagnostic.severity_level.isError()) style.caret_error else style.caret_warning;
}

test "severity rule tag matches minimal diagnostic prefix" {
    var buf: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try writeSeverityRuleTag(&writer, .warn, "missing_doc_comment", .none);
    try std.testing.expectEqualStrings("warning[missing_doc_comment]", writer.buffered());
}

test "severity rule tag uses cyan styling when color is enabled" {
    var buf: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try writeSeverityRuleTag(&writer, .warn, "missing_doc_comment", .ansi16);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\x1b[36m") != null);
}

test "minimal formatter shortens absolute paths under display root" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);

    var writer: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &out);
    defer writer.deinit();

    try writeDiagnostic(&writer.writer, .{
        .rule = "missing_doc_comment",
        .severity_level = .warn,
        .subject = .{ .kind = .function, .name = "main" },
        .file = "C:\\proj\\src\\lib\\root.zig",
        .line = 27,
        .column = 11,
    }, .{
        .format = .minimal,
        .color = .never,
        .path_display_root = "C:\\proj",
    });
    out = writer.toArrayList();

    try std.testing.expect(std.mem.indexOf(u8, out.items, "warning[missing_doc_comment] src/lib/root.zig:27:11") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b") == null);
}

test "minimal formatter renders one line without prose" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);

    var writer: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &out);
    defer writer.deinit();

    try writeDiagnostic(&writer.writer, .{
        .rule = "missing_doc_comment",
        .severity_level = .warn,
        .subject = .{ .kind = .function, .name = "main" },
        .file = "src/main.zig",
        .line = 5,
        .column = 8,
    }, .{
        .format = .minimal,
        .color = .never,
    });
    out = writer.toArrayList();

    try std.testing.expectEqualStrings(
        "warning[missing_doc_comment] src/main.zig:5:8\n",
        out.items,
    );
}

test "pretty formatter renders rustc-style block" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);

    var writer: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &out);
    defer writer.deinit();

    try writeDiagnostic(&writer.writer, .{
        .rule = "missing_doc_comment",
        .severity_level = .warn,
        .subject = .{ .kind = .function, .name = "main" },
        .file = "src/main.zig",
        .line = 5,
        .column = 8,
        .source_line = "pub fn main() void {}",
        .symbol_len = 4,
    }, .{
        .format = .pretty,
        .color = .never,
    });
    out = writer.toArrayList();

    try std.testing.expect(std.mem.startsWith(u8, out.items, "warning[missing_doc_comment]\n"));
    try std.testing.expect(std.mem.indexOf(u8, out.items, "Warning: Missing doc comment on function 'main'.\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, " --> src/main.zig:5:8\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "5 | pub fn main() void {}\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "       ^~~~\n") != null);
}

test "pretty formatter aligns two-digit line numbers" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);

    var writer: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &out);
    defer writer.deinit();

    try writeDiagnostic(&writer.writer, .{
        .rule = "missing_doc_comment",
        .severity_level = .warn,
        .subject = .{ .kind = .error_set, .name = "Error" },
        .file = "src/lib/Config.zig",
        .line = 24,
        .column = 11,
        .source_line = "    pub const Error = error{",
        .symbol_len = 5,
    }, .{
        .format = .pretty,
        .color = .never,
    });
    out = writer.toArrayList();

    try std.testing.expect(std.mem.indexOf(u8, out.items, "  --> src/lib/Config.zig:24:11\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "24 |     pub const Error = error{\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "           ^~~~~\n") != null);
}

test "writeDiagnostics separates pretty blocks with blank line" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);

    var writer: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &out);
    defer writer.deinit();

    const diagnostics = [_]Diagnostic{
        .{
            .rule = "blank_doc_comment",
            .severity_level = .warn,
            .subject = .{ .kind = .module, .name = "docent" },
            .file = "src/lib/root.zig",
            .line = 1,
            .column = 1,
            .source_line = "    //!",
            .symbol_len = 5,
        },
        .{
            .rule = "missing_doc_comment",
            .severity_level = .warn,
            .subject = .{ .kind = .field, .name = "offset" },
            .file = "src/lib/Diagnostic.zig",
            .line = 8,
            .column = 5,
            .source_line = "        offset: usize,",
            .symbol_len = 6,
        },
    };

    try writeDiagnostics(&writer.writer, &diagnostics, .{ .format = .pretty, .color = .never });
    out = writer.toArrayList();

    try std.testing.expect(std.mem.indexOf(u8, out.items, "warning[blank_doc_comment]\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "warning[missing_doc_comment]\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "warning[blank_doc_comment]\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\n\nwarning[missing_doc_comment]\n") != null);
}

test "pathForDisplay shortens absolute path under root" {
    var bufs: [2][std.Io.Dir.max_path_bytes]u8 = undefined;
    if (builtin.os.tag == .windows) {
        try std.testing.expectEqualStrings("src/main.zig", pathForDisplay("C:\\proj", "C:\\proj\\src\\main.zig", &bufs[0], &bufs[1]));
        try std.testing.expectEqualStrings(".", pathForDisplay("D:\\repo", "D:\\repo", &bufs[0], &bufs[1]));
    } else {
        try std.testing.expectEqualStrings("src/main.zig", pathForDisplay("/proj", "/proj/src/main.zig", &bufs[0], &bufs[1]));
        try std.testing.expectEqualStrings(".", pathForDisplay("/repo", "/repo", &bufs[0], &bufs[1]));
    }
}

test "countNoun uses singular only for one" {
    try std.testing.expectEqualStrings("warning", countNoun(1, "warning", "warnings"));
    try std.testing.expectEqualStrings("warnings", countNoun(2, "warning", "warnings"));
}

test "json formatter uses prose message" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);

    const diagnostics = [_]Diagnostic{.{
        .rule = "missing_doc_comment",
        .severity_level = .warn,
        .subject = .{ .kind = .field, .name = "offset" },
        .file = "src\\main.zig",
        .line = 1,
        .column = 1,
    }};

    var writer: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &out);
    defer writer.deinit();

    try writeJson(&writer.writer, std.testing.allocator, &diagnostics);
    out = writer.toArrayList();

    try std.testing.expect(std.mem.indexOf(u8, out.items, "Warning: Missing doc comment on field 'offset'.") != null);
}
