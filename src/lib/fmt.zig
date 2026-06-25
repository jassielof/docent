const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const fs = std.fs;
const Allocator = std.mem.Allocator;
const Color = std.zig.Color;

// TODO: This config should be just integrated within the main Docent TOML config.
pub const Config = struct {
    brace_style: BraceStyle = .k_r,

    pub const BraceStyle = enum { k_r, allman };

    const JsonConfig = struct {
        brace_style: ?[]const u8 = null,
    };

    pub fn load(gpa: Allocator, io: Io) Config {
        const content = Io.Dir.cwd().readFileAlloc(io, ".config/zigfmt.json", gpa, .unlimited) catch return .{};
        defer gpa.free(content);

        const parsed = std.json.parseFromSlice(JsonConfig, gpa, content, .{
            .ignore_unknown_fields = true,
        }) catch return .{};
        defer parsed.deinit();

        var config: Config = .{};
        if (parsed.value.brace_style) |bs| {
            config.brace_style = std.meta.stringToEnum(BraceStyle, bs) orelse .k_r;
        }
        return config;
    }
};

pub const Options = struct {
    check: bool = false,
    ast_check: bool = false,
    zon: bool = false,
    color: Color = .auto,
};

pub const Fmt = struct {
    seen: SeenMap,
    any_error: bool,
    check_ast: bool,
    check_mode: bool,
    force_zon: bool,
    color: Color,
    config: Config,
    gpa: Allocator,
    io: Io,
    out_buffer: Io.Writer.Allocating,
    stdout_writer: *Io.File.Writer,

    const SeenMap = std.AutoHashMap(Io.File.INode, void);

    pub fn init(gpa: Allocator, io: Io, stdout_writer: *Io.File.Writer, opts: Options, config: Config) Fmt {
        return .{
            .gpa = gpa,
            .io = io,
            .seen = .init(gpa),
            .any_error = false,
            .check_ast = opts.ast_check,
            .check_mode = opts.check,
            .force_zon = opts.zon,
            .color = opts.color,
            .config = config,
            .out_buffer = .init(gpa),
            .stdout_writer = stdout_writer,
        };
    }

    pub fn deinit(self: *Fmt) void {
        self.seen.deinit();
        self.out_buffer.deinit();
    }
};

pub fn formatStdin(gpa: Allocator, io: Io, opts: Options, config: Config) !void {
    const stdin: Io.File = .stdin();
    var stdio_buffer: [1024]u8 = undefined;
    var file_reader: Io.File.Reader = stdin.reader(io, &stdio_buffer);
    const source_code = std.zig.readSourceFileToEndAlloc(gpa, &file_reader) catch |err| {
        std.process.fatal("unable to read stdin: {}", .{err});
    };
    defer gpa.free(source_code);

    var tree = std.zig.Ast.parse(gpa, source_code, if (opts.zon) .zon else .zig) catch |err| {
        std.process.fatal("error parsing stdin: {}", .{err});
    };
    defer tree.deinit(gpa);

    if (opts.ast_check) {
        if (!opts.zon) {
            var zir = try std.zig.AstGen.generate(gpa, tree);
            defer zir.deinit(gpa);

            if (zir.hasCompileErrors()) {
                var wip_errors: std.zig.ErrorBundle.Wip = undefined;
                try wip_errors.init(gpa);
                defer wip_errors.deinit();
                try wip_errors.addZirErrorMessages(zir, tree, source_code, "<stdin>");
                var error_bundle = try wip_errors.toOwnedBundle("");
                defer error_bundle.deinit(gpa);
                error_bundle.renderToStderr(io, .{}, opts.color) catch {};
                std.process.exit(2);
            }
        } else {
            const zoir = try std.zig.ZonGen.generate(gpa, tree, .{});
            defer zoir.deinit(gpa);

            if (zoir.hasCompileErrors()) {
                var wip_errors: std.zig.ErrorBundle.Wip = undefined;
                try wip_errors.init(gpa);
                defer wip_errors.deinit();
                try wip_errors.addZoirErrorMessages(zoir, tree, source_code, "<stdin>");
                var error_bundle = try wip_errors.toOwnedBundle("");
                defer error_bundle.deinit(gpa);
                error_bundle.renderToStderr(io, .{}, opts.color) catch {};
                std.process.exit(2);
            }
        }
    } else if (tree.errors.len != 0) {
        std.zig.printAstErrorsToStderr(gpa, io, tree, "<stdin>", opts.color) catch {};
        std.process.exit(2);
    }

    const rendered = try tree.renderAlloc(gpa);
    defer gpa.free(rendered);

    const formatted = if (config.brace_style == .allman) blk: {
        break :blk try convertToAllman(gpa, rendered);
    } else rendered;
    defer if (config.brace_style == .allman) gpa.free(formatted);

    if (opts.check) {
        const code: u8 = @intFromBool(!mem.eql(u8, formatted, source_code));
        std.process.exit(code);
    }

    return Io.File.stdout().writeStreamingAll(io, formatted);
}

