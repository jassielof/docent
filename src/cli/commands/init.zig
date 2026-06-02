//! Initializes a project `.config/docent.toml` from the bundled template.

const std = @import("std");

const docent = @import("docent");
const fangz = @import("fangz");

const default_config_file = @embedFile("../templates/docent.toml");

const local_schema_line = "#:schema ../schemas/docent.schema.json\n";
const remote_schema_line = "#:schema https://jassielof.github.io/docent/schemas/docent.schema.json\n";

/// Registers the `init` sub-command on `root`.
pub fn register(root: *fangz.Command) !void {
    const init_cmd = try root.addSubcommand(.{
        .name = "init",
        .brief = "Create a default Docent configuration file",
        .description = "Write `.config/docent.toml` using the bundled template and the published JSON Schema URL. Does not overwrite an existing file.",
    });

    try init_cmd.addFlag(bool, .{
        .name = "force",
        .brief = "Overwrite an existing configuration file",
        .default = false,
    });

    init_cmd.setHooks(.{ .run = &run });
}

fn run(ctx: *fangz.ParseContext) !void {
    const allocator = ctx.allocator;
    const io = ctx.io;

    const Args = struct {
        force: bool = false,
    };

    const args = try ctx.extract(Args);
    const config_path = docent.config.default_relative_path;

    if (std.fs.path.dirname(config_path)) |parent| {
        if (parent.len > 0) try std.Io.Dir.cwd().createDirPath(io, parent);
    }

    if (!args.force and isReadableFile(io, config_path)) {
        try printStderr(io, "error: '{s}' already exists (use --force to overwrite)\n", .{config_path});
        std.process.exit(1);
    }

    const content = try renderDefaultConfig(allocator);
    defer allocator.free(content);

    const file = try std.Io.Dir.cwd().createFile(io, config_path, .{
        .truncate = args.force,
        .exclusive = !args.force,
    });
    defer file.close(io);

    try file.writeStreamingAll(io, content);
    try printStderr(io, "Created {s}\n", .{config_path});
}

fn renderDefaultConfig(allocator: std.mem.Allocator) ![]const u8 {
    if (std.mem.startsWith(u8, default_config_file, "#:schema")) {
        const rest_start = std.mem.indexOfScalar(u8, default_config_file, '\n') orelse default_config_file.len;
        const rest = default_config_file[rest_start + 1 ..];

        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(allocator);
        try out.appendSlice(allocator, remote_schema_line);
        try out.appendSlice(allocator, rest);
        return try out.toOwnedSlice(allocator);
    }

    return try std.mem.replaceOwned(u8, allocator, local_schema_line, remote_schema_line, default_config_file);
}

fn isReadableFile(io: std.Io, path: []const u8) bool {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    file.close(io);
    return true;
}

fn printStderr(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &buf);
    try stderr.interface.print(fmt, args);
    try stderr.interface.flush();
}

test "renderDefaultConfig uses the published schema URL" {
    const content = try renderDefaultConfig(std.testing.allocator);
    defer std.testing.allocator.free(content);

    try std.testing.expect(std.mem.startsWith(u8, content, remote_schema_line));
    try std.testing.expect(std.mem.indexOf(u8, content, local_schema_line) == null);
    try std.testing.expect(std.mem.indexOf(u8, content, "[docs]") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "[complexity.cognitive_complexity]") != null);
}
