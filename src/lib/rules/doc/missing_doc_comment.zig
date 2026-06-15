//! The `missing_doc_comment` namespace checks for missing doc comments.
//!
//! This checks declarations that are missing doc comments. Including, but not limited to:
//!
//! - [Functions and its parameters](https://ziglang.org/documentation/0.16.0/#Functions).
//!   - Parameters are allowed to be undocumented by default.
//! - [Container level variables and constants](https://ziglang.org/documentation/0.16.0/#Container-Level-Variables).
//! - [Enumerations and enumerators](https://ziglang.org/documentation/0.16.0/#enum).
//! - [Structures and their fields](https://ziglang.org/documentation/0.16.0/#struct).
//! - [Unions and their members](https://ziglang.org/documentation/0.16.0/#union).
//! - [Errors](https://ziglang.org/documentation/0.16.0/#Errors).
//!   - Individual errors inside a set (or merged set) are checked when `check_errors` is enabled.
const std = @import("std");
const Ast = std.zig.Ast;
const vereda = @import("vereda");
const Diagnostic = @import("../../Diagnostic.zig");
const severity = @import("../../severity.zig");
const scanning = @import("../../scanning.zig");
const category = @import("../category.zig");
const reexport = @import("../../reexport.zig");
const utils = @import("../utils.zig");
const doc = @import("../../doc.zig");

inline fn srcLoc() std.builtin.SourceLocation {
    return @src();
}

const rule_name = utils.ruleIdFromSrc(srcLoc());

/// The default_severity for the rule.
pub const default_severity: severity.Level = .warn;

/// Rule-specific knobs for `missing_doc_comment`, held in the `options` sub-space of `Rule`.
pub const Options = struct {
    /// When set, also require `///` on each named function parameter; default `false` keeps parameters optional.
    check_parameters: bool = false,
    /// When set, also require docs on individual error-set members; default `true` documents each error.
    check_errors: bool = true,
};

/// Full configuration for `missing_doc_comment`: severity, scan mode, and the documented `Options` sub-space.
pub const Rule = category.Rule(default_severity, Options, scanning.Modes.public_api_surface);

