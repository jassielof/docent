//! Initializes a project `.config/docent.toml` from the bundled template.

const std = @import("std");

const docent = @import("docent");
const fangz = @import("fangz");

const Preset = enum {
    standard,
    tiger,
    godoc,
};

const default_config_file = @embedFile("init/templates/docent.default.toml");
const tiger_config_file = @embedFile("init/templates/docent.tiger.toml");
const godoc_config_file = @embedFile("init/templates/docent.godoc.toml");

const remote_schema_line = "#:schema https://jassielof.github.io/docent/schema/docent.schema.json\n";

/// Registers the `init` sub-command on `root`.
pub fn register(root: *fangz.Command) !void {
    const init_cmd = try root.addSubcommand(.{
        .name = "init",
        .brief = "Create a default Docent configuration file",
        .description = "Write `.config/docent.toml` using the selected bundled template and the published JSON Schema URL. Use `--preset tiger` for Tiger Style or `--preset godoc` for Go Doc Comments. Does not overwrite an existing file.",
    });

    try init_cmd.addFlag(bool, .{
        .name = "force",
        .brief = "Overwrite an existing configuration file",
        .default = false,
    });
    try init_cmd.addFlag(Preset, .{
        .name = "preset",
        .brief = "Choose a bundled configuration preset",
        .description = "Use `tiger` for Tiger Style naming and a strict 100-column limit, or `godoc` for Go-style public API documentation.",
        .default = .standard,
        .allowed_values_style = .comma,
    });

    init_cmd.setHooks(.{ .run = &run });
}

fn run(ctx: *fangz.ParseContext) !void {
    const allocator = ctx.allocator;
    const io = ctx.io;

    const Args = struct {
        force: bool = false,
        preset: Preset = .standard,
    };

    const args = try ctx.extract(Args);
    const config_path = docent.config.default_relative_path;

    if (std.fs.path.dirname(config_path)) |parent| {
        if (parent.len > 0) try std.Io.Dir.cwd().createDirPath(io, parent);
    }

    if (!args.force and isReadableFile(io, config_path)) {
        try printStderr(
            io,
            "error: '{s}' already exists (use --force to overwrite)\n",
            .{config_path},
        );
        std.process.exit(1);
    }

    const content = try renderConfig(allocator, args.preset);
    defer allocator.free(content);

    const file = try std.Io.Dir.cwd().createFile(
        io,
        config_path,
        .{
            .truncate = args.force,
            .exclusive = !args.force,
        },
    );
    defer file.close(io);

    try file.writeStreamingAll(io, content);
    try printStderr(
        io,
        "Created {s}\n",
        .{config_path},
    );
}

fn renderDefaultConfig(allocator: std.mem.Allocator) ![]const u8 {
    return renderConfig(allocator, .standard);
}

fn renderConfig(
    allocator: std.mem.Allocator,
    preset: Preset,
) ![]const u8 {
    const config_file = switch (preset) {
        .standard => default_config_file,
        .tiger => tiger_config_file,
        .godoc => godoc_config_file,
    };

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, remote_schema_line);
    try out.appendSlice(allocator, config_file);
    return try out.toOwnedSlice(allocator);
}

fn isReadableFile(io: std.Io, path: []const u8) bool {
    const file = std.Io.Dir.cwd().openFile(
        io,
        path,
        .{},
    ) catch return false;
    file.close(io);
    return true;
}

fn printStderr(
    io: std.Io,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    var buf: [4096]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &buf);
    try stderr.interface.print(fmt, args);
    try stderr.interface.flush();
}

test "renderDefaultConfig uses the published schema URL" {
    const content = try renderDefaultConfig(std.testing.allocator);
    defer std.testing.allocator.free(content);

    try std.testing.expect(std.mem.startsWith(
        u8,
        content,
        remote_schema_line,
    ));
    try std.testing.expect(std.mem.indexOf(
        u8,
        content[remote_schema_line.len..],
        "#:schema",
    ) == null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        content,
        "[doc]",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        content,
        "[check]",
    ) != null);
}

test "renderConfig embeds the Tiger Style preset" {
    const content = try renderConfig(std.testing.allocator, .tiger);
    defer std.testing.allocator.free(content);

    try std.testing.expect(std.mem.startsWith(u8, content, remote_schema_line));
    try std.testing.expect(std.mem.indexOf(u8, content, "functions = \"snake_case\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "struct_file_case = \"snake_case\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "level = \"forbid\"") != null);
}

test "renderConfig embeds the Go Doc Comments preset" {
    const content = try renderConfig(std.testing.allocator, .godoc);
    defer std.testing.allocator.free(content);

    try std.testing.expect(std.mem.startsWith(u8, content, remote_schema_line));
    try std.testing.expect(std.mem.indexOf(u8, content, "scan_mode = \"public\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "missing_doctest = \"allow\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "ignore_leading_comments = true") != null);
}
