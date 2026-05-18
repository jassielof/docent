//! This tests cover CLI UX aspects of both Docent and Fangz, since Fangz is just a library, Docent works as a first-class user of Fangz, to help me test more complex CLI features in a real-world context.

const std = @import("std");
const testing = std.testing;
const cli = @import("cli");
const docent = @import("docent");
const fangz = @import("fangz");

/// Mirrors the root command tree built in `src/cli/main.zig` for parse/help/docgen tests only (no run hook).
fn wireCliTree(app: *fangz.App) !void {
    const root = app.root();

    try root.addPositional(.{
        .name = "paths",
        .brief = "Files or directories to lint. If omitted, Docent uses package paths from build.zig.zon when available.",
        .variadic = true,
    });

    try root.addFlag(fangz.KeyValueList, .{
        .name = "rule",
        .short = 'r',
        .brief = "Override one rule severity.",
        .description =
        \\You can repeat the flag to override multiple rules.
        \\Run `docent rules` to see rules and defaults.
        ,
        .key_metavar = "RULE",
        .value_metavar = "LEVEL",
        .allowed_keys = docent.RuleSet.fieldNames(),
        .allowed_values = &.{ "allow", "warn", "deny", "forbid" },
        .key_value_help = &cli.key_value_help,
        .examples = cli.rule_flag_examples,
        .allowed_values_style = .bullet_list,
    });

    try root.addFlag(?cli.AllPreset, .{
        .name = "all",
        .brief = "Apply one severity to all rules",
        .value_hint = "LEVEL",
    });

    try root.addFlag(cli.OutputMode, .{
        .name = "format",
        .short = 'f',
        .brief = "Output format",
        .value_hint = "FORMAT",
        .default = .pretty,
        .allowed_values_style = .comma,
    });

    try root.addFlag(bool, .{
        .name = "include-build-scripts",
        .brief = "Include build.zig and build/*.zig files in lint targets",
        .default = false,
    });

    try root.addFlag(cli.FailFast, .{
        .name = "fail-fast",
        .short = 'F',
        .brief = "Stop after the first matching severity",
        .value_hint = "WHEN",
        .default = .any,
    });

    root.examples = cli.app_examples;

    try cli.registerRulesSubcommands(root);
    try cli.registerStatusSubcommand(root, &cli.key_value_help);
}