/// Walks `tree` and appends diagnostics for undocumented public items.
///
/// When `require_module_doc` is set, also requires a file-level `//!` on module entry roots.
/// When `options.check_parameters` is set, also requires `///` on each named function parameter.
pub fn check(
    tree: *const Ast,
    rule: Rule,
    file: []const u8,
    require_module_doc: bool,
    module_name: ?[]const u8,
    allocator: std.mem.Allocator,
    io: std.Io,
    msg_allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) std.mem.Allocator.Error!void {
    if (!rule.level.isActive()) return;
    const severity_level = rule.level;
    const options = rule.options;
    try checkModuleDocComment(tree, severity_level, file, require_module_doc, module_name, allocator, msg_allocator, diagnostics);
    const public_api_only = rule.publicApiOnly();
    for (tree.rootDecls()) |decl| {
        try checkNode(tree, decl, severity_level, file, public_api_only, options, .field, allocator, io, msg_allocator, diagnostics);
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
    if (doc.hasContainerDocComment(tree, 0)) return;

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
    options: Options,
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
                if (options.check_parameters) {
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
                const info = reexport.getInfo(tree, init_node) orelse break :blk false;
                var emit_ctx = ReexportEmitContext{
                    .severity_level = severity_level,
                    .allocator = allocator,
                    .msg_allocator = msg_allocator,
                    .diagnostics = diagnostics,
                };
                break :blk try reexport.resolveMissingDocReexport(
                    info,
                    name,
                    file,
                    allocator,
                    io,
                    &emit_ctx,
                    .{
                        .on_undocumented_member = onUndocumentedReexportMember,
                        .on_undocumented_whole_module = onUndocumentedReexportWholeModule,
                    },
                );
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
        try checkVarDeclInit(tree, var_decl, severity_level, file, public_api_only, options, allocator, io, msg_allocator, diagnostics);
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
                try checkNode(tree, member, severity_level, file, public_api_only, options, child_member_kind, allocator, io, msg_allocator, diagnostics);
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
    options: Options,
    allocator: std.mem.Allocator,
    io: std.Io,
    msg_allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) std.mem.Allocator.Error!void {
    if (public_api_only and !shouldCheckDecl(tree, var_decl.visib_token, true)) return;

    const init_node = var_decl.ast.init_node.unwrap() orelse return;
    if (tree.nodeTag(init_node) == .error_set_decl) {
        try checkErrorSetMembers(tree, init_node, severity_level, file, options.check_errors, allocator, msg_allocator, diagnostics);
        return;
    }
    if (isContainerDecl(tree.nodeTag(init_node))) {
        var buf: [2]Ast.Node.Index = undefined;
        if (tree.fullContainerDecl(&buf, init_node)) |container| {
            const child_member_kind: Diagnostic.SubjectKind = if (utils.isEnumContainer(tree, init_node))
                .enumerator
            else
                .field;
            for (container.ast.members) |member| {
                try checkNode(tree, member, severity_level, file, public_api_only, options, child_member_kind, allocator, io, msg_allocator, diagnostics);
            }
        }
    }
}

fn checkErrorSetMembers(
    tree: *const Ast,
    node: Ast.Node.Index,
    severity_level: severity.Level,
    file: []const u8,
    check_errors: bool,
    allocator: std.mem.Allocator,
    msg_allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) std.mem.Allocator.Error!void {
    if (!check_errors) return;

    const first = tree.firstToken(node);
    const last = tree.lastToken(node);
    var tok = first;
    while (tok <= last) : (tok += 1) {
        if (tree.tokenTag(tok) != .identifier) continue;
        if (hasDocComment(tree, tok)) continue;

        const name = tree.tokenSlice(tok);
        const loc = tree.tokenLocation(0, tok);
        try diagnostics.append(allocator, .{
            .rule = rule_name,
            .severity_level = severity_level,
            .subject = try utils.ownedSubject(msg_allocator, .error_value, name),
            .file = file,
            .line = loc.line + 1,
            .column = loc.column + 1,
            .source_line = try utils.dupSourceLine(tree, tok, msg_allocator),
            .symbol_len = name.len,
        });
    }
}

const ReexportEmitContext = struct {
    severity_level: severity.Level,
    allocator: std.mem.Allocator,
    msg_allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
};

fn onUndocumentedReexportMember(
    ctx_ptr: *anyopaque,
    tree: *const Ast,
    name_tok: Ast.TokenIndex,
    display_symbol: []const u8,
    file_path: []const u8,
) !void {
    const ctx: *ReexportEmitContext = @ptrCast(@alignCast(ctx_ptr));
    const loc = tree.tokenLocation(0, name_tok);
    try ctx.diagnostics.append(ctx.allocator, .{
        .rule = rule_name,
        .severity_level = ctx.severity_level,
        .subject = try utils.ownedSubject(ctx.msg_allocator, .function, display_symbol),
        .detail = "re-exported without documentation",
        .file = try vereda.path.toPosixSeparators(ctx.msg_allocator, file_path),
        .line = loc.line + 1,
        .column = loc.column + 1,
        .source_line = try utils.dupSourceLine(tree, name_tok, ctx.msg_allocator),
        .symbol_len = display_symbol.len,
    });
}

fn onUndocumentedReexportWholeModule(
    ctx_ptr: *anyopaque,
    tree: *const Ast,
    file_path: []const u8,
) !void {
    const ctx: *ReexportEmitContext = @ptrCast(@alignCast(ctx_ptr));
    const source_basename = std.fs.path.basename(file_path);
    const subject_kind = doc.exposedSourceFileSubjectKind(tree);
    var line: usize = 0;
    var column: usize = 0;
    if (tree.tokens.len > 0) {
        const loc = tree.tokenLocation(0, 0);
        line = loc.line;
        column = loc.column;
    }
    try ctx.diagnostics.append(ctx.allocator, .{
        .rule = rule_name,
        .severity_level = ctx.severity_level,
        .subject = try utils.ownedSubject(ctx.msg_allocator, subject_kind, source_basename),
        .file = try vereda.path.toPosixSeparators(ctx.msg_allocator, file_path),
        .line = line + 1,
        .column = column + 1,
        .source_line = if (tree.tokens.len > 0) try utils.dupSourceLine(tree, 0, ctx.msg_allocator) else "",
        .symbol_len = source_basename.len,
    });
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
    options: Options,
) !TestResult {
    const base = std.testing.allocator;
    var msg_arena = std.heap.ArenaAllocator.init(base);
    errdefer msg_arena.deinit();

    var tree = try std.zig.Ast.parse(base, source, .zig);
    defer tree.deinit(base);

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    errdefer diagnostics.deinit(base);

    try check(&tree, .{ .options = options }, "<test>", require_module_doc, module_name, base, std.testing.io, msg_arena.allocator(), &diagnostics);
    return .{ .msg_arena = msg_arena, .items = diagnostics };
}

test "detects missing module doc comment on entry root" {
    var r = try runCheck("pub fn foo() void {}", true, "fixture", .{});
    defer r.deinit();
    try std.testing.expectEqual(2, r.items.items.len);
    try std.testing.expectEqualStrings(rule_name, r.items.items[0].rule);
    try std.testing.expectEqual(.module, r.items.items[0].subject.?.kind);
    try std.testing.expectEqualStrings("fixture", r.items.items[0].subject.?.name);
}

test "no module doc diagnostic when //! present" {
    var r = try runCheck("//! Module documentation.\npub fn foo() void {}", true, "fixture", .{});
    defer r.deinit();
    try std.testing.expectEqual(1, r.items.items.len);
    try std.testing.expectEqual(.function, r.items.items[0].subject.?.kind);
}

test "no module doc check when require_module_doc is false" {
    var r = try runCheck("pub fn foo() void {}", false, null, .{});
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
    , true, "mylib", .{});
    defer r.deinit();
    try std.testing.expectEqual(0, r.items.items.len);
}

test "detects missing doc comment on pub fn, names the symbol" {
    var r = try runCheck("pub fn foo() void {}", false, null, .{});
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
    , false, null, .{});
    defer r.deinit();
    try std.testing.expectEqual(0, r.items.items.len);
}

