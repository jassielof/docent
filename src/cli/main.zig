const std = @import("std");
const docent = @import("docent");
const fangz = @import("fangz");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try fangz.App.init(allocator, .{
        .name = "docent",
        .description = "Documentation linter for Zig projects",
        .version = "0.1.0",
    });

    defer app.deinit();

    const root = app.root();

    try root.addPositional(.{
        .name = "paths",
        .description = "Files or directories to lint",
        .variadic = true,
    });

    try root.addFlag(.{
        .name = "rule",
        .short = 'r',
        .description = "Override severity: <name>=<allow|warn|deny|forbid>",
        .value_type = .string_list,
    });

    try root.addFlag(.{ .name = "all-deny", .description = "Set all rules to deny" });

    try root.addFlag(.{ .name = "all-warn", .description = "Set all rules to warn" });

    try root.addFlag(.{ .name = "format", .short = 'f', .description = "Output format: pretty, minimal, or json", .value_type = .string, .default_value = .{ .string = "pretty" } });

    root.hooks.run = &runLint;

    try app.executeProcess();
}

fn runLint(ctx: *fangz.ParseContext) anyerror!void {
    const allocator = ctx.allocator;

    var rule_set: docent.RuleSet = .{};

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

    const format = ctx.stringFlag("format") orelse "pretty";
    const output_mode = parseOutputMode(format) catch |err| {
        try printStderr("error: invalid --format value '{s}': {}\n", .{ format, err });
        std.process.exit(1);
    };

    var summary: docent.output.Summary = .{};
    var all_diagnostics: std.ArrayList(docent.Diagnostic) = .empty;
    defer all_diagnostics.deinit(allocator);

    for (ctx.positionals.items) |path| {
        try lintPath(allocator, path, rule_set, &all_diagnostics, &summary, output_mode);
    }

    if (output_mode == .json) {
        try docent.output.printJsonStdout(allocator, all_diagnostics.items);
    }

    if (output_mode != .json) {
        try docent.output.printSummaryStderr(summary, docent.output.stderrSummaryOptions("doclint", .auto));
    }

    if (summary.errors > 0) {
        std.process.exit(1);
    }
}

// ── Lint orchestration ─────────────────────────────────────────────────────

const OutputMode = enum {
    pretty,
    minimal,
    json,
};

fn lintPath(
    allocator: std.mem.Allocator,
    path: []const u8,
    rule_set: docent.RuleSet,
    all_diagnostics: *std.ArrayList(docent.Diagnostic),
    summary: *docent.output.Summary,
    output_mode: OutputMode,
) !void {
    const stat = std.fs.cwd().statFile(path) catch |err| switch (err) {
        // On some platforms statFile returns IsDir for directory paths
        error.IsDir => {
            try lintDirectory(allocator, path, rule_set, all_diagnostics, summary, output_mode);
            return;
        },
        else => {
            try printStderr("error: cannot access '{s}': {}\n", .{ path, err });
            return;
        },
    };

    if (stat.kind == .directory) {
        try lintDirectory(allocator, path, rule_set, all_diagnostics, summary, output_mode);
    } else {
        try lintSingleFile(allocator, path, rule_set, all_diagnostics, summary, output_mode);
    }
}

fn lintDirectory(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    rule_set: docent.RuleSet,
    all_diagnostics: *std.ArrayList(docent.Diagnostic),
    summary: *docent.output.Summary,
    output_mode: OutputMode,
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

        try lintSingleFile(allocator, full_path, rule_set, all_diagnostics, summary, output_mode);
    }
}

fn lintSingleFile(
    allocator: std.mem.Allocator,
    path: []const u8,
    rule_set: docent.RuleSet,
    all_diagnostics: *std.ArrayList(docent.Diagnostic),
    summary: *docent.output.Summary,
    output_mode: OutputMode,
) !void {
    var result = docent.lintFile(allocator, path, rule_set) catch |err| {
        try printStderr("error: failed to lint '{s}': {}\n", .{ path, err });
        return;
    };
    defer result.deinit();

    for (result.diagnostics.items) |d| {
        summary.observe(d);

        if (output_mode == .json) {
            try all_diagnostics.append(allocator, d);
        } else {
            try docent.output.printDiagnosticStderr(d, docent.output.stderrTextOptions(textFormat(output_mode), .auto));
        }
    }
}

fn parseOutputMode(value: []const u8) !OutputMode {
    if (std.mem.eql(u8, value, "pretty") or std.mem.eql(u8, value, "text")) return .pretty;
    if (std.mem.eql(u8, value, "minimal")) return .minimal;
    if (std.mem.eql(u8, value, "json")) return .json;
    return error.InvalidFormat;
}

fn textFormat(mode: OutputMode) docent.output.TextFormat {
    return switch (mode) {
        .pretty => .pretty,
        .minimal => .minimal,
        .json => unreachable,
    };
}

// ── Rule overrides ─────────────────────────────────────────────────────────

fn applyRuleOverride(rule_set: *docent.RuleSet, spec: []const u8) !void {
    const eq_idx = std.mem.indexOfScalar(u8, spec, '=') orelse return error.InvalidFormat;
    const name = spec[0..eq_idx];
    const sev_str = spec[eq_idx + 1 ..];

    const severity: docent.Severity = if (std.mem.eql(u8, sev_str, "allow"))
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

// ── I/O helpers ────────────────────────────────────────────────────────────

fn printStderr(comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    var stderr = std.fs.File.stderr().writer(&buf);
    try stderr.interface.print(fmt, args);
    try stderr.interface.flush();
}
