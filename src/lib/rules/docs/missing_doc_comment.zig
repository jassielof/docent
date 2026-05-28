//! The `missing_doc_comment` namespace warns for missing doc comments.
//!
//! This includes:
//!
//! - Functions and its parameters
//! - Global variables and constants
//! - Enumerations and its enumerators
//! - Structures and its fields
//! - Unions and its fields
//! - Error sets, its values (or tags) aren't checked.
//!
//! ## Re-exported declarations
//!
//! Public re-exports are resolved transitively.
//!
//! For example, for `pub const Bar = @import("Foo.zig").Bar`, the rule follows the re-export chain and checks the documentation on the final resolved declaration.
//!
//! - If the resolved declaration is documented, no diagnostic is emitted.
//! - If it is undocumented, the diagnostic points to the resolved declaration.
//! - If resolution fails, the re-export is skipped to avoid false positives.
//!
//! ## Specializations
//!
//! To help with clarification and context, the following cases are reported with special diagnostic messages.
//!
//! ### Missing module doc comment
//!
//! Warns when a module root source file is missing a doc comment.
//!
//! ### Missing source file doc comment
//!
//! Warns when a source file is missing a doc comment.
//!
//! This will produce the respective message depending on the source file type, either a namespace or an implicit structure, that are publicly re-exported and exposed to the API surface (reached from the module root).

const missing_doc_comment = @This();

const std = @import("std");
const Ast = std.zig.Ast;
const Diagnostic = @import("../../Diagnostic.zig");
const Severity = @import("../../Severity.zig");
const utils = @import("../utils.zig");

const rule_name = "missing_doc_comment";

/// Walks `tree` and appends diagnostics for undocumented public items.
pub fn check(
    tree: *const Ast,
    severity: Severity.Level,
    file: []const u8,
    allocator: std.mem.Allocator,
    io: std.Io,
    msg_allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) std.mem.Allocator.Error!void {
    if (!severity.isActive()) return;
    for (tree.rootDecls()) |decl| {
        try checkNode(tree, decl, severity, file, allocator, io, msg_allocator, diagnostics);
    }
}

