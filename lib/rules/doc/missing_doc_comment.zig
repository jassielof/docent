//! The `missing_doc_comment` namespace checks for missing doc comments.
//!
//! This checks declarations that are missing doc comments. Including, but not limited to:
//!
//! - [Functions and its parameters](https://ziglang.org/documentation/0.16.0/#Functions).
//!   - Parameters are allowed to be undocumented by default.
//! - [Container level variables and constants](https://ziglang.org/documentation/0.16.0/#Container-Level-Variables).
//! - [Enumerations](https://ziglang.org/documentation/0.16.0/#enum).
//!   - Enumerators are checked when `check_enumerators` is enabled.
//! - [Structures](https://ziglang.org/documentation/0.16.0/#struct).
//!   - Fields are checked when `check_fields` is enabled.
//! - [Unions](https://ziglang.org/documentation/0.16.0/#union).
//!   - Fields are checked when `check_fields` is enabled.
//! - [Errors](https://ziglang.org/documentation/0.16.0/#Errors).
//!   - Individual errors inside a set (or merged set) are checked when `check_errors` is enabled.
const std = @import("std");
const Ast = std.zig.Ast;

const doc_comment = @import("doc_comment");
const lint = @import("lint");
const category = lint.category;
const Diagnostic = lint.Diagnostic;
const scan = lint.scan;
const severity = lint.severity;

const alias = @import("../scan/alias.zig");
const utils = @import("../utils.zig");

inline fn srcLoc() std.builtin.SourceLocation {
    return @src();
}

const rule_name = utils.ruleIdFromSrc(srcLoc());

/// The default_severity for the rule.
pub const default_severity: severity.Level = .warn;

/// Title for diagnostic prose (`Warning: {prose_title} on …`).
pub const prose_title = "Missing doc comment";

/// Rule-specific knobs for `missing_doc_comment`, held in the `options` sub-space of `Rule`.
pub const Options = struct {
    /// When set, also require `///` on each named function parameter; default `false` keeps parameters optional.
    check_parameters: bool = false,
    /// When set, also require docs on struct and union fields; default `false` keeps field documentation optional.
    check_fields: bool = false,
    /// When set, also require docs on enumerators; default `false` keeps enumerator documentation optional.
    check_enumerators: bool = false,
    /// When set, also require docs on individual error-set members; default `true` documents each error.
    check_errors: bool = true,
};

/// Full configuration for `missing_doc_comment`: severity, scan mode, and the documented `Options` sub-space.
pub const Rule = category.Rule(
    default_severity,
    Options,
    scan.RuleScanConfig.public_api_surface,
);

