//! Resolves local `@import` re-export expressions for documentation rules.
//!
//! ## Member re-exports
//!
//! For `pub const Foo = @import("other.zig").Bar`, the resolver follows the re-export chain
//! transitively and evaluates the rule predicate at the final resolved declaration.
//!
//! - When the resolved declaration satisfies the predicate, no diagnostic is emitted.
//! - When it does not, callbacks report at the resolved declaration site, not the re-export line.
//!
//! ## Whole-module re-exports
//!
//! For `pub const ns = @import("enums.zig")`, the resolver loads the imported file and evaluates
//! the predicate against its container doc comment block (`//!`).
//!
//! ## Unresolvable imports
//!
//! Missing files, package imports, parse failures, and unknown symbols are silently skipped so
//! re-export lines never produce false positives.

const std = @import("std");
const Ast = std.zig.Ast;
const vereda = @import("vereda");

const helpers = @import("../rules/utils/helpers.zig");
const doc = @import("../doc.zig");

/// Extracted info about a potential re-export expression.
pub const Info = struct {
    /// Raw import path from `@import("…")`, without quotes.
    import_path: []const u8,
    /// The identifier after the dot, e.g. `"Level"` in `@import(…).Level`.
    /// Null when re-exporting the entire file/module directly.
    field_name: ?[]const u8,
};

/// A root-level declaration located by name in an imported file.
pub const FoundDecl = struct {
    node: Ast.Node.Index,
    first_tok: Ast.TokenIndex,
    name_tok: Ast.TokenIndex,
};

const ResolveOutcome = enum {
    documented,
    undocumented,
    unresolved,
};

/// Returns info when `node` matches `@import("path").Field`, `@import("path")`, or `alias.field`
/// where `alias` is a file-local `@import` binding.
pub fn getInfo(tree: *const Ast, node: Ast.Node.Index) ?Info {
    const tag = tree.nodeTag(node);
    if (tag == .field_access) {
        const fa = tree.nodeData(node).node_and_token;
        const obj_node: Ast.Node.Index = fa[0];
        const field_name_tok: Ast.TokenIndex = fa[1];

        if (tree.tokenTag(field_name_tok) != .identifier) return null;

        const field_name = tree.tokenSlice(field_name_tok);

        if (getImportPath(tree, obj_node)) |import_path| {
            return .{
                .import_path = import_path,
                .field_name = field_name,
            };
        }

        if (tree.nodeTag(obj_node) == .identifier) {
            const alias = tree.tokenSlice(tree.nodeMainToken(obj_node));
            if (findLocalImportPath(tree, alias)) |import_path| {
                return .{
                    .import_path = import_path,
                    .field_name = field_name,
                };
            }
        }

        return null;
    } else if (getImportPath(tree, node)) |import_path| {
        return .{
            .import_path = import_path,
            .field_name = null,
        };
    }
    return null;
}

/// Resolves `import_path` relative to `current_file` and returns a normalized path.
pub fn resolveImportedPath(
    allocator: std.mem.Allocator,
    current_file: []const u8,
    import_path: []const u8,
) ![]const u8 {
    const base_dir = std.fs.path.dirname(current_file) orelse ".";
    const joined = try std.fs.path.join(allocator, &.{ base_dir, import_path });
    defer allocator.free(joined);
    return vereda.path.toPosixSeparators(allocator, joined);
}

/// Reads and parses a local `.zig` file. Caller owns and must deinit the returned AST and free `source`.
pub fn readParsedFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    file_path: []const u8,
) !struct { source: [:0]const u8, tree: Ast } {
    const source = try std.Io.Dir.cwd().readFileAllocOptions(
        io,
        file_path,
        allocator,
        .limited(std.math.maxInt(u32)),
        .of(u8),
        0,
    );
    errdefer allocator.free(source);

    const tree = std.zig.Ast.parse(allocator, source, .zig) catch {
        allocator.free(source);
        return error.ParseFailed;
    };

    return .{ .source = source, .tree = tree };
}

