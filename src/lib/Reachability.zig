const std = @import("std");

pub fn collectReachablePublicFiles(allocator: std.mem.Allocator, root_path: []const u8) !std.ArrayList([]const u8) {
    var files: std.ArrayList([]const u8) = .empty;
    errdefer deinitOwnedPaths(allocator, &files);

    var queue: std.ArrayList(usize) = .empty;
    defer queue.deinit(allocator);

    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    const root_abs = std.fs.cwd().realpathAlloc(allocator, root_path) catch {
        return files;
    };

    try files.append(allocator, root_abs);
    try seen.put(files.items[0], {});
    try queue.append(allocator, 0);

    var i: usize = 0;
    while (i < queue.items.len) : (i += 1) {
        const file_idx = queue.items[i];
        const current_path = files.items[file_idx];

        var imports: std.ArrayList([]const u8) = .empty;
        defer {
            for (imports.items) |p| allocator.free(p);
            imports.deinit(allocator);
        }

        try collectPublicImportsFromFile(allocator, current_path, &imports);

        for (imports.items) |candidate| {
            if (seen.contains(candidate)) {
                allocator.free(candidate);
                continue;
            }

            try files.append(allocator, candidate);
            try seen.put(files.items[files.items.len - 1], {});
            try queue.append(allocator, files.items.len - 1);
        }

        imports.clearRetainingCapacity();
    }

    return files;
}

pub fn deinitOwnedPaths(allocator: std.mem.Allocator, paths: *std.ArrayList([]const u8)) void {
    for (paths.items) |path| allocator.free(path);
    paths.deinit(allocator);
}

pub fn isContainerDecl(tag: std.zig.Ast.Node.Tag) bool {
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

fn collectPublicImportsFromFile(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    const f = std.fs.openFileAbsolute(file_path, .{}) catch return;
    defer f.close();

    const source = f.readToEndAllocOptions(allocator, std.math.maxInt(u32), null, .of(u8), 0) catch return;
    defer allocator.free(source);

    var tree = std.zig.Ast.parse(allocator, source, .zig) catch return;
    defer tree.deinit(allocator);

    for (tree.rootDecls()) |decl| {
        try collectPublicImportsFromNode(allocator, &tree, decl, file_path, out);
    }
}

fn collectPublicImportsFromNode(
    allocator: std.mem.Allocator,
    tree: *const std.zig.Ast,
    node: std.zig.Ast.Node.Index,
    current_file: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    if (tree.fullVarDecl(node)) |var_decl| {
        if (var_decl.visib_token) |vt| {
            if (tree.tokenTag(vt) == .keyword_pub) {
                const init_node = var_decl.ast.init_node.unwrap() orelse return;
                if (getImportPathFromExpr(tree, init_node)) |import_path| {
                    if (!std.mem.endsWith(u8, import_path, ".zig")) return;

                    const base_dir = std.fs.path.dirname(current_file) orelse ".";
                    const joined = try std.fs.path.join(allocator, &.{ base_dir, import_path });
                    defer allocator.free(joined);

                    const abs = std.fs.cwd().realpathAlloc(allocator, joined) catch return;
                    try out.append(allocator, abs);
                }
            }
        }

        const init_node = var_decl.ast.init_node.unwrap() orelse return;
        if (isContainerDecl(tree.nodeTag(init_node))) {
            var buf: [2]std.zig.Ast.Node.Index = undefined;
            if (tree.fullContainerDecl(&buf, init_node)) |container| {
                for (container.ast.members) |member| {
                    try collectPublicImportsFromNode(allocator, tree, member, current_file, out);
                }
            }
        }
        return;
    }

    if (isContainerDecl(tree.nodeTag(node))) {
        var buf: [2]std.zig.Ast.Node.Index = undefined;
        if (tree.fullContainerDecl(&buf, node)) |container| {
            for (container.ast.members) |member| {
                try collectPublicImportsFromNode(allocator, tree, member, current_file, out);
            }
        }
    }
}

fn getImportPathFromExpr(tree: *const std.zig.Ast, node: std.zig.Ast.Node.Index) ?[]const u8 {
    const tag = tree.nodeTag(node);

    if (tag == .field_access) {
        const fa = tree.nodeData(node).node_and_token;
        return getImportPathFromExpr(tree, fa[0]);
    }

    if (tag != .builtin_call_two and tag != .builtin_call_two_comma) return null;

    const builtin_tok = tree.nodeMainToken(node);
    if (tree.tokenTag(builtin_tok) != .builtin) return null;
    if (!std.mem.eql(u8, tree.tokenSlice(builtin_tok), "@import")) return null;

    const args = tree.nodeData(node).opt_node_and_opt_node;
    const arg_node = args[0].unwrap() orelse return null;
    if (tree.nodeTag(arg_node) != .string_literal) return null;

    const str_tok = tree.nodeMainToken(arg_node);
    const raw = tree.tokenSlice(str_tok);
    if (raw.len < 2 or raw[0] != '"' or raw[raw.len - 1] != '"') return null;
    return raw[1 .. raw.len - 1];
}