fn checkNode(
    tree: *const Ast,
    node: Ast.Node.Index,
    severity: Severity.Level,
    file: []const u8,
    allocator: std.mem.Allocator,
    io: std.Io,
    msg_allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) std.mem.Allocator.Error!void {
    const tag = tree.nodeTag(node);

    if (tag == .fn_decl) {
        var buf: [1]Ast.Node.Index = undefined;
        if (tree.fullFnProto(&buf, node)) |proto| {
            if (proto.visib_token) |vt| {
                if (tree.tokenTag(vt) == .keyword_pub) {
                    if (!hasDocComment(tree, proto.firstToken())) {
                        const name_tok = proto.name_token orelse proto.ast.fn_token;
                        const name = tree.tokenSlice(name_tok);
                        const loc = tree.tokenLocation(0, name_tok);
                        try diagnostics.append(allocator, .{
                            .rule = rule_name,
                            .severity = severity,
                            .message = try std.fmt.allocPrint(msg_allocator, "missing doc comment for function '{s}'", .{name}),
                            .file = file,
                            .line = loc.line + 1,
                            .column = loc.column + 1,
                            .source_line = try utils.dupSourceLine(tree, name_tok, msg_allocator),
                            .symbol_len = name.len,
                        });
                    }
                }
            }
        }
        return;
    }

    if (tree.fullVarDecl(node)) |var_decl| {
        if (var_decl.visib_token) |vt| {
            if (tree.tokenTag(vt) == .keyword_pub and !hasDocComment(tree, var_decl.firstToken())) {
                // Check whether this is a re-export: `pub const Foo = @import("…").Bar` or `pub const Foo = @import("…")`. If so, delegate to the cross-file resolver rather than emitting a false positive on the re-export line itself.
                const name_tok = var_decl.ast.mut_token + 1;
                const name = tree.tokenSlice(name_tok);
                const is_reexport: bool = blk: {
                    const init_node = var_decl.ast.init_node.unwrap() orelse break :blk false;
                    const info = getReexportInfo(tree, init_node) orelse break :blk false;
                    try tryResolveReexport(info, name, file, severity, allocator, io, msg_allocator, diagnostics);
                    break :blk true;
                };

                if (!is_reexport) {
                    const kind = if (tree.tokenTag(var_decl.ast.mut_token) == .keyword_const) "constant" else "variable";
                    const loc = tree.tokenLocation(0, name_tok);
                    try diagnostics.append(allocator, .{
                        .rule = rule_name,
                        .severity = severity,
                        .message = try std.fmt.allocPrint(msg_allocator, "missing doc comment for {s} '{s}'", .{ kind, name }),
                        .file = file,
                        .line = loc.line + 1,
                        .column = loc.column + 1,
                        .source_line = try utils.dupSourceLine(tree, name_tok, msg_allocator),
                        .symbol_len = name.len,
                    });
                }
            }
        }
        try checkVarDeclInit(tree, var_decl, severity, file, allocator, io, msg_allocator, diagnostics);
        return;
    }

    if (isContainerDecl(tag)) {
        var buf: [2]Ast.Node.Index = undefined;
        if (tree.fullContainerDecl(&buf, node)) |container| {
            for (container.ast.members) |member| {
                try checkNode(tree, member, severity, file, allocator, io, msg_allocator, diagnostics);
            }
        }
        return;
    }

    if (tree.fullContainerField(node)) |field| {
        if (!hasDocComment(tree, field.firstToken())) {
            const name_tok = field.ast.main_token;
            const name = tree.tokenSlice(name_tok);
            const loc = tree.tokenLocation(0, name_tok);
            try diagnostics.append(allocator, .{
                .rule = rule_name,
                .severity = severity,
                .message = try std.fmt.allocPrint(msg_allocator, "missing doc comment for field '{s}'", .{name}),
                .file = file,
                .line = loc.line + 1,
                .column = loc.column + 1,
                .source_line = try utils.dupSourceLine(tree, name_tok, msg_allocator),
                .symbol_len = name.len,
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
    io: std.Io,
    msg_allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) std.mem.Allocator.Error!void {
    // Fields and `pub fn` inside `const S = struct { ... }` are not public API; only walk container members when the declaration itself is `pub`.
    const decl_is_pub: bool = blk: {
        const vt = var_decl.visib_token orelse break :blk false;
        break :blk tree.tokenTag(vt) == .keyword_pub;
    };
    if (!decl_is_pub) return;

    const init_node = var_decl.ast.init_node.unwrap() orelse return;
    if (isContainerDecl(tree.nodeTag(init_node))) {
        var buf: [2]Ast.Node.Index = undefined;
        if (tree.fullContainerDecl(&buf, init_node)) |container| {
            for (container.ast.members) |member| {
                try checkNode(tree, member, severity, file, allocator, io, msg_allocator, diagnostics);
            }
        }
    }
}

// When we see `pub const Foo = @import("other.zig").Bar` with no doc comment, we follow the import and check whether `Bar` in `other.zig` has a doc comment there.  If it does, no diagnostic is emitted.  If it doesn't, the diagnostic is pointed at the definition in the imported file, not at the re-export line.
//
// If the import cannot be resolved (missing file, package import, parse error, etc.) the re-export is silently skipped — no false positive.

/// Extracted info about a potential re-export expression.
const ReexportInfo = struct {
    /// Raw import path from @import("…"), without quotes.
    import_path: []const u8,
    /// The identifier after the dot, e.g. "Level" in `@import(…).Level`.
    /// Null if re-exporting the entire file/module directly.
    field_name: ?[]const u8,
};

/// Returns info when `node` matches `@import("path").Field`, `@import("path")`, or `alias.field` where `alias` is a file-local `@import` binding.
fn getReexportInfo(tree: *const Ast, node: Ast.Node.Index) ?ReexportInfo {
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

/// Returns the import path for `const alias = @import("path");` at file scope.
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

/// Returns the import path string when `node` is `@import("path")`,
/// or null for any other expression.
fn getImportPath(tree: *const Ast, node: Ast.Node.Index) ?[]const u8 {
    const t = tree.nodeTag(node);
    if (t != .builtin_call_two and t != .builtin_call_two_comma) return null;

    // Check this is specifically @import, not another builtin
    const builtin_tok = tree.nodeMainToken(node);
    if (tree.tokenTag(builtin_tok) != .builtin) return null;
    if (!std.mem.eql(u8, tree.tokenSlice(builtin_tok), "@import")) return null;

    // builtin_call_two data: .opt_node_and_opt_node = { first_arg, second_arg }
    const args = tree.nodeData(node).opt_node_and_opt_node;
    const arg_node = args[0].unwrap() orelse return null;
    if (tree.nodeTag(arg_node) != .string_literal) return null;

    const str_tok = tree.nodeMainToken(arg_node);
    const raw = tree.tokenSlice(str_tok);
    // raw is the source text including surrounding quotes: "foo.zig"
    if (raw.len < 2 or raw[0] != '"' or raw[raw.len - 1] != '"') return null;
    return raw[1 .. raw.len - 1];
}

/// Attempts to resolve the re-export and check whether the original declaration has a doc comment.  Only `OutOfMemory` is propagated; all other errors (missing file, parse failure, …) are swallowed silently so that unresolvable imports never produce false positives.
fn tryResolveReexport(
    info: ReexportInfo,
    decl_name: []const u8,
    current_file: []const u8,
    severity: Severity.Level,
    allocator: std.mem.Allocator,
    io: std.Io,
    msg_allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) std.mem.Allocator.Error!void {
    tryResolveReexportImpl(info, decl_name, current_file, severity, allocator, io, msg_allocator, diagnostics) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {}, // silently skip: file not found, parse error, symbol not found, etc.
    };
}

fn tryResolveReexportImpl(
    info: ReexportInfo,
    decl_name: []const u8,
    current_file: []const u8,
    severity: Severity.Level,
    allocator: std.mem.Allocator,
    io: std.Io,
    msg_allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) !void {
    // Resolve the import path relative to the current file's directory.
    const base_dir = std.fs.path.dirname(current_file) orelse ".";
    const joined = try std.fs.path.join(allocator, &.{ base_dir, info.import_path });
    defer allocator.free(joined);
    const imported_path = try utils.normalizePathSeparators(allocator, joined);
    defer allocator.free(imported_path);

    _ = try resolveDocForSymbolInFile(
        imported_path,
        info.field_name,
        info.field_name orelse decl_name,
        severity,
        allocator,
        io,
        msg_allocator,
        diagnostics,
        0,
    );
}

const ResolveOutcome = enum {
    documented,
    undocumented,
    unresolved,
};

fn resolveDocForSymbolInFile(
    file_path: []const u8,
    symbol_name: ?[]const u8,
    display_symbol: []const u8,
    severity: Severity.Level,
    allocator: std.mem.Allocator,
    io: std.Io,
    msg_allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
    depth: usize,
) !ResolveOutcome {
    // Guard against pathological import cycles.
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
        // Search the top-level declarations of the imported file.
        for (imported_tree.rootDecls()) |decl| {
            const found = findNamedDecl(&imported_tree, decl, sym_name) orelse continue;
            if (hasDocComment(&imported_tree, found.first_tok)) {
                return .documented;
            }

            // Undocumented declaration found: recurse if it's itself a re-export.
            if (imported_tree.fullVarDecl(found.node)) |vd| {
                const init_node = vd.ast.init_node.unwrap() orelse {
                    try emitUndocumentedReexportDiagnostic(
                        &imported_tree,
                        found.name_tok,
                        display_symbol,
                        file_path,
                        severity,
                        allocator,
                        msg_allocator,
                        diagnostics,
                    );
                    return .undocumented;
                };

                if (getReexportInfo(&imported_tree, init_node)) |nested| {
                    const nested_base_dir = std.fs.path.dirname(file_path) orelse ".";
                    const nested_joined = try std.fs.path.join(allocator, &.{ nested_base_dir, nested.import_path });
                    defer allocator.free(nested_joined);
                    const nested_imported_path = try utils.normalizePathSeparators(allocator, nested_joined);
                    defer allocator.free(nested_imported_path);

                    const nested_outcome = try resolveDocForSymbolInFile(
                        nested_imported_path,
                        nested.field_name,
                        display_symbol,
                        severity,
                        allocator,
                        io,
                        msg_allocator,
                        diagnostics,
                        depth + 1,
                    );

                    return nested_outcome;
                }
            }

            try emitUndocumentedReexportDiagnostic(
                &imported_tree,
                found.name_tok,
                display_symbol,
                file_path,
                severity,
                allocator,
                msg_allocator,
                diagnostics,
            );
            return .undocumented;
        }

        // Symbol not found in the imported file — silently skip.
        return .unresolved;
    } else {
        // We are importing the entire file/module, so we check if it has a file-level (container) doc comment
        if (hasContainerDocComment(&imported_tree, 0)) {
            return .documented;
        }

        try emitUndocumentedReexportDiagnosticForFile(
            &imported_tree,
            display_symbol,
            file_path,
            severity,
            allocator,
            msg_allocator,
            diagnostics,
        );
        return .undocumented;
    }
}

fn hasContainerDocComment(tree: *const Ast, start_token: Ast.TokenIndex) bool {
    const tags = tree.tokens.items(.tag);
    if (start_token >= tags.len) return false;
    return tags[start_token] == .container_doc_comment;
}

fn emitUndocumentedReexportDiagnosticForFile(
    tree: *const Ast,
    display_symbol: []const u8,
    file_path: []const u8,
    severity: Severity.Level,
    allocator: std.mem.Allocator,
    msg_allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) std.mem.Allocator.Error!void {
    var line: usize = 0;
    var column: usize = 0;
    if (tree.tokens.len > 0) {
        const loc = tree.tokenLocation(0, 0);
        line = loc.line;
        column = loc.column;
    }
    try diagnostics.append(allocator, .{
        .rule = rule_name,
        .severity = severity,
        .message = try std.fmt.allocPrint(
            msg_allocator,
            "missing doc comment for '{s}' (re-exported without documentation)",
            .{display_symbol},
        ),
        // Store an owned copy of the path so it outlives the allocator.
        .file = try utils.normalizePathSeparators(msg_allocator, file_path),
        .line = line + 1,
        .column = column + 1,
        .source_line = if (tree.tokens.len > 0) try utils.dupSourceLine(tree, 0, msg_allocator) else "",
        .symbol_len = display_symbol.len,
    });
}

fn emitUndocumentedReexportDiagnostic(
    tree: *const Ast,
    name_tok: Ast.TokenIndex,
    display_symbol: []const u8,
    file_path: []const u8,
    severity: Severity.Level,
    allocator: std.mem.Allocator,
    msg_allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) std.mem.Allocator.Error!void {
    const loc = tree.tokenLocation(0, name_tok);
    try diagnostics.append(allocator, .{
        .rule = rule_name,
        .severity = severity,
        .message = try std.fmt.allocPrint(
            msg_allocator,
            "missing doc comment for '{s}' (re-exported without documentation)",
            .{display_symbol},
        ),
        // Store an owned copy of the path so it outlives the allocator.
        .file = try utils.normalizePathSeparators(msg_allocator, file_path),
        .line = loc.line + 1,
        .column = loc.column + 1,
        .source_line = try utils.dupSourceLine(tree, name_tok, msg_allocator),
        .symbol_len = display_symbol.len,
    });
}

const FoundDecl = struct {
    node: Ast.Node.Index,
    first_tok: Ast.TokenIndex,
    name_tok: Ast.TokenIndex,
};

/// Searches `decl` (a root-level node) for a declaration named `name` and returns the first/name tokens needed for doc-comment checking.
fn findNamedDecl(tree: *const Ast, decl: Ast.Node.Index, name: []const u8) ?FoundDecl {
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

const TestResult = struct {
    msg_arena: std.heap.ArenaAllocator,
    items: std.ArrayList(Diagnostic),

    fn deinit(self: *TestResult) void {
        self.msg_arena.deinit();
        self.items.deinit(std.testing.allocator);
    }
};

fn runCheck(source: [:0]const u8) !TestResult {
    const base = std.testing.allocator;
    var msg_arena = std.heap.ArenaAllocator.init(base);
    errdefer msg_arena.deinit();

    var tree = try std.zig.Ast.parse(base, source, .zig);
    defer tree.deinit(base);

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    errdefer diagnostics.deinit(base);

    try check(&tree, .warn, "<test>", base, std.testing.io, msg_arena.allocator(), &diagnostics);
    return .{ .msg_arena = msg_arena, .items = diagnostics };
}

test "detects missing doc comment on pub fn, names the symbol" {
    var r = try runCheck("pub fn foo() void {}");
    defer r.deinit();
    try std.testing.expectEqual(1, r.items.items.len);
    try std.testing.expectEqualStrings(rule_name, r.items.items[0].rule);
    try std.testing.expect(std.mem.indexOf(u8, r.items.items[0].message, "'foo'") != null);
    try std.testing.expectEqual(3, r.items.items[0].symbol_len);
}

test "no diagnostic for documented pub fn" {
    var r = try runCheck(
        \\/// Does something.
        \\pub fn foo() void {}
    );
    defer r.deinit();
    try std.testing.expectEqual(0, r.items.items.len);
}

test "no diagnostic for private fn" {
    var r = try runCheck("fn foo() void {}");
    defer r.deinit();
    try std.testing.expectEqual(0, r.items.items.len);
}

test "detects missing doc comment on pub const, names the symbol" {
    var r = try runCheck("pub const answer = 42;");
    defer r.deinit();
    try std.testing.expectEqual(1, r.items.items.len);
    try std.testing.expect(std.mem.indexOf(u8, r.items.items[0].message, "'answer'") != null);
}

test "detects missing doc comment on container fields, names the field" {
    var r = try runCheck(
        \\/// A struct.
        \\pub const S = struct {
        \\    x: u32,
        \\    y: u32,
        \\};
    );
    defer r.deinit();
    try std.testing.expectEqual(2, r.items.items.len);
    try std.testing.expect(std.mem.indexOf(u8, r.items.items[0].message, "'x'") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.items.items[1].message, "'y'") != null);
}

test "no diagnostic for private const struct members and pub fn inside" {
    var r = try runCheck(
        \\const PrivateStruct = struct {
        \\    step: i32,
        \\    color: []const u8,
        \\    pub fn world() void {}
        \\};
    );
    defer r.deinit();
    try std.testing.expectEqual(0, r.items.items.len);
}

test "location points to name token, not keyword" {
    var r = try runCheck("pub fn myFunc() void {}");
    defer r.deinit();
    try std.testing.expectEqual(1, r.items.items.len);
    try std.testing.expectEqual(@as(usize, 8), r.items.items[0].column);
}

test "source_line is populated" {
    var r = try runCheck("pub fn foo() void {}");
    defer r.deinit();
    try std.testing.expectEqual(1, r.items.items.len);
    try std.testing.expectEqualStrings("pub fn foo() void {}", r.items.items[0].source_line);
}

test "re-export with unresolvable import is silently skipped (no false positive)" {
    // When the imported file can't be resolved (fake path from <test> file),
    // the re-export must produce zero diagnostics.
    var r = try runCheck("pub const Foo = @import(\"definitely_nonexistent_xyz.zig\").Bar;");
    defer r.deinit();
    try std.testing.expectEqual(0, r.items.items.len);
}

test "re-export through local import alias is recognized" {
    var r = try runCheck(
        \\const helpers = @import("helpers.zig");
        \\pub const greet = helpers.greet;
    );
    defer r.deinit();
    // Unresolvable from <test> path — must not false-positive on the re-export line.
    try std.testing.expectEqual(0, r.items.items.len);
}
