const std = @import("std");
const doclint = @import("doclint");
const fangz = @import("fangz");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try fangz.App.init(allocator, .{
        .name = "doclint",
        .description = "Documentation linter for Zig projects",
        .version = "0.1.0",
    });
    defer app.deinit();

    const root = app.root();
    root.help_on_empty_args = true;

    try root.addPositional(.{
        .name = "paths",
        .description = "Files or directories to lint",
        .required = true,
        .variadic = true,
    });

    try root.addFlag(.{ .name = "rule", .short = 'r', .description = "Override severity: <name>=<allow|warn|deny|forbid>", .value_type = .string_list });
    try root.addFlag(.{ .name = "all-deny", .description = "Set all rules to deny" });
    try root.addFlag(.{ .name = "all-warn", .description = "Set all rules to warn" });
    try root.addFlag(.{ .name = "format", .short = 'f', .description = "Output format: text or json", .value_type = .string, .default_value = .{ .string = "text" } });

    root.hooks.run = &runLint;

    try app.executeProcess();
}

fn runLint(ctx: *fangz.ParseContext) anyerror!void {
    const allocator = ctx.allocator;

    var rule_set: doclint.RuleSet = .{};

    if (ctx.boolFlag("all-deny") orelse false) {
        rule_set = .{
            .missing_doc_comment = .deny,
            .missing_doctest = .deny,
            .private_doctest = .deny,
            .missing_container_doc_comment = .deny,
            .empty_doc_comment = .deny,
            .doctest_naming_mismatch = .deny,
        };
    } else if (ctx.boolFlag("all-warn") orelse false) {
        rule_set = .{
            .missing_doc_comment = .warn,
            .missing_doctest = .warn,
            .private_doctest = .warn,
            .missing_container_doc_comment = .warn,
            .empty_doc_comment = .warn,
            .doctest_naming_mismatch = .warn,
        };
    }

    if (ctx.stringListFlag("rule")) |overrides| {
        for (overrides) |override| {
            applyRuleOverride(&rule_set, override) catch |err| {
                try printStderr("error: invalid --rule value '{s}': {}\n", .{ override, err });
                std.process.exit(1);
            };
        }
    }

    const format = ctx.stringFlag("format") orelse "text";
    const is_json = std.mem.eql(u8, format, "json");

    var total_errors: usize = 0;
    var total_warnings: usize = 0;
    var all_diagnostics: std.ArrayList(doclint.Diagnostic) = .empty;
    defer all_diagnostics.deinit(allocator);

    for (ctx.positionals.items) |path| {
        try lintPath(allocator, path, rule_set, &all_diagnostics, &total_errors, &total_warnings, is_json);
    }

    if (is_json) {
        try printJson(allocator, all_diagnostics.items);
    }

    if (!is_json and (total_errors > 0 or total_warnings > 0)) {
        try printStderr("\n{} error(s), {} warning(s)\n", .{ total_errors, total_warnings });
    }

    if (total_errors > 0) {
        std.process.exit(1);
    }
}

fn lintPath(
    allocator: std.mem.Allocator,
    path: []const u8,
    rule_set: doclint.RuleSet,
    all_diagnostics: *std.ArrayList(doclint.Diagnostic),
    total_errors: *usize,
    total_warnings: *usize,
    is_json: bool,
) !void {
    const stat = std.fs.cwd().statFile(path) catch |err| {
        try printStderr("error: cannot access '{s}': {}\n", .{ path, err });
        return;
    };

    if (stat.kind == .directory) {
        try lintDirectory(allocator, path, rule_set, all_diagnostics, total_errors, total_warnings, is_json);
    } else {
        try lintSingleFile(allocator, path, rule_set, all_diagnostics, total_errors, total_warnings, is_json);
    }
}

fn lintDirectory(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    rule_set: doclint.RuleSet,
    all_diagnostics: *std.ArrayList(doclint.Diagnostic),
    total_errors: *usize,
    total_warnings: *usize,
    is_json: bool,
) !void {
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| {
        try printStderr("error: cannot open directory '{s}': {}\n", .{ dir_path, err });
        return;
    };
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;

        const full_path = try std.fs.path.join(allocator, &.{ dir_path, entry.path });
        defer allocator.free(full_path);

        try lintSingleFile(allocator, full_path, rule_set, all_diagnostics, total_errors, total_warnings, is_json);
    }
}

