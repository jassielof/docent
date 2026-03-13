// COMPAT: //! top-level doc comments — remove this file if deprecated in 0.16

const std = @import("std");
const Ast = std.zig.Ast;
const Diagnostic = @import("../Diagnostic.zig");
const Severity = @import("../Severity.zig");

const rule_name = "missing_container_doc_comment";

pub fn check(
    tree: *const Ast,
    severity: Severity.Level,
    file: []const u8,
    allocator: std.mem.Allocator,
    msg_allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) std.mem.Allocator.Error!void {
    if (!severity.isActive()) return;

    if (!hasContainerDocComment(tree, 0)) {
        const basename = std.fs.path.basename(file);
        try diagnostics.append(allocator, .{
            .rule = rule_name,
            .severity = severity,
            .message = try std.fmt.allocPrint(msg_allocator, "missing //! module doc comment for '{s}'", .{basename}),
            .file = file,
            .line = 1,
            .column = 1,
        });
    }

    for (tree.rootDecls()) |decl| {
        try checkContainerDecl(tree, decl, severity, file, allocator, msg_allocator, diagnostics);
    }
}

fn checkContainerDecl(
    tree: *const Ast,
    node: Ast.Node.Index,
    severity: Severity.Level,
    file: []const u8,
    allocator: std.mem.Allocator,
    msg_allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) std.mem.Allocator.Error!void {
    if (tree.fullVarDecl(node)) |var_decl| {
        if (var_decl.visib_token) |vt| {
            if (tree.tokenTag(vt) == .keyword_pub) {
                const init_node = var_decl.ast.init_node.unwrap() orelse return;
                const name_tok = var_decl.ast.mut_token + 1;
                const name = tree.tokenSlice(name_tok);
                try checkContainerNode(tree, init_node, name, severity, file, allocator, msg_allocator, diagnostics);
            }
        }
        return;
    }
}

fn checkContainerNode(
    tree: *const Ast,
    node: Ast.Node.Index,
    name: []const u8,
    severity: Severity.Level,
    file: []const u8,
    allocator: std.mem.Allocator,
    msg_allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) std.mem.Allocator.Error!void {
    if (!isContainerDecl(tree.nodeTag(node))) return;

    var buf: [2]Ast.Node.Index = undefined;
    const container = tree.fullContainerDecl(&buf, node) orelse return;

    const lbrace = container.ast.main_token + 1;
    const after_lbrace = if (tree.tokenTag(lbrace) == .l_brace) lbrace + 1 else lbrace;

    if (!hasContainerDocComment(tree, after_lbrace)) {
        const kind = containerKind(tree.tokenTag(container.ast.main_token));
        const loc = tree.tokenLocation(0, container.ast.main_token + 1);
        try diagnostics.append(allocator, .{
            .rule = rule_name,
            .severity = severity,
            .message = try std.fmt.allocPrint(msg_allocator, "missing //! doc comment for {s} '{s}'", .{ kind, name }),
            .file = file,
            .line = loc.line + 1,
            .column = loc.column + 1,
        });
    }

    for (container.ast.members) |member| {
        try checkContainerDecl(tree, member, severity, file, allocator, msg_allocator, diagnostics);
    }
}

fn containerKind(token_tag: std.zig.Token.Tag) []const u8 {
    return switch (token_tag) {
        .keyword_struct => "struct",
        .keyword_enum => "enum",
        .keyword_union => "union",
        .keyword_opaque => "opaque",
        else => "container",
    };
}

fn hasContainerDocComment(tree: *const Ast, start_token: Ast.TokenIndex) bool {
    const tags = tree.tokens.items(.tag);
    if (start_token >= tags.len) return false;
    return tags[start_token] == .container_doc_comment;
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

    try check(&tree, .warn, "<test>", base, msg_arena.allocator(), &diagnostics);
    return .{ .msg_arena = msg_arena, .items = diagnostics };
}

test "detects missing //! at file level, names the file" {
    var r = try runCheck("pub fn foo() void {}");
    defer r.deinit();
    try std.testing.expectEqual(1, r.items.items.len);
    try std.testing.expectEqualStrings(rule_name, r.items.items[0].rule);
    try std.testing.expect(std.mem.indexOf(u8, r.items.items[0].message, "<test>") != null);
}

test "no diagnostic when //! present" {
    var r = try runCheck(
        \\//! Module documentation.
        \\pub fn foo() void {}
    );
    defer r.deinit();
    try std.testing.expectEqual(0, r.items.items.len);
}

test "detects missing //! on named container, names the container" {
    var r = try runCheck(
        \\//! Module doc.
        \\pub const MyStruct = struct {
        \\    x: u32,
        \\};
    );
    defer r.deinit();
    try std.testing.expectEqual(1, r.items.items.len);
    try std.testing.expect(std.mem.indexOf(u8, r.items.items[0].message, "'MyStruct'") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.items.items[0].message, "struct") != null);
}