test "no diagnostic for private fn" {
    var r = try runCheck("fn foo() void {}", false, null, .{});
    defer r.deinit();
    try std.testing.expectEqual(0, r.items.items.len);
}

test "detects missing doc comment on pub const, names the symbol" {
    var r = try runCheck("pub const answer = 42;", false, null, .{});
    defer r.deinit();
    try std.testing.expectEqual(1, r.items.items.len);
    try std.testing.expectEqualStrings("answer", r.items.items[0].subject.?.name);
    try std.testing.expectEqual(.constant, r.items.items[0].subject.?.kind);
}

test "detects missing doc comment on pub const error set" {
    var r = try runCheck("pub const MyErr = error{ OutOfMemory };", false, null, .{});
    defer r.deinit();
    try std.testing.expectEqual(2, r.items.items.len);
    try std.testing.expectEqual(.error_set, r.items.items[0].subject.?.kind);
    try std.testing.expectEqualStrings("MyErr", r.items.items[0].subject.?.name);
    try std.testing.expectEqual(.error_value, r.items.items[1].subject.?.kind);
    try std.testing.expectEqualStrings("OutOfMemory", r.items.items[1].subject.?.name);
}

test "error members are skipped when check_errors is disabled" {
    var r = try runCheck("pub const MyErr = error{ OutOfMemory };", false, null, .{ .check_errors = false });
    defer r.deinit();
    try std.testing.expectEqual(1, r.items.items.len);
    try std.testing.expectEqual(.error_set, r.items.items[0].subject.?.kind);
}

test "documented error members are accepted" {
    var r = try runCheck(
        \\pub const MyErr = error{
        \\    /// Out of memory.
        \\    OutOfMemory,
        \\};
    , false, null, .{});
    defer r.deinit();
    try std.testing.expectEqual(1, r.items.items.len);
    try std.testing.expectEqual(.error_set, r.items.items[0].subject.?.kind);
}

test "detects missing doc comment on container fields, names the field" {
    var r = try runCheck(
        \\/// A struct.
        \\pub const S = struct {
        \\    x: u32,
        \\    y: u32,
        \\};
    , false, null, .{});
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
    , false, null, .{});
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
    , false, null, .{});
    defer r.deinit();
    try std.testing.expectEqual(0, r.items.items.len);
}

test "location points to name token, not keyword" {
    var r = try runCheck("pub fn myFunc() void {}", false, null, .{});
    defer r.deinit();
    try std.testing.expectEqual(1, r.items.items.len);
    try std.testing.expectEqual(@as(usize, 8), r.items.items[0].column);
}

test "source_line is populated" {
    var r = try runCheck("pub fn foo() void {}", false, null, .{});
    defer r.deinit();
    try std.testing.expectEqual(1, r.items.items.len);
    try std.testing.expectEqualStrings("pub fn foo() void {}", r.items.items[0].source_line);
}

test "re-export with unresolvable import is silently skipped (no false positive)" {
    // When the imported file can't be resolved (fake path from <test> file),
    // the re-export must produce zero diagnostics.
    var r = try runCheck("pub const Foo = @import(\"definitely_nonexistent_xyz.zig\").Bar;", false, null, .{});
    defer r.deinit();
    try std.testing.expectEqual(0, r.items.items.len);
}

test "re-export through local import alias is recognized" {
    var r = try runCheck(
        \\const helpers = @import("helpers.zig");
        \\pub const greet = helpers.greet;
    , false, null, .{});
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
    , false, null, .{});
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
    , false, null, .{ .check_parameters = true });
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
    , false, null, .{ .check_parameters = true });
    defer r.deinit();
    try std.testing.expectEqual(0, r.items.items.len);
}

test "unnamed and varargs parameters are skipped when enabled" {
    var r = try runCheck(
        \\/// Does something.
        \\pub fn foo(_: u32, args: anytype, ...) void {
        \\    _ = args;
        \\}
    , false, null, .{ .check_parameters = true });
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

    try check(&tree, .{ .scan_mode = .public_api_surface, .options = .{ .check_parameters = true } }, "<test>", false, null, base, std.testing.io, msg_arena.allocator(), &diagnostics);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}
