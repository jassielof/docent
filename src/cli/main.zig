const std = @import("std");

const fangz = @import("fangz");

const check_command = @import("commands/check.zig");
const init_command = @import("commands/init.zig");
const status_command = @import("commands/status.zig");
pub const rule_config = @import("rule_config.zig");

pub const registerStatusSubcommand = status_command.register;
pub const registerConfigPathFlag = @import("flags.zig").registerConfigPath;

pub const OutputMode = @import("types.zig").OutputMode;
pub const FailFast = @import("types.zig").FailFast;
pub const default_fail_fast = @import("types.zig").default_fail_fast;

pub const app_examples: []const fangz.Command.CliExample = &.{
    .{ .description = "Show available commands", .command = "docent" },
    .{ .description = "Compact summary of every check category", .command = "docent check" },
    .{ .description = "Documentation comment rules", .command = "docent check docs" },
    .{ .description = "Every check with full diagnostics", .command = "docent check all" },
    .{ .description = "Initialize project config", .command = "docent init" },
    .{ .description = "Show lint plan and effective rules", .command = "docent status" },
    .{ .description = "Generate CLI AsciiDoc", .command = "docent docs --output-dir docs" },
    .{ .description = "Shell completion script", .command = "docent completion nu" },
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var app = try fangz.App.init(gpa, io, .{
        .display_name = "Docent",
        .author_name = "",
        .author_email = "",
        .tagline = "A Documentation Linter for Zig Projects",
    });

    defer app.deinit();

    const root = app.root();
    root.setHelpOnEmptyArgs(true);
    root.examples = app_examples;

    try status_command.register(root);
    try init_command.register(root);
    try check_command.register(root);

    try app.executeProcess(init.minimal.args);
}
