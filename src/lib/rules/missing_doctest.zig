const std = @import("std");
const Ast = std.zig.Ast;
const Diagnostic = @import("../Diagnostic.zig");
const Severity = @import("../Severity.zig");

const rule_name = "missing_doctest";

pub fn check(
    tree: *const Ast,
    severity: Severity.Level,
    file: []const u8,
    allocator: std.mem.Allocator,
    msg_allocator: std.mem.Allocator,
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
            const name = entry.key_ptr.*;
            const loc = tree.tokenLocation(0, entry.value_ptr.*);
            try diagnostics.append(allocator, .{
                .rule = rule_name,
                .severity = severity,
                .message = try std.fmt.allocPrint(msg_allocator, "missing doctest for function '{s}'", .{name}),
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

test "detects missing doctest for pub fn, names the function" {
    var r = try runCheck(
        \\/// Does something.
        \\pub fn foo() void {}
    );
    defer r.deinit();
    try std.testing.expectEqual(1, r.items.items.len);
    try std.testing.expectEqualStrings(rule_name, r.items.items[0].rule);
    try std.testing.expect(std.mem.indexOf(u8, r.items.items[0].message, "'foo'") != null);
}

test "no diagnostic when doctest exists" {
    var r = try runCheck(
        \\/// Does something.
        \\pub fn foo() void {}
        \\test foo {}
    );
    defer r.deinit();
    try std.testing.expectEqual(0, r.items.items.len);
}

test "no diagnostic for private fn" {
    var r = try runCheck("fn foo() void {}");
    defer r.deinit();
    try std.testing.expectEqual(0, r.items.items.len);
}
