//! Core library for the Docent CLI: documentation, style, and complexity checks for Zig projects.

const std = @import("std");

const path_utils = @import("rules/utils.zig");

pub const Diagnostic = @import("Diagnostic.zig");
pub const LintResult = @import("LintResult.zig");
pub const output = @import("output.zig");
pub const reachability = @import("reachability.zig");
pub const RuleSet = @import("RuleSet.zig");
pub const rule_metadata = @import("rule_metadata.zig");
pub const scaffold = @import("scaffold.zig");
pub const addLintStep = scaffold.addLintStep;
pub const SeverityLevel = @import("severity.zig").Level;
pub const manifest = @import("manifest.zig");
pub const config = @import("config.zig");
pub const targeting = @import("targeting.zig");
pub const status_plan = @import("status_plan.zig");
pub const build_scan = @import("build_scan.zig");
pub const LintOptions = @import("LintOptions.zig");
pub const ComplexityOptions = @import("ComplexityOptions.zig");
pub const rules = @import("rules.zig");

// pub const myError = error{ hola_bola, Mambo };

/// Returns whether the file-level `//!` check applies to `path`.
///
/// Enabled when `path` is a known module entry root or the basename is `root.zig`.
pub fn resolveRequireModuleDoc(path: []const u8, library_entry_roots: []const []const u8) bool {
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

    const require_module_doc = resolveRequireModuleDoc(file_owned, library_entry_roots);

    try rules.docs.missing_doc_comment.check(
        &tree,
        rule_set.missing_doc_comment,
        file_owned,
        require_module_doc,
        options.module_name,
        options.public_api_only,
        allocator,
        io,
        msg,
        &result.diagnostics,
    );
    try rules.docs.blank_doc_comment.check(
        &tree,
        rule_set.blank_doc_comment,
        file_owned,
        options.module_name,
        allocator,
        msg,
        &result.diagnostics,
    );
    try rules.docs.missing_summary_terminal_punctuation.check(
        &tree,
        rule_set.missing_summary_terminal_punctuation,
        file_owned,
        options.module_name,
        allocator,
        msg,
        &result.diagnostics,
    );
    try rules.docs.trailing_blank_doc_comment.check(
        &tree,
        rule_set.trailing_blank_doc_comment,
        file_owned,
        options.module_name,
        allocator,
        msg,
        &result.diagnostics,
    );
    try rules.docs.missing_doctest.check(&tree, rule_set.missing_doctest, file_owned, options.public_api_only, allocator, msg, &result.diagnostics);
    try rules.docs.private_doctest.check(&tree, rule_set.private_doctest, file_owned, allocator, msg, &result.diagnostics);
    try rules.docs.doctest_naming_mismatch.check(&tree, rule_set.doctest_naming_mismatch, file_owned, options.public_api_only, allocator, msg, &result.diagnostics);
    try rules.docs.invalid_leading_phrase.check(
        &tree,
        rule_set.invalid_leading_phrase,
        file_owned,
        options.module_name,
        options.public_api_only,
        allocator,
        msg,
        &result.diagnostics,
    );

    return result;
}

/// Runs the complexity rules over in-memory Zig source and returns their diagnostics.
///
/// Unlike `lintSource`, this is driven by the `docent complexity` sub-command rather than the default lint run.
pub fn lintComplexitySource(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    rule_set: RuleSet,
    file: []const u8,
    options: LintOptions,
    complexity_options: ComplexityOptions,
) !LintResult {
    var tree = try std.zig.Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);

    var result = LintResult.init(allocator);
    errdefer result.deinit();

    const msg = result.messageAllocator();
    const file_owned = try path_utils.normalizePathSeparators(msg, file);

    try rules.complexity.cognitive.check(
        &tree,
        rule_set.cognitive_complexity,
        file_owned,
        options.public_api_only,
        complexity_options.cognitive_threshold,
        allocator,
        msg,
        &result.diagnostics,
    );

    return result;
}

/// Runs the style rules over in-memory Zig source and returns their diagnostics.
///
/// Unlike `lintSource`, this is driven by the `docent style` sub-command rather than the default lint run.
pub fn lintStyleSource(
    allocator: std.mem.Allocator,
    io: std.Io,
    source: [:0]const u8,
    rule_set: RuleSet,
    file: []const u8,
    options: LintOptions,
) !LintResult {
    var tree = try std.zig.Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);

    var result = LintResult.init(allocator);
    errdefer result.deinit();

    const msg = result.messageAllocator();
    const file_owned = try path_utils.normalizePathSeparators(msg, file);

    try rules.style.identifier_case.check(
        &tree,
        rule_set.identifier_case,
        file_owned,
        options.public_api_only,
        allocator,
        io,
        msg,
        &result.diagnostics,
    );

    return result;
}

/// Reads `path` from the cwd and runs `lintStyleSource` on its contents.
pub fn lintStyleFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    rule_set: RuleSet,
    options: LintOptions,
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

    return lintStyleSource(allocator, io, source, rule_set, path, options);
}

/// Reads `path` from the cwd and runs `lintComplexitySource` on its contents.
pub fn lintComplexityFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    rule_set: RuleSet,
    options: LintOptions,
    complexity_options: ComplexityOptions,
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

    return lintComplexitySource(allocator, source, rule_set, path, options, complexity_options);
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
