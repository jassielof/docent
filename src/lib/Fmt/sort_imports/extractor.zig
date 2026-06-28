const std = @import("std");
const mem = std.mem;
const Ast = std.zig.Ast;
const Allocator = std.mem.Allocator;

const types = @import("types.zig");
const ImportEntry = types.ImportEntry;
const Visibility = types.Visibility;
const ImportShape = types.ImportShape;
const classifier = @import("classifier.zig");

pub const ExtractionResult = struct {
    entries: []ImportEntry,
    block_start: usize,
    block_end: usize,
    prefix_end: usize,
};

pub fn extract(arena: Allocator, tree: *const Ast) !ExtractionResult {
    var entries: std.ArrayList(ImportEntry) = .empty;
    var known = std.StringHashMap(usize).init(arena);

    var block_start: ?usize = null;
    var block_end: usize = 0;
    var prefix_end: usize = 0;

    const source = tree.source;
    const root_decls = tree.rootDecls();

    for (root_decls) |decl| {
        const var_decl = tree.fullVarDecl(decl) orelse continue;
        const init_node = var_decl.ast.init_node.unwrap() orelse continue;

        const name_tok = var_decl.ast.mut_token + 1;
        const left = tree.tokenSlice(name_tok);
        const vis: Visibility = if (var_decl.visib_token) |vt| (if (tree.tokenTag(vt) == .keyword_pub) .public else .internal) else .internal;

        const decl_start = tokenStart(tree, firstToken(tree, decl, var_decl));
        const decl_end = findDeclEnd(source, lastTokenEnd(tree, decl));

        if (block_start == null) {
            block_start = decl_start;
            prefix_end = decl_start;
        }

        const decl_text = source[decl_start..decl_end];
        const comments = try collectAttachedComments(arena, source, decl_start);

        const tag = tree.nodeTag(init_node);

        if (tag == .if_simple or tag == .@"if") {
            if (containsImport(tree, init_node)) {
                try known.put(left, entries.items.len);
                try entries.append(arena, .{
                    .node = decl,
                    .visibility = vis,
                    .kind = .conditional,
                    .shape = .conditional,
                    .left = left,
                    .right = "",
                    .module = "",
                    .parent = null,
                    .comment_lines = comments,
                    .source_text = decl_text,
                });
                block_end = decl_end;
                continue;
            }
        }

        if (getImportPath(tree, init_node)) |import_path| {
            const kind = classifier.classifyKind(import_path);
            const shape: ImportShape = if (hasFieldAccess(tree, init_node)) .inline_field else .direct;
            const module = if (shape == .inline_field) import_path else import_path;

            try known.put(left, entries.items.len);
            try entries.append(arena, .{
                .node = decl,
                .visibility = vis,
                .kind = kind,
                .shape = shape,
                .left = left,
                .right = import_path,
                .module = module,
                .parent = null,
                .comment_lines = comments,
                .source_text = decl_text,
            });
            block_end = decl_end;
            continue;
        }

        const head = resolveHead(tree, init_node);
        if (head.len > 0 and known.contains(head)) {
            const parent_idx = known.get(head).?;
            const parent_entry = entries.items[parent_idx];
            const is_field = isFieldAccess(tree, init_node);
            const cross_visibility = vis == .public and parent_entry.visibility == .internal;
            const shape: ImportShape = if (cross_visibility) .reexport else if (is_field) .alias else .reexport;
            const parent_link: ?usize = if (cross_visibility) null else parent_idx;

            try known.put(left, entries.items.len);
            try entries.append(arena, .{
                .node = decl,
                .visibility = vis,
                .kind = if (cross_visibility) .file else parent_entry.kind,
                .shape = shape,
                .left = left,
                .right = "",
                .module = parent_entry.module,
                .parent = parent_link,
                .comment_lines = comments,
                .source_text = decl_text,
            });
            block_end = decl_end;
            continue;
        }
    }

    const bs = block_start orelse 0;
    return .{
        .entries = try entries.toOwnedSlice(arena),
        .block_start = if (entries.items.len > 0) adjustBlockStartForComments(source, bs, entries.items[0].comment_lines) else bs,
        .block_end = block_end,
        .prefix_end = prefix_end,
    };
}

fn adjustBlockStartForComments(source: []const u8, decl_start: usize, comments: []const []const u8) usize {
    if (comments.len == 0) return decl_start;
    var pos = decl_start;
    for (comments) |_| {
        if (pos == 0) break;
        pos -= 1;
        while (pos > 0 and source[pos - 1] != '\n') pos -= 1;
    }
    return pos;
}

