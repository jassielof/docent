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

    try root.addEnumFlag(AllPreset, .{
        .name = "all",
        .description = "The level to apply to all rules.",
    });

    try root.addEnumFlag(OutputMode, .{
        .name = "format",
        .short = 'f',
        .description = "The output format of the lints.",
        .default_value = .pretty,
    });

    root.hooks.run = &runLint;

    try app.executeProcess();
}

fn runLint(ctx: *fangz.ParseContext) anyerror!void {
    const allocator = ctx.allocator;

    var rule_set: docent.RuleSet = .{};

    if (ctx.enumFlag(AllPreset, "all")) |preset| {
        rule_set = switch (preset) {
            .deny => .{
                .missing_doc_comment = .deny,
                .missing_doctest = .deny,
                .private_doctest = .deny,
                .missing_container_doc_comment = .deny,
                .empty_doc_comment = .deny,
                .doctest_naming_mismatch = .deny,
            },
            .warn => .{
                .missing_doc_comment = .warn,
                .missing_doctest = .warn,
                .private_doctest = .warn,
                .missing_container_doc_comment = .warn,
                .empty_doc_comment = .warn,
                .doctest_naming_mismatch = .warn,
            },
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

    const output_mode = ctx.enumFlag(OutputMode, "format") orelse .pretty;

    var summary: docent.output.Summary = .{};
    var all_diagnostics: std.ArrayList(docent.Diagnostic) = .empty;
    defer all_diagnostics.deinit(allocator);

    var manifest_paths: std.ArrayList([]const u8) = .empty;
    defer deinitOwnedPaths(allocator, &manifest_paths);

    const target_paths = if (ctx.positionals.items.len > 0)
        ctx.positionals.items
    else blk: {
        manifest_paths = loadManifestPaths(allocator) catch |err| {
            try printStderr("error: failed to read manifest 'build.zig.zon': {}\n", .{err});
            std.process.exit(1);
        };
        if (manifest_paths.items.len == 0) {
            try printStderr("error: manifest 'build.zig.zon' has an empty .paths field\n", .{});
            std.process.exit(1);
        }
        break :blk manifest_paths.items;
    };

    for (target_paths) |path| {
        try lintPath(allocator, path, rule_set, &all_diagnostics, &summary, output_mode);
    }

    if (output_mode == .json) {
        try docent.output.printJsonStdout(allocator, all_diagnostics.items);
    }

    if (output_mode != .json) {
        try docent.output.printSummaryStderr(summary, docent.output.stderrSummaryOptions("docent", .auto));
    }

    if (summary.errors > 0) {
        std.process.exit(1);
    }
}

// ── Lint orchestration ─────────────────────────────────────────────────────

const OutputMode = enum {
    pretty,
    text,
    minimal,
    json,
};

const AllPreset = enum {
    warn,
    deny,
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
        if (!std.mem.endsWith(u8, path, ".zig")) return;
        try lintSingleFile(allocator, path, rule_set, all_diagnostics, summary, output_mode);
    }
}

fn loadManifestPaths(allocator: std.mem.Allocator) !std.ArrayList([]const u8) {
    const manifest_path = try findNearestManifestPath(allocator);
    defer allocator.free(manifest_path);

    const manifest_dir = std.fs.path.dirname(manifest_path) orelse return error.InvalidManifestPath;

    const manifest_text = blk: {
        const file = try std.fs.openFileAbsolute(manifest_path, .{});
        defer file.close();
        break :blk try file.readToEndAlloc(allocator, 1 * 1024 * 1024);
    };
    defer allocator.free(manifest_text);

    var paths: std.ArrayList([]const u8) = .empty;
    errdefer deinitOwnedPaths(allocator, &paths);

    const field_idx = std.mem.indexOf(u8, manifest_text, ".paths") orelse return error.ManifestPathsNotFound;
    var i = field_idx + ".paths".len;

    while (i < manifest_text.len and manifest_text[i] != '{') : (i += 1) {}
    if (i == manifest_text.len) return error.InvalidManifestPaths;

    i += 1;
    var depth: usize = 1;
    while (i < manifest_text.len and depth > 0) {
        if (manifest_text[i] == '/' and i + 1 < manifest_text.len and manifest_text[i + 1] == '/') {
            i += 2;
            while (i < manifest_text.len and manifest_text[i] != '\n') : (i += 1) {}
            continue;
        }

        if (manifest_text[i] == '"') {
            const start = i + 1;
            i += 1;
            var escaped = false;
            while (i < manifest_text.len) : (i += 1) {
                if (escaped) {
                    escaped = false;
                    continue;
                }
                if (manifest_text[i] == '\\') {
                    escaped = true;
                    continue;
                }
                if (manifest_text[i] == '"') break;
            }
            if (i >= manifest_text.len) return error.InvalidManifestPaths;

            if (depth == 1) {
                const raw = manifest_text[start..i];
                if (raw.len > 0) {
                    const resolved = if (std.fs.path.isAbsolute(raw))
                        try allocator.dupe(u8, raw)
                    else
                        try std.fs.path.join(allocator, &.{ manifest_dir, raw });
                    try paths.append(allocator, resolved);
                }
            }

            i += 1;
            continue;
        }

        if (manifest_text[i] == '{') {
            depth += 1;
        } else if (manifest_text[i] == '}') {
            depth -= 1;
        }

        i += 1;
    }

    if (depth != 0) return error.InvalidManifestPaths;
    return paths;
}

fn findNearestManifestPath(allocator: std.mem.Allocator) ![]u8 {
    var current = try std.process.getCwdAlloc(allocator);

    while (true) {
        const candidate = try std.fs.path.join(allocator, &.{ current, "build.zig.zon" });
        if (isReadableFile(candidate)) {
            allocator.free(current);
            return candidate;
        }
        allocator.free(candidate);

        const parent_opt = std.fs.path.dirname(current);
        if (parent_opt == null) {
            allocator.free(current);
            return error.ManifestNotFound;
        }

        const parent = parent_opt.?;
        if (parent.len == current.len) {
            allocator.free(current);
            return error.ManifestNotFound;
        }

        const next = try allocator.dupe(u8, parent);
        allocator.free(current);
        current = next;
    }
}

fn isReadableFile(path: []const u8) bool {
    const file = std.fs.openFileAbsolute(path, .{}) catch return false;
    file.close();
    return true;
}

fn deinitOwnedPaths(allocator: std.mem.Allocator, paths: *std.ArrayList([]const u8)) void {
    for (paths.items) |path| allocator.free(path);
    paths.deinit(allocator);
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

    // If this looks like a library package (has root.zig), lint only files
    // that are publicly reachable from that entrypoint.
    const root_candidate = try std.fs.path.join(allocator, &.{ dir_path, "root.zig" });
    defer allocator.free(root_candidate);

    if (isReadableLocalFile(root_candidate)) {
        var reachable = try docent.reachability.collectReachablePublicFiles(allocator, root_candidate);
        defer docent.reachability.deinitOwnedPaths(allocator, &reachable);

        for (reachable.items) |path| {
            try lintSingleFile(allocator, path, rule_set, all_diagnostics, summary, output_mode);
        }
        return;
    }

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

fn isReadableLocalFile(path: []const u8) bool {
    const file = std.fs.cwd().openFile(path, .{}) catch return false;
    file.close();
    return true;
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

fn textFormat(mode: OutputMode) docent.output.TextFormat {
    return switch (mode) {
        .pretty, .text => .pretty,
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
