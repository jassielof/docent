const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const fs = std.fs;
const Allocator = std.mem.Allocator;
const Color = std.zig.Color;

const config_mod = @import("config.zig");
const SchemaConfig = @import("schemas/Config.zig");

pub const Config = SchemaConfig.Fmt;
pub const BraceStyle = Config.BraceStyle;

pub const Options = struct {
    check: bool = false,
    ast_check: bool = false,
    zon: bool = false,
    color: Color = .auto,
};

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

const Fmt = @This();
const SeenMap = std.AutoHashMap(Io.File.INode, void);

pub fn loadConfig(gpa: Allocator, io: Io) Config {
    const cfg = config_mod.loadConfigFromCli(gpa, io, null) catch return .{};
    return cfg.fmt;
}

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

    const pp = try applyPostProcessing(gpa, rendered, config);
    defer if (pp.allocated) gpa.free(pp.output);

    if (opts.check) {
        const code: u8 = @intFromBool(!mem.eql(u8, pp.output, source_code));
        std.process.exit(code);
    }

    return Io.File.stdout().writeStreamingAll(io, pp.output);
}

pub fn formatPaths(self: *Fmt, input_files: []const []const u8, excluded_files: []const []const u8) !void {
    for (excluded_files) |file_path| {
        const stat = Io.Dir.cwd().statFile(self.io, file_path, .{}) catch |err| switch (err) {
            error.FileNotFound => continue,
            error.IsDir => dir: {
                var dir = try Io.Dir.cwd().openDir(self.io, file_path, .{});
                defer dir.close(self.io);
                break :dir try dir.stat(self.io);
            },
            else => |e| return e,
        };
        try self.seen.put(stat.inode, {});
    }

    for (input_files) |file_path| {
        try self.fmtPath(file_path, Io.Dir.cwd(), file_path);
    }
    try self.stdout_writer.interface.flush();
    if (self.any_error) {
        std.process.exit(1);
    }
}

fn fmtPath(self: *Fmt, file_path: []const u8, dir: Io.Dir, sub_path: []const u8) !void {
    self.fmtPathFile(file_path, dir, sub_path) catch |err| switch (err) {
        error.IsDir, error.AccessDenied => return self.fmtPathDir(file_path, dir, sub_path),
        else => {
            std.log.err("unable to format '{s}': {s}", .{ file_path, @errorName(err) });
            self.any_error = true;
            return;
        },
    };
}

fn fmtPathDir(
    self: *Fmt,
    file_path: []const u8,
    parent_dir: Io.Dir,
    parent_sub_path: []const u8,
) !void {
    const io = self.io;

    var dir = try parent_dir.openDir(io, parent_sub_path, .{ .iterate = true });
    defer dir.close(io);

    const stat = try dir.stat(io);
    if (try self.seen.fetchPut(stat.inode, {})) |_| return;

    var dir_it = dir.iterate();
    while (try dir_it.next(io)) |entry| {
        const is_dir = entry.kind == .directory;

        if (mem.startsWith(u8, entry.name, ".")) continue;

        if (is_dir or entry.kind == .file and (mem.endsWith(u8, entry.name, ".zig") or mem.endsWith(u8, entry.name, ".zon"))) {
            const full_path = try fs.path.join(self.gpa, &[_][]const u8{ file_path, entry.name });
            defer self.gpa.free(full_path);

            if (is_dir) {
                try self.fmtPathDir(full_path, dir, entry.name);
            } else {
                self.fmtPathFile(full_path, dir, entry.name) catch |err| {
                    std.log.err("unable to format '{s}': {s}", .{ full_path, @errorName(err) });
                    self.any_error = true;
                    return;
                };
            }
        }
    }
}

