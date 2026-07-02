//! `docent typeset` — generate offline PDF/document output for a Zig module's
//! public API via Typst, instead of `zig build docs`'s HTML/WASM viewer.
//!
//! Pipeline (see `src/lib/typeset.zig` for the supporting library):
//!   module root path -> walker.walkModule -> json_emit.emit -> docs.json
//!   -> `typst compile` (shelled out, see build.zig's `docs-pdf` step) -> PDF
//!
//! v0.1 scope: single module, flat top-level public decls, no nesting
//! render, no cross-references, default Typst styling.

const std = @import("std");

const fangz = @import("fangz");
const docent = @import("docent");

pub fn register(root: *fangz.Command) !void {
    const typeset_cmd = try root.addSubcommand(.{
        .name = "typeset",
        .brief = "Generate docs.json for Typst-based PDF documentation",
        .description = "Walks a Zig module's public API and emits docs.json for rendering by the Typst template in typst/docent-docs/. Does not invoke `typst` itself; see the `docs-pdf` build step for the full docs.json -> PDF pipeline.",
    });

    try typeset_cmd.addPositional(.{
        .name = "module_root",
        .brief = "Path to the module's root source file",
    });

    try typeset_cmd.addFlag([]const u8, .{
        .name = "module-name",
        .brief = "Name to register the module under (used to build fully-qualified decl ids). Defaults to the file stem.",
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

    if (ctx.positionals.items.len == 0) {
        std.process.fatal("expected a module root file argument", .{});
    }
    const module_root = ctx.positionals.items[0];
    const output = ctx.stringFlag("output") orelse "docs.json";

    const module_name = ctx.stringFlag("module-name") orelse std.fs.path.stem(module_root);

    const root_decl = docent.typeset.walker.walkModule(allocator, io, module_root, module_name) catch |err| {
        std.process.fatal("failed to walk '{s}': {t}", .{ module_root, err });
    };

    var timestamp_buf: [32]u8 = undefined;
    const generated_at = isoTimestamp(io, &timestamp_buf) catch "unknown";

    const docs_file = docent.typeset.json_emit.emit(
        allocator,
        root_decl,
        module_name,
        @import("builtin").zig_version_string,
        "docent-typeset-0.1.0",
        generated_at,
    ) catch |err| {
        std.process.fatal("failed to build docs.json for '{s}': {t}", .{ module_root, err });
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
