//! Documentation linter for Zig projects.

const std = @import("std");

const path_utils = @import("rules/utils.zig");

pub const Diagnostic = @import("Diagnostic.zig");
pub const LintResult = @import("LintResult.zig");
pub const output = @import("Output.zig");
pub const reachability = @import("Reachability.zig");
pub const RuleSet = @import("RuleSet.zig");
pub const rule_metadata = @import("rule_metadata.zig");
pub const scaffold = @import("scaffold.zig");
pub const addLintStep = scaffold.addLintStep;
pub const Severity = @import("Severity.zig").Level;
pub const manifest = @import("Manifest.zig");
pub const targeting = @import("Targeting.zig");
pub const status_plan = @import("StatusPlan.zig");
pub const build_scan = @import("BuildScan.zig");
pub const LintOptions = @import("LintOptions.zig");
pub const rules = @import("rules.zig");

/// Returns whether the file-level `//!` check applies to `path`.
///
/// Enabled when `options.require_module_doc` is set, when `path` is a library entry root from `collectLibraryEntryRoots`, or when the basename is `root.zig`.
pub fn resolveRequireModuleDoc(
    path: []const u8,
    options: LintOptions,
    library_entry_roots: []const []const u8,
) bool {
    if (options.require_module_doc) return true;
    for (library_entry_roots) |root| {
        if (targeting.pathsEqual(path, root)) return true;
    }

    return std.mem.eql(u8, std.fs.path.basename(path), "root.zig");
}

fn realPathFileAlloc(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try std.Io.Dir.cwd().realPathFile(io, path, &buffer);
    return allocator.dupe(u8, buffer[0..len]);
}

/// Collects canonical `root_source_file` paths for library targets from `build.zig`.
///
/// Caller owns the returned slice and each path string; free with `targeting.deinitOwnedPaths`.
pub fn collectLibraryEntryRoots(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
) ![]const []const u8 {
    var roots: std.ArrayList([]const u8) = .empty;
    errdefer targeting.deinitOwnedPaths(allocator, &roots);

    var scanned = try build_scan.scanProjectBuildScript(allocator, io, project_root);
    defer if (scanned) |*scan| scan.deinit(allocator);

    if (scanned) |scan| {
        for (scan.targets) |t| {
            if (t.kind != .lib) continue;

            const joined = if (std.fs.path.isAbsolute(t.root_source_file))
                try allocator.dupe(u8, t.root_source_file)
            else
                try std.fs.path.join(allocator, &.{ project_root, t.root_source_file });
            defer allocator.free(joined);

            const abs = realPathFileAlloc(allocator, io, joined) catch try allocator.dupe(u8, joined);
            try roots.append(allocator, abs);
        }
    }

    return try roots.toOwnedSlice(allocator);
}

/// Lints in-memory Zig source and returns all rule diagnostics.
///
/// `file` is the path stored on each diagnostic (normalized to forward slashes). Message and file strings live in the result's message arena until `deinit`.
pub fn lintSource(
    allocator: std.mem.Allocator,
    io: std.Io,
    source: [:0]const u8,
    rule_set: RuleSet,
    file: []const u8,
    options: LintOptions,
    library_entry_roots: []const []const u8,
) !LintResult {
    var tree = try std.zig.Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);

    var result = LintResult.init(allocator);
    errdefer result.deinit();

    const msg = result.messageAllocator();
    const file_owned = try path_utils.normalizePathSeparators(msg, file);

    const require_module_doc = resolveRequireModuleDoc(file_owned, options, library_entry_roots);

    try rules.missing_doc_comment.check(&tree, rule_set.missing_doc_comment, file_owned, allocator, io, msg, &result.diagnostics);
    try rules.empty_doc_comment.check(&tree, rule_set.empty_doc_comment, file_owned, allocator, msg, &result.diagnostics);
    try rules.missing_doctest.check(&tree, rule_set.missing_doctest, file_owned, allocator, msg, &result.diagnostics);
    try rules.private_doctest.check(&tree, rule_set.private_doctest, file_owned, allocator, msg, &result.diagnostics);
    try rules.doctest_naming_mismatch.check(&tree, rule_set.doctest_naming_mismatch, file_owned, allocator, msg, &result.diagnostics);
    // COMPAT: //! top-level doc comments — remove if deprecated in 0.16
    try rules.missing_container_doc_comment.check(
        &tree,
        rule_set.missing_container_doc_comment,
        file_owned,
        require_module_doc,
        allocator,
        msg,
        &result.diagnostics,
    );

    return result;
}

/// Reads `path` from the cwd and runs `lintSource` on its contents.
pub fn lintFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    rule_set: RuleSet,
    options: LintOptions,
    library_entry_roots: []const []const u8,
) !LintResult {
    const source = try std.Io.Dir.cwd().readFileAllocOptions(
        io,
        path,
        allocator,
        .limited(std.math.maxInt(u32)),
        .of(u8),
        0,
    );
    defer allocator.free(source);

    return lintSource(allocator, io, source, rule_set, path, options, library_entry_roots);
}

comptime {
    std.testing.refAllDecls(@This());
}
