const fangz = @import("fangz");

/// Registers `--config-path` on a command (root lint or `status`).
pub fn registerConfigPath(cmd: *fangz.Command) !void {
    try cmd.addFlag(?[]const u8, .{
        .name = "config-path",
        .brief = "Path to docent.json",
        .description = "When omitted, Docent searches upward from the working directory for `.config/docent.json`.",
        .value_hint = "PATH",
    });
}
