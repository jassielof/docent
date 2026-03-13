const std = @import("std");
const Ast = std.zig.Ast;
const Token = std.zig.Token;
const Diagnostic = @import("../Diagnostic.zig");
const Severity = @import("../Severity.zig");

const rule_name = "doctest_naming_mismatch";

pub fn check(
    tree: *const Ast,
    severity: Severity.Level,
    file: []const u8,
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) !void {
    if (!severity.isActive()) return;

    var pub_fn_names = std.StringHashMap(void).init(allocator);
    defer pub_fn_names.deinit();

    for (tree.rootDecls()) |decl| {
        if (tree.nodeTag(decl) == .fn_decl) {
            var buf: [1]Ast.Node.Index = undefined;
            if (tree.fullFnProto(&buf, decl)) |proto| {
                if (proto.visib_token) |vt| {
                    if (tree.tokenTag(vt) == .keyword_pub) {
                        if (proto.name_token) |nt| {
                            try pub_fn_names.put(tree.tokenSlice(nt), {});
                        }
                    }
                }
            }
        }
    }

    for (tree.rootDecls()) |decl| {
        if (tree.nodeTag(decl) == .test_decl) {
            const name_token_opt: Ast.OptionalTokenIndex = tree.nodeData(decl).opt_token_and_node[0];
            if (name_token_opt.unwrap()) |name_token| {
                if (tree.tokenTag(name_token) == .string_literal) {
                    const raw = tree.tokenSlice(name_token);
                    const unquoted = stripQuotes(raw);
                    if (pub_fn_names.contains(unquoted)) {
                        const loc = tree.tokenLocation(0, name_token);
                        try diagnostics.append(allocator, .{
                            .rule = rule_name,
                            .severity = severity,
                            .message = "use `test identifier` instead of `test \"string\"` for doctests",
                            .file = file,
                            .line = loc.line + 1,
                            .column = loc.column + 1,
                        });
                    }
                }
            }
        }
    }
}

fn stripQuotes(s: []const u8) []const u8 {
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') {
        return s[1 .. s.len - 1];
    }
    return s;
}

test "detects string test name matching pub fn" {
    const source =
        \\/// Does something.
        \\pub fn foo() void {}
        \\test "foo" {}
    ;
    var result = try runCheck(source);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(1, result.items.len);
    try std.testing.expectEqualStrings(rule_name, result.items[0].rule);
}

test "no diagnostic for identifier test name" {
    const source =
        \\/// Does something.
        \\pub fn foo() void {}
        \\test foo {}
    ;
    var result = try runCheck(source);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(0, result.items.len);
}

test "no diagnostic for string test not matching any pub fn" {
    const source =
        \\/// Does something.
        \\pub fn foo() void {}
        \\test "bar" {}
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
