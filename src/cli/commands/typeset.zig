//! `docent typeset` — generate offline PDF/document output for a Zig
//! package's modules via Typst, instead of `zig build docs`'s HTML/WASM
//! viewer.
//!
//! Pipeline (see `src/lib/typeset.zig` for the supporting library):
//!   module discovery -> walker.walkModule (per module) -> json_emit.emitPackage
//!   -> docs.json -> `typst compile` (shelled out, see build.zig's
//!   `docs-pdf` step) -> PDF
//!
//! Module discovery has two modes:
//! - No positional paths: reuses `status_plan.gather` (the same
//!   `build.zig` target discovery `docent status`/`docent check` use) to
//!   find every lib/bin/test target matching the `--lib`/`--bins`/`--tests`
//!   flags (same names, same defaults -- library targets only unless
//!   bins/tests are explicitly requested).
//! - One or more positional paths: each is its own explicit module (for
//!   ad-hoc use and the fixtures under tests/fixtures/typeset/), named via
//!   `--module-name` (single-path only) or its file stem.

const std = @import("std");

const fangz = @import("fangz");
const docent = @import("docent");

pub fn register(root: *fangz.Command) !void {
    const typeset_cmd = try root.addSubcommand(.{
        .name = "typeset",
        .brief = "Generate docs.json for Typst-based PDF documentation",
        .description = "Discovers a package's modules (or walks explicit paths) and emits docs.json for rendering by the Typst template in typst/docent-docs/. Does not invoke `typst` itself; see the `docs-pdf` build step for the full docs.json -> PDF pipeline.",
    });

    try typeset_cmd.addPositional(.{
        .name = "paths",
        .brief = "Explicit module root file(s). If omitted, discovers targets from build.zig.",
        .variadic = true,
    });

    try typeset_cmd.addFlag(bool, .{
        .name = "lib",
        .brief = "Document library targets (default when no bin/test filters are set)",
        .default = false,
    });

    try typeset_cmd.addFlag(bool, .{
        .name = "bins",
        .brief = "Document all executable targets",
        .default = false,
    });

    try typeset_cmd.addFlag([]const []const u8, .{
        .name = "bin",
        .brief = "Document a specific executable by name (repeatable)",
    });

    try typeset_cmd.addFlag(bool, .{
        .name = "tests",
        .brief = "Document all test targets",
        .default = false,
    });

    try typeset_cmd.addFlag([]const []const u8, .{
        .name = "test",
        .brief = "Document a specific test target by name (repeatable)",
    });

    try typeset_cmd.addFlag(bool, .{
        .name = "deps",
        .brief = "Also document local path dependencies from build.zig.zon",
        .default = false,
    });

    try typeset_cmd.addFlag(bool, .{
        .name = "include-private",
        .brief = "Include non-public declarations",
        .default = false,
    });

    try typeset_cmd.addFlag([]const u8, .{
        .name = "module-name",
        .brief = "Name for the module (single explicit path only; used to build fully-qualified decl ids). Defaults to the file stem.",
        .value_hint = "NAME",
    });

    try typeset_cmd.addFlag([]const u8, .{
        .name = "output",
        .short = 'o',
        .brief = "Path to write docs.json to",
        .default = "docs.json",
        .value_hint = "PATH",
    });

    typeset_cmd.hooks.run = &run;
}

fn run(ctx: *fangz.ParseContext) anyerror!void {
    // The typeset pipeline builds a large, short-lived decl/schema tree with
    // no need for fine-grained frees -- an arena keeps json_emit.zig free of
    // per-node cleanup bookkeeping and avoids tripping ctx.allocator's leak
    // detection for what is, by design, "leak until process exit" tree data.
    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const io = ctx.io;

    const paths = ctx.positionals.items;
    const output = ctx.stringFlag("output") orelse "docs.json";
    const include_private = ctx.boolFlag("include-private") orelse false;

    var modules: std.ArrayList(docent.typeset.json_emit.Module) = .empty;

    if (paths.len > 0) {
        const module_name_flag = ctx.stringFlag("module-name") orelse "";
        for (paths) |path| {
            const name = if (paths.len == 1 and module_name_flag.len > 0)
                module_name_flag
            else
                std.fs.path.stem(path);

            const root_decl = docent.typeset.walker.walkModule(allocator, io, path, name) catch |err| {
                std.process.fatal("failed to walk '{s}': {t}", .{ path, err });
            };
            try modules.append(allocator, .{ .root_decl = root_decl, .name = name });
        }
    } else {
        var plan = docent.status_plan.gather(allocator, io, .{
            .lib = ctx.boolFlag("lib") orelse false,
            .bins = ctx.boolFlag("bins") orelse false,
            .bin_names = ctx.stringListFlag("bin") orelse &.{},
            .tests = ctx.boolFlag("tests") orelse false,
            .test_names = ctx.stringListFlag("test") orelse &.{},
            .deps = ctx.boolFlag("deps") orelse false,
        }) catch |err| {
            std.process.fatal("failed to discover modules: {t}", .{err});
        };
        defer plan.deinit(allocator);

        // `rt.name`/`rt.root_source_file` are owned by `plan`, freed when
        // this block exits -- `modules` outlives that, so anything kept
        // must be copied, not just referenced.
        var used_names: std.StringHashMap(void) = .init(allocator);

        for (plan.resolved_targets) |rt| {
            if (rt.status != .linted) continue;

            const abs_root = if (std.fs.path.isAbsolute(rt.root_source_file))
                rt.root_source_file
            else
                try std.fs.path.join(allocator, &.{ plan.package.project_root, rt.root_source_file });

            // Distinct build targets can share a step name (e.g. this
            // project's own library and executable are both named
            // "docent") -- `walker.walkModule` registers each module under
            // `Walk.modules[name]`, so a collision there would silently
            // overwrite the first module's entry and corrupt its `Decl.fqn`
            // derivation. Disambiguate with the target kind when needed.
            const name = if (used_names.contains(rt.name))
                try std.fmt.allocPrint(allocator, "{s}-{s}", .{ rt.name, @tagName(rt.kind) })
            else
                try allocator.dupe(u8, rt.name);
            try used_names.put(name, {});

            const root_decl = docent.typeset.walker.walkModule(allocator, io, abs_root, name) catch |err| {
                std.process.fatal("failed to walk '{s}' ({s}): {t}", .{ abs_root, name, err });
            };
            try modules.append(allocator, .{ .root_decl = root_decl, .name = name });
        }
    }

    if (modules.items.len == 0) {
        std.process.fatal("no modules found to document (nothing matched --lib/--bins/--tests, and no explicit paths given)", .{});
    }

    var timestamp_buf: [32]u8 = undefined;
    const generated_at = isoTimestamp(io, &timestamp_buf) catch "unknown";

    const docs_file = docent.typeset.json_emit.emitPackage(
        allocator,
        modules.items,
        include_private,
        @import("builtin").zig_version_string,
        "docent-typeset-0.1.0",
        generated_at,
    ) catch |err| {
        std.process.fatal("failed to build docs.json: {t}", .{err});
    };

    docent.typeset.json_emit.writeToFile(allocator, io, docs_file, output) catch |err| {
        std.process.fatal("failed to write '{s}': {t}", .{ output, err });
    };
}

fn isoTimestamp(io: std.Io, buf: []u8) ![]const u8 {
    const now = std.Io.Clock.real.now(io);
    const epoch_seconds: std.time.epoch.EpochSeconds = .{ .secs = @intCast(now.toSeconds()) };
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();

    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        @as(u8, month_day.day_index) + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    });
}
