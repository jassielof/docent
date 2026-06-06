//! The `missing_doc_comment` namespace checks for missing doc comments.
//!
//! This will _warn_ on declarations that are missing doc comments. Including, but not limited to:
//!
//! - [Functions and its parameters](https://ziglang.org/documentation/0.16.0/#Functions).
//!   - Parameters are allowed to be undocumented by default.
//! - [Container level variables and constants](https://ziglang.org/documentation/0.16.0/#Container-Level-Variables).
//! - [Enumerations and enumerators](https://ziglang.org/documentation/0.16.0/#enum).
//! - [Structures and their fields](https://ziglang.org/documentation/0.16.0/#struct).
//! - [Unions and their members](https://ziglang.org/documentation/0.16.0/#union).
//! - [Errors](https://ziglang.org/documentation/0.16.0/#Errors).
//!   - Its values aren't checked since Zig documentation generator doesn't support them.
//!
//! ## Re-exported declarations
//!
//! Public re-exports

const std = @import("std");
const Ast = std.zig.Ast;
const Diagnostic = @import("../../Diagnostic.zig");
const severity = @import("../../severity.zig");
const utils = @import("../utils.zig");
const import_reexport = utils.import_reexport;

const rule_name = "missing_doc_comment";

// TODO: The rule should have its options in this Options struct, instead of receiving them as separate parameters in the check function.
pub const Options = struct {};

/// Walks `tree` and appends diagnostics for undocumented public items.
///
/// - When `require_module_doc` is set, also requires a file-level `//!` on module entry roots.
/// -  When `require_function_param_docs` is set, also requires `///` on each named function parameter.
pub fn check(
    tree: *const Ast,
    severity_level: severity.Level,
    file: []const u8,
    require_module_doc: bool,
    module_name: ?[]const u8,
    public_api_only: bool,
    require_function_param_docs: bool,
    allocator: std.mem.Allocator,
    io: std.Io,
    msg_allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) std.mem.Allocator.Error!void {
    if (!severity_level.isActive()) return;
    try checkModuleDocComment(tree, severity_level, file, require_module_doc, module_name, allocator, msg_allocator, diagnostics);
    for (tree.rootDecls()) |decl| {
        try checkNode(tree, decl, severity_level, file, public_api_only, require_function_param_docs, .field, allocator, io, msg_allocator, diagnostics);
    }
}

fn checkModuleDocComment(
    tree: *const Ast,
    severity_level: severity.Level,
    file: []const u8,
    require_module_doc: bool,
    module_name: ?[]const u8,
    allocator: std.mem.Allocator,
    msg_allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) std.mem.Allocator.Error!void {
    if (!require_module_doc) return;
    if (utils.hasContainerDocComment(tree, 0)) return;

    const display_name = utils.moduleDisplayName(file, module_name);
    const first_src = if (tree.tokens.len > 0)
        try utils.dupSourceLine(tree, 0, msg_allocator)
    else
        "";
    try diagnostics.append(allocator, .{
        .rule = rule_name,
        .severity_level = severity_level,
        .subject = try utils.ownedSubject(msg_allocator, .module, display_name),
        .file = file,
        .line = 1,
        .column = 1,
        .source_line = first_src,
        .symbol_len = 1,
    });
}

fn pubVarDeclSubjectKind(tree: *const Ast, var_decl: Ast.full.VarDecl) Diagnostic.SubjectKind {
    if (tree.tokenTag(var_decl.ast.mut_token) != .keyword_const) return .variable;
    const init_node = var_decl.ast.init_node.unwrap() orelse return .constant;
    if (tree.nodeTag(init_node) == .error_set_decl) return .error_set;
    if (utils.isEnumContainer(tree, init_node)) return .enumeration;
    return .constant;
}

fn isPubVisibility(tree: *const Ast, visib_token: ?Ast.TokenIndex) bool {
    const vt = visib_token orelse return false;
    return tree.tokenTag(vt) == .keyword_pub;
}

