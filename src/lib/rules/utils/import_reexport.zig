//! Shared helpers for resolving local `@import` re-exports in documentation rules.

const std = @import("std");
const Ast = std.zig.Ast;

const helpers = @import("helpers.zig");

/// Extracted info about a potential re-export expression.
pub const Info = struct {
    /// Raw import path from `@import("…")`, without quotes.
    import_path: []const u8,
    /// The identifier after the dot, e.g. `"Level"` in `@import(…).Level`.
    /// Null when re-exporting the entire file/module directly.
    field_name: ?[]const u8,
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

/// Resolves `import_path` relative to `current_file` and returns a normalized absolute path.
pub fn resolveImportedPath(
    allocator: std.mem.Allocator,
    current_file: []const u8,
    import_path: []const u8,
) ![]const u8 {
    const base_dir = std.fs.path.dirname(current_file) orelse ".";
    const joined = try std.fs.path.join(allocator, &.{ base_dir, import_path });
    defer allocator.free(joined);
    return helpers.normalizePathSeparators(allocator, joined);
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
    const t = tree.nodeTag(node);
    if (t != .builtin_call_two and t != .builtin_call_two_comma) return null;

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
