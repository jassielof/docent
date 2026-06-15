//! The doc namespace helps extract and analyze doc comments from Zig's AST.
//!
//! Aligned with Go's `go/doc` package: AST-level helpers for locating doc comments
//! and resolving the declarations they document. For parsing comment text itself
//! (summaries, paragraphs, line bodies), use `doc.comment`.
const std = @import("std");
const Ast = std.zig.Ast;

const Diagnostic = @import("Diagnostic.zig");
const helpers = @import("rules/utils/helpers.zig");

pub const comment = @import("doc/comment.zig");

/// When `public_api_only` is true, returns whether the declaration at `documented_first_token` is public API.
pub fn shouldCheckDocCommentTarget(
    tree: *const Ast,
    documented_first_token: Ast.TokenIndex,
    public_api_only: bool,
) bool {
    if (!public_api_only) return true;
    for (tree.rootDecls()) |decl| {
        if (findDocCommentVisibility(tree, documented_first_token, false, decl)) |visible| return visible;
    }
    return false;
}

/// Resolves the declaration a `///` doc comment block documents, for diagnostic subjects.
pub fn resolveDocCommentSubject(
    tree: *const Ast,
    documented_first_token: Ast.TokenIndex,
    file: []const u8,
    module_name: ?[]const u8,
    msg_allocator: std.mem.Allocator,
) std.mem.Allocator.Error!Diagnostic.Subject {
    for (tree.rootDecls()) |decl| {
        if (try findSubjectInNode(tree, documented_first_token, null, decl, msg_allocator)) |subject| {
            return subject;
        }
    }
    _ = file;
    _ = module_name;
    return try helpers.ownedSubject(msg_allocator, .doc_comment, "");
}

/// True when the file has no structure fields at file scope.
pub fn fileIsNamespace(tree: *const Ast) bool {
    for (tree.rootDecls()) |decl| {
        if (tree.fullContainerField(decl) != null) return false;
    }
    return true;
}

/// Subject kind for an exposed implicit struct or namespace source file.
pub fn exposedSourceFileSubjectKind(tree: *const Ast) Diagnostic.SubjectKind {
    return if (fileIsNamespace(tree)) .namespace else .structure;
}

/// True when `start_token` begins a `//!` container doc comment block.
pub fn hasContainerDocComment(tree: *const Ast, start_token: Ast.TokenIndex) bool {
    const tags = tree.tokens.items(.tag);
    if (start_token >= tags.len) return false;
    return tags[start_token] == .container_doc_comment;
}

/// True when the file begins with a `//!` block whose lines are all blank or whitespace-only.
pub fn containerDocBlockIsFullyBlank(tree: *const Ast) bool {
    const tags = tree.tokens.items(.tag);
    if (tags.len == 0 or tags[0] != .container_doc_comment) return false;

    var i: usize = 0;
    while (i < tags.len and tags[i] == .container_doc_comment) : (i += 1) {
        const tok: Ast.TokenIndex = @intCast(i);
        if (!comment.isEmptyLine(tree.tokenSlice(tok))) return false;
    }
    return true;
}

fn findDocCommentVisibility(
    tree: *const Ast,
    documented_first_token: Ast.TokenIndex,
    inside_public_container: bool,
    node: Ast.Node.Index,
) ?bool {
    if (tree.firstToken(node) == documented_first_token) {
        return visibilityAtNode(tree, node, inside_public_container);
    }

    if (tree.fullVarDecl(node)) |var_decl| {
        const init_node = var_decl.ast.init_node.unwrap() orelse return null;
        if (helpers.isContainerDecl(tree.nodeTag(init_node))) {
            const child_inside = helpers.isPubVisibility(tree, var_decl.visib_token);
            var buf: [2]Ast.Node.Index = undefined;
            if (tree.fullContainerDecl(&buf, init_node)) |container| {
                for (container.ast.members) |member| {
                    if (findDocCommentVisibility(tree, documented_first_token, child_inside, member)) |visible| {
                        return visible;
                    }
                }
            }
        }
        return null;
    }

    const tag = tree.nodeTag(node);
    if (helpers.isContainerDecl(tag)) {
        var buf: [2]Ast.Node.Index = undefined;
        if (tree.fullContainerDecl(&buf, node)) |container| {
            for (container.ast.members) |member| {
                if (findDocCommentVisibility(tree, documented_first_token, inside_public_container, member)) |visible| {
                    return visible;
                }
            }
        }
    }

    return null;
}

fn visibilityAtNode(tree: *const Ast, node: Ast.Node.Index, inside_public_container: bool) bool {
    if (tree.fullContainerField(node) != null) return inside_public_container;

    if (tree.nodeTag(node) == .fn_decl) {
        var buf: [1]Ast.Node.Index = undefined;
        if (tree.fullFnProto(&buf, node)) |proto| return helpers.isPubVisibility(tree, proto.visib_token);
        return false;
    }

    if (tree.fullVarDecl(node)) |var_decl| return helpers.isPubVisibility(tree, var_decl.visib_token);

    return inside_public_container;
}

