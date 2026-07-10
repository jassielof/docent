//! AST-level helpers for locating Zig doc comments and resolving the
//! declarations they document.
//!
//! For parsing comment text itself (summaries, paragraphs, line bodies), use
//! `doc_comment.comment`.

const std = @import("std");
const Ast = std.zig.Ast;

const comment = @import("comment.zig");

/// Kind of declaration a doc comment documents (mirrors lint diagnostic subjects).
pub const SubjectKind = enum {
    function,
    constant,
    variable,
    error_set,
    enumeration,
    field,
    enumerator,
    doc_comment,
    structure,
    namespace,
};

/// Named declaration a doc comment attaches to.
pub const Subject = struct {
    kind: SubjectKind,
    name: []const u8,
};

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

/// Resolves the declaration a `///` doc comment block documents.
pub fn resolveDocCommentSubject(
    tree: *const Ast,
    documented_first_token: Ast.TokenIndex,
    file: []const u8,
    module_name: ?[]const u8,
    msg_allocator: std.mem.Allocator,
) std.mem.Allocator.Error!Subject {
    for (tree.rootDecls()) |decl| {
        if (try findSubjectInNode(tree, documented_first_token, null, decl, msg_allocator)) |subject| {
            return subject;
        }
    }
    _ = file;
    _ = module_name;
    return .{ .kind = .doc_comment, .name = try msg_allocator.dupe(u8, "") };
}

/// True when the file has no structure fields at file scope.
pub fn fileIsNamespace(tree: *const Ast) bool {
    for (tree.rootDecls()) |decl| {
        if (tree.fullContainerField(decl) != null) return false;
    }
    return true;
}

/// Subject kind for an exposed implicit struct or namespace source file.
pub fn exposedSourceFileSubjectKind(tree: *const Ast) SubjectKind {
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
        if (isContainerDecl(tree.nodeTag(init_node))) {
            const child_inside = isPubVisibility(tree, var_decl.visib_token);
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
    if (isContainerDecl(tag)) {
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
        if (tree.fullFnProto(&buf, node)) |proto| return isPubVisibility(tree, proto.visib_token);
        return false;
    }

    if (tree.fullVarDecl(node)) |var_decl| return isPubVisibility(tree, var_decl.visib_token);

    return inside_public_container;
}

fn findSubjectInNode(
    tree: *const Ast,
    documented_first_token: Ast.TokenIndex,
    enum_container: ?Ast.Node.Index,
    node: Ast.Node.Index,
    msg_allocator: std.mem.Allocator,
) std.mem.Allocator.Error!?Subject {
    if (tree.firstToken(node) == documented_first_token) {
        return try subjectForDeclNode(tree, node, enum_container != null, msg_allocator);
    }

    if (tree.fullVarDecl(node)) |var_decl| {
        const init_node = var_decl.ast.init_node.unwrap() orelse return null;
        if (isContainerDecl(tree.nodeTag(init_node))) {
            const child_enum = if (isEnumContainer(tree, init_node)) init_node else enum_container;
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
    if (isContainerDecl(tag)) {
        const child_enum = if (isEnumContainer(tree, node)) node else enum_container;
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
) std.mem.Allocator.Error!?Subject {
    if (tree.fullContainerField(node)) |field| {
        const name = tree.tokenSlice(field.ast.main_token);
        const kind: SubjectKind = if (in_enum_container) .enumerator else .field;
        return .{ .kind = kind, .name = try msg_allocator.dupe(u8, name) };
    }

    if (tree.nodeTag(node) == .fn_decl) {
        var buf: [1]Ast.Node.Index = undefined;
        if (tree.fullFnProto(&buf, node)) |proto| {
            const name_tok = proto.name_token orelse return null;
            return .{ .kind = .function, .name = try msg_allocator.dupe(u8, tree.tokenSlice(name_tok)) };
        }
        return null;
    }

    if (tree.fullVarDecl(node)) |var_decl| {
        const name_tok = var_decl.ast.mut_token + 1;
        const kind = varDeclSubjectKind(tree, var_decl);
        return .{ .kind = kind, .name = try msg_allocator.dupe(u8, tree.tokenSlice(name_tok)) };
    }

    return null;
}

fn varDeclSubjectKind(tree: *const Ast, var_decl: Ast.full.VarDecl) SubjectKind {
    if (tree.tokenTag(var_decl.ast.mut_token) != .keyword_const) return .variable;
    const init_node = var_decl.ast.init_node.unwrap() orelse return .constant;
    if (tree.nodeTag(init_node) == .error_set_decl) return .error_set;
    if (isEnumContainer(tree, init_node)) return .enumeration;
    return .constant;
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

fn isEnumContainer(tree: *const Ast, container_node: Ast.Node.Index) bool {
    var buf: [2]Ast.Node.Index = undefined;
    const container = tree.fullContainerDecl(&buf, container_node) orelse return false;
    return tree.tokenTag(container.ast.main_token) == .keyword_enum;
}

fn isPubVisibility(tree: *const Ast, visib_token: ?Ast.TokenIndex) bool {
    const vt = visib_token orelse return false;
    return tree.tokenTag(vt) == .keyword_pub;
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
