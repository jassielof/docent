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

    try status_command.register(root);
    try init_command.register(root);
    try check_command.register(root);
    try app.executeProcess(init.minimal.args);
}