/// Searches `decl` (a root-level node) for a declaration named `name`.
pub fn findNamedDecl(tree: *const Ast, decl: Ast.Node.Index, name: []const u8) ?FoundDecl {
    if (tree.fullVarDecl(decl)) |vd| {
        const nt = vd.ast.mut_token + 1;
        if (std.mem.eql(u8, tree.tokenSlice(nt), name))
            return .{ .node = decl, .first_tok = vd.firstToken(), .name_tok = nt };
    }
    if (tree.nodeTag(decl) == .fn_decl) {
        var buf: [1]Ast.Node.Index = undefined;
        if (tree.fullFnProto(&buf, decl)) |proto| {
            if (proto.name_token) |nt| {
                if (std.mem.eql(u8, tree.tokenSlice(nt), name))
                    return .{ .node = decl, .first_tok = proto.firstToken(), .name_tok = nt };
            }
        }
    }
    return null;
}

/// Callbacks invoked when a missing-documentation predicate fails at the resolved site.
pub const MissingDocCallbacks = struct {
    on_undocumented_member: *const fn (
        ctx: *anyopaque,
        tree: *const Ast,
        name_tok: Ast.TokenIndex,
        display_symbol: []const u8,
        file_path: []const u8,
    ) anyerror!void,
    on_undocumented_whole_module: *const fn (
        ctx: *anyopaque,
        tree: *const Ast,
        file_path: []const u8,
    ) anyerror!void,
};

/// Follows a re-export chain for a member or whole-module import and checks line/container doc comments.
///
/// Returns `true` when `info` described a re-export (the caller must not emit a local diagnostic).
/// Only `OutOfMemory` is propagated; all other resolution failures are treated as handled re-exports.
pub fn resolveMissingDocReexport(
    info: Info,
    decl_name: []const u8,
    current_file: []const u8,
    allocator: std.mem.Allocator,
    io: std.Io,
    ctx: *anyopaque,
    callbacks: MissingDocCallbacks,
) std.mem.Allocator.Error!bool {
    resolveMissingDocReexportImpl(info, decl_name, current_file, allocator, io, ctx, callbacks) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return true,
    };
    return true;
}

fn dummyOnUndocumentedMember(
    ctx: *anyopaque,
    tree: *const Ast,
    name_tok: Ast.TokenIndex,
    display_symbol: []const u8,
    file_path: []const u8,
) anyerror!void {
    _ = ctx;
    _ = tree;
    _ = name_tok;
    _ = display_symbol;
    _ = file_path;
}

fn dummyOnUndocumentedWholeModule(
    ctx: *anyopaque,
    tree: *const Ast,
    file_path: []const u8,
) anyerror!void {
    _ = ctx;
    _ = tree;
    _ = file_path;
}

/// Follows a re-export chain and returns true if the target definition is documented.
/// Returns false if target is undocumented, unresolved, or failed to parse.
pub fn isTargetDocumented(
    info: Info,
    decl_name: []const u8,
    current_file: []const u8,
    allocator: std.mem.Allocator,
    io: std.Io,
) std.mem.Allocator.Error!bool {
    const imported_path = try resolveImportedPath(allocator, current_file, info.import_path);
    defer allocator.free(imported_path);

    const outcome = resolveDocForSymbolInFile(
        imported_path,
        info.field_name,
        info.field_name orelse decl_name,
        allocator,
        io,
        undefined,
        .{
            .on_undocumented_member = dummyOnUndocumentedMember,
            .on_undocumented_whole_module = dummyOnUndocumentedWholeModule,
        },
        0,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    return outcome == .documented;
}


/// When `info.field_name == null`, evaluates `predicate` on the imported module's container doc block.
///
/// Only `OutOfMemory` is propagated; other resolution failures are silently ignored.
pub fn resolveWholeModuleReexport(
    info: Info,
    current_file: []const u8,
    allocator: std.mem.Allocator,
    io: std.Io,
    ctx: *anyopaque,
    predicate: *const fn (tree: *const Ast) bool,
    on_match: *const fn (ctx: *anyopaque, tree: *const Ast, file_path: []const u8) anyerror!void,
) std.mem.Allocator.Error!void {
    resolveWholeModuleReexportImpl(info, current_file, allocator, io, ctx, predicate, on_match) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {},
    };
}