test "status subcommand appears in full help" {
    var app = try makeCliApp();
    defer app.deinit();

    try wireCliTree(&app);
    try app.root_command.freeze();

    var buf: [32768]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try fangz.HelpRenderer.render(&writer, app.root(), .none, .full);
    const text = writer.buffered();

    try testing.expect(std.mem.indexOf(u8, text, "status") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Show project lint plan and diagnostic summary") != null);
}

fn makeCliApp() !fangz.App {
    return fangz.App.init(testing.allocator, testing.io, .{
        // display_name is documentation-oriented; binary name still comes from `fangz_meta.name`.
        .display_name = "Docent",
        .brief = "Documentation linter (CLI UX tests).",
    });
}

fn readFileAlloc(path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(testing.io, path, testing.allocator, .unlimited);
}

test "short help: --rule shows RULE=LEVEL and stays compact" {
    var app = try makeCliApp();
    defer app.deinit();

    try wireCliTree(&app);
    try app.root_command.freeze();

    var buf: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try fangz.HelpRenderer.render(&writer, app.root(), .none, .short);
    const text = writer.buffered();

    try testing.expect(std.mem.indexOf(u8, text, "<RULE=LEVEL>") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Override one rule severity") != null);
    try testing.expect(std.mem.indexOf(u8, text, "docent rules") == null);
    // Full rule catalog must not appear in -h-style output.
    try testing.expect(std.mem.indexOf(u8, text, "Public declarations should have doc comments") == null);
}

test "full help: --rule includes examples and key-value sections" {
    var app = try makeCliApp();
    defer app.deinit();

    try wireCliTree(&app);
    try app.root_command.freeze();

    var buf: [32768]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try fangz.HelpRenderer.render(&writer, app.root(), .none, .full);
    const text = writer.buffered();

    try testing.expect(std.mem.indexOf(u8, text, "<RULE=LEVEL>") != null);
    try testing.expect(std.mem.indexOf(u8, text, "docent rules") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Examples:") != null);
    try testing.expect(std.mem.indexOf(u8, text, "--rule missing_doc_comment=deny") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Later overrides win") != null);
}

test "parse errors: --rule value without equals" {
    var app = try makeCliApp();
    defer app.deinit();

    try wireCliTree(&app);
    try app.root_command.freeze();

    const argv: []const []const u8 = &.{ "--rule", "not_a_pair" };
    _ = fangz.Parser.parse(testing.allocator, testing.io, app.root(), argv) catch |err| {
        const pe: fangz.Parser.ParseError = switch (err) {
            error.KeyValueMissingEquals => error.KeyValueMissingEquals,
            else => return err,
        };
        var diag = try fangz.Parser.diagnoseError(testing.allocator, app.root(), argv, pe);
        defer diag.deinit();
        try testing.expect(std.mem.indexOf(u8, diag.message, "invalid format") != null);
        try testing.expect(std.mem.indexOf(u8, diag.message, "RULE=LEVEL") != null);
        return;
    };
    return error.TestExpectedError;
}

test "parse errors: unknown rule typo" {
    var app = try makeCliApp();
    defer app.deinit();

    try wireCliTree(&app);
    try app.root_command.freeze();

    // One-edit typo from `missing_doc_comment` so `Suggest.closest` reliably proposes it.
    const argv: []const []const u8 = &.{ "--rule", "missing_doc_coment=deny" };
    _ = fangz.Parser.parse(testing.allocator, testing.io, app.root(), argv) catch |err| {
        const pe: fangz.Parser.ParseError = switch (err) {
            error.InvalidAllowedKey => error.InvalidAllowedKey,
            else => return err,
        };
        var diag = try fangz.Parser.diagnoseError(testing.allocator, app.root(), argv, pe);
        defer diag.deinit();
        try testing.expect(std.mem.indexOf(u8, diag.message, "invalid rule") != null);
        try testing.expect(std.mem.indexOf(u8, diag.message, "missing_doc_coment") != null);
        try testing.expect(diag.hint != null);
        try testing.expect(std.mem.indexOf(u8, diag.hint.?, "missing_doc_comment") != null);
        return;
    };
    return error.TestExpectedError;
}

test "parse errors: unknown level" {
    var app = try makeCliApp();
    defer app.deinit();

    try wireCliTree(&app);
    try app.root_command.freeze();

    const argv: []const []const u8 = &.{ "--rule", "missing_doc_comment=error" };
    _ = fangz.Parser.parse(testing.allocator, testing.io, app.root(), argv) catch |err| {
        const pe: fangz.Parser.ParseError = switch (err) {
            error.InvalidAllowedValue => error.InvalidAllowedValue,
            else => return err,
        };
        var diag = try fangz.Parser.diagnoseError(testing.allocator, app.root(), argv, pe);
        defer diag.deinit();
        try testing.expect(std.mem.indexOf(u8, diag.message, "invalid level") != null);
        try testing.expect(std.mem.indexOf(u8, diag.message, "allow") != null);
        try testing.expect(std.mem.indexOf(u8, diag.message, "forbid") != null);
        return;
    };
    return error.TestExpectedError;
}

test "generated AsciiDoc: synopsis, RULE=LEVEL, rules table, no command index by default" {
    var app = try makeCliApp();
    defer app.deinit();

    try wireCliTree(&app);
    try app.root_command.freeze();

    const out_dir = "zig-out/cliux-docgen";
    std.Io.Dir.cwd().deleteTree(testing.io, out_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(testing.io, out_dir) catch {};

    try fangz.DocGenerator.generateDocs(testing.allocator, testing.io, app.root(), .{
        .output_dir = out_dir,
    });

    const path = try std.fs.path.join(testing.allocator, &.{ out_dir, "cli.adoc" });
    defer testing.allocator.free(path);

    const content = try readFileAlloc(path);
    defer testing.allocator.free(content);

    try testing.expect(std.mem.indexOf(u8, content, "== Synopsis") != null);
    try testing.expect(std.mem.indexOf(u8, content, "RULE=LEVEL") != null);
    try testing.expect(std.mem.indexOf(u8, content, "missing_doc_comment") != null);
    try testing.expect(std.mem.indexOf(u8, content, "== Command index") == null);
}

test "rule_metadata keys stay aligned with Fangz key-value help" {
    try testing.expectEqual(cli.key_value_rule_count, docent.rule_metadata.rules.len);
    try testing.expectEqual(cli.key_value_level_count, docent.rule_metadata.levels.len);
}
