//! Traverses local `pub` import graphs to discover which Zig files belong to a library's public API surface.

const std = @import("std");

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

const Crawler = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    seen: *std.StringHashMap(void),
    files: *std.ArrayList([]const u8),
    group: std.Io.Group = .init,
    pub_only: bool,
    err: ?anyerror = null,

    fn hasErr(self: *Crawler) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.err != null;
    }

    fn setErr(self: *Crawler, err: anyerror) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.err == null) {
            self.err = err;
        }
    }

    fn crawlTask(self: *Crawler, path: []const u8) std.Io.Cancelable!void {
        if (self.hasErr()) return;

        var imports: std.ArrayList([]const u8) = .empty;
        var i: usize = 0;
        defer {
            while (i < imports.items.len) : (i += 1) {
                self.allocator.free(imports.items[i]);
            }
            imports.deinit(self.allocator);
        }

        if (self.pub_only) {
            collectPublicImportsFromFile(
                self.allocator,
                self.io,
                path,
                &imports,
            ) catch |e| {
                self.setErr(e);
                return;
            };
        } else {
            collectAllImportsFromFile(
                self.allocator,
                self.io,
                path,
                &imports,
            ) catch |e| {
                self.setErr(e);
                return;
            };
        }

        while (i < imports.items.len) {
            const candidate = imports.items[i];

            try self.mutex.lock(self.io);
            if (self.err != null) {
                self.mutex.unlock(self.io);
                return;
            }

            if (self.seen.contains(candidate)) {
                self.mutex.unlock(self.io);
                self.allocator.free(candidate);
                i += 1;
                continue;
            }

            self.files.append(self.allocator, candidate) catch |e| {
                self.mutex.unlock(self.io);
                self.setErr(e);
                return;
            };

            self.seen.put(candidate, {}) catch |e| {
                self.mutex.unlock(self.io);
                self.setErr(e);
                return;
            };

            self.mutex.unlock(self.io);

            i += 1;

            self.group.async(
                self.io,
                crawlTask,
                .{ self, candidate },
            );
        }
    }
};

fn collectReachableGeneric(
    allocator: std.mem.Allocator,
    io: std.Io,
    root_path: []const u8,
    pub_only: bool,
) !std.ArrayList([]const u8) {
    var files: std.ArrayList([]const u8) = .empty;
    errdefer deinitOwnedPaths(allocator, &files);

    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    const root_abs = try realPathFileAlloc(
        allocator,
        io,
        root_path,
    );
    try files.append(allocator, root_abs);
    try seen.put(files.items[0], {});

    var crawler = Crawler{
        .allocator = allocator,
        .io = io,
        .seen = &seen,
        .files = &files,
        .pub_only = pub_only,
    };

    crawler.group.async(
        io,
        Crawler.crawlTask,
        .{ &crawler, root_abs },
    );
    try crawler.group.await(io);

    if (crawler.err) |err| return err;
    return files;
}

/// Collects local Zig files that are publicly reachable from a root entry file.
pub fn collectReachablePublicFiles(
    allocator: std.mem.Allocator,
    io: std.Io,
    root_path: []const u8,
) !std.ArrayList([]const u8) {
    return collectReachableGeneric(
        allocator,
        io,
        root_path,
        true,
    );
}

/// Collects local Zig files reachable from `root_path` by following every file-scope `@import("…zig")`.
pub fn collectReachableFiles(
    allocator: std.mem.Allocator,
    io: std.Io,
    root_path: []const u8,
) !std.ArrayList([]const u8) {
    return collectReachableGeneric(
        allocator,
        io,
        root_path,
        false,
    );
}

/// Frees every owned path in `paths` and then deinits the list.
pub fn deinitOwnedPaths(allocator: std.mem.Allocator, paths: *std.ArrayList([]const u8)) void {
    for (paths.items) |path| allocator.free(path);
    paths.deinit(allocator);
}

/// Returns whether an AST node tag is any container declaration form.
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

fn collectAllImportsFromFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    file_path: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    const source_text = std.Io.Dir.cwd().readFileAllocOptions(
        io,
        file_path,
        allocator,
        .limited(std.math.maxInt(u32)),
        .of(u8),
        0,
    ) catch return;
    defer allocator.free(source_text);

    var tree = std.zig.Ast.parse(
        allocator,
        source_text,
        .zig,
    ) catch return;
    defer tree.deinit(allocator);

    for (tree.rootDecls()) |decl| {
        try collectAllImportsFromNode(
            allocator,
            io,
            &tree,
            decl,
            file_path,
            out,
        );
    }
}

