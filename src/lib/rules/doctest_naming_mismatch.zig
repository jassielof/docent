const std = @import("std");
const Ast = std.zig.Ast;
const Diagnostic = @import("../Diagnostic.zig");
const Severity = @import("../Severity.zig");

const rule_name = "doctest_naming_mismatch";

pub fn check(
    tree: *const Ast,
    severity: Severity.Level,
    file: []const u8,
    allocator: std.mem.Allocator,
    msg_allocator: std.mem.Allocator,
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
                            .message = try std.fmt.allocPrint(
                                msg_allocator,
                                "use `test {s}` instead of `test \"{s}\"` for the doctest",
                                .{ unquoted, unquoted },
                            ),
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

test "detects string test name matching pub fn, shows correction" {
    var r = try runCheck(
        \\/// Does something.
        \\pub fn foo() void {}
        \\test "foo" {}
    );
    defer r.deinit();
    try std.testing.expectEqual(1, r.items.items.len);
    try std.testing.expectEqualStrings(rule_name, r.items.items[0].rule);
    try std.testing.expect(std.mem.indexOf(u8, r.items.items[0].message, "test foo") != null);
}

test "no diagnostic for identifier test name" {
    var r = try runCheck(
        \\/// Does something.
        \\pub fn foo() void {}
        \\test foo {}
    );
    defer r.deinit();
    try std.testing.expectEqual(0, r.items.items.len);
}

test "no diagnostic for string test not matching any pub fn" {
    var r = try runCheck(
        \\/// Does something.
        \\pub fn foo() void {}
        \\test "bar" {}
    );
    defer r.deinit();
    try std.testing.expectEqual(0, r.items.items.len);
}
