const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;

const format_test_assertions = @import("format_test_assertions.zig");
pub const classifier = @import("sort_imports/classifier.zig");
pub const extractor = @import("sort_imports/extractor.zig");
pub const renderer = @import("sort_imports/renderer.zig");
pub const sorter = @import("sort_imports/sorter.zig");
pub const types = @import("sort_imports/types.zig");

test "sorts imports" {
    const gpa = std.testing.allocator;
    const input =
        \\//! Module doc comment stays at the top.
        \\
        \\const std = @import("std");
        \\const builtin = @import("builtin");
        \\const vereda = @import("vereda");
        \\const Walker = vereda.Walker;
        \\const WalkEntry = vereda.WalkEntry;
        \\const fangz = @import("fangz");
        \\const App = fangz.App;
        \\const Flag = fangz.Flag;
        \\const Command = fangz.Command;
        \\const Allocator = std.mem.Allocator;
        \\const fs = std.fs;
        \\const mem = std.mem;
        \\const process = std.process;
        \\const assert = std.debug.assert;
        \\const root = @import("root");
        \\const version = root.version;
        \\const suppressions = @import("suppressions.zig");
        \\const check_command = @import("commands/check.zig");
        \\const fmt_command = @import("commands/fmt.zig");
        \\const init_command = @import("commands/init.zig");
        \\const status_command = @import("commands/status.zig");
        \\const analysis = @import("analysis.zig");
        \\const string_utils = @import("utils/string.zig");
        \\
        \\const platform = if (builtin.os.tag == .windows)
        \\    @import("platform/windows.zig")
        \\else
        \\    @import("platform/posix.zig");
        \\
        \\pub const Diagnostic = @import("Diagnostic.zig");
        \\pub const Config = @import("Config.zig");
        \\pub const severity = @import("severity.zig");
        \\pub const scan = @import("scan.zig");
        \\pub const rule_config = @import("rule_config.zig");
        \\
        \\pub const OutputMode = @import("types.zig").OutputMode;
        \\pub const default_fail_fast = @import("types.zig").default_fail_fast;
        \\pub const FailFast = @import("types.zig").FailFast;
        \\
        \\pub const registerConfigPathFlag = @import("flags.zig").registerConfigPath;
        \\
        \\pub const Suppressions = suppressions.Table;
        \\pub const registerStatusSubcommand = status_command.register;
        \\
    ;
    const expected =
        \\//! Module doc comment stays at the top.
        \\
        \\const std = @import("std");
        \\const assert = std.debug.assert;
        \\const fs = std.fs;
        \\const mem = std.mem;
        \\const Allocator = std.mem.Allocator;
        \\const process = std.process;
        \\
        \\const builtin = @import("builtin");
        \\
        \\const root = @import("root");
        \\const version = root.version;
        \\
        \\const fangz = @import("fangz");
        \\const App = fangz.App;
        \\const Command = fangz.Command;
        \\const Flag = fangz.Flag;
        \\const vereda = @import("vereda");
        \\const WalkEntry = vereda.WalkEntry;
        \\const Walker = vereda.Walker;
        \\
        \\const analysis = @import("analysis.zig");
        \\const check_command = @import("commands/check.zig");
        \\const fmt_command = @import("commands/fmt.zig");
        \\const init_command = @import("commands/init.zig");
        \\const status_command = @import("commands/status.zig");
        \\const suppressions = @import("suppressions.zig");
        \\const string_utils = @import("utils/string.zig");
        \\const platform = if (builtin.os.tag == .windows)
        \\    @import("platform/windows.zig")
        \\else
        \\    @import("platform/posix.zig");
        \\
        \\pub const Config = @import("Config.zig");
        \\pub const Diagnostic = @import("Diagnostic.zig");
        \\pub const rule_config = @import("rule_config.zig");
        \\pub const scan = @import("scan.zig");
        \\pub const severity = @import("severity.zig");
        \\
        \\pub const registerConfigPathFlag = @import("flags.zig").registerConfigPath;
        \\
        \\pub const default_fail_fast = @import("types.zig").default_fail_fast;
        \\pub const FailFast = @import("types.zig").FailFast;
        \\pub const OutputMode = @import("types.zig").OutputMode;
        \\
        \\pub const registerStatusSubcommand = status_command.register;
        \\pub const Suppressions = suppressions.Table;
        \\
    ;

    const formatted = try sortImports(gpa, input);
    defer gpa.free(formatted);
    try std.testing.expectEqualStrings(expected, formatted);
    try format_test_assertions.expectValidZig(formatted);

    const formatted_expected = try sortImports(gpa, expected);
    defer gpa.free(formatted_expected);
    try format_test_assertions.expectIdempotent(expected, formatted_expected);
}

