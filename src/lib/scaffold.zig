const std = @import("std");
const docent = @import("root.zig");

pub const LintStep = struct {
    step: std.Build.Step,
    sources: []const []const u8,
    rule_set: docent.RuleSet,
    exclude: []const []const u8,
    include_build_scripts: bool,
    output: OutputOptions,

    pub fn create(b: *std.Build, options: Options) *LintStep {
        const self = b.allocator.create(LintStep) catch @panic("OOM");
        self.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = "docent",
                .owner = b,
                .makeFn = make,
            }),
            .sources = b.allocator.dupe([]const u8, options.sources) catch @panic("OOM"),
            .rule_set = options.rules,
            .exclude = if (options.exclude) |ex| b.allocator.dupe([]const u8, ex) catch @panic("OOM") else &.{},
            .include_build_scripts = options.include_build_scripts,
            .output = options.output,
        };
        return self;
    }

    fn make(step: *std.Build.Step, _: std.Build.Step.MakeOptions) anyerror!void {
        const self: *LintStep = @fieldParentPtr("step", step);
        const allocator = step.owner.allocator;
        const io = step.owner.graph.io;

        const path_display_root: ?[]const u8 = realPathFileAlloc(allocator, io, ".") catch null;
        defer if (path_display_root) |p| allocator.free(p);

        var summary: docent.output.Summary = .{};
        var total_files: usize = 0;

        for (self.sources) |source_path| {
            const stat = std.Io.Dir.cwd().statFile(io, source_path, .{}) catch |err| {
                if (err == error.IsDir) {
                    try self.lintDirectory(allocator, io, source_path, step, &summary, &total_files, path_display_root);
                    continue;
                }
                step.result_error_msgs.append(
                    allocator,
                    std.fmt.allocPrint(allocator, "cannot access '{s}': {}", .{ source_path, err }) catch @panic("OOM"),
                ) catch @panic("OOM");
                return error.MakeFailed;
            };

            if (stat.kind == .directory) {
                try self.lintDirectory(allocator, io, source_path, step, &summary, &total_files, path_display_root);
            } else {
                if (docent.targeting.shouldSkipLintFile(source_path, .{ .include_build_scripts = self.include_build_scripts })) continue;
                try self.lintSingleFile(allocator, io, source_path, step, &summary, &total_files, path_display_root);
            }
        }

        if (summary.errors > 0) {
            step.result_error_msgs.append(
                allocator,
                std.fmt.allocPrint(allocator, "doc_lint: {d} error(s), {d} warning(s) in {d} file(s)", .{ summary.errors, summary.warnings, total_files }) catch @panic("OOM"),
            ) catch @panic("OOM");
            return error.MakeFailed;
        }
    }

    fn lintDirectory(self: *LintStep, allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8, step: *std.Build.Step, summary: *docent.output.Summary, total_files: *usize, path_display_root: ?[]const u8) !void {
        var targets = docent.targeting.collectDirectoryLintTargets(
            allocator,
            io,
            dir_path,
            .{ .include_build_scripts = self.include_build_scripts },
        ) catch |err| {
            step.result_error_msgs.append(
                allocator,
                std.fmt.allocPrint(allocator, "cannot collect lint targets in '{s}': {}", .{ dir_path, err }) catch @panic("OOM"),
            ) catch @panic("OOM");
            return error.MakeFailed;
        };
        defer docent.targeting.deinitOwnedPaths(allocator, &targets);

        for (targets.items) |full_path| {
            if (self.isExcluded(full_path)) continue;
            try self.lintSingleFile(allocator, io, full_path, step, summary, total_files, path_display_root);
        }
    }

    fn lintSingleFile(self: *LintStep, allocator: std.mem.Allocator, io: std.Io, path: []const u8, step: *std.Build.Step, summary: *docent.output.Summary, total_files: *usize, path_display_root: ?[]const u8) !void {
        var result = docent.lintFile(allocator, io, path, self.rule_set) catch |err| {
            step.result_error_msgs.append(
                allocator,
                std.fmt.allocPrint(allocator, "failed to lint '{s}': {}", .{ path, err }) catch @panic("OOM"),
            ) catch @panic("OOM");
            return error.MakeFailed;
        };
        defer result.deinit();

        var file_has_errors = false;
        for (result.diagnostics.items) |d| {
            summary.observe(d);
            switch (d.severity) {
                .allow => continue,
                .warn => {
                    try docent.output.printDiagnosticStderr(io, d, docent.output.stderrTextOptions(io, self.output.format, self.output.color, path_display_root));
                },
                .deny, .forbid => {
                    file_has_errors = true;
                    try docent.output.printDiagnosticStderr(io, d, docent.output.stderrTextOptions(io, self.output.format, self.output.color, path_display_root));
                },
            }
        }
        if (file_has_errors) total_files.* += 1;
    }

    fn isExcluded(self: *LintStep, path: []const u8) bool {
        for (self.exclude) |pattern| {
            if (std.mem.indexOf(u8, path, pattern) != null) return true;
        }
        return false;
    }
};

pub const Options = struct {
    sources: []const []const u8,
    rules: docent.RuleSet = .{},
    exclude: ?[]const []const u8 = null,
    include_build_scripts: bool = false,
    output: OutputOptions = .{},
};

pub const OutputOptions = struct {
    format: docent.output.TextFormat = .pretty,
    color: docent.output.ColorMode = .auto,
};

pub fn addLintStep(b: *std.Build, options: Options) *LintStep {
    return LintStep.create(b, options);
}

fn realPathFileAlloc(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try std.Io.Dir.cwd().realPathFile(io, path, &buffer);
    return allocator.dupe(u8, buffer[0..len]);
}
