const std = @import("std");
const Ast = std.zig.Ast;
const Token = std.zig.Token;
const Diagnostic = @import("../Diagnostic.zig");
const Severity = @import("../Severity.zig");

const rule_name = "missing_doc_comment";

pub fn check(
    tree: *const Ast,
    severity: Severity.Level,
    file: []const u8,
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) !void {
    if (!severity.isActive()) return;
    for (tree.rootDecls()) |decl| {
        try checkNode(tree, decl, severity, file, allocator, diagnostics);
    }
}

fn checkNode(
    tree: *const Ast,
    node: Ast.Node.Index,
    severity: Severity.Level,
    file: []const u8,
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) std.mem.Allocator.Error!void {
    const tag = tree.nodeTag(node);

    if (tag == .fn_decl) {
        var buf: [1]Ast.Node.Index = undefined;
        if (tree.fullFnProto(&buf, node)) |proto| {
            if (proto.visib_token) |vt| {
                if (tree.tokenTag(vt) == .keyword_pub) {
                    if (!hasDocComment(tree, tree.firstToken(node))) {
                        const loc = tree.tokenLocation(0, tree.firstToken(node));
                        try diagnostics.append(allocator, .{
                            .rule = rule_name,
                            .severity = severity,
                            .message = "public function is missing a doc comment",
                            .file = file,
                            .line = loc.line + 1,
                            .column = loc.column + 1,
                        });
                    }
                }
            }
        }
        return;
    }

    if (tree.fullVarDecl(node)) |var_decl| {
        if (var_decl.visib_token) |vt| {
            if (tree.tokenTag(vt) == .keyword_pub) {
                if (!hasDocComment(tree, tree.firstToken(node))) {
                    const loc = tree.tokenLocation(0, tree.firstToken(node));
                    try diagnostics.append(allocator, .{
                        .rule = rule_name,
                        .severity = severity,
                        .message = "public declaration is missing a doc comment",
                        .file = file,
                        .line = loc.line + 1,
                        .column = loc.column + 1,
                    });
                }
            }
        }
        try checkVarDeclInit(tree, var_decl, severity, file, allocator, diagnostics);
        return;
    }

    if (isContainerDecl(tag)) {
        var buf: [2]Ast.Node.Index = undefined;
        if (tree.fullContainerDecl(&buf, node)) |container| {
            for (container.ast.members) |member| {
                try checkNode(tree, member, severity, file, allocator, diagnostics);
            }
        }
        return;
    }

    if (tree.fullContainerField(node) != null) {
        if (!hasDocComment(tree, tree.firstToken(node))) {
            const loc = tree.tokenLocation(0, tree.firstToken(node));
            try diagnostics.append(allocator, .{
                .rule = rule_name,
                .severity = severity,
                .message = "container field is missing a doc comment",
                .file = file,
                .line = loc.line + 1,
                .column = loc.column + 1,
            });
        }
        return;
    }
}

fn checkVarDeclInit(
    tree: *const Ast,
    var_decl: Ast.full.VarDecl,
    severity: Severity.Level,
    file: []const u8,
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) std.mem.Allocator.Error!void {
    const init_node = var_decl.ast.init_node.unwrap() orelse return;
    if (isContainerDecl(tree.nodeTag(init_node))) {
        var buf: [2]Ast.Node.Index = undefined;
        if (tree.fullContainerDecl(&buf, init_node)) |container| {
            for (container.ast.members) |member| {
                try checkNode(tree, member, severity, file, allocator, diagnostics);
            }
        }
    }
}

fn hasDocComment(tree: *const Ast, first_token: Ast.TokenIndex) bool {
    if (first_token == 0) return false;
    return tree.tokenTag(first_token - 1) == .doc_comment;
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

test "detects missing doc comment on pub fn" {
    const source =
        \\pub fn foo() void {}
    ;
    var result = try runCheck(source);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(1, result.items.len);
    try std.testing.expectEqualStrings(rule_name, result.items[0].rule);
}

test "no diagnostic for documented pub fn" {
    const source =
        \\/// Does something.
        \\pub fn foo() void {}
    ;
    var result = try runCheck(source);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(0, result.items.len);
}

test "no diagnostic for private fn" {
    const source =
        \\fn foo() void {}
    ;
    var result = try runCheck(source);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(0, result.items.len);
}

test "detects missing doc comment on pub const" {
    const source =
        \\pub const x = 42;
    ;
    var result = try runCheck(source);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(1, result.items.len);
}

test "detects missing doc comment on container fields" {
    const source =
        \\/// A struct.
        \\pub const S = struct {
        \\    x: u32,
        \\    y: u32,
        \\};
    ;
    var result = try runCheck(source);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(2, result.items.len);
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
