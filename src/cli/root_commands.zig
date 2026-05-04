//! Registers Docent's root command tree (flags, subcommands). Keeps `main.zig` for `run` hooks and lint logic.
const std = @import("std");
const carnaval = @import("carnaval");
const docent = @import("docent");
const fangz = @import("fangz");

const docent_kv_help = @import("docent_kv_help.zig");

const zig_paths_completer =
    \\let current = ($context | split words | last | default "")
    \\
    \\let ends_with_separator = (
    \\  ($current | str ends-with "/") or
    \\  ($current | str ends-with "\\")
    \\)
    \\
    \\let search_dir = if $ends_with_separator {
    \\  if ($current | is-empty) { "." } else { $current }
    \\} else {
    \\  let parent = ($current | path dirname)
    \\
    \\  if ($parent | is-empty) or $parent == "." {
    \\    "."
    \\  } else {
    \\    $parent
    \\  }
    \\}
    \\
    \\let prefix = if $ends_with_separator {
    \\  ""
    \\} else {
    \\  $current | path basename
    \\}
    \\
    \\let completions = (
    \\  try {
    \\    ls $search_dir
    \\  } catch {
    \\    []
    \\  }
    \\  | where {|entry|
    \\      $entry.type == "dir"
    \\      or ($entry.name | str ends-with ".zig")
    \\      or ($entry.name | str ends-with ".zon")
    \\    }
    \\  | where {|entry|
    \\      ($entry.name | path basename) | str starts-with $prefix
    \\    }
    \\  | sort-by type name
    \\  | each {|entry|
    \\      if $entry.type == "dir" {
    \\        {
    \\          value: $"($entry.name)/",
    \\          description: "directory"
    \\        }
    \\      } else if ($entry.name | str ends-with ".zig") {
    \\        {
    \\          value: $entry.name,
    \\          description: "Zig source file"
    \\        }
    \\      } else {
    \\        {
    \\          value: $entry.name,
    \\          description: "Zig package/manifest file"
    \\        }
    \\      }
    \\    }
    \\)
    \\
    \\{
    \\  options: {
    \\    case_sensitive: false
    \\    completion_algorithm: prefix
    \\    sort: false
    \\  }
    \\  completions: $completions
    \\}
;

/// Count of documented rule keys (for tests); matches `docent.rule_metadata.rules`.
pub const key_value_rule_count = docent_kv_help.keys.len;
/// Count of documented severity levels (for tests); matches `docent.rule_metadata.levels`.
pub const key_value_level_count = docent_kv_help.values.len;

/// Wires flags, positional paths, `rules`, and examples. Caller must set `root.hooks.run` (e.g. lint entrypoint).
pub fn registerDocentRoot(root: *fangz.Command) !void {
    var usage_buf: [192]u8 = undefined;
    root.usage_override = try std.fmt.bufPrint(&usage_buf, "{s} [OPTIONS] [PATHS]...\n{s} <COMMAND>", .{ root.name, root.name });
    root.examples = docent_kv_help.app_examples;

    try root.addPositional(.{
        .name = "paths",
        .description = "Files or directories to lint. If omitted, Docent uses package paths from build.zig.zon when available.",
        .variadic = true,
        .completion = .{
            .nu = .{
                .name = "complete-zig-paths",
                .params = "context: string",
                .body = zig_paths_completer,
            },
        },
    });

    try root.addFlag(fangz.KeyValueList, .{
        .name = "rule",
        .short = 'r',
        .description =
        \\Override one rule severity
        \\Repeat the flag to override multiple rules
        \\Run `docent rules` to see rules and defaults.
        ,
        .key_metavar = "RULE",
        .value_metavar = "LEVEL",
        .allowed_keys = docent.RuleSet.fieldNames(),
        .allowed_values = &.{ "allow", "warn", "deny", "forbid" },
        .key_value_help = &docent_kv_help.key_value_help,
        .examples = docent_kv_help.flag_examples,
        .allowed_values_style = .bullet_list,
    });

    try root.addFlag(?AllPreset, .{
        .name = "all",
        .description = "Apply one severity to all rules",
        .value_hint = "LEVEL",
    });

    try root.addFlag(OutputMode, .{
        .name = "format",
        .short = 'f',
        .description = "Output format",
        .value_hint = "FORMAT",
        .default = .pretty,
        .allowed_values_style = .comma,
    });

    try root.addFlag(bool, .{
        .name = "include-build-scripts",
        .description = "Include build.zig and build/*.zig files in lint targets",
        .default = false,
    });

    try root.addFlag(FailFast, .{
        .name = "fail-fast",
        .description = "Stop after the first matching severity",
        .value_hint = "WHEN",
        .default = .any,
    });

    const rules_cmd = try root.addSubcommand(.{
        .name = "rules",
        .description = "List lint rules, defaults, and severity levels",
    });
    rules_cmd.setHooks(.{ .run = &runRulesCommand });
}

pub fn runRulesCommand(ctx: *fangz.ParseContext) !void {
    try printRulesReference(ctx.io);
}

pub fn printRulesReference(io: std.Io) !void {
    const profile = carnaval.colorProfileForHandle(std.Io.File.stdout().handle);
    var buf: [16384]u8 = undefined;
    var out = std.Io.File.stdout().writer(io, &buf);
    const w = &out.interface;

    try carnaval.Style.init().bolded().renderWithProfile("Docent lint rules\n\n", w, profile);
    try carnaval.Style.init().bolded().renderWithProfile("Rule overrides:\n", w, profile);
    try w.print("  -r, --rule <RULE=LEVEL>...\n\n", .{});
    try w.print("  Override one rule's severity. Repeat the flag to override multiple rules.\n\n", .{});

    try carnaval.Style.init().bolded().renderWithProfile("Examples:\n", w, profile);
    for (docent_kv_help.flag_examples) |ex| {
        if (ex.description.len > 0) try w.print("  {s}\n", .{ex.description});
        try w.print("    {s}\n", .{ex.command});
    }
    try w.print("\n", .{});

    try carnaval.Style.init().bolded().renderWithProfile("Severity levels:\n", w, profile);
    for (docent.rule_metadata.levels) |row| {
        try w.print("  {s}", .{row.name});
        var pad: usize = 0;
        while (pad < 8 -| row.name.len) : (pad += 1) try w.print(" ", .{});
        try w.print(" {s}\n", .{row.summary});
    }
    try w.print("\n", .{});

    try carnaval.Style.init().bolded().renderWithProfile("Rules:\n", w, profile);
    for (docent.rule_metadata.rules) |row| {
        try w.print("  {s}", .{row.name});
        var k: usize = 0;
        while (k < 32 -| row.name.len) : (k += 1) try w.print(" ", .{});
        try w.print("{s}\n", .{row.default_level});
        try w.print("    {s}\n\n", .{row.summary});
    }

    try carnaval.Style.init().bolded().renderWithProfile("Override order:\n", w, profile);
    var lines = std.mem.splitScalar(u8, docent.rule_metadata.override_behavior_note, '\n');
    while (lines.next()) |line| try w.print("  {s}\n", .{line});

    try w.flush();
}

pub const OutputMode = enum {
    pretty,
    text,
    minimal,
    json,
};

pub const AllPreset = enum {
    warn,
    deny,
};

pub const FailFast = enum {
    none,
    @"error",
    warn,
    any,
};