test "keeps conditional imports in their origin category and orders reexports by base path" {
    const gpa = std.testing.allocator;
    const input =
        \\const std = @import("std");
        \\const zoo = @import("zoo.zig");
        \\const alpha = @import("alpha.zig");
        \\const platform = if (std.builtin.os.tag == .windows)
        \\    @import("platform/windows.zig")
        \\else
        \\    @import("platform/posix.zig");
        \\const dependency = if (std.builtin.os.tag == .windows)
        \\    @import("windows-dependency")
        \\else
        \\    @import("posix-dependency");
        \\pub const Aardvark = zoo.Value;
        \\pub const Zebra = alpha.Value;
        \\
    ;
    const expected =
        \\const std = @import("std");
        \\
        \\const dependency = if (std.builtin.os.tag == .windows)
        \\    @import("windows-dependency")
        \\else
        \\    @import("posix-dependency");
        \\
        \\const alpha = @import("alpha.zig");
        \\const zoo = @import("zoo.zig");
        \\const platform = if (std.builtin.os.tag == .windows)
        \\    @import("platform/windows.zig")
        \\else
        \\    @import("platform/posix.zig");
        \\
        \\pub const Zebra = alpha.Value;
        \\pub const Aardvark = zoo.Value;
        \\
    ;

    const formatted = try sortImports(gpa, input);
    defer gpa.free(formatted);
    try std.testing.expectEqualStrings(expected, formatted);
    try format_test_assertions.expectValidZig(formatted);
}

test "retains internal inline imports and their attached comments" {
    const gpa = std.testing.allocator;
    const input =
        \\// NOTE: keep this comment exactly once.
        \\const std = @import("std");
        \\const SeverityLevel = @import("severity.zig").Level;
        \\const Renderer = @import("renderer.zig").Renderer;
        \\const alpha = @import("alpha.zig");
        \\pub const Name = alpha.Name;
        \\
    ;
    const expected =
        \\// NOTE: keep this comment exactly once.
        \\const std = @import("std");
        \\
        \\const alpha = @import("alpha.zig");
        \\const Renderer = @import("renderer.zig").Renderer;
        \\const SeverityLevel = @import("severity.zig").Level;
        \\
        \\pub const Name = alpha.Name;
        \\
    ;

    const formatted = try sortImports(gpa, input);
    defer gpa.free(formatted);
    try std.testing.expectEqualStrings(expected, formatted);

    const formatted_expected = try sortImports(gpa, expected);
    defer gpa.free(formatted_expected);
    try format_test_assertions.expectIdempotent(expected, formatted_expected);
}

/// Sorts the leading top-level import block using AST-based extraction.
///
/// Imports are regrouped into categories (std, builtin, root, dependencies,
/// local files) separated by blank lines. Bases sort by import path and
/// aliases remain directly beneath their base, ordered by accessed member path.
/// Conditional imports join the origin category of their most-local branch and
/// remain at the end of that category.
///
/// Internal and public imports are separated by a single blank line (Zig's
/// formatter collapses consecutive blank lines, so a double gap would not
/// survive a subsequent `zig fmt` / AST render pass).
/// Only the contiguous leading import block is touched.
pub fn sortImports(gpa: Allocator, input: []const u8) Allocator.Error![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const sentinel_input = try gpa.dupeZ(u8, input);
    defer gpa.free(sentinel_input);

    var tree = std.zig.Ast.parse(
        gpa,
        sentinel_input,
        .zig,
    ) catch return gpa.dupe(u8, input);
    defer tree.deinit(gpa);

    if (tree.errors.len != 0) return gpa.dupe(u8, input);

    const result = extractor.extract(arena, &tree) catch return gpa.dupe(u8, input);
    if (result.entries.len == 0) return gpa.dupe(u8, input);

    const groups = sorter.buildGroups(arena, result.entries) catch return gpa.dupe(u8, input);
    const rendered = renderer.render(
        arena,
        groups,
        result.entries,
    ) catch return gpa.dupe(u8, input);

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(gpa);

    const prefix = input[0..result.block_start];
    try output.ensureTotalCapacity(gpa, prefix.len + rendered.len + (input.len - result.block_end) + 2);

    try output.appendSlice(gpa, prefix);

    if (rendered.len > 0 and rendered[rendered.len - 1] != '\n') {
        try output.appendSlice(gpa, rendered);
        try output.append(gpa, '\n');
    } else {
        try output.appendSlice(gpa, rendered);
    }

    if (result.block_end < input.len) {
        var rest_start = result.block_end;
        while (rest_start < input.len and (input[rest_start] == '\n' or input[rest_start] == '\r')) rest_start += 1;
        if (rest_start < input.len) {
            try output.appendSlice(gpa, input[rest_start..]);
        }
    }

    return output.toOwnedSlice(gpa);
}