pub fn formatPaths(fmt: *Fmt, input_files: []const []const u8, excluded_files: []const []const u8) !void {
    for (excluded_files) |file_path| {
        const stat = Io.Dir.cwd().statFile(fmt.io, file_path, .{}) catch |err| switch (err) {
            error.FileNotFound => continue,
            error.IsDir => dir: {
                var dir = try Io.Dir.cwd().openDir(fmt.io, file_path, .{});
                defer dir.close(fmt.io);
                break :dir try dir.stat(fmt.io);
            },
            else => |e| return e,
        };
        try fmt.seen.put(stat.inode, {});
    }

    for (input_files) |file_path| {
        try fmtPath(fmt, file_path, Io.Dir.cwd(), file_path);
    }
    try fmt.stdout_writer.interface.flush();
    if (fmt.any_error) {
        std.process.exit(1);
    }
}

fn fmtPath(fmt: *Fmt, file_path: []const u8, dir: Io.Dir, sub_path: []const u8) !void {
    fmtPathFile(fmt, file_path, dir, sub_path) catch |err| switch (err) {
        error.IsDir, error.AccessDenied => return fmtPathDir(fmt, file_path, dir, sub_path),
        else => {
            std.log.err("unable to format '{s}': {s}", .{ file_path, @errorName(err) });
            fmt.any_error = true;
            return;
        },
    };
}

fn fmtPathDir(
    fmt: *Fmt,
    file_path: []const u8,
    parent_dir: Io.Dir,
    parent_sub_path: []const u8,
) !void {
    const io = fmt.io;

    var dir = try parent_dir.openDir(io, parent_sub_path, .{ .iterate = true });
    defer dir.close(io);

    const stat = try dir.stat(io);
    if (try fmt.seen.fetchPut(stat.inode, {})) |_| return;

    var dir_it = dir.iterate();
    while (try dir_it.next(io)) |entry| {
        const is_dir = entry.kind == .directory;

        if (mem.startsWith(u8, entry.name, ".")) continue;

        if (is_dir or entry.kind == .file and (mem.endsWith(u8, entry.name, ".zig") or mem.endsWith(u8, entry.name, ".zon"))) {
            const full_path = try fs.path.join(fmt.gpa, &[_][]const u8{ file_path, entry.name });
            defer fmt.gpa.free(full_path);

            if (is_dir) {
                try fmtPathDir(fmt, full_path, dir, entry.name);
            } else {
                fmtPathFile(fmt, full_path, dir, entry.name) catch |err| {
                    std.log.err("unable to format '{s}': {s}", .{ full_path, @errorName(err) });
                    fmt.any_error = true;
                    return;
                };
            }
        }
    }
}

