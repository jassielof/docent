//! Requires a file-level `//!` doc comment on library entry points.
// COMPAT: //! top-level doc comments — remove this file if deprecated in 0.16

const std = @import("std");
const Ast = std.zig.Ast;
const Diagnostic = @import("../../Diagnostic.zig");
const Severity = @import("../../Severity.zig");
const utils = @import("../utils.zig");

const rule_name = "missing_container_doc_comment";

/// Appends a diagnostic when `require_module_doc` is set and the file has no `//!` comment.
pub fn check(
    tree: *const Ast,
    severity: Severity.Level,
    file: []const u8,
    require_module_doc: bool,
    allocator: std.mem.Allocator,
    msg_allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) std.mem.Allocator.Error!void {
    if (!severity.isActive()) return;
    if (!require_module_doc) return;

    if (hasContainerDocComment(tree, 0)) return;

    const basename = std.fs.path.basename(file);
    // Use the first token (index 0) so we get a properly owned copy of the source line.
    const first_src = if (tree.tokens.len > 0)
        try utils.dupSourceLine(tree, 0, msg_allocator)
    else
        "";
    try diagnostics.append(allocator, .{
        .rule = rule_name,
        .severity = severity,
        .message = try std.fmt.allocPrint(msg_allocator, "missing //! library entry point doc comment for '{s}'", .{basename}),
        .file = file,
        .line = 1,
        .column = 1,
        .source_line = first_src,
        .symbol_len = 1,
    });
}

fn hasContainerDocComment(tree: *const Ast, start_token: Ast.TokenIndex) bool {
    const tags = tree.tokens.items(.tag);
    if (start_token >= tags.len) return false;
    return tags[start_token] == .container_doc_comment;
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

    try check(&tree, .warn, "<test>", true, base, msg_arena.allocator(), &diagnostics);
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
    var r = try runCheck("//! Module documentation.\npub fn foo() void {}");
    defer r.deinit();
    try std.testing.expectEqual(0, r.items.items.len);
}

test "no diagnostic for pub const container without inner //!" {
    var r = try runCheck("//! Module doc.\npub const MyStruct = struct {\n    x: u32,\n};");
    defer r.deinit();
    try std.testing.expectEqual(0, r.items.items.len);
}

test "no file-level check when require_module_doc is false" {
    const base = std.testing.allocator;
    var msg_arena = std.heap.ArenaAllocator.init(base);
    defer msg_arena.deinit();

    var tree = try std.zig.Ast.parse(base, "pub fn foo() void {}", .zig);
    defer tree.deinit(base);

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(base);

    try check(&tree, .warn, "<test>", false, base, msg_arena.allocator(), &diagnostics);
    try std.testing.expectEqual(0, diagnostics.items.len);
}
