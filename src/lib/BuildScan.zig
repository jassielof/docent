//! Lightweight AST scan of `build.zig` to discover lint targets and dependency names.

const std = @import("std");

/// Kind of build step discovered in `build.zig`.
pub const TargetKind = enum {
    /// Library module or `addLibrary` / `addModule` target.
    lib,
    /// Executable from `addExecutable`.
    bin,
    /// Test artifact from `addTest`.
    test_target,
};

/// One lintable target extracted from the build script.
pub const Target = struct {
    /// Step or module name (for example `docent` or `default`).
    name: []const u8,
    /// Whether this target is a library, binary, or test.
    kind: TargetKind,
    /// `root_source_file` path as written in the build script.
    root_source_file: []const u8,
};

/// Parsed output from scanning a `build.zig` file.
pub const Result = struct {
    /// Library, executable, and test targets with root source files.
    targets: []const Target,
    /// Dependency names passed to `b.dependency(...)` (for example `fangz`).
    dependencies: []const []const u8,

    /// Frees all owned target and dependency strings.
    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        for (self.targets) |t| {
            allocator.free(t.name);
            allocator.free(t.root_source_file);
        }
        allocator.free(self.targets);

        for (self.dependencies) |d| {
            allocator.free(d);
        }
        allocator.free(self.dependencies);

        self.* = .{ .targets = &.{}, .dependencies = &.{} };
    }
};

const CallInfo = struct {
    method: []const u8,
    params: [8]std.zig.Ast.Node.Index = undefined,
    params_len: usize = 0,
};

fn matchBuilderCall(tree: std.zig.Ast, node: std.zig.Ast.Node.Index, b_name: []const u8) ?CallInfo {
    const tag = tree.nodeTag(node);
    var fn_expr: std.zig.Ast.Node.Index = undefined;
    var call_info = CallInfo{ .method = "", .params_len = 0 };

    switch (tag) {
        .call, .call_comma => {
            const call = tree.callFull(node);
            fn_expr = call.ast.fn_expr;
            for (call.ast.params) |param| {
                if (call_info.params_len >= 8) break;
                call_info.params[call_info.params_len] = param;
                call_info.params_len += 1;
            }
        },
        .call_one, .call_one_comma => {
            const data = tree.nodeData(node).node_and_opt_node;
            fn_expr = data[0];
            if (data[1].unwrap()) |arg| {
                call_info.params[0] = arg;
                call_info.params_len = 1;
            }
        },
        else => return null,
    }

    const fn_expr_tag = tree.nodeTag(fn_expr);
    if (fn_expr_tag == .field_access) {
        const node_data = tree.nodeData(fn_expr);
        const lhs = node_data.node_and_token[0];
        const tok = node_data.node_and_token[1];

        if (tree.nodeTag(lhs) == .identifier) {
            const receiver = tree.tokenSlice(tree.nodeMainToken(lhs));
            if (std.mem.eql(u8, receiver, b_name)) {
                call_info.method = tree.tokenSlice(tok);
                return call_info;
            }
        }
    }
    return null;
}

fn getPathOrString(tree: std.zig.Ast, node: std.zig.Ast.Node.Index, b_name: []const u8, var_paths: std.StringHashMap([]const u8)) ?[]const u8 {
    const tag = tree.nodeTag(node);
    if (tag == .string_literal) {
        const slice = tree.tokenSlice(tree.nodeMainToken(node));
        if (slice.len >= 2) {
            return slice[1 .. slice.len - 1];
        }
    } else if (tag == .identifier) {
        const ident = tree.tokenSlice(tree.nodeMainToken(node));
        return var_paths.get(ident);
    } else if (matchBuilderCall(tree, node, b_name)) |call| {
        if (std.mem.eql(u8, call.method, "path") and call.params_len > 0) {
            return getPathOrString(tree, call.params[0], b_name, var_paths);
        }
    }
    return null;
}

fn resolveModuleSource(
    tree: std.zig.Ast,
    node: std.zig.Ast.Node.Index,
    b_name: []const u8,
    var_paths: *std.StringHashMap([]const u8),
    targets: *std.ArrayList(Target),
    dependencies: *std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
) anyerror!?[]const u8 {
    const tag = tree.nodeTag(node);
    if (tag == .identifier) {
        const ref_var = tree.tokenSlice(tree.nodeMainToken(node));
        return var_paths.get(ref_var);
    }
    return try scanCall(tree, node, b_name, var_paths, targets, dependencies, allocator);
}