fn fmtPathFile(
    self: *Fmt,
    file_path: []const u8,
    dir: Io.Dir,
    sub_path: []const u8,
) !void {
    const io = self.io;

    const source_file = try dir.openFile(io, sub_path, .{});
    var file_closed = false;
    errdefer if (!file_closed) source_file.close(io);

    const stat = try source_file.stat(io);

    if (stat.kind == .directory)
        return error.IsDir;

    var read_buffer: [1024]u8 = undefined;
    var file_reader: Io.File.Reader = source_file.reader(io, &read_buffer);
    file_reader.size = stat.size;

    const gpa = self.gpa;
    const source_code = std.zig.readSourceFileToEndAlloc(gpa, &file_reader) catch |err| switch (err) {
        error.ReadFailed => return file_reader.err.?,
        else => |e| return e,
    };
    defer gpa.free(source_code);

    source_file.close(io);
    file_closed = true;

    if (try self.seen.fetchPut(stat.inode, {})) |_| return;

    const mode: std.zig.Ast.Mode = mode: {
        if (self.force_zon) break :mode .zon;
        if (mem.endsWith(u8, sub_path, ".zon")) break :mode .zon;
        break :mode .zig;
    };
    var tree = try std.zig.Ast.parse(gpa, source_code, mode);
    defer tree.deinit(gpa);
    if (tree.errors.len != 0) {
        try std.zig.printAstErrorsToStderr(gpa, io, tree, file_path, self.color);
        self.any_error = true;
        return;
    }

    if (self.check_ast) {
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
                    try error_bundle.renderToStderr(io, .{}, self.color);
                    self.any_error = true;
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
                    try error_bundle.renderToStderr(io, .{}, self.color);
                    self.any_error = true;
                }
            },
        }
    }

    self.out_buffer.clearRetainingCapacity();
    try self.out_buffer.ensureTotalCapacity(source_code.len);

    tree.render(gpa, &self.out_buffer.writer, .{}) catch |err| switch (err) {
        error.WriteFailed, error.OutOfMemory => return error.OutOfMemory,
    };

    const rendered = self.out_buffer.written();
    const pp = try applyPostProcessing(gpa, rendered, self.config);
    defer if (pp.allocated) gpa.free(pp.output);

    if (mem.eql(u8, pp.output, source_code))
        return;

    if (self.check_mode) {
        try self.stdout_writer.interface.print("{s}\n", .{file_path});
        self.any_error = true;
    } else {
        var af = try dir.createFileAtomic(io, sub_path, .{ .permissions = stat.permissions, .replace = true });
        defer af.deinit(io);

        try af.file.writeStreamingAll(io, pp.output);
        try af.replace(io);
        try self.stdout_writer.interface.print("{s}\n", .{file_path});
    }
}

pub const brace_style = @import("fmt/brace_style.zig");
pub const convertToAllman = brace_style.convertToAllman;
pub const single_line_braces = @import("fmt/single_line_braces.zig");
pub const enforceBraces = single_line_braces.enforceBraces;
pub const trailing_comma = @import("fmt/trailing_comma.zig");
pub const addTrailingCommas = trailing_comma.addTrailingCommas;
pub const logical_blank_lines = @import("fmt/logical_blank_lines.zig");
pub const enforceLogicalBlankLines = logical_blank_lines.enforceLogicalBlankLines;
pub const sort_imports = @import("fmt/sort_imports.zig");
pub const sortImports = sort_imports.sortImports;
pub const indent_width = @import("fmt/indent_width.zig");
pub const reindent = indent_width.reindent;

/// Applies all configured post-processing passes to rendered source.
/// Caller owns the returned slice when it differs from `input`.
fn applyPostProcessing(gpa: Allocator, input: []const u8, config: Config) Allocator.Error!struct { output: []const u8, allocated: bool } {
    var current: []const u8 = input;
    var current_allocated = false;

    if (config.sort_imports) {
        const result = try sortImports(gpa, current);
        if (current_allocated) gpa.free(current);
        current = result;
        current_allocated = true;
    }

    if (config.trailing_comma) {
        const result = try addTrailingCommas(gpa, current);
        if (current_allocated) gpa.free(current);
        current = result;
        current_allocated = true;
    }

    if (config.single_line_braces) {
        const result = try enforceBraces(gpa, current);
        if (current_allocated) gpa.free(current);
        current = result;
        current_allocated = true;
    }

    if (config.brace_style == .allman) {
        const result = try convertToAllman(gpa, current);
        if (current_allocated) gpa.free(current);
        current = result;
        current_allocated = true;
    }

    if (config.logical_blank_lines) {
        const result = try enforceLogicalBlankLines(gpa, current);
        if (current_allocated) gpa.free(current);
        current = result;
        current_allocated = true;
    }

    if (config.indent_width != 4) {
        const result = try reindent(gpa, current, config.indent_width);
        if (current_allocated) gpa.free(current);
        current = result;
        current_allocated = true;
    }

    return .{ .output = current, .allocated = current_allocated };
}
