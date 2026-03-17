const std = @import("std");

pub const Severity = @import("Severity.zig").Level;
pub const Diagnostic = @import("Diagnostic.zig");
pub const RuleSet = @import("RuleSet.zig");
pub const LintResult = @import("LintResult.zig");
pub const output = @import("Output.zig");
pub const reachability = @import("Reachability.zig");

pub const scaffold = @import("scaffold.zig");
pub const addLintStep = scaffold.addLintStep;

pub const rules = struct {
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

pub fn lintSource(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    rule_set: RuleSet,
    file: []const u8,
) !LintResult {
    var tree = try std.zig.Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);

    var result = LintResult.init(allocator);
    errdefer result.deinit();

    const msg = result.messageAllocator();

    try rules.missing_doc_comment.check(&tree, rule_set.missing_doc_comment, file, allocator, msg, &result.diagnostics);
    try rules.empty_doc_comment.check(&tree, rule_set.empty_doc_comment, file, allocator, msg, &result.diagnostics);
    try rules.missing_doctest.check(&tree, rule_set.missing_doctest, file, allocator, msg, &result.diagnostics);
    try rules.private_doctest.check(&tree, rule_set.private_doctest, file, allocator, msg, &result.diagnostics);
    try rules.doctest_naming_mismatch.check(&tree, rule_set.doctest_naming_mismatch, file, allocator, msg, &result.diagnostics);
    // COMPAT: //! top-level doc comments — remove if deprecated in 0.16
    try rules.missing_container_doc_comment.check(&tree, rule_set.missing_container_doc_comment, file, allocator, msg, &result.diagnostics);

    return result;
}

pub fn lintFile(
    allocator: std.mem.Allocator,
    path: []const u8,
    rule_set: RuleSet,
) !LintResult {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const source = try file.readToEndAllocOptions(allocator, std.math.maxInt(u32), null, .of(u8), 0);
    defer allocator.free(source);

    return lintSource(allocator, source, rule_set, path);
}

test {
    _ = rules.missing_doc_comment;
    _ = rules.empty_doc_comment;
    _ = rules.missing_doctest;
    _ = rules.private_doctest;
    _ = rules.doctest_naming_mismatch;
    _ = rules.missing_container_doc_comment;
}
