//! Documentation linter for Zig projects.

const std = @import("std");

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

/// Per-file options for `lintSource` / `lintFile`.
pub const LintOptions = struct {
    /// When true, require a file-level `//!` doc comment for this source file.
    require_module_doc: bool = false,
};

pub const Rules = struct {
    pub const missing_doc_comment = @import("rules/missing_doc_comment.zig");
    pub const empty_doc_comment = @import("rules/empty_doc_comment.zig");
    pub const missing_doctest = @import("rules/missing_doctest.zig");
    pub const private_doctest = @import("rules/private_doctest.zig");
    pub const doctest_naming_mismatch = @import("rules/doctest_naming_mismatch.zig");
    // COMPAT: //! top-level doc comments — remove if deprecated in 0.16
    // Top level comments might be moved to simply:
    // /// <Doc comment content>
    // const Self = @This()
    pub const missing_container_doc_comment = @import("rules/missing_container_doc_comment.zig");
};

/// Returns whether the file-level `//!` check should run for `path`.
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
    const require_module_doc = resolveRequireModuleDoc(file, options, library_entry_roots);

    try Rules.missing_doc_comment.check(&tree, rule_set.missing_doc_comment, file, allocator, io, msg, &result.diagnostics);
    try Rules.empty_doc_comment.check(&tree, rule_set.empty_doc_comment, file, allocator, msg, &result.diagnostics);
    try Rules.missing_doctest.check(&tree, rule_set.missing_doctest, file, allocator, msg, &result.diagnostics);
    try Rules.private_doctest.check(&tree, rule_set.private_doctest, file, allocator, msg, &result.diagnostics);
    try Rules.doctest_naming_mismatch.check(&tree, rule_set.doctest_naming_mismatch, file, allocator, msg, &result.diagnostics);
    // COMPAT: //! top-level doc comments — remove if deprecated in 0.16
    try Rules.missing_container_doc_comment.check(
        &tree,
        rule_set.missing_container_doc_comment,
        file,
        require_module_doc,
        allocator,
        msg,
        &result.diagnostics,
    );

    return result;
}

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
