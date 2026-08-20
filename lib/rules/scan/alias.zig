//! Recognizes import-rooted aliases and re-exports in one parsed source file.
//!
//! These helpers intentionally perform no filesystem access. Directory-based linting checks the
//! imported source independently; rules only need to classify the local declaration correctly.

const std = @import("std");
const Ast = std.zig.Ast;

/// Extracted information about an `@import` expression or a local alias rooted at one.
pub const Info = struct {
    /// Raw import path from `@import("…")`, without quotes.
    import_path: []const u8,
    /// The identifier after the dot, or null for a whole-module import.
    field_name: ?[]const u8,
};

/// Returns info when `node` is `@import("path").Field`, `@import("path")`, or `alias.Field`.
pub fn getInfo(tree: *const Ast, node: Ast.Node.Index) ?Info {
    const tag = tree.nodeTag(node);
    if (tag == .field_access) {
        const field_access = tree.nodeData(node).node_and_token;
        const object = field_access[0];
        const field_name_token = field_access[1];
        if (tree.tokenTag(field_name_token) != .identifier) return null;

        const import_path = getImportPath(tree, object) orelse blk: {
            if (tree.nodeTag(object) != .identifier) return null;
            const alias = tree.tokenSlice(tree.nodeMainToken(object));
            break :blk findLocalImportPath(tree, alias) orelse return null;
        };
        return .{
            .import_path = import_path,
            .field_name = tree.tokenSlice(field_name_token),
        };
    }

    if (getImportPath(tree, node)) |import_path| {
        return .{ .import_path = import_path, .field_name = null };
    }
    return null;
}

/// Returns whether `node` is a member access through local aliases rooted at `@import`.
///
/// Named module paths such as `const doc_rules = rules.doc; pub const Doc = doc_rules.Doc;`
/// count as re-exports even though their module specifier is not a filesystem path.
pub fn isModuleMemberReexport(tree: *const Ast, node: Ast.Node.Index) bool {
    if (tree.nodeTag(node) != .field_access) return false;
    return isImportRootedNode(tree, tree.nodeData(node).node_and_token[0]);
}

fn isImportRootedNode(tree: *const Ast, node: Ast.Node.Index) bool {
    if (getImportPath(tree, node) != null) return true;
    return switch (tree.nodeTag(node)) {
        .identifier => isImportRootedAlias(tree, tree.tokenSlice(tree.nodeMainToken(node))),
        .field_access => isImportRootedNode(tree, tree.nodeData(node).node_and_token[0]),
        else => false,
    };
}

fn findLocalImportPath(tree: *const Ast, alias: []const u8) ?[]const u8 {
    for (tree.rootDecls()) |decl| {
        const variable = tree.fullVarDecl(decl) orelse continue;
        const name_token = variable.ast.mut_token + 1;
        if (!std.mem.eql(u8, tree.tokenSlice(name_token), alias)) continue;
        const init = variable.ast.init_node.unwrap() orelse continue;
        return getImportPath(tree, init);
    }
    return null;
}

fn isImportRootedAlias(tree: *const Ast, alias: []const u8) bool {
    for (tree.rootDecls()) |decl| {
        const variable = tree.fullVarDecl(decl) orelse continue;
        const name_token = variable.ast.mut_token + 1;
        if (!std.mem.eql(u8, tree.tokenSlice(name_token), alias)) continue;
        const init = variable.ast.init_node.unwrap() orelse return false;
        return getImportPath(tree, init) != null or isModuleMemberReexport(tree, init);
    }
    return false;
}

fn getImportPath(tree: *const Ast, node: Ast.Node.Index) ?[]const u8 {
    if (tree.nodeTag(node) == .field_access) {
        return getImportPath(tree, tree.nodeData(node).node_and_token[0]);
    }
    if (tree.nodeTag(node) != .builtin_call_two and tree.nodeTag(node) != .builtin_call_two_comma) return null;

    const builtin_token = tree.nodeMainToken(node);
    if (tree.tokenTag(builtin_token) != .builtin or !std.mem.eql(u8, tree.tokenSlice(builtin_token), "@import")) return null;

    const argument = tree.nodeData(node).opt_node_and_opt_node[0].unwrap() orelse return null;
    if (tree.nodeTag(argument) != .string_literal) return null;

    const raw = tree.tokenSlice(tree.nodeMainToken(argument));
    if (raw.len < 2 or raw[0] != '"' or raw[raw.len - 1] != '"') return null;
    return raw[1 .. raw.len - 1];
}