fn shouldCheckDecl(tree: *const Ast, visib_token: ?Ast.TokenIndex, public_api_only: bool) bool {
    if (!public_api_only) return true;
    return isPubVisibility(tree, visib_token);
}

fn checkNode(
    tree: *const Ast,
    node: Ast.Node.Index,
    severity_level: severity.Level,
    file: []const u8,
    public_api_only: bool,
    require_function_param_docs: bool,
    member_field_kind: Diagnostic.SubjectKind,
    allocator: std.mem.Allocator,
    io: std.Io,
    msg_allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) std.mem.Allocator.Error!void {
    const tag = tree.nodeTag(node);

    if (tag == .fn_decl) {
        var buf: [1]Ast.Node.Index = undefined;
        if (tree.fullFnProto(&buf, node)) |proto| {
            if (shouldCheckDecl(tree, proto.visib_token, public_api_only)) {
                if (!hasDocComment(tree, proto.firstToken())) {
                    const name_tok = proto.name_token orelse proto.ast.fn_token;
                    const name = tree.tokenSlice(name_tok);
                    const loc = tree.tokenLocation(0, name_tok);
                    try diagnostics.append(allocator, .{
                        .rule = rule_name,
                        .severity_level = severity_level,
                        .subject = try utils.ownedSubject(msg_allocator, .function, name),
                        .file = file,
                        .line = loc.line + 1,
                        .column = loc.column + 1,
                        .source_line = try utils.dupSourceLine(tree, name_tok, msg_allocator),
                        .symbol_len = name.len,
                    });
                }
                if (require_function_param_docs) {
                    try checkFunctionParams(tree, proto, severity_level, file, allocator, msg_allocator, diagnostics);
                }
            }
        }
        return;
    }

    if (tree.fullVarDecl(node)) |var_decl| {
        if (shouldCheckDecl(tree, var_decl.visib_token, public_api_only) and
            !hasDocComment(tree, var_decl.firstToken()))
        {
            const name_tok = var_decl.ast.mut_token + 1;
            const name = tree.tokenSlice(name_tok);
            const is_reexport: bool = if (public_api_only) blk: {
                const init_node = var_decl.ast.init_node.unwrap() orelse break :blk false;
                const info = import_reexport.getInfo(tree, init_node) orelse break :blk false;
                try tryResolveReexport(info, name, file, severity_level, allocator, io, msg_allocator, diagnostics);
                break :blk true;
            } else false;

            if (!is_reexport) {
                const loc = tree.tokenLocation(0, name_tok);
                try diagnostics.append(allocator, .{
                    .rule = rule_name,
                    .severity_level = severity_level,
                    .subject = try utils.ownedSubject(msg_allocator, pubVarDeclSubjectKind(tree, var_decl), name),
                    .file = file,
                    .line = loc.line + 1,
                    .column = loc.column + 1,
                    .source_line = try utils.dupSourceLine(tree, name_tok, msg_allocator),
                    .symbol_len = name.len,
                });
            }
        }
        try checkVarDeclInit(tree, var_decl, severity_level, file, public_api_only, require_function_param_docs, allocator, io, msg_allocator, diagnostics);
        return;
    }

    if (isContainerDecl(tag)) {
        var buf: [2]Ast.Node.Index = undefined;
        if (tree.fullContainerDecl(&buf, node)) |container| {
            const child_member_kind: Diagnostic.SubjectKind = if (utils.isEnumContainer(tree, node))
                .enumerator
            else
                member_field_kind;
            for (container.ast.members) |member| {
                try checkNode(tree, member, severity_level, file, public_api_only, require_function_param_docs, child_member_kind, allocator, io, msg_allocator, diagnostics);
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
                .severity_level = severity_level,
                .subject = try utils.ownedSubject(msg_allocator, member_field_kind, name),
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

fn checkFunctionParams(
    tree: *const Ast,
    proto: Ast.full.FnProto,
    severity_level: severity.Level,
    file: []const u8,
    allocator: std.mem.Allocator,
    msg_allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) std.mem.Allocator.Error!void {
    var it = proto.iterate(tree);
    while (it.next()) |param| {
        const name_tok = param.name_token orelse continue;
        if (param.first_doc_comment != null) continue;

        const name = tree.tokenSlice(name_tok);
        if (std.mem.eql(u8, name, "_")) continue;
        const loc = tree.tokenLocation(0, name_tok);
        try diagnostics.append(allocator, .{
            .rule = rule_name,
            .severity_level = severity_level,
            .subject = try utils.ownedSubject(msg_allocator, .parameter, name),
            .file = file,
            .line = loc.line + 1,
            .column = loc.column + 1,
            .source_line = try utils.dupSourceLine(tree, name_tok, msg_allocator),
            .symbol_len = name.len,
        });
    }
}

fn checkVarDeclInit(
    tree: *const Ast,
    var_decl: Ast.full.VarDecl,
    severity_level: severity.Level,
    file: []const u8,
    public_api_only: bool,
    require_function_param_docs: bool,
    allocator: std.mem.Allocator,
    io: std.Io,
    msg_allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) std.mem.Allocator.Error!void {
    if (public_api_only and !shouldCheckDecl(tree, var_decl.visib_token, true)) return;

    const init_node = var_decl.ast.init_node.unwrap() orelse return;
    if (isContainerDecl(tree.nodeTag(init_node))) {
        var buf: [2]Ast.Node.Index = undefined;
        if (tree.fullContainerDecl(&buf, init_node)) |container| {
            const child_member_kind: Diagnostic.SubjectKind = if (utils.isEnumContainer(tree, init_node))
                .enumerator
            else
                .field;
            for (container.ast.members) |member| {
                try checkNode(tree, member, severity_level, file, public_api_only, require_function_param_docs, child_member_kind, allocator, io, msg_allocator, diagnostics);
            }
        }
    }
}

// When we see `pub const Foo = @import("other.zig").Bar` with no doc comment, we follow the import and check whether `Bar` in `other.zig` has a doc comment there.  If it does, no diagnostic is emitted.  If it doesn't, the diagnostic is pointed at the definition in the imported file, not at the re-export line.
//
// If the import cannot be resolved (missing file, package import, parse error, etc.) the re-export is silently skipped — no false positive.

/// Attempts to resolve the re-export and check whether the original declaration has a doc comment.  Only `OutOfMemory` is propagated; all other errors (missing file, parse failure, …) are swallowed silently so that unresolvable imports never produce false positives.
fn tryResolveReexport(
    info: import_reexport.Info,
    decl_name: []const u8,
    current_file: []const u8,
    severity_level: severity.Level,
    allocator: std.mem.Allocator,
    io: std.Io,
    msg_allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) std.mem.Allocator.Error!void {
    tryResolveReexportImpl(info, decl_name, current_file, severity_level, allocator, io, msg_allocator, diagnostics) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {}, // silently skip: file not found, parse error, symbol not found, etc.
    };
}

fn tryResolveReexportImpl(
    info: import_reexport.Info,
    decl_name: []const u8,
    current_file: []const u8,
    severity_level: severity.Level,
    allocator: std.mem.Allocator,
    io: std.Io,
    msg_allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) !void {
    const imported_path = try import_reexport.resolveImportedPath(allocator, current_file, info.import_path);
    defer allocator.free(imported_path);

    _ = try resolveDocForSymbolInFile(
        imported_path,
        info.field_name,
        info.field_name orelse decl_name,
        severity_level,
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
    severity_level: severity.Level,
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
                        severity_level,
                        allocator,
                        msg_allocator,
                        diagnostics,
                    );
                    return .undocumented;
                };

                if (import_reexport.getInfo(&imported_tree, init_node)) |nested| {
                    const nested_imported_path = try import_reexport.resolveImportedPath(allocator, file_path, nested.import_path);
                    defer allocator.free(nested_imported_path);

                    const nested_outcome = try resolveDocForSymbolInFile(
                        nested_imported_path,
                        nested.field_name,
                        display_symbol,
                        severity_level,
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
                severity_level,
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
        if (utils.hasContainerDocComment(&imported_tree, 0)) {
            return .documented;
        }

        try emitUndocumentedReexportDiagnosticForFile(
            &imported_tree,
            file_path,
            severity_level,
            allocator,
            msg_allocator,
            diagnostics,
        );
        return .undocumented;
    }
}

fn emitUndocumentedReexportDiagnosticForFile(
    tree: *const Ast,
    file_path: []const u8,
    severity_level: severity.Level,
    allocator: std.mem.Allocator,
    msg_allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) std.mem.Allocator.Error!void {
    const source_basename = std.fs.path.basename(file_path);
    const subject_kind = utils.exposedSourceFileSubjectKind(tree);
    var line: usize = 0;
    var column: usize = 0;
    if (tree.tokens.len > 0) {
        const loc = tree.tokenLocation(0, 0);
        line = loc.line;
        column = loc.column;
    }
    try diagnostics.append(allocator, .{
        .rule = rule_name,
        .severity_level = severity_level,
        .subject = try utils.ownedSubject(msg_allocator, subject_kind, source_basename),
        .file = try utils.normalizePathSeparators(msg_allocator, file_path),
        .line = line + 1,
        .column = column + 1,
        .source_line = if (tree.tokens.len > 0) try utils.dupSourceLine(tree, 0, msg_allocator) else "",
        .symbol_len = source_basename.len,
    });
}

fn emitUndocumentedReexportDiagnostic(
    tree: *const Ast,
    name_tok: Ast.TokenIndex,
    display_symbol: []const u8,
    file_path: []const u8,
    severity_level: severity.Level,
    allocator: std.mem.Allocator,
    msg_allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) std.mem.Allocator.Error!void {
    const loc = tree.tokenLocation(0, name_tok);
    try diagnostics.append(allocator, .{
        .rule = rule_name,
        .severity_level = severity_level,
        .subject = try utils.ownedSubject(msg_allocator, .function, display_symbol),
        .detail = "re-exported without documentation",
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
    return utils.isContainerDecl(tag);
}

const TestResult = struct {
    msg_arena: std.heap.ArenaAllocator,
    items: std.ArrayList(Diagnostic),

    fn deinit(self: *TestResult) void {
        self.msg_arena.deinit();
        self.items.deinit(std.testing.allocator);
    }
};

fn runCheck(
    source: [:0]const u8,
    require_module_doc: bool,
    module_name: ?[]const u8,
    require_function_param_docs: bool,
) !TestResult {
    const base = std.testing.allocator;
    var msg_arena = std.heap.ArenaAllocator.init(base);
    errdefer msg_arena.deinit();

    var tree = try std.zig.Ast.parse(base, source, .zig);
    defer tree.deinit(base);

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    errdefer diagnostics.deinit(base);

    try check(&tree, .warn, "<test>", require_module_doc, module_name, true, require_function_param_docs, base, std.testing.io, msg_arena.allocator(), &diagnostics);
    return .{ .msg_arena = msg_arena, .items = diagnostics };
}

test "detects missing module doc comment on entry root" {
    var r = try runCheck("pub fn foo() void {}", true, "fixture", false);
    defer r.deinit();
    try std.testing.expectEqual(2, r.items.items.len);
    try std.testing.expectEqualStrings(rule_name, r.items.items[0].rule);
    try std.testing.expectEqual(.module, r.items.items[0].subject.?.kind);
    try std.testing.expectEqualStrings("fixture", r.items.items[0].subject.?.name);
}

test "no module doc diagnostic when //! present" {
    var r = try runCheck("//! Module documentation.\npub fn foo() void {}", true, "fixture", false);
    defer r.deinit();
    try std.testing.expectEqual(1, r.items.items.len);
    try std.testing.expectEqual(.function, r.items.items[0].subject.?.kind);
}

test "no module doc check when require_module_doc is false" {
    var r = try runCheck("pub fn foo() void {}", false, null, false);
    defer r.deinit();
    try std.testing.expectEqual(1, r.items.items.len);
    try std.testing.expect(r.items.items[0].subject.?.kind != .module);
}

test "no extra module doc required inside pub const struct body" {
    var r = try runCheck(
        \\//! Module doc.
        \\/// Documented struct.
        \\pub const MyStruct = struct {
        \\    /// Documented field.
        \\    x: u32,
        \\};
    , true, "mylib", false);
    defer r.deinit();
    try std.testing.expectEqual(0, r.items.items.len);
}

test "detects missing doc comment on pub fn, names the symbol" {
    var r = try runCheck("pub fn foo() void {}", false, null, false);
    defer r.deinit();
    try std.testing.expectEqual(1, r.items.items.len);
    try std.testing.expectEqualStrings(rule_name, r.items.items[0].rule);
    try std.testing.expectEqualStrings("foo", r.items.items[0].subject.?.name);
    try std.testing.expectEqual(3, r.items.items[0].symbol_len);
}

test "no diagnostic for documented pub fn" {
    var r = try runCheck(
        \\/// Does something.
        \\pub fn foo() void {}
    , false, null, false);
    defer r.deinit();
    try std.testing.expectEqual(0, r.items.items.len);
}

test "no diagnostic for private fn" {
    var r = try runCheck("fn foo() void {}", false, null, false);
    defer r.deinit();
    try std.testing.expectEqual(0, r.items.items.len);
}

test "detects missing doc comment on pub const, names the symbol" {
    var r = try runCheck("pub const answer = 42;", false, null, false);
    defer r.deinit();
    try std.testing.expectEqual(1, r.items.items.len);
    try std.testing.expectEqualStrings("answer", r.items.items[0].subject.?.name);
    try std.testing.expectEqual(.constant, r.items.items[0].subject.?.kind);
}

test "detects missing doc comment on pub const error set" {
    var r = try runCheck("pub const MyErr = error{ OutOfMemory };", false, null, false);
    defer r.deinit();
    try std.testing.expectEqual(1, r.items.items.len);
    try std.testing.expectEqual(.error_set, r.items.items[0].subject.?.kind);
    try std.testing.expectEqualStrings("MyErr", r.items.items[0].subject.?.name);
}

test "detects missing doc comment on container fields, names the field" {
    var r = try runCheck(
        \\/// A struct.
        \\pub const S = struct {
        \\    x: u32,
        \\    y: u32,
        \\};
    , false, null, false);
    defer r.deinit();
    try std.testing.expectEqual(2, r.items.items.len);
    try std.testing.expectEqualStrings("x", r.items.items[0].subject.?.name);
    try std.testing.expectEqual(.field, r.items.items[0].subject.?.kind);
    try std.testing.expectEqualStrings("y", r.items.items[1].subject.?.name);
    try std.testing.expectEqual(.field, r.items.items[1].subject.?.kind);
}

test "detects missing doc comment on pub enum and enumerators" {
    var r = try runCheck(
        \\pub const Color = enum {
        \\    red,
        \\    green,
        \\};
    , false, null, false);
    defer r.deinit();
    try std.testing.expectEqual(3, r.items.items.len);
    try std.testing.expectEqual(.enumeration, r.items.items[0].subject.?.kind);
    try std.testing.expectEqualStrings("Color", r.items.items[0].subject.?.name);
    try std.testing.expectEqual(.enumerator, r.items.items[1].subject.?.kind);
    try std.testing.expectEqualStrings("red", r.items.items[1].subject.?.name);
    try std.testing.expectEqual(.enumerator, r.items.items[2].subject.?.kind);
    try std.testing.expectEqualStrings("green", r.items.items[2].subject.?.name);
}

test "no diagnostic for private const struct members and pub fn inside" {
    var r = try runCheck(
        \\const PrivateStruct = struct {
        \\    step: i32,
        \\    color: []const u8,
        \\    pub fn world() void {}
        \\};
    , false, null, false);
    defer r.deinit();
    try std.testing.expectEqual(0, r.items.items.len);
}

test "location points to name token, not keyword" {
    var r = try runCheck("pub fn myFunc() void {}", false, null, false);
    defer r.deinit();
    try std.testing.expectEqual(1, r.items.items.len);
    try std.testing.expectEqual(@as(usize, 8), r.items.items[0].column);
}

test "source_line is populated" {
    var r = try runCheck("pub fn foo() void {}", false, null, false);
    defer r.deinit();
    try std.testing.expectEqual(1, r.items.items.len);
    try std.testing.expectEqualStrings("pub fn foo() void {}", r.items.items[0].source_line);
}

test "re-export with unresolvable import is silently skipped (no false positive)" {
    // When the imported file can't be resolved (fake path from <test> file),
    // the re-export must produce zero diagnostics.
    var r = try runCheck("pub const Foo = @import(\"definitely_nonexistent_xyz.zig\").Bar;", false, null, false);
    defer r.deinit();
    try std.testing.expectEqual(0, r.items.items.len);
}

test "re-export through local import alias is recognized" {
    var r = try runCheck(
        \\const helpers = @import("helpers.zig");
        \\pub const greet = helpers.greet;
    , false, null, false);
    defer r.deinit();
    // Unresolvable from <test> path — must not false-positive on the re-export line.
    try std.testing.expectEqual(0, r.items.items.len);
}

test "function parameters are not checked by default" {
    var r = try runCheck(
        \\/// Does something.
        \\pub fn foo(allocator: std.mem.Allocator, value: u32) void {
        \\    _ = allocator;
        \\    _ = value;
        \\}
    , false, null, false);
    defer r.deinit();
    try std.testing.expectEqual(0, r.items.items.len);
}

test "undocumented function parameters are reported when enabled" {
    var r = try runCheck(
        \\/// Does something.
        \\pub fn foo(
        \\    /// The allocator.
        \\    allocator: std.mem.Allocator,
        \\    value: u32,
        \\) void {
        \\    _ = allocator;
        \\    _ = value;
        \\}
    , false, null, true);
    defer r.deinit();
    try std.testing.expectEqual(1, r.items.items.len);
    try std.testing.expectEqual(.parameter, r.items.items[0].subject.?.kind);
    try std.testing.expectEqualStrings("value", r.items.items[0].subject.?.name);
}

test "all documented function parameters are accepted when enabled" {
    var r = try runCheck(
        \\/// Does something.
        \\pub fn foo(
        \\    /// The allocator.
        \\    allocator: std.mem.Allocator,
        \\    /// The value.
        \\    value: u32,
        \\) void {
        \\    _ = allocator;
        \\    _ = value;
        \\}
    , false, null, true);
    defer r.deinit();
    try std.testing.expectEqual(0, r.items.items.len);
}

test "unnamed and varargs parameters are skipped when enabled" {
    var r = try runCheck(
        \\/// Does something.
        \\pub fn foo(_: u32, args: anytype, ...) void {
        \\    _ = args;
        \\}
    , false, null, true);
    defer r.deinit();
    try std.testing.expectEqual(1, r.items.items.len);
    try std.testing.expectEqualStrings("args", r.items.items[0].subject.?.name);
}

test "private function parameters are not checked under public_api_only" {
    const base = std.testing.allocator;
    var msg_arena = std.heap.ArenaAllocator.init(base);
    defer msg_arena.deinit();

    const source =
        \\/// Does something.
        \\fn hidden(allocator: std.mem.Allocator) void {
        \\    _ = allocator;
        \\}
    ++ "\x00";
    var tree = try std.zig.Ast.parse(base, source, .zig);
    defer tree.deinit(base);

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(base);

    try check(&tree, .warn, "<test>", false, null, true, true, base, std.testing.io, msg_arena.allocator(), &diagnostics);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}