fn scanCall(
    tree: std.zig.Ast,
    node: std.zig.Ast.Node.Index,
    b_name: []const u8,
    var_paths: *std.StringHashMap([]const u8),
    targets: *std.ArrayList(Target),
    dependencies: *std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
) anyerror!?[]const u8 {
    var resolved_src: ?[]const u8 = null;

    if (matchBuilderCall(tree, node, b_name)) |call| {
        if (std.mem.eql(u8, call.method, "dependency") and call.params_len > 0) {
            if (getPathOrString(tree, call.params[0], b_name, var_paths.*)) |dep_name| {
                var found = false;
                for (dependencies.items) |d| {
                    if (std.mem.eql(u8, d, dep_name)) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    try dependencies.append(allocator, try allocator.dupe(u8, dep_name));
                }
            }
        } else {
            const is_lib = std.mem.eql(u8, call.method, "addLibrary") or
                std.mem.eql(u8, call.method, "addSharedLibrary") or
                std.mem.eql(u8, call.method, "addStaticLibrary") or
                std.mem.eql(u8, call.method, "addModule") or
                std.mem.eql(u8, call.method, "createModule");
            const is_bin = std.mem.eql(u8, call.method, "addExecutable");
            const is_test = std.mem.eql(u8, call.method, "addTest");

            if (is_lib or is_bin or is_test) {
                var name: ?[]const u8 = null;
                var root_src: ?[]const u8 = null;

                const kind: TargetKind = if (is_lib) .lib else if (is_bin) .bin else .test_target;

                if (std.mem.eql(u8, call.method, "addModule") or std.mem.eql(u8, call.method, "createModule")) {
                    const opts_node = if (std.mem.eql(u8, call.method, "addModule") and call.params_len > 1)
                        call.params[1]
                    else
                        call.params[0];

                    if (std.mem.eql(u8, call.method, "addModule") and call.params_len > 0) {
                        name = getPathOrString(tree, call.params[0], b_name, var_paths.*);
                    }

                    var struct_buf: [2]std.zig.Ast.Node.Index = undefined;
                    if (tree.fullStructInit(&struct_buf, opts_node)) |struct_init| {
                        for (struct_init.ast.fields) |field_node| {
                            const first_tok = tree.firstToken(field_node);
                            if (tree.tokens.items(.tag)[first_tok - 1] == .equal) {
                                const field_name = tree.tokenSlice(first_tok - 2);
                                if (std.mem.eql(u8, field_name, "root_source_file")) {
                                    root_src = getPathOrString(tree, field_node, b_name, var_paths.*);
                                }
                            }
                        }
                    }
                } else {
                    if (call.params_len > 0) {
                        const opts_node = call.params[0];
                        var struct_buf: [2]std.zig.Ast.Node.Index = undefined;
                        if (tree.fullStructInit(&struct_buf, opts_node)) |struct_init| {
                            for (struct_init.ast.fields) |field_node| {
                                const first_tok = tree.firstToken(field_node);
                                if (tree.tokens.items(.tag)[first_tok - 1] == .equal) {
                                    const field_name = tree.tokenSlice(first_tok - 2);
                                    if (std.mem.eql(u8, field_name, "name")) {
                                        name = getPathOrString(tree, field_node, b_name, var_paths.*);
                                    } else if (std.mem.eql(u8, field_name, "root_source_file")) {
                                        root_src = getPathOrString(tree, field_node, b_name, var_paths.*);
                                    } else if (std.mem.eql(u8, field_name, "root_module")) {
                                        root_src = try resolveModuleSource(tree, field_node, b_name, var_paths, targets, dependencies, allocator);
                                    }
                                }
                            }
                        }
                    }
                }

                if (root_src) |src| {
                    const target_name = name orelse "default";
                    var found = false;
                    for (targets.items) |t| {
                        if (std.mem.eql(u8, t.name, target_name) and t.kind == kind and std.mem.eql(u8, t.root_source_file, src)) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        try targets.append(allocator, .{
                            .name = try allocator.dupe(u8, target_name),
                            .kind = kind,
                            .root_source_file = try allocator.dupe(u8, src),
                        });
                    }
                    resolved_src = src;
                }
            }
        }
    }

    const tag = tree.nodeTag(node);
    switch (tag) {
        .call, .call_comma => {
            const call = tree.callFull(node);
            const r = try scanCall(tree, call.ast.fn_expr, b_name, var_paths, targets, dependencies, allocator);
            if (r) |s| resolved_src = s;
            for (call.ast.params) |param| {
                const pr = try scanCall(tree, param, b_name, var_paths, targets, dependencies, allocator);
                if (pr) |s| resolved_src = s;
            }
        },
        .call_one, .call_one_comma => {
            const data = tree.nodeData(node).node_and_opt_node;
            const r1 = try scanCall(tree, data[0], b_name, var_paths, targets, dependencies, allocator);
            if (r1) |s| resolved_src = s;
            if (data[1].unwrap()) |arg| {
                const r2 = try scanCall(tree, arg, b_name, var_paths, targets, dependencies, allocator);
                if (r2) |s| resolved_src = s;
            }
        },
        .field_access => {
            const data = tree.nodeData(node).node_and_token;
            const r = try scanCall(tree, data[0], b_name, var_paths, targets, dependencies, allocator);
            if (r) |s| resolved_src = s;
        },
        .struct_init, .struct_init_comma, .struct_init_dot, .struct_init_dot_comma => {
            var struct_buf: [2]std.zig.Ast.Node.Index = undefined;
            if (tree.fullStructInit(&struct_buf, node)) |struct_init| {
                for (struct_init.ast.fields) |field| {
                    const r = try scanCall(tree, field, b_name, var_paths, targets, dependencies, allocator);
                    if (r) |s| resolved_src = s;
                }
            }
        },
        else => {},
    }

    return resolved_src;
}

