const std = @import("std");
const Ast = std.zig.Ast;
const Token = std.zig.Token;
const Diagnostic = @import("../Diagnostic.zig");
const Severity = @import("../Severity.zig");

const rule_name = "private_doctest";

pub fn check(
    tree: *const Ast,
    severity: Severity.Level,
    file: []const u8,
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) !void {
    if (!severity.isActive()) return;

    var pub_names = std.StringHashMap(void).init(allocator);
    defer pub_names.deinit();

    var ident_tests: std.ArrayList(TestEntry) = .empty;
    defer ident_tests.deinit(allocator);

    for (tree.rootDecls()) |decl| {
        try collectDecl(tree, decl, allocator, &pub_names, &ident_tests);
    }

    for (ident_tests.items) |entry| {
        if (!pub_names.contains(entry.name)) {
            const loc = tree.tokenLocation(0, entry.token);
            try diagnostics.append(allocator, .{
                .rule = rule_name,
                .severity = severity,
                .message = "doctest references private declaration",
                .file = file,
                .line = loc.line + 1,
                .column = loc.column + 1,
            });
        }
    }
}

const TestEntry = struct { name: []const u8, token: Ast.TokenIndex };

fn collectDecl(
    tree: *const Ast,
    node: Ast.Node.Index,
    allocator: std.mem.Allocator,
    pub_names: *std.StringHashMap(void),
    ident_tests: *std.ArrayList(TestEntry),
) !void {
    const tag = tree.nodeTag(node);

    if (tag == .test_decl) {
        const name_token_opt: Ast.OptionalTokenIndex = tree.nodeData(node).opt_token_and_node[0];
        if (name_token_opt.unwrap()) |name_token| {
            if (tree.tokenTag(name_token) == .identifier) {
                try ident_tests.append(allocator, .{ .name = tree.tokenSlice(name_token), .token = name_token });
            }
        }
        return;
    }

    if (tag == .fn_decl) {
        var buf: [1]Ast.Node.Index = undefined;
        if (tree.fullFnProto(&buf, node)) |proto| {
            if (proto.visib_token) |vt| {
                if (tree.tokenTag(vt) == .keyword_pub) {
                    if (proto.name_token) |nt| {
                        try pub_names.put(tree.tokenSlice(nt), {});
                    }
                }
            }
        }
        return;
    }

    if (tree.fullVarDecl(node)) |var_decl| {
        if (var_decl.visib_token) |vt| {
            if (tree.tokenTag(vt) == .keyword_pub) {
                const name_token = var_decl.ast.mut_token + 1;
                try pub_names.put(tree.tokenSlice(name_token), {});
            }
        }
        return;
    }
}

test "detects doctest referencing private fn" {
    const source =
        \\fn foo() void {}
        \\test foo {}
    ;
    var result = try runCheck(source);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(1, result.items.len);
    try std.testing.expectEqualStrings(rule_name, result.items[0].rule);
}

test "no diagnostic when doctest references pub fn" {
    const source =
        \\/// Does something.
        \\pub fn foo() void {}
        \\test foo {}
    ;
    var result = try runCheck(source);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(0, result.items.len);
}

test "no diagnostic for string-literal test names" {
    const source =
        \\test "some behavior" {}
    ;
    var result = try runCheck(source);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(0, result.items.len);
}

fn runCheck(source: [:0]const u8) !std.ArrayList(Diagnostic) {
    const allocator = std.testing.allocator;
    var tree = try std.zig.Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    errdefer diagnostics.deinit(allocator);

    try check(&tree, .warn, "<test>", allocator, &diagnostics);
    return diagnostics;
}
