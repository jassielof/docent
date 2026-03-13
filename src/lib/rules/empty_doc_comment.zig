const std = @import("std");
const Ast = std.zig.Ast;
const Token = std.zig.Token;
const Diagnostic = @import("../Diagnostic.zig");
const Severity = @import("../Severity.zig");

const rule_name = "empty_doc_comment";

pub fn check(
    tree: *const Ast,
    severity: Severity.Level,
    file: []const u8,
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) !void {
    if (!severity.isActive()) return;
    const tags = tree.tokens.items(.tag);
    for (tags, 0..) |tag, i| {
        if (tag == .doc_comment or tag == .container_doc_comment) {
            const slice = tree.tokenSlice(@intCast(i));
            if (isEmptyDocComment(slice)) {
                const loc = tree.tokenLocation(0, @intCast(i));
                try diagnostics.append(allocator, .{
                    .rule = rule_name,
                    .severity = severity,
                    .message = "doc comment is empty",
                    .file = file,
                    .line = loc.line + 1,
                    .column = loc.column + 1,
                });
            }
        }
    }
}

fn isEmptyDocComment(slice: []const u8) bool {
    const prefix: []const u8 = if (std.mem.startsWith(u8, slice, "//!"))
        "//!"
    else if (std.mem.startsWith(u8, slice, "///"))
        "///"
    else
        return false;

    const rest = slice[prefix.len..];
    return std.mem.trim(u8, rest, " \t\r\n").len == 0;
}

test "detects empty /// comment" {
    const source =
        \\///
        \\pub fn foo() void {}
    ;
    var result = try runCheck(source);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(1, result.items.len);
    try std.testing.expectEqualStrings(rule_name, result.items[0].rule);
}

test "detects empty /// with spaces" {
    const source =
        \\///   
        \\pub fn foo() void {}
    ;
    var result = try runCheck(source);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(1, result.items.len);
}

test "no diagnostic for non-empty doc comment" {
    const source =
        \\/// Does something.
        \\pub fn foo() void {}
    ;
    var result = try runCheck(source);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(0, result.items.len);
}

test "detects empty //! comment" {
    const source =
        \\//!
    ;
    var result = try runCheck(source);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(1, result.items.len);
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