fn fmtPathFile(
    fmt: *Fmt,
    file_path: []const u8,
    dir: Io.Dir,
    sub_path: []const u8,
) !void {
    const io = fmt.io;

    const source_file = try dir.openFile(io, sub_path, .{});
    var file_closed = false;
    errdefer if (!file_closed) source_file.close(io);

    const stat = try source_file.stat(io);

    if (stat.kind == .directory)
        return error.IsDir;

    var read_buffer: [1024]u8 = undefined;
    var file_reader: Io.File.Reader = source_file.reader(io, &read_buffer);
    file_reader.size = stat.size;

    const gpa = fmt.gpa;
    const source_code = std.zig.readSourceFileToEndAlloc(gpa, &file_reader) catch |err| switch (err) {
        error.ReadFailed => return file_reader.err.?,
        else => |e| return e,
    };
    defer gpa.free(source_code);

    source_file.close(io);
    file_closed = true;

    if (try fmt.seen.fetchPut(stat.inode, {})) |_| return;

    const mode: std.zig.Ast.Mode = mode: {
        if (fmt.force_zon) break :mode .zon;
        if (mem.endsWith(u8, sub_path, ".zon")) break :mode .zon;
        break :mode .zig;
    };
    var tree = try std.zig.Ast.parse(gpa, source_code, mode);
    defer tree.deinit(gpa);
    if (tree.errors.len != 0) {
        try std.zig.printAstErrorsToStderr(gpa, io, tree, file_path, fmt.color);
        fmt.any_error = true;
        return;
    }

    if (fmt.check_ast) {
        if (stat.size > std.zig.max_src_size)
            return error.FileTooBig;

        switch (mode) {
            .zig => {
                var zir = try std.zig.AstGen.generate(gpa, tree);
                defer zir.deinit(gpa);

                if (zir.hasCompileErrors()) {
                    var wip_errors: std.zig.ErrorBundle.Wip = undefined;
                    try wip_errors.init(gpa);
                    defer wip_errors.deinit();
                    try wip_errors.addZirErrorMessages(zir, tree, source_code, file_path);
                    var error_bundle = try wip_errors.toOwnedBundle("");
                    defer error_bundle.deinit(gpa);
                    try error_bundle.renderToStderr(io, .{}, fmt.color);
                    fmt.any_error = true;
                }
            },
            .zon => {
                var zoir = try std.zig.ZonGen.generate(gpa, tree, .{});
                defer zoir.deinit(gpa);

                if (zoir.hasCompileErrors()) {
                    var wip_errors: std.zig.ErrorBundle.Wip = undefined;
                    try wip_errors.init(gpa);
                    defer wip_errors.deinit();
                    try wip_errors.addZoirErrorMessages(zoir, tree, source_code, file_path);
                    var error_bundle = try wip_errors.toOwnedBundle("");
                    defer error_bundle.deinit(gpa);
                    try error_bundle.renderToStderr(io, .{}, fmt.color);
                    fmt.any_error = true;
                }
            },
        }
    }

    fmt.out_buffer.clearRetainingCapacity();
    try fmt.out_buffer.ensureTotalCapacity(source_code.len);

    tree.render(gpa, &fmt.out_buffer.writer, .{}) catch |err| switch (err) {
        error.WriteFailed, error.OutOfMemory => return error.OutOfMemory,
    };

    const rendered = fmt.out_buffer.written();
    const formatted: []const u8 = if (fmt.config.brace_style == .allman) blk: {
        break :blk try convertToAllman(gpa, rendered);
    } else rendered;
    defer if (fmt.config.brace_style == .allman) gpa.free(formatted);

    if (mem.eql(u8, formatted, source_code))
        return;

    if (fmt.check_mode) {
        try fmt.stdout_writer.interface.print("{s}\n", .{file_path});
        fmt.any_error = true;
    } else {
        var af = try dir.createFileAtomic(io, sub_path, .{ .permissions = stat.permissions, .replace = true });
        defer af.deinit(io);

        try af.file.writeStreamingAll(io, formatted);
        try af.replace(io);
        try fmt.stdout_writer.interface.print("{s}\n", .{file_path});
    }
}

/// Converts K&R brace style to Allman style by post-processing rendered output.
///
/// Moves opening braces to their own line and separates `} else`/`} catch`
/// clauses onto individual lines. Struct/tuple literals (`.{`) and empty
/// blocks (`{}`) are left unchanged.
pub fn convertToAllman(gpa: Allocator, input: []const u8) Allocator.Error![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(gpa);

    try output.ensureTotalCapacity(gpa, input.len + input.len / 4);

    var line_start: usize = 0;
    while (line_start < input.len) {
        const line_end = mem.indexOfScalar(u8, input[line_start..], '\n') orelse input.len - line_start;
        const full_line = input[line_start .. line_start + line_end];
        line_start += line_end + 1;

        const trimmed = mem.trimEnd(u8, full_line, " ");
        if (trimmed.len == 0) {
            try output.appendSlice(gpa, full_line);
            if (line_start <= input.len) try output.append(gpa, '\n');
            continue;
        }

        const indent_len = leadingSpaces(full_line);
        const indent = full_line[0..indent_len];
        const content = full_line[indent_len..trimmed.len];

        if (tryHandleElseCatch(gpa, &output, indent, content) catch return error.OutOfMemory) {
            if (line_start <= input.len) try output.append(gpa, '\n');
            continue;
        }

        if (tryHandleTrailingBrace(gpa, &output, indent, content) catch return error.OutOfMemory) {
            if (line_start <= input.len) try output.append(gpa, '\n');
            continue;
        }

        try output.appendSlice(gpa, full_line);
        if (line_start <= input.len) try output.append(gpa, '\n');
    }

    return output.toOwnedSlice(gpa);
}

