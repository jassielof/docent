const std = @import("std");
const Ast = std.zig.Ast;
const Diagnostic = @import("../Diagnostic.zig");
const Severity = @import("../Severity.zig");
const utils = @import("utils.zig");

const rule_name = "private_doctest";

pub fn check(
    tree: *const Ast,
    severity: Severity.Level,
    file: []const u8,
    allocator: std.mem.Allocator,
    msg_allocator: std.mem.Allocator,
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
                .message = try std.fmt.allocPrint(msg_allocator, "doctest 'test {s}' references a non-public symbol", .{entry.name}),
                .file = file,
                .line = loc.line + 1,
                .column = loc.column + 1,
                .source_line = try utils.dupSourceLine(tree, entry.token, msg_allocator),
                .symbol_len = entry.name.len,
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

test "detects doctest referencing private fn, names the symbol" {
    var r = try runCheck("fn foo() void {}\ntest foo {}");
    defer r.deinit();
    try std.testing.expectEqual(1, r.items.items.len);
    try std.testing.expectEqualStrings(rule_name, r.items.items[0].rule);
    try std.testing.expect(std.mem.indexOf(u8, r.items.items[0].message, "foo") != null);
}

test "no diagnostic when doctest references pub fn" {
    var r = try runCheck("/// Does something.\npub fn foo() void {}\ntest foo {}");
    defer r.deinit();
    try std.testing.expectEqual(0, r.items.items.len);
}

test "no diagnostic for string-literal test names" {
    var r = try runCheck("test \"some behavior\" {}");
    defer r.deinit();
    try std.testing.expectEqual(0, r.items.items.len);
}
