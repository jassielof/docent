//! Finds every comma-delimited list in a parsed tree — call arguments,
//! builtin-call arguments, struct/array-init elements, and function
//! parameter lists — as flat `ListNode` records with exact token/byte
//! positions for their opening delimiter, closing delimiter, and whether a
//! trailing comma is already present.
//!
//! This exists so `trailing_comma.zig` and `auto_wrap.zig` can decide
//! *whether* a list needs a forced trailing comma purely from AST facts
//! (item count, existing trailing comma, "is this merely an element of an
//! array/struct literal") and then hand the actual line-breaking back to
//! `Ast.render` — the same renderer that produces the real `zig fmt`
//! output — instead of re-deriving indentation from already-rendered text.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;

pub const ListNode = struct {
    /// The call/builtin-call/struct-init/array-init/fn-proto node itself.
    node: Ast.Node.Index,
    /// The `(`/`{` token that opens the list.
    open: Ast.TokenIndex,
    /// The `)`/`}` token that closes the list. Already accounts for an
    /// existing trailing comma: this is the closing delimiter itself, not
    /// the comma before it.
    close: Ast.TokenIndex,
    item_count: usize,
    has_trailing_comma: bool,
};

/// Collects every list in `tree`, excluding array-init elements and
/// struct-init fields: those are laid out by `Ast.render`'s own
/// width-based bin-packing once their enclosing list is (or isn't) forced
/// multi-line, and forcing them independently would fight that layout
/// instead of composing with it. Caller owns the returned slice.
pub fn collect(gpa: Allocator, tree: *const Ast) Allocator.Error![]ListNode {
    var results: std.ArrayList(ListNode) = .empty;
    errdefer results.deinit(gpa);

    var skip: std.AutoHashMap(Ast.Node.Index, void) = .init(gpa);
    defer skip.deinit();

    var seen_close: std.AutoHashMap(Ast.TokenIndex, void) = .init(gpa);
    defer seen_close.deinit();

    var i: usize = 0;
    while (i < tree.nodes.len) : (i += 1) {
        const node: Ast.Node.Index = @enumFromInt(i);

        var buf1: [1]Ast.Node.Index = undefined;
        if (tree.fullCall(&buf1, node)) |call| {
            try addCandidate(
                gpa,
                tree,
                &results,
                &seen_close,
                node,
                call.ast.lparen,
                call.ast.params,
            );
        }

        var buf2: [2]Ast.Node.Index = undefined;
        if (tree.builtinCallParams(&buf2, node)) |params| {
            try addCandidate(
                gpa,
                tree,
                &results,
                &seen_close,
                node,
                tree.nodeMainToken(node) + 1,
                params,
            );
        }

        if (tree.fullStructInit(&buf2, node)) |struct_init| {
            try addCandidate(
                gpa,
                tree,
                &results,
                &seen_close,
                node,
                struct_init.ast.lbrace,
                struct_init.ast.fields,
            );
            for (struct_init.ast.fields) |field| try skip.put(field, {});
        }

        if (tree.fullArrayInit(&buf2, node)) |array_init| {
            try addCandidate(
                gpa,
                tree,
                &results,
                &seen_close,
                node,
                array_init.ast.lbrace,
                array_init.ast.elements,
            );
            for (array_init.ast.elements) |element| try skip.put(element, {});
        }

        var buf3: [1]Ast.Node.Index = undefined;
        if (tree.fullFnProto(&buf3, node)) |fn_proto| {
            try addCandidate(
                gpa,
                tree,
                &results,
                &seen_close,
                node,
                fn_proto.lparen,
                fn_proto.ast.params,
            );
        }
    }

    var out: std.ArrayList(ListNode) = .empty;
    errdefer out.deinit(gpa);
    for (results.items) |list_node| {
        if (skip.contains(list_node.node)) continue;
        try out.append(gpa, list_node);
    }
    results.deinit(gpa);

    return out.toOwnedSlice(gpa);
}

fn addCandidate(
    gpa: Allocator,
    tree: *const Ast,
    results: *std.ArrayList(ListNode),
    seen_close: *std.AutoHashMap(Ast.TokenIndex, void),
    node: Ast.Node.Index,
    open: Ast.TokenIndex,
    items: []const Ast.Node.Index,
) Allocator.Error!void {
    if (items.len == 0) return;

    var close = tree.lastToken(items[items.len - 1]) + 1;
    const has_trailing_comma = tree.tokenTag(close) == .comma;
    if (has_trailing_comma) close += 1;

    // `fn_decl` and its inner `fn_proto_*` node both resolve to the same
    // parameter list via `fullFnProto`'s internal delegation — dedup by the
    // closing token so it isn't recorded (and later force-inserted) twice.
    if ((try seen_close.fetchPut(close, {})) != null) return;

    try results.append(gpa, .{
        .node = node,
        .open = open,
        .close = close,
        .item_count = items.len,
        .has_trailing_comma = has_trailing_comma,
    });
}