fn resolveMissingDocReexportImpl(
    info: Info,
    decl_name: []const u8,
    current_file: []const u8,
    allocator: std.mem.Allocator,
    io: std.Io,
    ctx: *anyopaque,
    callbacks: MissingDocCallbacks,
) !void {
    const imported_path = try resolveImportedPath(allocator, current_file, info.import_path);
    defer allocator.free(imported_path);

    _ = try resolveDocForSymbolInFile(
        imported_path,
        info.field_name,
        info.field_name orelse decl_name,
        allocator,
        io,
        ctx,
        callbacks,
        0,
    );
}

fn resolveWholeModuleReexportImpl(
    info: Info,
    current_file: []const u8,
    allocator: std.mem.Allocator,
    io: std.Io,
    ctx: *anyopaque,
    predicate: *const fn (tree: *const Ast) bool,
    on_match: *const fn (ctx: *anyopaque, tree: *const Ast, file_path: []const u8) anyerror!void,
) !void {
    if (info.field_name != null) return;

    const imported_path = try resolveImportedPath(allocator, current_file, info.import_path);
    defer allocator.free(imported_path);

    var parsed = readParsedFile(allocator, io, imported_path) catch return;
    defer allocator.free(parsed.source);
    defer parsed.tree.deinit(allocator);

    if (!predicate(&parsed.tree)) return;
    try on_match(ctx, &parsed.tree, imported_path);
}

fn resolveDocForSymbolInFile(
    file_path: []const u8,
    symbol_name: ?[]const u8,
    display_symbol: []const u8,
    allocator: std.mem.Allocator,
    io: std.Io,
    ctx: *anyopaque,
    callbacks: MissingDocCallbacks,
    depth: usize,
) !ResolveOutcome {
    if (depth > 32) return .unresolved;

    const source = try std.Io.Dir.cwd().readFileAllocOptions(
        io,
        file_path,
        allocator,
        .limited(std.math.maxInt(u32)),
        .of(u8),
        0,
    );
    defer allocator.free(source);

    var imported_tree = try std.zig.Ast.parse(allocator, source, .zig);
    defer imported_tree.deinit(allocator);

    if (symbol_name) |sym_name| {
        for (imported_tree.rootDecls()) |decl| {
            const found = findNamedDecl(&imported_tree, decl, sym_name) orelse continue;
            if (hasLineDocComment(&imported_tree, found.first_tok)) {
                return .documented;
            }

            if (imported_tree.fullVarDecl(found.node)) |vd| {
                const init_node = vd.ast.init_node.unwrap() orelse {
                    try callbacks.on_undocumented_member(ctx, &imported_tree, found.name_tok, display_symbol, file_path);
                    return .undocumented;
                };

                if (getInfo(&imported_tree, init_node)) |nested| {
                    const nested_imported_path = try resolveImportedPath(allocator, file_path, nested.import_path);
                    defer allocator.free(nested_imported_path);

                    return try resolveDocForSymbolInFile(
                        nested_imported_path,
                        nested.field_name,
                        display_symbol,
                        allocator,
                        io,
                        ctx,
                        callbacks,
                        depth + 1,
                    );
                }
            }

            try callbacks.on_undocumented_member(ctx, &imported_tree, found.name_tok, display_symbol, file_path);
            return .undocumented;
        }

        return .unresolved;
    }

    if (doc.hasContainerDocComment(&imported_tree, 0)) {
        return .documented;
    }

    try callbacks.on_undocumented_whole_module(ctx, &imported_tree, file_path);
    return .undocumented;
}

fn hasLineDocComment(tree: *const Ast, first_token: Ast.TokenIndex) bool {
    if (first_token == 0) return false;
    return tree.tokenTag(first_token - 1) == .doc_comment;
}

fn findLocalImportPath(tree: *const Ast, alias: []const u8) ?[]const u8 {
    for (tree.rootDecls()) |decl| {
        if (tree.fullVarDecl(decl)) |vd| {
            const name_tok = vd.ast.mut_token + 1;
            if (!std.mem.eql(u8, tree.tokenSlice(name_tok), alias)) continue;
            const init_node = vd.ast.init_node.unwrap() orelse continue;
            if (getImportPath(tree, init_node)) |path| return path;
        }
    }
    return null;
}

fn getImportPath(tree: *const Ast, node: Ast.Node.Index) ?[]const u8 {
    const tag = tree.nodeTag(node);

    if (tag == .field_access) {
        const fa = tree.nodeData(node).node_and_token;
        return getImportPath(tree, fa[0]);
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