/// AST scan of `build.zig` for targets and dependency names.
pub fn scanBuildScript(allocator: std.mem.Allocator, build_text: []const u8) !Result {
    const build_text_z = try allocator.dupeZ(u8, build_text);
    defer allocator.free(build_text_z);

    var tree = try std.zig.Ast.parse(allocator, build_text_z, .zig);
    defer tree.deinit(allocator);

    var var_paths = std.StringHashMap([]const u8).init(allocator);
    defer var_paths.deinit();

    var targets: std.ArrayList(Target) = .empty;
    errdefer {
        for (targets.items) |t| {
            allocator.free(t.name);
            allocator.free(t.root_source_file);
        }
        targets.deinit(allocator);
    }

    var dependencies: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (dependencies.items) |d| allocator.free(d);
        dependencies.deinit(allocator);
    }

    const decls = tree.rootDecls();
    for (decls) |decl| {
        if (tree.nodeTag(decl) == .fn_decl) {
            var buf: [1]std.zig.Ast.Node.Index = undefined;
            const proto = tree.fullFnProto(&buf, decl) orelse continue;
            const fn_name = tree.tokenSlice(proto.name_token orelse continue);
            if (!std.mem.eql(u8, fn_name, "build")) continue;

            var b_name: []const u8 = "b";
            if (proto.ast.params.len > 0) {
                const first_param = proto.ast.params[0];
                const first_tok = tree.firstToken(first_param);
                if (tree.tokens.items(.tag)[first_tok - 1] == .colon) {
                    b_name = tree.tokenSlice(first_tok - 2);
                }
            }

            const body = tree.nodeData(decl).node_and_node[1];
            var block_buf: [2]std.zig.Ast.Node.Index = undefined;
            const stmts = tree.blockStatements(&block_buf, body) orelse continue;

            for (stmts) |stmt| {
                const tag = tree.nodeTag(stmt);
                if (tree.fullVarDecl(stmt)) |var_decl| {
                    const var_name = tree.tokenSlice(var_decl.ast.mut_token + 1);
                    const init_node = var_decl.ast.init_node.unwrap() orelse continue;

                    if (getPathOrString(tree, init_node, b_name, var_paths)) |str| {
                        try var_paths.put(var_name, str);
                    } else {
                        const src = try scanCall(tree, init_node, b_name, &var_paths, &targets, &dependencies, allocator);
                        if (src) |s| {
                            try var_paths.put(var_name, s);
                        }
                    }
                } else if (tag == .assign) {
                    const lhs = tree.nodeData(stmt).node_and_node[0];
                    const rhs = tree.nodeData(stmt).node_and_node[1];
                    const src = try scanCall(tree, rhs, b_name, &var_paths, &targets, &dependencies, allocator);
                    if (src) |s| {
                        if (tree.nodeTag(lhs) == .identifier) {
                            const var_name = tree.tokenSlice(tree.nodeMainToken(lhs));
                            try var_paths.put(var_name, s);
                        }
                    }
                } else {
                    _ = try scanCall(tree, stmt, b_name, &var_paths, &targets, &dependencies, allocator);
                }
            }
        }
    }

    var filtered_targets: std.ArrayList(Target) = .empty;
    errdefer {
        for (filtered_targets.items) |t| {
            allocator.free(t.name);
            allocator.free(t.root_source_file);
        }
        filtered_targets.deinit(allocator);
    }

    for (targets.items, 0..) |t, i| {
        var keep = true;
        if (t.kind == .lib and std.mem.eql(u8, t.name, "default")) {
            for (targets.items, 0..) |other, j| {
                if (i == j) continue;
                if (std.mem.eql(u8, t.root_source_file, other.root_source_file)) {
                    keep = false;
                    break;
                }
            }
        }
        if (keep) {
            try filtered_targets.append(allocator, t);
        } else {
            allocator.free(t.name);
            allocator.free(t.root_source_file);
        }
    }
    targets.deinit(allocator);
    targets = filtered_targets;

    return Result{
        .targets = try targets.toOwnedSlice(allocator),
        .dependencies = try dependencies.toOwnedSlice(allocator),
    };
}

/// Reads and scans `build.zig` at `project_root/build.zig` when present.
pub fn scanProjectBuildScript(allocator: std.mem.Allocator, io: std.Io, project_root: []const u8) !?Result {
    const build_path = try std.fs.path.join(allocator, &.{ project_root, "build.zig" });
    defer allocator.free(build_path);

    const build_text = std.Io.Dir.cwd().readFileAlloc(io, build_path, allocator, .limited(2 * 1024 * 1024)) catch return null;
    defer allocator.free(build_text);

    return try scanBuildScript(allocator, build_text);
}
