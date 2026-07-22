//! `docent typeset` — generate offline PDF/document output for a Zig
//! package's modules via Typst, instead of `zig build docs`'s HTML/WASM
//! viewer.
//!
//! Pipeline (see `modules/typeset.zig` for the supporting library):
//!   module discovery -> walker.walkModule (per module) -> serialize.emitPackage
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
//!
//! Cross-package references (`std.*` and named dependencies) are resolved
//! without walking their source -- see `modules/typeset/external_refs.zig`
//! for the design and `--external-refs`/`--refs-output` below.
//!
//! Dependency bundling (PDF size strategy):
//! - Default: primary modules only.
//! - `--deps`: direct `.path` dependencies from build.zig.zon as appendix.
//! - `--deps-recursive`: also nest into those deps' own `.path` deps
//!   (e.g. vereda → xdg). Still `.path`-only; never URL/hash cache packages.
//! - `--bundle-std`: one-hop referenced std files only (see std_bundle.zig).
//! - Otherwise `std.*` / unbundled deps use ziglang.org / `--external-refs`.

const std = @import("std");

const docent = @import("docent");
const fangz = @import("fangz");
const typeset = @import("typeset");

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
        .brief = "Also document direct local .path dependencies from build.zig.zon as appendix modules",
        .default = false,
    });

    try typeset_cmd.addFlag(bool, .{
        .name = "deps-recursive",
        .brief = "With --deps, also recurse into nested .path dependencies (e.g. vereda -> xdg)",
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

    try typeset_cmd.addFlag([]const []const u8, .{
        .name = "external-refs",
        .brief = "Load a dependency's published reference sidecar (repeatable). See --refs-output.",
        .value_hint = "PATH",
    });

    try typeset_cmd.addFlag(?[]const u8, .{
        .name = "refs-output",
        .brief = "Also write a reference sidecar (id -> --refs-doc-url) for dependents to consume via --external-refs",
        .value_hint = "PATH",
    });

    try typeset_cmd.addFlag([]const u8, .{
        .name = "refs-doc-url",
        .brief = "URL recorded in the sidecar for every id (required with --refs-output)",
        .value_hint = "URL",
    });

    try typeset_cmd.addFlag(bool, .{
        .name = "bundle-std",
        .brief = "Bundle referenced std.* declarations into the appendix instead of linking to ziglang.org (requires `zig` on PATH)",
        .default = false,
    });

    typeset_cmd.hooks.run = &run;
}

fn run(ctx: *fangz.ParseContext) anyerror!void {
    // The typeset pipeline builds a large, short-lived decl/schema tree with
    // no need for fine-grained frees -- an arena keeps serialize.zig free of
    // per-node cleanup bookkeeping and avoids tripping ctx.allocator's leak
    // detection for what is, by design, "leak until process exit" tree data.
    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const io = ctx.io;

    // Isolate this typeset run's declaration graph from any prior Walk state.
    var walk_session: typeset.Walk.Session = .{};
    const prev_session = typeset.Walk.activate(&walk_session);
    defer _ = typeset.Walk.activate(prev_session);

    var cfg: docent.Config = docent.config.loadConfigFromCli(
        ctx.allocator,
        io,
        null,
    ) catch .{};
    defer cfg.deinit(ctx.allocator);

    const paths = ctx.positionals.items;
    const cli_output = ctx.stringFlag("output") orelse "docs.json";
    const output = if (std.mem.eql(
        u8,
        cli_output,
        "docs.json",
    ) and cfg.typeset.output_owned)
        cfg.typeset.output
    else
        cli_output;
    const include_private = (ctx.boolFlag("include-private") orelse false) or cfg.typeset.include_private;
    const want_deps = (ctx.boolFlag("deps") orelse false) or cfg.typeset.deps;
    const deps_recursive = ctx.boolFlag("deps-recursive") orelse false;
    const want_bundle_std = (ctx.boolFlag("bundle-std") orelse false) or cfg.typeset.bundle_std;

    var modules: std.ArrayList(typeset.serialize.Module) = .empty;
    var appendix: std.ArrayList(typeset.serialize.Module) = .empty;

    if (paths.len > 0) {
        const module_name_flag = ctx.stringFlag("module-name") orelse "";
        for (paths) |path| {
            const name = if (paths.len == 1 and module_name_flag.len > 0)
                module_name_flag
            else
                std.fs.path.stem(path);

            const root_decl = typeset.walker.walkModule(
                allocator,
                io,
                path,
                name,
            ) catch |err| {
                std.process.fatal("failed to walk '{s}': {t}", .{ path, err });
            };
            try modules.append(allocator, .{ .root_decl = root_decl, .name = name });
        }
    } else {
        var plan = docent.status_plan.gather(allocator, io, .{
            .lib = (ctx.boolFlag("lib") orelse false) or cfg.typeset.lib,
            .bins = (ctx.boolFlag("bins") orelse false) or cfg.typeset.bins,
            .bin_names = ctx.stringListFlag("bin") orelse &.{},
            .tests = (ctx.boolFlag("tests") orelse false) or cfg.typeset.tests,
            .test_names = ctx.stringListFlag("test") orelse &.{},
            .deps = want_deps,
            .exclude_targets = cfg.typeset.exclude_targets,
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
                try std.fmt.allocPrint(
                    allocator,
                    "{s}-{s}",
                    .{ rt.name, @tagName(rt.kind) },
                )
            else
                try allocator.dupe(u8, rt.name);
            try used_names.put(name, {});

            const root_decl = typeset.walker.walkModule(
                allocator,
                io,
                abs_root,
                name,
            ) catch |err| {
                std.process.fatal("failed to walk '{s}' ({s}): {t}", .{
                    abs_root,
                    name,
                    err,
                });
            };
            try modules.append(allocator, .{ .root_decl = root_decl, .name = name });
        }

        // `--deps`: bundle each `.path` build.zig.zon dependency as an
        // appendix module in this *same* docs.json/PDF. With `--deps-recursive`,
        // also walk nested `.path` deps (vereda → xdg).
        if (want_deps and plan.package.manifest_path != null) {
            var deps = if (deps_recursive)
                typeset.path_deps.discoverRecursive(
                    allocator,
                    io,
                    plan.package.manifest_path.?,
                ) catch |err| {
                    std.process.fatal("failed to read dependencies from '{s}': {t}", .{ plan.package.manifest_path.?, err });
                }
            else
                typeset.path_deps.discover(
                    allocator,
                    io,
                    plan.package.manifest_path.?,
                ) catch |err| {
                    std.process.fatal("failed to read dependencies from '{s}': {t}", .{ plan.package.manifest_path.?, err });
                };
            defer typeset.path_deps.deinitEntries(allocator, &deps);

            for (deps.items) |dep| {
                const root = typeset.path_deps.findRootModule(
                    allocator,
                    io,
                    dep.root_dir,
                ) catch |err| {
                    std.process.fatal("failed to inspect dependency '{s}': {t}", .{ dep.name, err });
                } orelse {
                    var stderr_buf: [256]u8 = undefined;
                    var stderr = std.Io.File.stderr().writer(io, &stderr_buf);
                    stderr.interface.print(
                        "warning: skipping dependency '{s}': no root.zig-style module root found under '{s}'\n",
                        .{ dep.name, dep.root_dir },
                    ) catch {};
                    stderr.interface.flush() catch {};
                    continue;
                };

                const name = if (used_names.contains(dep.name))
                    try std.fmt.allocPrint(
                        allocator,
                        "{s}-dep",
                        .{dep.name},
                    )
                else
                    try allocator.dupe(u8, dep.name);
                try used_names.put(name, {});

                const root_decl = typeset.walker.walkModule(
                    allocator,
                    io,
                    root,
                    name,
                ) catch |err| {
                    std.process.fatal("failed to walk dependency '{s}' ({s}): {t}", .{
                        dep.name,
                        root,
                        err,
                    });
                };
                try appendix.append(allocator, .{ .root_decl = root_decl, .name = name });
            }
        }
    }

    if (modules.items.len == 0) {
        std.process.fatal("no modules found to document (nothing matched --lib/--bins/--tests, and no explicit paths given)", .{});
    }

    var refs_table: typeset.external_refs.Table = .{};
    for (ctx.stringListFlag("external-refs") orelse &.{}) |path| {
        refs_table.loadFile(
            allocator,
            io,
            path,
        ) catch |err| {
            std.process.fatal("failed to load external refs '{s}': {t}", .{ path, err });
        };
    }

    var std_collector: ?typeset.std_bundle.Collector = null;
    if (want_bundle_std) {
        if (typeset.std_bundle.discover(allocator, io)) |root| {
            std_collector = .{ .root = root };
        } else {
            var stderr_buf: [256]u8 = undefined;
            var stderr = std.Io.File.stderr().writer(io, &stderr_buf);
            stderr.interface.print("warning: --bundle-std requires `zig` on PATH; falling back to ziglang.org links\n", .{}) catch {};
            stderr.interface.flush() catch {};
        }
    }

    var timestamp_buf: [32]u8 = undefined;
    const generated_at = isoTimestamp(io, &timestamp_buf) catch "unknown";

    const docs_file = typeset.serialize.emitPackage(
        allocator,
        io,
        modules.items,
        appendix.items,
        include_private,
        &refs_table,
        if (std_collector) |*c| c else null,
        @import("builtin").zig_version_string,
        "docent-typeset-0.1.0",
        generated_at,
    ) catch |err| {
        std.process.fatal("failed to build docs.json: {t}", .{err});
    };

    typeset.serialize.writeToFile(
        allocator,
        io,
        docs_file,
        output,
    ) catch |err| {
        std.process.fatal("failed to write '{s}': {t}", .{ output, err });
    };

    if (ctx.stringFlag("refs-output")) |refs_output| {
        const doc_url = ctx.stringFlag("refs-doc-url") orelse
            std.process.fatal("--refs-output requires --refs-doc-url", .{});
        const package_name = if (modules.items.len == 1) modules.items[0].name else "package";
        typeset.external_refs.writeRefsFile(
            allocator,
            io,
            package_name,
            doc_url,
            docs_file.modules,
            refs_output,
        ) catch |err| {
            std.process.fatal("failed to write '{s}': {t}", .{ refs_output, err });
        };
    }
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