/// Walks `tree` and appends diagnostics for undocumented public items.
///
/// When `require_module_doc` is set, also requires a file-level `//!` on module entry roots.
/// When `options.check_parameters` is set, also requires `///` on each named function parameter.
/// When `options.check_fields` is set, also requires `///` on struct and union fields.
/// When `options.check_enumerators` is set, also requires `///` on enum enumerators.
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
    try checkModuleDocComment(
        tree,
        severity_level,
        file,
        require_module_doc,
        module_name,
        allocator,
        msg_allocator,
        diagnostics,
    );
    const public_api_only = rule.publicApiOnly();
    for (tree.rootDecls()) |decl| {
        try checkNode(
            tree,
            decl,
            severity_level,
            file,
            public_api_only,
            options,
            .field,
            allocator,
            io,
            msg_allocator,
            diagnostics,
        );
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
    if (doc_comment.hasContainerDocComment(tree, 0)) return;

    const display_name = utils.moduleDisplayName(file, module_name);
    const first_src = if (tree.tokens.len > 0)
        try utils.dupSourceLine(
            tree,
            0,
            msg_allocator,
        )
    else
        "";
    try diagnostics.append(allocator, .{
        .rule = rule_name,
        .severity_level = severity_level,
        .subject = try utils.ownedSubject(
            msg_allocator,
            .module,
            display_name,
        ),
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
    var buf: [2]Ast.Node.Index = undefined;
    if (tree.fullContainerDecl(&buf, init_node)) |container| {
        return switch (tree.tokenTag(container.ast.main_token)) {
            .keyword_enum => .enumeration,
            .keyword_struct => .structure,
            .keyword_union => .@"union",
            else => .constant,
        };
    }
    return .constant;
}

fn isPubVisibility(tree: *const Ast, visib_token: ?Ast.TokenIndex) bool {
    const vt = visib_token orelse return false;
    return tree.tokenTag(vt) == .keyword_pub;
}

fn shouldCheckDecl(
    tree: *const Ast,
    visib_token: ?Ast.TokenIndex,
    public_api_only: bool,
) bool {
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
            if (shouldCheckDecl(
                tree,
                proto.visib_token,
                public_api_only,
            )) {
                if (!hasDocComment(tree, proto.firstToken())) {
                    const name_tok = proto.name_token orelse proto.ast.fn_token;
                    const name = tree.tokenSlice(name_tok);
                    const loc = tree.tokenLocation(0, name_tok);
                    try diagnostics.append(allocator, .{
                        .rule = rule_name,
                        .severity_level = severity_level,
                        .subject = try utils.ownedSubject(
                            msg_allocator,
                            .function,
                            name,
                        ),
                        .file = file,
                        .line = loc.line + 1,
                        .column = loc.column + 1,
                        .source_line = try utils.dupSourceLine(
                            tree,
                            name_tok,
                            msg_allocator,
                        ),
                        .symbol_len = name.len,
                    });
                }
                if (options.check_parameters) {
                    try checkFunctionParams(
                        tree,
                        proto,
                        severity_level,
                        file,
                        allocator,
                        msg_allocator,
                        diagnostics,
                    );
                }
            }
        }
        return;
    }

    if (tree.fullVarDecl(node)) |var_decl| {
        if (shouldCheckDecl(
            tree,
            var_decl.visib_token,
            public_api_only,
        ) and
            !hasDocComment(tree, var_decl.firstToken()))
        {
            const name_tok = var_decl.ast.mut_token + 1;
            const name = tree.tokenSlice(name_tok);
            const is_reexport: bool = blk: {
                const init_node = var_decl.ast.init_node.unwrap() orelse break :blk false;
                break :blk alias.getInfo(tree, init_node) != null or
                    alias.isModuleMemberReexport(tree, init_node);
            };

            if (!is_reexport) {
                const loc = tree.tokenLocation(0, name_tok);
                try diagnostics.append(allocator, .{
                    .rule = rule_name,
                    .severity_level = severity_level,
                    .subject = try utils.ownedSubject(
                        msg_allocator,
                        pubVarDeclSubjectKind(tree, var_decl),
                        name,
                    ),
                    .file = file,
                    .line = loc.line + 1,
                    .column = loc.column + 1,
                    .source_line = try utils.dupSourceLine(
                        tree,
                        name_tok,
                        msg_allocator,
                    ),
                    .symbol_len = name.len,
                });
            }
        }
        try checkVarDeclInit(
            tree,
            var_decl,
            severity_level,
            file,
            public_api_only,
            options,
            allocator,
            io,
            msg_allocator,
            diagnostics,
        );
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
                try checkNode(
                    tree,
                    member,
                    severity_level,
                    file,
                    public_api_only,
                    options,
                    child_member_kind,
                    allocator,
                    io,
                    msg_allocator,
                    diagnostics,
                );
            }
        }
        return;
    }

    if (tree.fullContainerField(node)) |field| {
        if (member_field_kind == .field and !options.check_fields) return;
        if (member_field_kind == .enumerator and !options.check_enumerators) return;
        if (!hasDocComment(tree, field.firstToken())) {
            const name_tok = field.ast.main_token;
            const name = tree.tokenSlice(name_tok);
            const loc = tree.tokenLocation(0, name_tok);
            try diagnostics.append(allocator, .{
                .rule = rule_name,
                .severity_level = severity_level,
                .subject = try utils.ownedSubject(
                    msg_allocator,
                    member_field_kind,
                    name,
                ),
                .file = file,
                .line = loc.line + 1,
                .column = loc.column + 1,
                .source_line = try utils.dupSourceLine(
                    tree,
                    name_tok,
                    msg_allocator,
                ),
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
        if (std.mem.eql(
            u8,
            name,
            "_",
        )) continue;
        const loc = tree.tokenLocation(0, name_tok);
        try diagnostics.append(allocator, .{
            .rule = rule_name,
            .severity_level = severity_level,
            .subject = try utils.ownedSubject(
                msg_allocator,
                .parameter,
                name,
            ),
            .file = file,
            .line = loc.line + 1,
            .column = loc.column + 1,
            .source_line = try utils.dupSourceLine(
                tree,
                name_tok,
                msg_allocator,
            ),
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
    if (public_api_only and !shouldCheckDecl(
        tree,
        var_decl.visib_token,
        true,
    )) return;

    const init_node = var_decl.ast.init_node.unwrap() orelse return;
    if (tree.nodeTag(init_node) == .error_set_decl) {
        try checkErrorSetMembers(
            tree,
            init_node,
            severity_level,
            file,
            options.check_errors,
            allocator,
            msg_allocator,
            diagnostics,
        );
        return;
    }
    if (isContainerDecl(tree.nodeTag(init_node))) {
        var buf: [2]Ast.Node.Index = undefined;
        if (tree.fullContainerDecl(&buf, init_node)) |container| {
            const child_member_kind: Diagnostic.SubjectKind = if (utils.isEnumContainer(
                tree,
                init_node,
            ))
                .enumerator
            else
                .field;
            for (container.ast.members) |member| {
                try checkNode(
                    tree,
                    member,
                    severity_level,
                    file,
                    public_api_only,
                    options,
                    child_member_kind,
                    allocator,
                    io,
                    msg_allocator,
                    diagnostics,
                );
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
            .subject = try utils.ownedSubject(
                msg_allocator,
                .error_value,
                name,
            ),
            .file = file,
            .line = loc.line + 1,
            .column = loc.column + 1,
            .source_line = try utils.dupSourceLine(
                tree,
                tok,
                msg_allocator,
            ),
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
        .subject = try utils.ownedSubject(
            ctx.msg_allocator,
            .function,
            display_symbol,
        ),
        .detail = "re-exported without documentation",
        .file = try std.mem.replaceOwned(
            u8,
            ctx.msg_allocator,
            file_path,
            "\\",
            "/",
        ),
        .line = loc.line + 1,
        .column = loc.column + 1,
        .source_line = try utils.dupSourceLine(
            tree,
            name_tok,
            ctx.msg_allocator,
        ),
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
    const subject_kind = utils.diagnosticSubjectKindFromDoc(
        doc_comment.exposedSourceFileSubjectKind(tree),
    );
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
        .subject = try utils.ownedSubject(
            ctx.msg_allocator,
            subject_kind,
            source_basename,
        ),
        .file = try std.mem.replaceOwned(
            u8,
            ctx.msg_allocator,
            file_path,
            "\\",
            "/",
        ),
        .line = line + 1,
        .column = column + 1,
        .source_line = if (tree.tokens.len > 0) try utils.dupSourceLine(
            tree,
            0,
            ctx.msg_allocator,
        ) else "",
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
    var tree = try std.zig.Ast.parse(
        base,
        source,
        .zig,
    );
    defer tree.deinit(base);

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(base);

    try check(
        &tree,
        .{
            .scan_mode = scan.RuleScanConfig.public_api_surface,
            .options = .{ .check_parameters = true },
        },
        "<test>",
        false,
        null,
        base,
        std.testing.io,
        msg_arena.allocator(),
        &diagnostics,
    );
    try std.testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}

fn runCheck(
    source: [:0]const u8,
    rule: Rule,
    file: []const u8,
    require_module_doc: bool,
    module_name: ?[]const u8,
    diagnostics: *std.ArrayList(Diagnostic),
    msg_allocator: std.mem.Allocator,
) !void {
    const allocator = std.testing.allocator;
    var tree = try std.zig.Ast.parse(
        allocator,
        source,
        .zig,
    );
    defer tree.deinit(allocator);

    try check(
        &tree,
        rule,
        file,
        require_module_doc,
        module_name,
        allocator,
        std.testing.io,
        msg_allocator,
        diagnostics,
    );
}

const deny_rule: Rule = .{ .level = .deny };

test "compliant_pub_declarations has no violations" {
    const source =
        \\//! A fully compliant module with all public declarations documented.
        \\
        \\/// Adds two numbers together.
        \\pub fn add(a: i32, b: i32) i32 {
        \\    return a + b;
        \\}
        \\
        \\/// A point in 2D space.
        \\pub const Point = struct {
        \\    /// The x coordinate.
        \\    x: f64,
        \\    /// The y coordinate.
        \\    y: f64,
        \\};
        \\
        \\/// The application version.
        \\pub const version = "1.0.0";
    ;

    var msg_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer msg_arena.deinit();
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    try runCheck(
        source,
        deny_rule,
        "<test>",
        false,
        null,
        &diagnostics,
        msg_arena.allocator(),
    );
    try std.testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}

test "undocumented_pub_declarations skips fields by default and reports at deny severity" {
    const source =
        \\//! Module with missing doc comments.
        \\
        \\pub fn undocumented_fn() void {}
        \\
        \\pub const undocumented_const = 42;
        \\
        \\/// Documented struct but fields are not.
        \\pub const MyStruct = struct {
        \\    x: u32,
        \\    y: u32,
        \\};
    ;

    var msg_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer msg_arena.deinit();
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    try runCheck(
        source,
        deny_rule,
        "<test>",
        false,
        null,
        &diagnostics,
        msg_arena.allocator(),
    );
    try std.testing.expectEqual(@as(usize, 2), diagnostics.items.len);
    for (diagnostics.items) |d| try std.testing.expectEqual(severity.Level.deny, d.severity_level);
}

test "undocumented public struct is reported as a structure" {
    const source =
        \\pub const Node = struct {
        \\    value: u32,
        \\};
    ;

    var msg_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer msg_arena.deinit();
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    try runCheck(
        source,
        deny_rule,
        "<test>",
        false,
        null,
        &diagnostics,
        msg_arena.allocator(),
    );
    try std.testing.expectEqual(@as(usize, 1), diagnostics.items.len);
    try std.testing.expectEqual(.structure, diagnostics.items[0].subject.?.kind);
    try std.testing.expectEqualStrings("Node", diagnostics.items[0].subject.?.name);
}

test "private_struct_members_allowed does not require private field docs" {
    const source =
        \\//! Fixture module.
        \\
        \\/// Documented
        \\pub const hello = "world";
        \\
        \\// Since the struct is private, omit everything about it, including its members and functions even public ones.
        \\const PrivateStruct = struct {
        \\    step: i32,
        \\    color: []const u8,
        \\
        \\    fn hello() void {}
        \\    pub fn world() void {}
        \\};
        \\
        \\/// Documented
        \\pub const PublicStruct = struct {
        \\    /// Documented
        \\    step: i32,
        \\    /// Documented
        \\    color: []const u8,
        \\
        \\    fn hello() void {}
        \\    /// Documented
        \\    pub fn world() void {}
        \\};
    ;

    var msg_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer msg_arena.deinit();
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    try runCheck(
        source,
        deny_rule,
        "<test>",
        false,
        null,
        &diagnostics,
        msg_arena.allocator(),
    );
    try std.testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}

test "pub_struct_undocumented_members skips undocumented fields by default" {
    const source =
        \\//! Fixture module.
        \\
        \\/// Documented
        \\pub const hello = "world";
        \\
        \\/// Documented container; members below intentionally lack docs (invalid case).
        \\pub const PublicStruct = struct {
        \\    step: i32,
        \\    color: []const u8,
        \\
        \\    fn hello() void {}
        \\    pub fn world() void {}
        \\};
    ;

    var msg_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer msg_arena.deinit();
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    try runCheck(
        source,
        deny_rule,
        "<test>",
        false,
        null,
        &diagnostics,
        msg_arena.allocator(),
    );
    try std.testing.expectEqual(@as(usize, 1), diagnostics.items.len);
}

test "detects missing module doc comment on entry root" {
    const source =
        \\pub fn foo() void {}
    ;

    var msg_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer msg_arena.deinit();
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    try runCheck(
        source,
        deny_rule,
        "root.zig",
        true,
        "fixture",
        &diagnostics,
        msg_arena.allocator(),
    );
    try std.testing.expectEqual(@as(usize, 2), diagnostics.items.len);
    try std.testing.expectEqual(.module, diagnostics.items[0].subject.?.kind);
    try std.testing.expectEqualStrings("fixture", diagnostics.items[0].subject.?.name);
}

test "no module doc diagnostic when //! present" {
    const source =
        \\//! Module documentation.
        \\pub fn foo() void {}
    ;

    var msg_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer msg_arena.deinit();
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    try runCheck(
        source,
        deny_rule,
        "root.zig",
        true,
        "fixture",
        &diagnostics,
        msg_arena.allocator(),
    );
    try std.testing.expectEqual(@as(usize, 1), diagnostics.items.len);
    try std.testing.expectEqual(.function, diagnostics.items[0].subject.?.kind);
}

test "no module doc check when require_module_doc is false" {
    const source =
        \\pub fn foo() void {}
    ;

    var msg_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer msg_arena.deinit();
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    try runCheck(
        source,
        deny_rule,
        "<test>",
        false,
        null,
        &diagnostics,
        msg_arena.allocator(),
    );
    try std.testing.expectEqual(@as(usize, 1), diagnostics.items.len);
    try std.testing.expect(diagnostics.items[0].subject.?.kind != .module);
}

test "no extra module doc required inside pub const struct body" {
    const source =
        \\//! Module doc.
        \\/// Documented struct.
        \\pub const MyStruct = struct {
        \\    /// Documented field.
        \\    x: u32,
        \\};
    ;

    var msg_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer msg_arena.deinit();
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    try runCheck(
        source,
        deny_rule,
        "root.zig",
        true,
        "mylib",
        &diagnostics,
        msg_arena.allocator(),
    );
    try std.testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}

test "detects missing doc comment on pub fn, names the symbol" {
    const source =
        \\pub fn foo() void {}
    ;

    var msg_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer msg_arena.deinit();
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    try runCheck(
        source,
        deny_rule,
        "<test>",
        false,
        null,
        &diagnostics,
        msg_arena.allocator(),
    );
    try std.testing.expectEqual(@as(usize, 1), diagnostics.items.len);
    try std.testing.expectEqualStrings("foo", diagnostics.items[0].subject.?.name);
    try std.testing.expectEqual(@as(usize, 3), diagnostics.items[0].symbol_len);
}

test "no diagnostic for documented pub fn" {
    const source =
        \\/// Does something.
        \\pub fn foo() void {}
    ;

    var msg_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer msg_arena.deinit();
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    try runCheck(
        source,
        deny_rule,
        "<test>",
        false,
        null,
        &diagnostics,
        msg_arena.allocator(),
    );
    try std.testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}

test "no diagnostic for private fn" {
    const source =
        \\fn foo() void {}
    ;

    var msg_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer msg_arena.deinit();
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    try runCheck(
        source,
        deny_rule,
        "<test>",
        false,
        null,
        &diagnostics,
        msg_arena.allocator(),
    );
    try std.testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}

test "detects missing doc comment on pub const, names the symbol" {
    const source =
        \\pub const answer = 42;
    ;

    var msg_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer msg_arena.deinit();
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    try runCheck(
        source,
        deny_rule,
        "<test>",
        false,
        null,
        &diagnostics,
        msg_arena.allocator(),
    );
    try std.testing.expectEqual(@as(usize, 1), diagnostics.items.len);
    try std.testing.expectEqualStrings("answer", diagnostics.items[0].subject.?.name);
    try std.testing.expectEqual(.constant, diagnostics.items[0].subject.?.kind);
}

test "detects missing doc comment on pub const error set" {
    const source =
        \\pub const MyErr = error{ OutOfMemory };
    ;

    var msg_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer msg_arena.deinit();
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    try runCheck(
        source,
        deny_rule,
        "<test>",
        false,
        null,
        &diagnostics,
        msg_arena.allocator(),
    );
    try std.testing.expectEqual(@as(usize, 2), diagnostics.items.len);
    try std.testing.expectEqual(.error_set, diagnostics.items[0].subject.?.kind);
    try std.testing.expectEqualStrings("MyErr", diagnostics.items[0].subject.?.name);
    try std.testing.expectEqual(.error_value, diagnostics.items[1].subject.?.kind);
    try std.testing.expectEqualStrings("OutOfMemory", diagnostics.items[1].subject.?.name);
}

test "error members are skipped when check_errors is disabled" {
    const source =
        \\pub const MyErr = error{ OutOfMemory };
    ;

    var msg_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer msg_arena.deinit();
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    try runCheck(
        source,
        .{ .level = .deny, .options = .{ .check_errors = false } },
        "<test>",
        false,
        null,
        &diagnostics,
        msg_arena.allocator(),
    );
    try std.testing.expectEqual(@as(usize, 1), diagnostics.items.len);
    try std.testing.expectEqual(.error_set, diagnostics.items[0].subject.?.kind);
}

test "documented error members are accepted" {
    const source =
        \\pub const MyErr = error{
        \\    /// Out of memory.
        \\    OutOfMemory,
        \\};
    ;

    var msg_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer msg_arena.deinit();
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    try runCheck(
        source,
        deny_rule,
        "<test>",
        false,
        null,
        &diagnostics,
        msg_arena.allocator(),
    );
    try std.testing.expectEqual(@as(usize, 1), diagnostics.items.len);
    try std.testing.expectEqual(.error_set, diagnostics.items[0].subject.?.kind);
}

test "container fields are not checked by default" {
    const source =
        \\/// A struct.
        \\pub const S = struct {
        \\    x: u32,
        \\    y: u32,
        \\};
    ;

    var msg_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer msg_arena.deinit();
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    try runCheck(
        source,
        deny_rule,
        "<test>",
        false,
        null,
        &diagnostics,
        msg_arena.allocator(),
    );
    try std.testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}

test "detects missing doc comment on container fields when enabled" {
    const source =
        \\/// A struct.
        \\pub const S = struct {
        \\    x: u32,
        \\    y: u32,
        \\};
    ;

    var msg_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer msg_arena.deinit();
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    try runCheck(
        source,
        .{ .level = .deny, .options = .{ .check_fields = true } },
        "<test>",
        false,
        null,
        &diagnostics,
        msg_arena.allocator(),
    );
    try std.testing.expectEqual(@as(usize, 2), diagnostics.items.len);
    try std.testing.expectEqualStrings("x", diagnostics.items[0].subject.?.name);
    try std.testing.expectEqual(.field, diagnostics.items[0].subject.?.kind);
    try std.testing.expectEqualStrings("y", diagnostics.items[1].subject.?.name);
    try std.testing.expectEqual(.field, diagnostics.items[1].subject.?.kind);
}

test "enumerators are not checked by default" {
    const source =
        \\pub const Color = enum {
        \\    red,
        \\    green,
        \\};
    ;

    var msg_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer msg_arena.deinit();
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    try runCheck(
        source,
        deny_rule,
        "<test>",
        false,
        null,
        &diagnostics,
        msg_arena.allocator(),
    );
    try std.testing.expectEqual(@as(usize, 1), diagnostics.items.len);
    try std.testing.expectEqual(.enumeration, diagnostics.items[0].subject.?.kind);
    try std.testing.expectEqualStrings("Color", diagnostics.items[0].subject.?.name);
}

test "detects missing doc comment on enumerators when enabled" {
    const source =
        \\pub const Color = enum {
        \\    red,
        \\    green,
        \\};
    ;

    var msg_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer msg_arena.deinit();
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    try runCheck(
        source,
        .{ .level = .deny, .options = .{ .check_enumerators = true } },
        "<test>",
        false,
        null,
        &diagnostics,
        msg_arena.allocator(),
    );
    try std.testing.expectEqual(@as(usize, 3), diagnostics.items.len);
    try std.testing.expectEqual(.enumerator, diagnostics.items[1].subject.?.kind);
    try std.testing.expectEqualStrings("red", diagnostics.items[1].subject.?.name);
    try std.testing.expectEqual(.enumerator, diagnostics.items[2].subject.?.kind);
    try std.testing.expectEqualStrings("green", diagnostics.items[2].subject.?.name);
}

test "no diagnostic for private const struct members and pub fn inside" {
    const source =
        \\const PrivateStruct = struct {
        \\    step: i32,
        \\    color: []const u8,
        \\    pub fn world() void {}
        \\};
    ;

    var msg_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer msg_arena.deinit();
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    try runCheck(
        source,
        deny_rule,
        "<test>",
        false,
        null,
        &diagnostics,
        msg_arena.allocator(),
    );
    try std.testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}

test "location points to name token, not keyword" {
    const source =
        \\pub fn myFunc() void {}
    ;

    var msg_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer msg_arena.deinit();
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    try runCheck(
        source,
        deny_rule,
        "<test>",
        false,
        null,
        &diagnostics,
        msg_arena.allocator(),
    );
    try std.testing.expectEqual(@as(usize, 1), diagnostics.items.len);
    try std.testing.expectEqual(@as(usize, 8), diagnostics.items[0].column);
}

test "source_line is populated" {
    const source =
        \\pub fn foo() void {}
    ;

    var msg_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer msg_arena.deinit();
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    try runCheck(
        source,
        deny_rule,
        "<test>",
        false,
        null,
        &diagnostics,
        msg_arena.allocator(),
    );
    try std.testing.expectEqual(@as(usize, 1), diagnostics.items.len);
    try std.testing.expectEqualStrings("pub fn foo() void {}", diagnostics.items[0].source_line);
}

test "re-export via an unresolvable import produces no false positive" {
    const source =
        \\pub const Foo = @import("definitely_nonexistent_xyz.zig").Bar;
    ;

    var msg_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer msg_arena.deinit();
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    try runCheck(
        source,
        deny_rule,
        "<test>",
        false,
        null,
        &diagnostics,
        msg_arena.allocator(),
    );
    try std.testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}

test "re-export through a local import alias produces no false positive" {
    const source =
        \\const helpers = @import("helpers.zig");
        \\pub const greet = helpers.greet;
    ;

    var msg_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer msg_arena.deinit();
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    try runCheck(
        source,
        deny_rule,
        "<test>",
        false,
        null,
        &diagnostics,
        msg_arena.allocator(),
    );
    try std.testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}

test "nested member alias through a local import produces no false positive" {
    const source =
        \\const Document = @import("Document.zig");
        \\
        \\pub const tag = Document.Node.Tag.blockquote;
    ;

    var msg_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer msg_arena.deinit();
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    try runCheck(
        source,
        deny_rule,
        "<test>",
        false,
        null,
        &diagnostics,
        msg_arena.allocator(),
    );
    try std.testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}

test "re-export of a named module import produces no false positive" {
    const source =
        \\const rules = @import("rules");
        \\pub const Doc = rules.doc.Doc;
    ;

    var msg_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer msg_arena.deinit();
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    try runCheck(
        source,
        deny_rule,
        "<test>",
        false,
        null,
        &diagnostics,
        msg_arena.allocator(),
    );
    try std.testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}

test "function parameters are not checked by default" {
    const source =
        \\/// Does something.
        \\pub fn foo(allocator: std.mem.Allocator, value: u32) void {
        \\    _ = allocator;
        \\    _ = value;
        \\}
    ;

    var msg_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer msg_arena.deinit();
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    try runCheck(
        source,
        deny_rule,
        "<test>",
        false,
        null,
        &diagnostics,
        msg_arena.allocator(),
    );
    try std.testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}

test "undocumented function parameters are reported when enabled" {
    const source =
        \\/// Does something.
        \\pub fn foo(
        \\    /// The allocator.
        \\    allocator: std.mem.Allocator,
        \\    value: u32,
        \\) void {
        \\    _ = allocator;
        \\    _ = value;
        \\}
    ;

    var msg_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer msg_arena.deinit();
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    try runCheck(
        source,
        .{ .level = .deny, .options = .{ .check_parameters = true } },
        "<test>",
        false,
        null,
        &diagnostics,
        msg_arena.allocator(),
    );
    try std.testing.expectEqual(@as(usize, 1), diagnostics.items.len);
    try std.testing.expectEqual(.parameter, diagnostics.items[0].subject.?.kind);
    try std.testing.expectEqualStrings("value", diagnostics.items[0].subject.?.name);
}

test "all documented function parameters are accepted when enabled" {
    const source =
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
    ;

    var msg_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer msg_arena.deinit();
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    try runCheck(
        source,
        .{ .level = .deny, .options = .{ .check_parameters = true } },
        "<test>",
        false,
        null,
        &diagnostics,
        msg_arena.allocator(),
    );
    try std.testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}

test "unnamed and varargs parameters are skipped when enabled" {
    const source =
        \\/// Does something.
        \\pub fn foo(_: u32, args: anytype, ...) void {
        \\    _ = args;
        \\}
    ;

    var msg_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer msg_arena.deinit();
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    try runCheck(
        source,
        .{ .level = .deny, .options = .{ .check_parameters = true } },
        "<test>",
        false,
        null,
        &diagnostics,
        msg_arena.allocator(),
    );
    try std.testing.expectEqual(@as(usize, 1), diagnostics.items.len);
    try std.testing.expectEqualStrings("args", diagnostics.items[0].subject.?.name);
}

test "missing_module_doc_on_entry reports missing module doc comment" {
    const source =
        \\pub const version = "0.0.0";
        \\
        \\pub fn ping() void {}
    ;

    var msg_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer msg_arena.deinit();
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    try runCheck(
        source,
        deny_rule,
        "root.zig",
        true,
        "fixture",
        &diagnostics,
        msg_arena.allocator(),
    );
    try std.testing.expectEqual(@as(usize, 3), diagnostics.items.len);

    var module_doc_count: usize = 0;
    for (diagnostics.items) |d| {
        if (d.subject != null and d.subject.?.kind == .module and std.mem.eql(
            u8,
            d.subject.?.name,
            "fixture",
        )) {
            module_doc_count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), module_doc_count);
}

comptime {
    std.testing.refAllDecls(@This());
}