fn collectAllImportsFromNode(
    allocator: std.mem.Allocator,
    io: std.Io,
    tree: *const std.zig.Ast,
    node: std.zig.Ast.Node.Index,
    current_file: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    if (tree.fullVarDecl(node)) |var_decl| {
        if (var_decl.ast.init_node.unwrap()) |init_node| {
            if (getImportPathFromExpr(tree, init_node)) |import_path|
                if (try resolveLocalZigImport(
                    allocator,
                    io,
                    current_file,
                    import_path,
                )) |abs|
                    try out.append(allocator, abs);

            if (isContainerDecl(tree.nodeTag(init_node))) {
                var buf: [2]std.zig.Ast.Node.Index = undefined;

                if (tree.fullContainerDecl(&buf, init_node)) |container|
                    for (container.ast.members) |member|
                        try collectAllImportsFromNode(
                            allocator,
                            io,
                            tree,
                            member,
                            current_file,
                            out,
                        );
            }
        }

        return;
    }

    if (isContainerDecl(tree.nodeTag(node))) {
        var buf: [2]std.zig.Ast.Node.Index = undefined;

        if (tree.fullContainerDecl(&buf, node)) |container|
            for (container.ast.members) |member|
                try collectAllImportsFromNode(
                    allocator,
                    io,
                    tree,
                    member,
                    current_file,
                    out,
                );
    }
}

fn collectPublicImportsFromFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    file_path: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    const source_text = std.Io.Dir.cwd().readFileAllocOptions(
        io,
        file_path,
        allocator,
        .limited(std.math.maxInt(u32)),
        .of(u8),
        0,
    ) catch return;
    defer allocator.free(source_text);

    var tree = std.zig.Ast.parse(
        allocator,
        source_text,
        .zig,
    ) catch return;
    defer tree.deinit(allocator);

    for (tree.rootDecls()) |decl| {
        try collectPublicImportsFromNode(
            allocator,
            io,
            &tree,
            decl,
            file_path,
            out,
        );
    }
}

fn collectPublicImportsFromNode(
    allocator: std.mem.Allocator,
    io: std.Io,
    tree: *const std.zig.Ast,
    node: std.zig.Ast.Node.Index,
    current_file: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    if (tree.fullVarDecl(node)) |var_decl| {
        if (var_decl.ast.init_node.unwrap()) |init_node| {
            if (var_decl.visib_token) |vt| {
                if (tree.tokenTag(vt) == .keyword_pub) {
                    if (getImportPathFromExpr(tree, init_node)) |import_path| {
                        if (try resolveLocalZigImport(
                            allocator,
                            io,
                            current_file,
                            import_path,
                        )) |abs| {
                            try out.append(allocator, abs);
                        }
                    }
                }
            }

            if (isContainerDecl(tree.nodeTag(init_node))) {
                var buf: [2]std.zig.Ast.Node.Index = undefined;
                if (tree.fullContainerDecl(&buf, init_node)) |container| {
                    for (container.ast.members) |member| {
                        try collectPublicImportsFromNode(
                            allocator,
                            io,
                            tree,
                            member,
                            current_file,
                            out,
                        );
                    }
                }
            }
        }
        return;
    }

    if (isContainerDecl(tree.nodeTag(node))) {
        var buf: [2]std.zig.Ast.Node.Index = undefined;
        if (tree.fullContainerDecl(&buf, node)) |container| {
            for (container.ast.members) |member| {
                try collectPublicImportsFromNode(
                    allocator,
                    io,
                    tree,
                    member,
                    current_file,
                    out,
                );
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
    if (!std.mem.eql(
        u8,
        tree.tokenSlice(builtin_tok),
        "@import",
    )) return null;

    const args = tree.nodeData(node).opt_node_and_opt_node;
    const arg_node = args[0].unwrap() orelse return null;
    if (tree.nodeTag(arg_node) != .string_literal) return null;

    const str_tok = tree.nodeMainToken(arg_node);
    const raw = tree.tokenSlice(str_tok);
    if (raw.len < 2 or raw[0] != '"' or raw[raw.len - 1] != '"') return null;
    return raw[1 .. raw.len - 1];
}

fn resolveLocalZigImport(
    allocator: std.mem.Allocator,
    io: std.Io,
    current_file: []const u8,
    import_path: []const u8,
) !?[]const u8 {
    // Package imports like "std" are intentionally excluded from local reachability.
    if (!std.mem.endsWith(
        u8,
        import_path,
        ".zig",
    )) return null;
    if (std.fs.path.isAbsolute(import_path)) return null;

    const base_dir = std.fs.path.dirname(current_file) orelse ".";
    const joined = try std.fs.path.join(allocator, &.{ base_dir, import_path });
    defer allocator.free(joined);

    const abs = realPathFileAlloc(
        allocator,
        io,
        joined,
    ) catch return null;

    const stat = std.Io.Dir.openFileAbsolute(
        io,
        abs,
        .{},
    ) catch {
        allocator.free(abs);
        return null;
    };
    stat.close(io);

    return abs;
}