test "collects call, builtin call, array-init, and fn-proto lists" {
    const gpa = std.testing.allocator;
    const source =
        \\fn foo(a: u8, b: u8, c: u8) void {
        \\    bar(1, 2, 3);
        \\    @max(1, 2, 3);
        \\    const arr = [_]u8{ 1, 2, 3 };
        \\}
        \\
    ;
    const source_z = try gpa.dupeZ(u8, source);
    defer gpa.free(source_z);
    var tree = try Ast.parse(
        gpa,
        source_z,
        .zig,
    );
    defer tree.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), tree.errors.len);

    const lists = try collect(gpa, &tree);
    defer gpa.free(lists);

    // Four independent 3-item lists: the `fn foo` parameter list, the
    // `bar(...)` call, the `@max(...)` builtin call, and the outer
    // array-init (its `1, 2, 3` elements are plain number literals, not
    // list-kind nodes themselves, so they don't also appear here).
    var three_item_lists: usize = 0;
    for (lists) |list_node| {
        if (list_node.item_count == 3) three_item_lists += 1;
    }
    try std.testing.expectEqual(@as(usize, 4), three_item_lists);
    try std.testing.expectEqual(@as(usize, 4), lists.len);
}

test "excludes array-init elements from independent forcing" {
    const gpa = std.testing.allocator;
    // `Rp(...)` is a direct element of the outer array-init: it must not
    // appear as its own candidate, even though it has 3+ items itself —
    // forcing it independently would fight `Ast.render`'s own bin-packing
    // of the (already trailing-comma'd) outer list.
    const source =
        \\const steps = [_]QuarterRound{
        \\    Rp(4, 0, 12, 7),
        \\    Rp(8, 4, 0, 9),
        \\};
        \\
    ;
    const source_z = try gpa.dupeZ(u8, source);
    defer gpa.free(source_z);
    var tree = try Ast.parse(
        gpa,
        source_z,
        .zig,
    );
    defer tree.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), tree.errors.len);

    const lists = try collect(gpa, &tree);
    defer gpa.free(lists);

    for (lists) |list_node| {
        // The only 4-item list is the outer array-init; both `Rp(...)`
        // calls (4 items each) must have been filtered out.
        if (list_node.item_count == 4) {
            try std.testing.expect(tree.tokenTag(list_node.open) == .l_brace);
        }
    }
}

/// Inserts a `,` at each byte offset in `offsets` (ascending, as produced by
/// sorting the `tree.tokenStart(...)` of each list's closing delimiter).
/// Caller owns the returned slice.
pub fn applyInsertions(
    gpa: Allocator,
    source: []const u8,
    offsets: []const usize,
) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, source.len + offsets.len);

    var cursor: usize = 0;
    for (offsets) |offset| {
        try out.appendSlice(gpa, source[cursor..offset]);
        try out.append(gpa, ',');
        cursor = offset;
    }
    try out.appendSlice(gpa, source[cursor..]);

    return out.toOwnedSlice(gpa);
}

/// Re-parses `source` and renders it with `Ast.render` — the real `zig fmt`
/// renderer, not a re-implementation of it. If `source` fails to parse (it
/// shouldn't: callers only ever insert a `,` at an already-valid closing
/// delimiter), the original `source` is returned unchanged rather than
/// risking a broken rewrite. Caller owns the returned slice.
pub fn renderSource(
    gpa: Allocator,
    source: []const u8,
    mode: Ast.Mode,
) Allocator.Error![]u8 {
    const source_z = try gpa.dupeZ(u8, source);
    defer gpa.free(source_z);

    var tree = try Ast.parse(
        gpa,
        source_z,
        mode,
    );
    defer tree.deinit(gpa);
    if (tree.errors.len != 0) return gpa.dupe(u8, source);

    var out_buf: std.Io.Writer.Allocating = .init(gpa);
    errdefer out_buf.deinit();
    tree.render(
        gpa,
        &out_buf.writer,
        .{},
    ) catch |err| switch (err) {
        error.WriteFailed, error.OutOfMemory => return error.OutOfMemory,
    };
    return out_buf.toOwnedSlice();
}

test "applyInsertions inserts commas at ascending byte offsets" {
    const gpa = std.testing.allocator;
    const source = "foo(a)bar(b)";
    const result = try applyInsertions(
        gpa,
        source,
        &.{ 5, 11 },
    );
    defer gpa.free(result);
    try std.testing.expectEqualStrings("foo(a,)bar(b,)", result);
}

test "renderSource falls back to the original text on parse failure" {
    const gpa = std.testing.allocator;
    const broken = "fn foo(";
    const result = try renderSource(
        gpa,
        broken,
        .zig,
    );
    defer gpa.free(result);
    try std.testing.expectEqualStrings(broken, result);
}
