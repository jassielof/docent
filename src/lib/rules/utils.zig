const std = @import("std");
const Ast = std.zig.Ast;

/// Extracts a copy of the source line containing `token`, trimmed of trailing
/// CR/LF. Allocates from `allocator` — caller is responsible for freeing.
pub fn dupSourceLine(
    tree: *const Ast,
    token: Ast.TokenIndex,
    allocator: std.mem.Allocator,
) std.mem.Allocator.Error![]const u8 {
    const loc = tree.tokenLocation(0, token);
    var end = loc.line_start;
    while (end < tree.source.len and tree.source[end] != '\n') end += 1;
    const raw = tree.source[loc.line_start..end];
    const trimmed = std.mem.trimEnd(u8, raw, "\r");
    return allocator.dupe(u8, trimmed);
}
