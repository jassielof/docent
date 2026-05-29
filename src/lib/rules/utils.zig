const std = @import("std");
const Ast = std.zig.Ast;
const vereda = @import("vereda");

const Diagnostic = @import("../Diagnostic.zig");

/// Normalizes `\` to `/` so diagnostic paths match Zig source import style on every platform.
pub fn normalizePathSeparators(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    return vereda.path.toPosixSeparators(allocator, path);
}

/// Extracts a copy of the source line containing `token`, trimmed of trailing
/// CR/LF. Allocates from `allocator` — caller is responsible for freeing.
/// Copies `name` into `allocator` for use in `Diagnostic.subject`.
pub fn ownedSubject(allocator: std.mem.Allocator, kind: Diagnostic.SubjectKind, name: []const u8) !Diagnostic.Subject {
    return .{ .kind = kind, .name = try allocator.dupe(u8, name) };
}

/// Display name for module-level diagnostics (`root.zig`, package name, or file stem).
pub fn moduleDisplayName(file: []const u8, module_name: ?[]const u8) []const u8 {
    if (module_name) |name| return name;

    const base = std.fs.path.basename(file);
    if (std.mem.eql(u8, base, "root.zig")) {
        if (std.fs.path.dirname(file)) |dir| {
            const parent = std.fs.path.basename(dir);
            if (parent.len > 0 and !std.mem.eql(u8, parent, ".") and !std.mem.eql(u8, parent, "..")) {
                return parent;
            }
        }
    }

    if (std.mem.endsWith(u8, base, ".zig")) return base[0 .. base.len - ".zig".len];
    return base;
}

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
