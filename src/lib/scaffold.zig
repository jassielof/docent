const std = @import("std");
const doc_lint = @import("root.zig");

pub const LintStep = struct {
    step: std.Build.Step,
    sources: []const []const u8,
    rule_set: doc_lint.RuleSet,
    exclude: []const []const u8,

    pub fn create(b: *std.Build, options: Options) *LintStep {
        const self = b.allocator.create(LintStep) catch @panic("OOM");
        self.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = "doc_lint",
                .owner = b,
                .makeFn = make,
            }),
            .sources = b.allocator.dupe([]const u8, options.sources) catch @panic("OOM"),
            .rule_set = options.rules,
            .exclude = if (options.exclude) |ex| b.allocator.dupe([]const u8, ex) catch @panic("OOM") else &.{},
        };
        return self;
    }

    fn make(step: *std.Build.Step, _: std.Build.Step.MakeOptions) anyerror!void {
        const self: *LintStep = @fieldParentPtr("step", step);
        const allocator = step.owner.allocator;

        var total_errors: usize = 0;
        var total_files: usize = 0;

        for (self.sources) |source_path| {
            const stat = std.fs.cwd().statFile(source_path) catch |err| {
                if (err == error.IsDir) {
                    try self.lintDirectory(allocator, source_path, step, &total_errors, &total_files);
                    continue;
                }
                step.result_error_msgs.append(
                    allocator,
                    std.fmt.allocPrint(allocator, "cannot access '{s}': {}", .{ source_path, err }) catch @panic("OOM"),
                ) catch @panic("OOM");
                return error.MakeFailed;
            };

            if (stat.kind == .directory) {
                try self.lintDirectory(allocator, source_path, step, &total_errors, &total_files);
            } else {
                try self.lintSingleFile(allocator, source_path, step, &total_errors, &total_files);
            }
        }

        if (total_errors > 0) {
            step.result_error_msgs.append(
                allocator,
                std.fmt.allocPrint(allocator, "doc_lint: {d} error(s) in {d} file(s)", .{ total_errors, total_files }) catch @panic("OOM"),
            ) catch @panic("OOM");
            return error.MakeFailed;
        }
    }

    fn lintDirectory(self: *LintStep, allocator: std.mem.Allocator, dir_path: []const u8, step: *std.Build.Step, total_errors: *usize, total_files: *usize) !void {
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

            try self.lintSingleFile(allocator, full_path, step, total_errors, total_files);
        }
    }

    fn lintSingleFile(self: *LintStep, allocator: std.mem.Allocator, path: []const u8, step: *std.Build.Step, total_errors: *usize, total_files: *usize) !void {
        var result = doc_lint.lintFile(allocator, path, self.rule_set) catch |err| {
            step.result_error_msgs.append(
                allocator,
                std.fmt.allocPrint(allocator, "failed to lint '{s}': {}", .{ path, err }) catch @panic("OOM"),
            ) catch @panic("OOM");
            return error.MakeFailed;
        };
        defer result.deinit();

        var file_has_errors = false;
        for (result.diagnostics.items) |d| {
            switch (d.severity) {
                .allow => continue,
                .warn => {
                    // Warnings should be visible but must not fail the build step.
                    std.debug.print("warning: {s}:{d}:{d}: [{s}] {s}\n", .{
                        d.file,
                        d.line,
                        d.column,
                        d.rule,
                        d.message,
                    });
                },
                .deny, .forbid => {
                    file_has_errors = true;
                    total_errors.* += 1;
                    step.result_error_msgs.append(
                        allocator,
                        std.fmt.allocPrint(allocator, "{s}:{d}:{d}: error: [{s}] {s}", .{
                            d.file,
                            d.line,
                            d.column,
                            d.rule,
                            d.message,
                        }) catch @panic("OOM"),
                    ) catch @panic("OOM");
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
    rules: doc_lint.RuleSet = .{},
    exclude: ?[]const []const u8 = null,
};

pub fn addLintStep(b: *std.Build, options: Options) *LintStep {
    return LintStep.create(b, options);
}
