const std = @import("std");
const mem = std.mem;
const Ast = std.zig.Ast;
const Allocator = mem.Allocator;

const format_test_assertions = @import("format_test_assertions.zig");

const Kind = enum { function, test_decl };

const Entry = struct {
    kind: Kind,
    name: []const u8,
    start: usize,
    end: usize,
};

test "places named tests directly after their matching function" {
    const gpa = std.testing.allocator;
    const input =
        \\fn add(a: u8, b: u8) u8 {
        \\    return a + b;
        \\}
        \\
        \\fn subtract(a: u8, b: u8) u8 {
        \\    return a - b;
        \\}
        \\
        \\fn divide(a: u8, b: u8) u8 {
        \\    return a / b;
        \\}
        \\
        \\test "subtract" {
        \\    try std.testing.expectEqual(@as(u8, 1), subtract(2, 1));
        \\}
        \\
        \\test "add" {
        \\    try std.testing.expectEqual(@as(u8, 3), add(1, 2));
        \\}
        \\
    ;
    const expected =
        \\fn add(a: u8, b: u8) u8 {
        \\    return a + b;
        \\}
        \\
        \\test "add" {
        \\    try std.testing.expectEqual(@as(u8, 3), add(1, 2));
        \\}
        \\
        \\fn subtract(a: u8, b: u8) u8 {
        \\    return a - b;
        \\}
        \\
        \\test "subtract" {
        \\    try std.testing.expectEqual(@as(u8, 1), subtract(2, 1));
        \\}
        \\
        \\fn divide(a: u8, b: u8) u8 {
        \\    return a / b;
        \\}
        \\
    ;

    const formatted = try sortDoctests(gpa, input);
    defer gpa.free(formatted);
    try std.testing.expectEqualStrings(expected, formatted);
    try format_test_assertions.expectValidZig(formatted);
}

/// Reorders contiguous top-level function/test blocks so a named test follows
/// the function with the same name. Tests with no matching function retain
/// their relative order at the end of the block.
pub fn sortDoctests(gpa: Allocator, input: []const u8) Allocator.Error![]u8 {
    const sentinel = try gpa.dupeZ(u8, input);
    defer gpa.free(sentinel);

    var tree = std.zig.Ast.parse(gpa, sentinel, .zig) catch return gpa.dupe(u8, input);
    defer tree.deinit(gpa);
    if (tree.errors.len != 0) return gpa.dupe(u8, input);

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(gpa);

    const root_decls = tree.rootDecls();
    var cursor: usize = 0;
    var i: usize = 0;
    while (i < root_decls.len) {
        if (!isCandidate(&tree, root_decls[i])) {
            i += 1;
            continue;
        }

        const block_first = i;
        while (i < root_decls.len and isCandidate(&tree, root_decls[i])) : (i += 1) {}
        const block_last = i;

        var entries: std.ArrayList(Entry) = .empty;
        defer entries.deinit(gpa);
        for (root_decls[block_first..block_last]) |node| {
            try entries.append(gpa, entryFor(&tree, node));
        }
        if (!hasMatchingPair(entries.items)) continue;

        const start = entries.items[0].start;
        const end = entries.items[entries.items.len - 1].end;
        try output.appendSlice(gpa, input[cursor..start]);
        try renderBlock(gpa, &output, entries.items, input);
        if (end == input.len and output.items.len >= 2 and output.items[output.items.len - 1] == '\n' and output.items[output.items.len - 2] == '\n') {
            output.items.len -= 1;
        }
        cursor = end;
    }

    if (cursor == 0) return gpa.dupe(u8, input);
    try output.appendSlice(gpa, input[cursor..]);
    return output.toOwnedSlice(gpa);
}

fn isCandidate(tree: *const Ast, node: Ast.Node.Index) bool {
    return switch (tree.nodeTag(node)) {
        .fn_decl, .test_decl => true,
        else => false,
    };
}

fn entryFor(tree: *const Ast, node: Ast.Node.Index) Entry {
    const kind: Kind = if (tree.nodeTag(node) == .fn_decl) .function else .test_decl;
    return .{
        .kind = kind,
        .name = if (kind == .function) functionName(tree, node) else testName(tree, node),
        .start = declarationStart(tree, node),
        .end = declarationEnd(tree, node),
    };
}

fn functionName(tree: *const Ast, node: Ast.Node.Index) []const u8 {
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, node) orelse return "";
    const name_token = proto.name_token orelse return "";
    return tree.tokenSlice(name_token);
}

fn testName(tree: *const Ast, node: Ast.Node.Index) []const u8 {
    const token = tree.nodeData(node).opt_token_and_node[0].unwrap() orelse return "";
    const raw = tree.tokenSlice(token);
    if (tree.tokenTag(token) == .string_literal) {
        if (raw.len < 2 or raw[0] != '"' or raw[raw.len - 1] != '"') return "";
        const unquoted = raw[1 .. raw.len - 1];
        if (mem.indexOfScalar(u8, unquoted, '\\') != null) return "";
        return unquoted;
    }
    return raw;
}

fn declarationStart(tree: *const Ast, node: Ast.Node.Index) usize {
    var start = tree.tokens.items(.start)[tree.firstToken(node)];
    while (start > 0) {
        var line_end = start;
        if (line_end > 0 and tree.source[line_end - 1] == '\n') line_end -= 1;
        var line_start = line_end;
        while (line_start > 0 and tree.source[line_start - 1] != '\n') line_start -= 1;
        const line = mem.trim(u8, tree.source[line_start..line_end], " \t\r");
        if (!mem.startsWith(u8, line, "//")) break;
        start = line_start;
    }
    return start;
}

fn declarationEnd(tree: *const Ast, node: Ast.Node.Index) usize {
    const last = tree.lastToken(node);
    const start = tree.tokens.items(.start)[last];
    var end = start + tree.tokenSlice(last).len;
    while (end < tree.source.len and tree.source[end] != '\n') end += 1;
    if (end < tree.source.len) end += 1;
    return end;
}

fn hasMatchingPair(entries: []const Entry) bool {
    for (entries) |function| {
        if (function.kind != .function or function.name.len == 0) continue;
        for (entries) |test_decl| {
            if (test_decl.kind == .test_decl and mem.eql(u8, function.name, test_decl.name)) return true;
        }
    }
    return false;
}

fn renderBlock(gpa: Allocator, output: *std.ArrayList(u8), entries: []const Entry, source: []const u8) !void {
    var emitted: std.ArrayList(bool) = .empty;
    defer emitted.deinit(gpa);
    try emitted.resize(gpa, entries.len);
    @memset(emitted.items, false);

    for (entries, 0..) |entry, index| {
        if (entry.kind != .function) continue;
        try renderEntry(gpa, output, entry, source);
        emitted.items[index] = true;
        for (entries, 0..) |test_decl, test_index| {
            if (test_decl.kind != .test_decl or !mem.eql(u8, entry.name, test_decl.name)) continue;
            try renderEntry(gpa, output, test_decl, source);
            emitted.items[test_index] = true;
        }
    }
    for (entries, 0..) |entry, index| {
        if (emitted.items[index]) continue;
        try renderEntry(gpa, output, entry, source);
    }
}

fn renderEntry(gpa: Allocator, output: *std.ArrayList(u8), entry: Entry, source: []const u8) !void {
    try output.appendSlice(gpa, source[entry.start..entry.end]);
    if (output.items.len == 0 or output.items[output.items.len - 1] != '\n') try output.append(gpa, '\n');
    try output.append(gpa, '\n');
}