fn findSubjectInNode(
    tree: *const Ast,
    documented_first_token: Ast.TokenIndex,
    enum_container: ?Ast.Node.Index,
    node: Ast.Node.Index,
    msg_allocator: std.mem.Allocator,
) std.mem.Allocator.Error!?Diagnostic.Subject {
    if (tree.firstToken(node) == documented_first_token) {
        return try subjectForDeclNode(tree, node, enum_container != null, msg_allocator);
    }

    if (tree.fullVarDecl(node)) |var_decl| {
        const init_node = var_decl.ast.init_node.unwrap() orelse return null;
        if (helpers.isContainerDecl(tree.nodeTag(init_node))) {
            const child_enum = if (helpers.isEnumContainer(tree, init_node)) init_node else enum_container;
            var buf: [2]Ast.Node.Index = undefined;
            if (tree.fullContainerDecl(&buf, init_node)) |container| {
                for (container.ast.members) |member| {
                    if (try findSubjectInNode(tree, documented_first_token, child_enum, member, msg_allocator)) |subject| {
                        return subject;
                    }
                }
            }
        }
        return null;
    }

    const tag = tree.nodeTag(node);
    if (helpers.isContainerDecl(tag)) {
        const child_enum = if (helpers.isEnumContainer(tree, node)) node else enum_container;
        var buf: [2]Ast.Node.Index = undefined;
        if (tree.fullContainerDecl(&buf, node)) |container| {
            for (container.ast.members) |member| {
                if (try findSubjectInNode(tree, documented_first_token, child_enum, member, msg_allocator)) |subject| {
                    return subject;
                }
            }
        }
    }

    return null;
}

fn subjectForDeclNode(
    tree: *const Ast,
    node: Ast.Node.Index,
    in_enum_container: bool,
    msg_allocator: std.mem.Allocator,
) std.mem.Allocator.Error!?Diagnostic.Subject {
    if (tree.fullContainerField(node)) |field| {
        const name = tree.tokenSlice(field.ast.main_token);
        const kind: Diagnostic.SubjectKind = if (in_enum_container) .enumerator else .field;
        return try helpers.ownedSubject(msg_allocator, kind, name);
    }

    if (tree.nodeTag(node) == .fn_decl) {
        var buf: [1]Ast.Node.Index = undefined;
        if (tree.fullFnProto(&buf, node)) |proto| {
            const name_tok = proto.name_token orelse return null;
            return try helpers.ownedSubject(msg_allocator, .function, tree.tokenSlice(name_tok));
        }
        return null;
    }

    if (tree.fullVarDecl(node)) |var_decl| {
        const name_tok = var_decl.ast.mut_token + 1;
        const kind = varDeclSubjectKind(tree, var_decl);
        return try helpers.ownedSubject(msg_allocator, kind, tree.tokenSlice(name_tok));
    }

    return null;
}

fn varDeclSubjectKind(tree: *const Ast, var_decl: Ast.full.VarDecl) Diagnostic.SubjectKind {
    if (tree.tokenTag(var_decl.ast.mut_token) != .keyword_const) return .variable;
    const init_node = var_decl.ast.init_node.unwrap() orelse return .constant;
    if (tree.nodeTag(init_node) == .error_set_decl) return .error_set;
    if (helpers.isEnumContainer(tree, init_node)) return .enumeration;
    return .constant;
}

test "fileIsNamespace" {
    const ns_source = "pub const x = 1;\n" ++ "\x00";
    var ns_tree = try std.zig.Ast.parse(std.testing.allocator, ns_source, .zig);
    defer ns_tree.deinit(std.testing.allocator);
    try std.testing.expect(fileIsNamespace(&ns_tree));

    const struct_source =
        \\//! Structure file
        \\x: u8,
    ++ "\x00";
    var struct_tree = try std.zig.Ast.parse(std.testing.allocator, struct_source, .zig);
    defer struct_tree.deinit(std.testing.allocator);
    try std.testing.expect(!fileIsNamespace(&struct_tree));
}

test "containerDocBlockIsFullyBlank" {
    const blank = "//!\n//!\npub fn f() void {}\n" ++ "\x00";
    var tree = try std.zig.Ast.parse(std.testing.allocator, blank, .zig);
    defer tree.deinit(std.testing.allocator);
    try std.testing.expect(containerDocBlockIsFullyBlank(&tree));

    const text = "//! Module docs.\npub fn f() void {}\n" ++ "\x00";
    var tree2 = try std.zig.Ast.parse(std.testing.allocator, text, .zig);
    defer tree2.deinit(std.testing.allocator);
    try std.testing.expect(!containerDocBlockIsFullyBlank(&tree2));
}
