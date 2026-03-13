const std = @import("std");
const Ast = std.zig.Ast;
const Diagnostic = @import("../Diagnostic.zig");
const Severity = @import("../Severity.zig");

const rule_name = "missing_doc_comment";

pub fn check(
    tree: *const Ast,
    severity: Severity.Level,
    file: []const u8,
    allocator: std.mem.Allocator,
    msg_allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) std.mem.Allocator.Error!void {
    if (!severity.isActive()) return;
    for (tree.rootDecls()) |decl| {
        try checkNode(tree, decl, severity, file, allocator, msg_allocator, diagnostics);
    }
}

fn checkNode(
    tree: *const Ast,
    node: Ast.Node.Index,
    severity: Severity.Level,
    file: []const u8,
    allocator: std.mem.Allocator,
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
                        });
                    }
                }
            }
        }
        return;
    }

    if (tree.fullVarDecl(node)) |var_decl| {
        if (var_decl.visib_token) |vt| {
            if (tree.tokenTag(vt) == .keyword_pub) {
                if (!hasDocComment(tree, var_decl.firstToken())) {
                    const name_tok = var_decl.ast.mut_token + 1;
                    const name = tree.tokenSlice(name_tok);
                    const kind = if (tree.tokenTag(var_decl.ast.mut_token) == .keyword_const) "constant" else "variable";
                    const loc = tree.tokenLocation(0, name_tok);
                    try diagnostics.append(allocator, .{
                        .rule = rule_name,
                        .severity = severity,
                        .message = try std.fmt.allocPrint(msg_allocator, "missing doc comment for {s} '{s}'", .{ kind, name }),
                        .file = file,
                        .line = loc.line + 1,
                        .column = loc.column + 1,
                    });
                }
            }
        }
        try checkVarDeclInit(tree, var_decl, severity, file, allocator, msg_allocator, diagnostics);
        return;
    }

    if (isContainerDecl(tag)) {
        var buf: [2]Ast.Node.Index = undefined;
        if (tree.fullContainerDecl(&buf, node)) |container| {
            for (container.ast.members) |member| {
                try checkNode(tree, member, severity, file, allocator, msg_allocator, diagnostics);
            }
        }
        return;
    }

    if (tree.fullContainerField(node)) |field| {
        if (!hasDocComment(tree, field.firstToken())) {
            const name = tree.tokenSlice(field.ast.main_token);
            const loc = tree.tokenLocation(0, field.ast.main_token);
            try diagnostics.append(allocator, .{
                .rule = rule_name,
                .severity = severity,
                .message = try std.fmt.allocPrint(msg_allocator, "missing doc comment for field '{s}'", .{name}),
                .file = file,
                .line = loc.line + 1,
                .column = loc.column + 1,
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
    msg_allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) std.mem.Allocator.Error!void {
    const init_node = var_decl.ast.init_node.unwrap() orelse return;
    if (isContainerDecl(tree.nodeTag(init_node))) {
        var buf: [2]Ast.Node.Index = undefined;
        if (tree.fullContainerDecl(&buf, init_node)) |container| {
            for (container.ast.members) |member| {
                try checkNode(tree, member, severity, file, allocator, msg_allocator, diagnostics);
            }
        }
    }
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

    try check(&tree, .warn, "<test>", base, msg_arena.allocator(), &diagnostics);
    return .{ .msg_arena = msg_arena, .items = diagnostics };
}

test "detects missing doc comment on pub fn, names the symbol" {
    var r = try runCheck("pub fn foo() void {}");
    defer r.deinit();
    try std.testing.expectEqual(1, r.items.items.len);
    try std.testing.expectEqualStrings(rule_name, r.items.items[0].rule);
    try std.testing.expect(std.mem.indexOf(u8, r.items.items[0].message, "'foo'") != null);
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

test "location points to name token, not keyword" {
    var r = try runCheck("pub fn myFunc() void {}");
    defer r.deinit();
    try std.testing.expectEqual(1, r.items.items.len);
    // 'pub' is col 1, 'fn' is col 5, 'myFunc' is col 8
    try std.testing.expectEqual(@as(usize, 8), r.items.items[0].column);
}
