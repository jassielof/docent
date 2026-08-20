//! The `misplaced_doc_comment` namespace checks for doc comments on imports and re-exports.

const std = @import("std");
const Ast = std.zig.Ast;

const lint = @import("lint");
const category = lint.category;
const Diagnostic = lint.Diagnostic;
const scan = lint.scan;
const severity = lint.severity;

const alias = @import("../scan/alias.zig");
const utils = @import("../utils.zig");

inline fn srcLoc() std.builtin.SourceLocation {
    return @src();
}

const rule_name = utils.ruleIdFromSrc(srcLoc());

/// The default_severity for the rule.
pub const default_severity: severity.Level = .warn;

/// Title for diagnostic prose (`Warning: {prose_title} on …`).
pub const prose_title = "Misplaced doc comment";

/// Full configuration for `misplaced_doc_comment`: severity and scan mode, with no rule-specific options.
pub const Rule = category.Rule(
    default_severity,
    struct {},
    scan.RuleScanConfig.all_declarations,
);

/// Walks `tree` and appends diagnostics for doc comments on imports and re-exports.
pub fn check(
    tree: *const Ast,
    rule: Rule,
    file: []const u8,
    module_name: ?[]const u8,
    allocator: std.mem.Allocator,
    msg_allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) !void {
    if (!rule.level.isActive()) return;
    const severity_level = rule.level;
    const public_api_only = rule.publicDeclarationsOnly();
    _ = module_name;

    for (tree.rootDecls()) |decl| {
        try checkNode(
            tree,
            decl,
            severity_level,
            file,
            public_api_only,
            allocator,
            msg_allocator,
            diagnostics,
        );
    }
}

fn checkNode(
    tree: *const Ast,
    node: Ast.Node.Index,
    severity_level: severity.Level,
    file: []const u8,
    public_api_only: bool,
    allocator: std.mem.Allocator,
    msg_allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) std.mem.Allocator.Error!void {
    const tag = tree.nodeTag(node);

    if (tree.fullVarDecl(node)) |var_decl| {
        const first_tok = var_decl.firstToken();
        if (shouldCheckDecl(
            tree,
            var_decl.visib_token,
            public_api_only,
        ) and
            hasDocComment(tree, first_tok))
        {
            const init_node = var_decl.ast.init_node.unwrap() orelse return;
            if (alias.getInfo(
                tree,
                init_node,
            ) != null or alias.isModuleMemberReexport(tree, init_node)) {
                const name_tok = var_decl.ast.mut_token + 1;
                const name = tree.tokenSlice(name_tok);
                // Point to the leading doc block rather than the imported binding.
                var doc_tok = first_tok - 1;
                while (doc_tok > 0 and tree.tokenTag(
                    doc_tok - 1,
                ) == .doc_comment) : (doc_tok -= 1) {}

                const loc = tree.tokenLocation(0, doc_tok);
                const slice = tree.tokenSlice(doc_tok);
                try diagnostics.append(allocator, .{
                    .rule = rule_name,
                    .severity_level = severity_level,
                    .subject = try utils.ownedSubject(
                        msg_allocator,
                        pubVarDeclSubjectKind(tree, var_decl),
                        name,
                    ),
                    .detail = "move it to the declaration in the imported module",
                    .file = file,
                    .line = loc.line + 1,
                    .column = loc.column + 1,
                    .source_line = try utils.dupSourceLine(
                        tree,
                        doc_tok,
                        msg_allocator,
                    ),
                    .symbol_len = slice.len,
                });
            }
        }

        try checkVarDeclInit(
            tree,
            var_decl,
            severity_level,
            file,
            public_api_only,
            allocator,
            msg_allocator,
            diagnostics,
        );
        return;
    }

    if (isContainerDecl(tag)) {
        var buf: [2]Ast.Node.Index = undefined;
        if (tree.fullContainerDecl(&buf, node)) |container| {
            for (container.ast.members) |member| {
                try checkNode(
                    tree,
                    member,
                    severity_level,
                    file,
                    public_api_only,
                    allocator,
                    msg_allocator,
                    diagnostics,
                );
            }
        }
        return;
    }
}

fn checkVarDeclInit(
    tree: *const Ast,
    var_decl: Ast.full.VarDecl,
    severity_level: severity.Level,
    file: []const u8,
    public_api_only: bool,
    allocator: std.mem.Allocator,
    msg_allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) std.mem.Allocator.Error!void {
    if (public_api_only and !shouldCheckDecl(
        tree,
        var_decl.visib_token,
        true,
    )) return;

    const init_node = var_decl.ast.init_node.unwrap() orelse return;
    if (isContainerDecl(tree.nodeTag(init_node))) {
        var buf: [2]Ast.Node.Index = undefined;
        if (tree.fullContainerDecl(&buf, init_node)) |container| {
            for (container.ast.members) |member| {
                try checkNode(
                    tree,
                    member,
                    severity_level,
                    file,
                    public_api_only,
                    allocator,
                    msg_allocator,
                    diagnostics,
                );
            }
        }
    }
}