fn getImportPath(tree: *const Ast, node: Ast.Node.Index) ?[]const u8 {
    var cur = node;
    while (tree.nodeTag(cur) == .field_access) {
        cur = tree.nodeData(cur).node_and_token[0];
    }
    const tag = tree.nodeTag(cur);
    if (tag != .builtin_call_two and tag != .builtin_call_two_comma) return null;

    const builtin_tok = tree.nodeMainToken(cur);
    if (tree.tokenTag(builtin_tok) != .builtin) return null;
    if (!mem.eql(u8, tree.tokenSlice(builtin_tok), "@import")) return null;

    const args = tree.nodeData(cur).opt_node_and_opt_node;
    const arg_node = args[0].unwrap() orelse return null;
    if (tree.nodeTag(arg_node) != .string_literal) return null;

    const raw = tree.tokenSlice(tree.nodeMainToken(arg_node));
    if (raw.len < 2 or raw[0] != '"' or raw[raw.len - 1] != '"') return null;
    return raw[1 .. raw.len - 1];
}

fn hasFieldAccess(tree: *const Ast, node: Ast.Node.Index) bool {
    return tree.nodeTag(node) == .field_access;
}

fn isFieldAccess(tree: *const Ast, node: Ast.Node.Index) bool {
    const tag = tree.nodeTag(node);
    return tag == .field_access;
}

fn containsImport(tree: *const Ast, node: Ast.Node.Index) bool {
    const tag = tree.nodeTag(node);
    if (tag == .builtin_call_two or tag == .builtin_call_two_comma) {
        const tok = tree.nodeMainToken(node);
        return mem.eql(u8, tree.tokenSlice(tok), "@import");
    }
    if (tag == .if_simple or tag == .@"if") {
        const if_full = tree.fullIf(node) orelse return false;
        if (containsImport(tree, if_full.ast.then_expr)) return true;
        if (if_full.ast.else_expr.unwrap()) |else_node| {
            if (containsImport(tree, else_node)) return true;
        }
        return false;
    }
    if (tag == .field_access) {
        return containsImport(tree, tree.nodeData(node).node_and_token[0]);
    }
    return false;
}

fn resolveHead(tree: *const Ast, node: Ast.Node.Index) []const u8 {
    var cur = node;
    while (tree.nodeTag(cur) == .field_access) {
        cur = tree.nodeData(cur).node_and_token[0];
    }
    if (tree.nodeTag(cur) == .identifier) {
        return tree.tokenSlice(tree.nodeMainToken(cur));
    }
    return "";
}

fn firstToken(tree: *const Ast, node: Ast.Node.Index, var_decl: Ast.full.VarDecl) Ast.TokenIndex {
    if (var_decl.visib_token) |vt| return vt;
    _ = tree;
    _ = node;
    return var_decl.ast.mut_token;
}

fn tokenStart(tree: *const Ast, tok: Ast.TokenIndex) usize {
    return tree.tokens.items(.start)[tok];
}

fn lastTokenEnd(tree: *const Ast, node: Ast.Node.Index) usize {
    const last_tok = tree.lastToken(node);
    const start = tree.tokens.items(.start)[last_tok];
    const slice = tree.tokenSlice(last_tok);
    return start + slice.len;
}

fn findDeclEnd(source: []const u8, after_semi: usize) usize {
    var pos = after_semi;
    while (pos < source.len and source[pos] != '\n') pos += 1;
    if (pos < source.len) pos += 1;
    return pos;
}

fn collectAttachedComments(arena: Allocator, source: []const u8, decl_start: usize) ![]const []const u8 {
    var comment_lines: std.ArrayList([]const u8) = .empty;
    var pos = decl_start;

    while (pos > 0) {
        var line_end = pos;
        if (line_end > 0 and source[line_end - 1] == '\n') line_end -= 1;
        var line_start = line_end;
        while (line_start > 0 and source[line_start - 1] != '\n') line_start -= 1;

        const line = mem.trimEnd(u8, source[line_start..line_end], " \t\r");
        const trimmed = mem.trimStart(u8, line, " \t");

        if (trimmed.len == 0) break;
        if (!mem.startsWith(u8, trimmed, "//")) break;
        if (mem.startsWith(u8, trimmed, "//!")) break;

        var full_line = source[line_start..line_end];
        if (line_end < source.len and source[line_end] == '\n') {
            full_line = source[line_start .. line_end + 1];
        }
        try comment_lines.insert(arena, 0, mem.trimEnd(u8, full_line, "\r\n"));
        pos = line_start;
    }

    return comment_lines.toOwnedSlice(arena);
}
