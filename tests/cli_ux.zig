//! CLI UX isn't related to linting tests, but rather to cover aspects of Fangz, since it's just a library, Docent works as a first-class user of Fangz, to help test CLI features and general UI/UX in a real-world context.
// TODO: CLI UX tests are somewhat inconvenient to cross-depend with the Fangz library and my Docent project. So these will be moved to the Fangz test suite with generic fixtures so it doesn't depend on Docent, nor causes bothersome.

const std = @import("std");
const testing = std.testing;
const cli = @import("cli");
const fangz = @import("fangz");

/// Mirrors the root command tree built in `src/cli/main.zig` for parse/help/docgen tests only (no run hook).
fn wireCliTree(app: *fangz.App) !void {
    const root = app.root();

    try root.addPositional(.{
        .name = "paths",
        .brief = "Files or directories to lint. If omitted, Docent uses package paths from build.zig.zon when available.",
        .variadic = true,
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
        .default = cli.default_fail_fast,
    });

    root.examples = cli.app_examples;

    try cli.registerStatusSubcommand(root);
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
    try testing.expect(std.mem.indexOf(u8, text, "Show project lint plan and effective rules") != null);
    try testing.expect(std.mem.indexOf(u8, text, "List lint rules, defaults, and severity levels") == null);
}

test "short help: no rule override flags" {
    var app = try makeCliApp();
    defer app.deinit();

    try wireCliTree(&app);
    try app.root_command.freeze();

    var buf: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try fangz.HelpRenderer.render(&writer, app.root(), .none, .short);
    const text = writer.buffered();

    try testing.expect(std.mem.indexOf(u8, text, "<RULE=LEVEL>") == null);
    try testing.expect(std.mem.indexOf(u8, text, "--rule") == null);
    try testing.expect(std.mem.indexOf(u8, text, "--all") == null);
}

test "parse errors: unknown --rule flag" {
    var app = try makeCliApp();
    defer app.deinit();

    try wireCliTree(&app);
    try app.root_command.freeze();

    const argv: []const []const u8 = &.{ "--rule", "missing_doc_comment=deny" };
    try testing.expectError(error.UnknownFlag, fangz.Parser.parse(testing.allocator, testing.io, app.root(), argv));
}

test "generated AsciiDoc: synopsis without rule flags" {
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

    const path = try std.fs.path.join(testing.allocator, &.{ out_dir, "docent.adoc" });
    defer testing.allocator.free(path);

    const content = try readFileAlloc(path);
    defer testing.allocator.free(content);

    try testing.expect(std.mem.indexOf(u8, content, "== Synopsis") != null);
    try testing.expect(std.mem.indexOf(u8, content, "RULE=LEVEL") == null);
    try testing.expect(std.mem.indexOf(u8, content, "== Command index") == null);
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
