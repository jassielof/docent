// COMPAT: //! top-level doc comments — remove this file if deprecated in 0.16

const std = @import("std");
const Ast = std.zig.Ast;
const Token = std.zig.Token;
const Diagnostic = @import("../Diagnostic.zig");
const Severity = @import("../Severity.zig");

const rule_name = "missing_container_doc_comment";

pub fn check(
    tree: *const Ast,
    severity: Severity.Level,
    file: []const u8,
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) !void {
    if (!severity.isActive()) return;

    if (!hasContainerDocComment(tree, 0)) {
        try diagnostics.append(allocator, .{
            .rule = rule_name,
            .severity = severity,
            .message = "file is missing a top-level container doc comment (//!)",
            .file = file,
            .line = 1,
            .column = 1,
        });
    }

    for (tree.rootDecls()) |decl| {
        try checkContainerDecl(tree, decl, severity, file, allocator, diagnostics);
    }
}

fn checkContainerDecl(
    tree: *const Ast,
    node: Ast.Node.Index,
    severity: Severity.Level,
    file: []const u8,
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) std.mem.Allocator.Error!void {
    if (tree.fullVarDecl(node)) |var_decl| {
        if (var_decl.visib_token) |vt| {
            if (tree.tokenTag(vt) == .keyword_pub) {
                const init_node = var_decl.ast.init_node.unwrap() orelse return;
                try checkContainerNode(tree, init_node, severity, file, allocator, diagnostics);
            }
        }
        return;
    }
}

fn checkContainerNode(
    tree: *const Ast,
    node: Ast.Node.Index,
    severity: Severity.Level,
    file: []const u8,
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) std.mem.Allocator.Error!void {
    if (!isContainerDecl(tree.nodeTag(node))) return;

    var buf: [2]Ast.Node.Index = undefined;
    const container = tree.fullContainerDecl(&buf, node) orelse return;

    const lbrace = container.ast.main_token + 1;
    const after_lbrace = if (tree.tokenTag(lbrace) == .l_brace) lbrace + 1 else lbrace;

    if (!hasContainerDocComment(tree, after_lbrace)) {
        const loc = tree.tokenLocation(0, container.ast.main_token);
        try diagnostics.append(allocator, .{
            .rule = rule_name,
            .severity = severity,
            .message = "container is missing a doc comment (//!)",
            .file = file,
            .line = loc.line + 1,
            .column = loc.column + 1,
        });
    }

    for (container.ast.members) |member| {
        try checkContainerDecl(tree, member, severity, file, allocator, diagnostics);
    }
}

fn hasContainerDocComment(tree: *const Ast, start_token: Ast.TokenIndex) bool {
    const tags = tree.tokens.items(.tag);
    if (start_token >= tags.len) return false;
    return tags[start_token] == .container_doc_comment;
}

fn isContainerDecl(tag: Ast.Node.Tag) bool {
    return switch (tag) {
        .container_decl,
        .container_decl_trailing,
        .container_decl_two,
        .container_decl_two_trailing,
        .container_decl_arg,
        .container_decl_arg_trailing,
        .tagged_union,
        .tagged_union_trailing,
        .tagged_union_two,
        .tagged_union_two_trailing,
        .tagged_union_enum_tag,
        .tagged_union_enum_tag_trailing,
        => true,
        else => false,
    };
}

test "detects missing //! at file level" {
    const source =
        \\pub fn foo() void {}
    ;
    var result = try runCheck(source);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(1, result.items.len);
    try std.testing.expectEqualStrings(rule_name, result.items[0].rule);
}

test "no diagnostic when //! present" {
    const source =
        \\//! Module documentation.
        \\pub fn foo() void {}
    ;
    var result = try runCheck(source);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(0, result.items.len);
}

fn runCheck(source: [:0]const u8) !std.ArrayList(Diagnostic) {
    const allocator = std.testing.allocator;
    var tree = try std.zig.Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    errdefer diagnostics.deinit(allocator);

    try check(&tree, .warn, "<test>", allocator, &diagnostics);
    return diagnostics;
}
