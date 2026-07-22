//! The Docent module serves as the core library for the Docent CLI for documentation, style, and complexity checks for Zig projects.

const std = @import("std");
const Ast = std.zig.Ast;

const vereda = @import("vereda");

pub const build_scan = @import("build_scan.zig");
pub const check_shared = @import("check_shared.zig");
pub const config = @import("config.zig");
pub const Diagnostic = @import("Diagnostic.zig");
pub const flags = @import("flags.zig");
pub const LintOptions = @import("LintOptions.zig");
pub const LintResult = @import("LintResult.zig");
pub const manifest = @import("manifest.zig");
pub const output = @import("output.zig");
pub const rule_config = @import("rule_config.zig");
pub const rule_metadata = @import("rule_metadata.zig");
pub const rules = @import("rules.zig");
pub const RuleSeverities = @import("RuleSeverities.zig");
pub const scaffold = @import("scaffold.zig");
pub const addLintStep = scaffold.addLintStep;
pub const scan = @import("scan.zig");
pub const Config = @import("schemas/Config.zig");
pub const severity = @import("severity.zig");
pub const SeverityLevel = severity.Level;
pub const status_plan = @import("status_plan.zig");
const suppressions = @import("suppressions.zig");
pub const Suppressions = suppressions.Table;
pub const types = @import("types.zig");

/// Returns whether the file-level `//!` check applies to `path`.
///
/// Enabled when `path` is a known module entry root or the basename is `root.zig`.
pub fn resolveRequireModuleDoc(path: []const u8, library_entry_roots: []const []const u8) bool {
    for (library_entry_roots) |root|
        if (scan.target.pathsEqual(path, root))
            return true;

    return std.mem.eql(
        u8,
        std.fs.path.basename(path),
        "root.zig",
    );
}

fn realPathFileAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) ![]u8 {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try std.Io.Dir.cwd().realPathFile(
        io,
        path,
        &buffer,
    );

    return allocator.dupe(u8, buffer[0..len]);
}

/// Collects canonical `root_source_file` paths for library targets from `build.zig`.
///
/// Caller owns the returned slice and each path string; free with `scan.target.deinitOwnedPaths`.
pub fn collectLibraryEntryRoots(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
) ![]const []const u8 {
    var roots: std.ArrayList([]const u8) = .empty;
    errdefer scan.target.deinitOwnedPaths(allocator, &roots);

    var scanned = try build_scan.scanProjectBuildScript(
        allocator,
        io,
        project_root,
    );
    defer if (scanned) |*sc| sc.deinit(allocator);

    if (scanned) |sc| {
        for (sc.targets) |t| {
            if (t.kind != .lib)
                continue;

            const joined = if (std.fs.path.isAbsolute(t.root_source_file))
                try allocator.dupe(u8, t.root_source_file)
            else
                try std.fs.path.join(allocator, &.{ project_root, t.root_source_file });
            defer allocator.free(joined);

            const abs = realPathFileAlloc(
                allocator,
                io,
                joined,
            ) catch
                try allocator.dupe(u8, joined);

            try roots.append(allocator, abs);
        }
    }

    return try roots.toOwnedSlice(allocator);
}

fn applySuppressions(
    allocator: std.mem.Allocator,
    tree: *const Ast,
    result: *LintResult,
) !void {
    var table = try suppressions.collectFromTree(allocator, tree);
    defer table.deinit(allocator);
    suppressions.filterDiagnostics(
        allocator,
        &result.diagnostics,
        &table,
    );
}

/// Lints in-memory Zig source and returns all rule diagnostics.
///
/// `file` is the path stored on each diagnostic (normalized to forward slashes). Message and file strings live in the result's message arena until `deinit`.
pub fn lintSource(
    allocator: std.mem.Allocator,
    io: std.Io,
    source: [:0]const u8,
    file: []const u8,
    options: LintOptions,
    library_entry_roots: []const []const u8,
    doc_cfg: rules.doc.Doc,
) !LintResult {
    var tree = try std.zig.Ast.parse(
        allocator,
        source,
        .zig,
    );
    defer tree.deinit(allocator);

    var result = LintResult.init(allocator);
    errdefer result.deinit();

    const msg = result.messageAllocator();
    const file_owned = try vereda.path.toPosixSeparators(msg, file);

    const require_module_doc = resolveRequireModuleDoc(file_owned, library_entry_roots);

    try rules.doc.missing_doc_comment.check(
        &tree,
        doc_cfg.missing_doc_comment,
        file_owned,
        require_module_doc,
        options.module_name,
        allocator,
        io,
        msg,
        &result.diagnostics,
    );
    try rules.doc.blank_doc_comment.check(
        &tree,
        doc_cfg.blank_doc_comment,
        file_owned,
        options.module_name,
        require_module_doc,
        allocator,
        io,
        msg,
        &result.diagnostics,
    );
    try rules.doc.missing_summary_terminal_punctuation.check(
        &tree,
        doc_cfg.missing_summary_terminal_punctuation,
        file_owned,
        options.module_name,
        allocator,
        msg,
        &result.diagnostics,
    );
    try rules.doc.trailing_blank_doc_comment.check(
        &tree,
        doc_cfg.trailing_blank_doc_comment,
        file_owned,
        options.module_name,
        allocator,
        msg,
        &result.diagnostics,
    );
    try rules.doc.missing_doctest.check(
        &tree,
        doc_cfg.missing_doctest,
        file_owned,
        allocator,
        msg,
        &result.diagnostics,
    );
    try rules.doc.private_doctest.check(
        &tree,
        doc_cfg.private_doctest,
        file_owned,
        allocator,
        msg,
        &result.diagnostics,
    );
    try rules.doc.doctest_naming_mismatch.check(
        &tree,
        doc_cfg.doctest_naming_mismatch,
        file_owned,
        allocator,
        msg,
        &result.diagnostics,
    );
    try rules.doc.invalid_leading_phrase.check(
        &tree,
        doc_cfg.invalid_leading_phrase,
        file_owned,
        options.module_name,
        allocator,
        msg,
        &result.diagnostics,
    );
    try rules.doc.redundant_doc_comment.check(
        &tree,
        doc_cfg.redundant_doc_comment,
        file_owned,
        options.module_name,
        allocator,
        io,
        msg,
        &result.diagnostics,
    );

    try applySuppressions(
        allocator,
        &tree,
        &result,
    );

    return result;
}

