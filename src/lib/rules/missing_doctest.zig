const std = @import("std");
const Ast = std.zig.Ast;
const Token = std.zig.Token;
const Diagnostic = @import("../Diagnostic.zig");
const Severity = @import("../Severity.zig");

const rule_name = "missing_doctest";

pub fn check(
    tree: *const Ast,
    severity: Severity.Level,
    file: []const u8,
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) !void {
    if (!severity.isActive()) return;

    var pub_fns = std.StringHashMap(Ast.TokenIndex).init(allocator);
    defer pub_fns.deinit();

    var tested_names = std.StringHashMap(void).init(allocator);
    defer tested_names.deinit();

    for (tree.rootDecls()) |decl| {
        try collectDecl(tree, decl, &pub_fns, &tested_names);
    }

    var iter = pub_fns.iterator();
    while (iter.next()) |entry| {
        if (!tested_names.contains(entry.key_ptr.*)) {
            const loc = tree.tokenLocation(0, entry.value_ptr.*);
            try diagnostics.append(allocator, .{
                .rule = rule_name,
                .severity = severity,
                .message = "public function is missing a doctest",
                .file = file,
                .line = loc.line + 1,
                .column = loc.column + 1,
            });
        }
    }
}

fn collectDecl(
    tree: *const Ast,
    node: Ast.Node.Index,
    pub_fns: *std.StringHashMap(Ast.TokenIndex),
    tested_names: *std.StringHashMap(void),
) !void {
    const tag = tree.nodeTag(node);

    if (tag == .test_decl) {
        const name_token_opt: Ast.OptionalTokenIndex = tree.nodeData(node).opt_token_and_node[0];
        if (name_token_opt.unwrap()) |name_token| {
            if (tree.tokenTag(name_token) == .identifier) {
                try tested_names.put(tree.tokenSlice(name_token), {});
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
                        try pub_fns.put(tree.tokenSlice(nt), nt);
                    }
                }
            }
        }
        return;
    }
}

test "detects missing doctest for pub fn" {
    const source =
        \\/// Does something.
        \\pub fn foo() void {}
    ;
    var result = try runCheck(source);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(1, result.items.len);
    try std.testing.expectEqualStrings(rule_name, result.items[0].rule);
}

test "no diagnostic when doctest exists" {
    const source =
        \\/// Does something.
        \\pub fn foo() void {}
        \\test foo {}
    ;
    var result = try runCheck(source);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(0, result.items.len);
}

test "no diagnostic for private fn" {
    const source =
        \\fn foo() void {}
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