fn leadingSpaces(line: []const u8) usize {
    for (line, 0..) |c, i| {
        if (c != ' ') return i;
    }
    return line.len;
}

/// Handles lines starting with `} else` or `} catch`.
/// Splits into `}`, the clause, and optionally `{` on separate lines.
fn tryHandleElseCatch(gpa: Allocator, output: *std.ArrayList(u8), indent: []const u8, content: []const u8) !bool {
    if (content.len < 3 or content[0] != '}' or content[1] != ' ') return false;

    const rest = content[2..];
    const is_else = mem.startsWith(u8, rest, "else");
    const is_catch = mem.startsWith(u8, rest, "catch");
    if (!is_else and !is_catch) return false;

    // Emit closing brace on its own line.
    try output.appendSlice(gpa, indent);
    try output.append(gpa, '}');
    try output.append(gpa, '\n');

    // Check if the rest ends with " {" (and it's not ".{" or "{}").
    if (endsWithBlockBrace(rest)) {
        const rest_without_brace = mem.trimEnd(u8, rest[0 .. rest.len - 2], " ");
        try output.appendSlice(gpa, indent);
        try output.appendSlice(gpa, rest_without_brace);
        try output.append(gpa, '\n');
        try output.appendSlice(gpa, indent);
        try output.append(gpa, '{');
    } else {
        try output.appendSlice(gpa, indent);
        try output.appendSlice(gpa, rest);
    }

    return true;
}

/// Handles lines whose content ends with ` {` (a block-opening brace).
/// Moves the brace to a new line with the same indentation.
fn tryHandleTrailingBrace(gpa: Allocator, output: *std.ArrayList(u8), indent: []const u8, content: []const u8) !bool {
    if (!endsWithBlockBrace(content)) return false;

    const without_brace = mem.trimEnd(u8, content[0 .. content.len - 2], " ");
    try output.appendSlice(gpa, indent);
    try output.appendSlice(gpa, without_brace);
    try output.append(gpa, '\n');
    try output.appendSlice(gpa, indent);
    try output.append(gpa, '{');

    return true;
}

/// Returns true when `content` ends with a block-opening brace:
/// trailing ` {` that is NOT `.{` (struct literal) and NOT `{}` (empty block).
fn endsWithBlockBrace(content: []const u8) bool {
    if (content.len < 2) return false;
    if (!mem.endsWith(u8, content, " {")) return false;
    // Reject `.{` struct/tuple literals.
    if (content.len >= 3 and content[content.len - 3] == '.') return false;
    return true;
}

// TODO: Move these tests as integration tests as double fixtures of input and expected files.
test "allman: function definition" {
    const gpa = std.testing.allocator;
    const input = "fn main() void {\n    return;\n}\n";
    const expected = "fn main() void\n{\n    return;\n}\n";
    const result = try convertToAllman(gpa, input);
    defer gpa.free(result);
    try std.testing.expectEqualStrings(expected, result);
}

test "allman: if-else" {
    const gpa = std.testing.allocator;
    const input = "    if (cond) {\n        body;\n    } else {\n        other;\n    }\n";
    const expected = "    if (cond)\n    {\n        body;\n    }\n    else\n    {\n        other;\n    }\n";
    const result = try convertToAllman(gpa, input);
    defer gpa.free(result);
    try std.testing.expectEqualStrings(expected, result);
}

test "allman: else-if chain" {
    const gpa = std.testing.allocator;
    const input = "    } else if (b) {\n";
    const expected = "    }\n    else if (b)\n    {\n";
    const result = try convertToAllman(gpa, input);
    defer gpa.free(result);
    try std.testing.expectEqualStrings(expected, result);
}

test "allman: struct literal untouched" {
    const gpa = std.testing.allocator;
    const input = "    const x = .{ .a = 1 };\n";
    const result = try convertToAllman(gpa, input);
    defer gpa.free(result);
    try std.testing.expectEqualStrings(input, result);
}

test "allman: empty block untouched" {
    const gpa = std.testing.allocator;
    const input = "    if (cond) {}\n";
    const result = try convertToAllman(gpa, input);
    defer gpa.free(result);
    try std.testing.expectEqualStrings(input, result);
}

test "allman: catch with capture" {
    const gpa = std.testing.allocator;
    const input = "    } catch |err| {\n";
    const expected = "    }\n    catch |err|\n    {\n";
    const result = try convertToAllman(gpa, input);
    defer gpa.free(result);
    try std.testing.expectEqualStrings(expected, result);
}