/// Runs the complexity rules over in-memory Zig source and returns their diagnostics.
///
/// Unlike `lintSource`, this is driven by `docent check complexity` (and related check commands).
pub fn lintComplexitySource(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    file: []const u8,
    complexity_cfg: rules.complexity.Complexity,
) !LintResult {
    var tree = try std.zig.Ast.parse(
        allocator,
        source,
        .zig,
    );
    defer tree.deinit(allocator);

    var result = LintResult.init(allocator);
    errdefer result.deinit();

    const msg = result.messageAllocator();
    const file_owned = try vereda.path.toPosixSeparators(msg, file);

    try rules.complexity.cognitive.check(
        &tree,
        complexity_cfg.cognitive_complexity,
        file_owned,
        allocator,
        msg,
        &result.diagnostics,
    );
    try rules.complexity.cyclomatic.check(
        &tree,
        complexity_cfg.cyclomatic_complexity,
        file_owned,
        allocator,
        msg,
        &result.diagnostics,
    );

    try applySuppressions(
        allocator,
        &tree,
        &result,
    );

    return result;
}

/// Runs the size rules over in-memory Zig source and returns their diagnostics.
///
/// Unlike `lintSource`, this is driven by `docent check size` (and related check commands).
pub fn lintSizeSource(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    file: []const u8,
    size_cfg: rules.size.Size,
) !LintResult {
    var tree = try std.zig.Ast.parse(
        allocator,
        source,
        .zig,
    );
    defer tree.deinit(allocator);

    var result = LintResult.init(allocator);
    errdefer result.deinit();

    const msg = result.messageAllocator();
    const file_owned = try vereda.path.toPosixSeparators(msg, file);

    try rules.size.max_fun_params.check(
        &tree,
        size_cfg.max_function_parameters,
        file_owned,
        allocator,
        msg,
        &result.diagnostics,
    );
    try rules.size.line_length_limit.check(
        source,
        size_cfg.line_length_limit,
        file_owned,
        allocator,
        msg,
        &result.diagnostics,
    );

    try applySuppressions(
        allocator,
        &tree,
        &result,
    );

    return result;
}

/// Runs the style rules over in-memory Zig source and returns their diagnostics.
///
/// Unlike `lintSource`, this is driven by `docent check style` (and related check commands).
pub fn lintStyleSource(
    allocator: std.mem.Allocator,
    io: std.Io,
    source: [:0]const u8,
    file: []const u8,
    style_cfg: rules.style.Style,
) !LintResult {
    var tree = try std.zig.Ast.parse(
        allocator,
        source,
        .zig,
    );
    defer tree.deinit(allocator);

    var result = LintResult.init(allocator);
    errdefer result.deinit();

    const msg = result.messageAllocator();
    const file_owned = try vereda.path.toPosixSeparators(msg, file);

    try rules.style.identifier_case.check(
        &tree,
        style_cfg.identifier_case,
        file_owned,
        allocator,
        io,
        msg,
        &result.diagnostics,
    );

    try applySuppressions(
        allocator,
        &tree,
        &result,
    );

    return result;
}

/// Reads `path` from the cwd and runs `lintStyleSource` on its contents.
pub fn lintStyleFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    style_cfg: rules.style.Style,
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

    return lintStyleSource(
        allocator,
        io,
        source,
        path,
        style_cfg,
    );
}

/// Reads `path` from the cwd and runs `lintComplexitySource` on its contents.
pub fn lintComplexityFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    complexity_cfg: rules.complexity.Complexity,
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

    return lintComplexitySource(
        allocator,
        source,
        path,
        complexity_cfg,
    );
}

/// Reads `path` from the cwd and runs `lintSizeSource` on its contents.
pub fn lintSizeFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    size_cfg: rules.size.Size,
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

    return lintSizeSource(
        allocator,
        source,
        path,
        size_cfg,
    );
}

/// Reads `path` from the cwd and runs `lintSource` on its contents.
pub fn lintFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    options: LintOptions,
    library_entry_roots: []const []const u8,
    doc_cfg: rules.doc.Doc,
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

    return lintSource(
        allocator,
        io,
        source,
        path,
        options,
        library_entry_roots,
        doc_cfg,
    );
}

comptime {
    std.testing.refAllDecls(@This());
}
