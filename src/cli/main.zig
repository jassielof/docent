const std = @import("std");

const docent = @import("docent");
pub const rule_config = docent.rule_config;
pub const default_fail_fast = docent.types.default_fail_fast;
pub const FailFast = docent.types.FailFast;
pub const OutputMode = docent.types.OutputMode;
pub const registerConfigPathFlag = docent.flags.registerConfigPath;
const fangz = @import("fangz");

const check_command = @import("commands/check.zig");
const fmt = @import("commands/fmt.zig");
const init_command = @import("commands/init.zig");
const status_command = @import("commands/status.zig");
pub const registerStatusSubcommand = status_command.register;
const typeset_command = @import("commands/typeset.zig");

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
    try fmt.register(root);
    try typeset_command.register(root);

    try app.executeProcess(init.minimal.args);
}