fn lintSingleFile(
    allocator: std.mem.Allocator,
    path: []const u8,
    rule_set: doclint.RuleSet,
    all_diagnostics: *std.ArrayList(doclint.Diagnostic),
    total_errors: *usize,
    total_warnings: *usize,
    is_json: bool,
) !void {
    var result = doclint.lintFile(allocator, path, rule_set) catch |err| {
        try printStderr("error: failed to lint '{s}': {}\n", .{ path, err });
        return;
    };
    defer result.deinit();

    for (result.diagnostics.items) |d| {
        if (d.severity.isError()) {
            total_errors.* += 1;
        } else if (d.severity == .warn) {
            total_warnings.* += 1;
        }

        if (is_json) {
            try all_diagnostics.append(allocator, d);
        } else {
            try printTextDiagnostic(d);
        }
    }
}

fn printTextDiagnostic(d: doclint.Diagnostic) !void {
    const severity_str: []const u8 = switch (d.severity) {
        .warn => "warning",
        .deny, .forbid => "error",
        .allow => return,
    };
    try printStderr("{s}:{d}:{d}: {s}: [{s}] {s}\n", .{
        d.file,
        d.line,
        d.column,
        severity_str,
        d.rule,
        d.message,
    });
}

fn printJson(allocator: std.mem.Allocator, diagnostics: []const doclint.Diagnostic) !void {
    var buf: [8192]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&buf);

    try stdout.interface.writeAll("[");
    for (diagnostics, 0..) |d, i| {
        if (i > 0) try stdout.interface.writeAll(",");

        const severity_str: []const u8 = switch (d.severity) {
            .allow => "allow",
            .warn => "warn",
            .deny => "deny",
            .forbid => "forbid",
        };

        const file_json = try jsonEscape(allocator, d.file);
        defer allocator.free(file_json);
        const msg_json = try jsonEscape(allocator, d.message);
        defer allocator.free(msg_json);

        try stdout.interface.print("{{\"rule\":\"{s}\",\"severity\":\"{s}\",\"message\":\"{s}\",\"file\":\"{s}\",\"line\":{d},\"column\":{d}}}", .{
            d.rule,
            severity_str,
            msg_json,
            file_json,
            d.line,
            d.column,
        });
    }
    try stdout.interface.writeAll("]\n");
    try stdout.interface.flush();
}

fn jsonEscape(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(allocator);

    for (input) |c| {
        switch (c) {
            '"' => try result.appendSlice(allocator, "\\\""),
            '\\' => try result.appendSlice(allocator, "\\\\"),
            '\n' => try result.appendSlice(allocator, "\\n"),
            '\r' => try result.appendSlice(allocator, "\\r"),
            '\t' => try result.appendSlice(allocator, "\\t"),
            else => try result.append(allocator, c),
        }
    }

    return try result.toOwnedSlice(allocator);
}

fn applyRuleOverride(rule_set: *doclint.RuleSet, spec: []const u8) !void {
    const eq_idx = std.mem.indexOfScalar(u8, spec, '=') orelse return error.InvalidFormat;
    const name = spec[0..eq_idx];
    const sev_str = spec[eq_idx + 1 ..];

    const severity: doclint.Severity = if (std.mem.eql(u8, sev_str, "allow"))
        .allow
    else if (std.mem.eql(u8, sev_str, "warn"))
        .warn
    else if (std.mem.eql(u8, sev_str, "deny"))
        .deny
    else if (std.mem.eql(u8, sev_str, "forbid"))
        .forbid
    else
        return error.InvalidSeverity;

    if (std.mem.eql(u8, name, "missing_doc_comment")) {
        rule_set.missing_doc_comment = severity;
    } else if (std.mem.eql(u8, name, "missing_doctest")) {
        rule_set.missing_doctest = severity;
    } else if (std.mem.eql(u8, name, "private_doctest")) {
        rule_set.private_doctest = severity;
    } else if (std.mem.eql(u8, name, "missing_container_doc_comment")) {
        rule_set.missing_container_doc_comment = severity;
    } else if (std.mem.eql(u8, name, "empty_doc_comment")) {
        rule_set.empty_doc_comment = severity;
    } else if (std.mem.eql(u8, name, "doctest_naming_mismatch")) {
        rule_set.doctest_naming_mismatch = severity;
    } else {
        return error.UnknownRule;
    }
}

fn printStderr(comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    var stderr = std.fs.File.stderr().writer(&buf);
    try stderr.interface.print(fmt, args);
    try stderr.interface.flush();
}
