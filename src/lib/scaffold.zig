const std = @import("std");
const docent = @import("root.zig");

pub const LintStep = struct {
    step: std.Build.Step,
    sources: []const []const u8,
    rule_set: docent.RuleSet,
    exclude: []const []const u8,
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
            .output = options.output,
        };
        return self;
    }

    fn make(step: *std.Build.Step, _: std.Build.Step.MakeOptions) anyerror!void {
        const self: *LintStep = @fieldParentPtr("step", step);
        const allocator = step.owner.allocator;

        var summary: docent.output.Summary = .{};
        var total_files: usize = 0;

        for (self.sources) |source_path| {
            const stat = std.fs.cwd().statFile(source_path) catch |err| {
                if (err == error.IsDir) {
                    try self.lintDirectory(allocator, source_path, step, &summary, &total_files);
                    continue;
                }
                step.result_error_msgs.append(
                    allocator,
                    std.fmt.allocPrint(allocator, "cannot access '{s}': {}", .{ source_path, err }) catch @panic("OOM"),
                ) catch @panic("OOM");
                return error.MakeFailed;
            };

            if (stat.kind == .directory) {
                try self.lintDirectory(allocator, source_path, step, &summary, &total_files);
            } else {
                try self.lintSingleFile(allocator, source_path, step, &summary, &total_files);
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

    fn lintDirectory(self: *LintStep, allocator: std.mem.Allocator, dir_path: []const u8, step: *std.Build.Step, summary: *docent.output.Summary, total_files: *usize) !void {
        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| {
            step.result_error_msgs.append(
                allocator,
                std.fmt.allocPrint(allocator, "cannot open directory '{s}': {}", .{ dir_path, err }) catch @panic("OOM"),
            ) catch @panic("OOM");
            return error.MakeFailed;
        };
        defer dir.close();

        var walker = try dir.walk(allocator);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;

            const full_path = std.fs.path.join(allocator, &.{ dir_path, entry.path }) catch @panic("OOM");
            defer allocator.free(full_path);

            if (self.isExcluded(full_path)) continue;

            try self.lintSingleFile(allocator, full_path, step, summary, total_files);
        }
    }

    fn lintSingleFile(self: *LintStep, allocator: std.mem.Allocator, path: []const u8, step: *std.Build.Step, summary: *docent.output.Summary, total_files: *usize) !void {
        var result = docent.lintFile(allocator, path, self.rule_set) catch |err| {
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
                    try docent.output.printDiagnosticStderr(d, docent.output.stderrTextOptions(self.output.format, self.output.color));
                },
                .deny, .forbid => {
                    file_has_errors = true;
                    try docent.output.printDiagnosticStderr(d, docent.output.stderrTextOptions(self.output.format, self.output.color));
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
    output: OutputOptions = .{},
};

pub const OutputOptions = struct {
    format: docent.output.TextFormat = .pretty,
    color: docent.output.ColorMode = .auto,
};

pub fn addLintStep(b: *std.Build, options: Options) *LintStep {
    return LintStep.create(b, options);
}