fn isContainerDecl(tag: Ast.Node.Tag) bool {
    return utils.isContainerDecl(tag);
}

fn hasDocComment(tree: *const Ast, first_token: Ast.TokenIndex) bool {
    if (first_token == 0) return false;
    return tree.tokenTag(first_token - 1) == .doc_comment;
}

fn isPubVisibility(tree: *const Ast, visib_token: ?Ast.TokenIndex) bool {
    const vt = visib_token orelse return false;
    return tree.tokenTag(vt) == .keyword_pub;
}

fn shouldCheckDecl(
    tree: *const Ast,
    visib_token: ?Ast.TokenIndex,
    public_api_only: bool,
) bool {
    if (!public_api_only) return true;
    return isPubVisibility(tree, visib_token);
}

fn pubVarDeclSubjectKind(tree: *const Ast, var_decl: Ast.full.VarDecl) Diagnostic.SubjectKind {
    if (tree.tokenTag(var_decl.ast.mut_token) != .keyword_const) return .variable;
    const init_node = var_decl.ast.init_node.unwrap() orelse return .constant;
    if (tree.nodeTag(init_node) == .error_set_decl) return .error_set;
    if (utils.isEnumContainer(tree, init_node)) return .enumeration;
    return .constant;
}

fn runCheck(
    source: [:0]const u8,
    rule: Rule,
    diagnostics: *std.ArrayList(Diagnostic),
    msg_allocator: std.mem.Allocator,
) !void {
    const allocator = std.testing.allocator;
    var tree = try std.zig.Ast.parse(
        allocator,
        source,
        .zig,
    );
    defer tree.deinit(allocator);

    try check(
        &tree,
        rule,
        "<test>",
        null,
        allocator,
        msg_allocator,
        diagnostics,
    );
}

const warn_rule: Rule = .{ .level = .warn };

test "flags a doc comment on a whole-module re-export" {
    const source =
        \\/// Redundant doc comment on whole-module re-export
        \\pub const my_helper = @import("redundant_helper.zig");
    ;

    var msg_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer msg_arena.deinit();
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    try runCheck(
        source,
        warn_rule,
        &diagnostics,
        msg_arena.allocator(),
    );
    try std.testing.expectEqual(@as(usize, 1), diagnostics.items.len);
    try std.testing.expectEqualStrings("my_helper", diagnostics.items[0].subject.?.name);
    try std.testing.expectEqualStrings(
        "move it to the declaration in the imported module",
        diagnostics.items[0].detail.?,
    );
}

test "flags a doc comment on a member re-export" {
    const source =
        \\const helper = @import("redundant_helper.zig");
        \\/// Redundant doc comment on member re-export
        \\pub const Foo = helper.Foo;
    ;

    var msg_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer msg_arena.deinit();
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    try runCheck(
        source,
        warn_rule,
        &diagnostics,
        msg_arena.allocator(),
    );
    try std.testing.expectEqual(@as(usize, 1), diagnostics.items.len);
    try std.testing.expectEqualStrings("Foo", diagnostics.items[0].subject.?.name);
}

test "no diagnostic for re-exports without a doc comment" {
    const source =
        \\const helper = @import("redundant_helper.zig");
        \\
        \\// No doc comment here, completely fine
        \\pub const my_helper = helper;
        \\
        \\// No doc comment here, completely fine
        \\pub const Foo = helper.Foo;
    ;

    var msg_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer msg_arena.deinit();
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    try runCheck(
        source,
        warn_rule,
        &diagnostics,
        msg_arena.allocator(),
    );
    try std.testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}

test "flags a doc comment on a member re-export even when the target is undocumented" {
    const source =
        \\const helper = @import("redundant_helper.zig");
        \\
        \\/// Doc comment on member that is NOT documented in target
        \\pub const UndocumentedFoo = helper.UndocumentedFoo;
    ;

    var msg_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer msg_arena.deinit();
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    try runCheck(
        source,
        warn_rule,
        &diagnostics,
        msg_arena.allocator(),
    );
    try std.testing.expectEqual(@as(usize, 1), diagnostics.items.len);
    try std.testing.expectEqualStrings("UndocumentedFoo", diagnostics.items[0].subject.?.name);
}

comptime {
    std.testing.refAllDecls(@This());
}
