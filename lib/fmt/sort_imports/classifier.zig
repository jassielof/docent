const std = @import("std");
const mem = std.mem;

const types = @import("types.zig");
const SourceKind = types.SourceKind;

// TODO: `builtin` will be deprecated and renamed to `lang` in a future Zig 0.17.0. See https://github.com/ziglang/zig/issues/19690.
pub fn classifyKind(path: []const u8) SourceKind {
    if (mem.eql(
        u8,
        path,
        "builtin",
    )) return .builtin_mod;
    if (mem.eql(
        u8,
        path,
        "std",
    )) return .stdlib;
    if (mem.eql(
        u8,
        path,
        "root",
    )) return .root_mod;
    if (mem.indexOfScalar(
        u8,
        path,
        '/',
    ) != null) return .file;
    if (path.len > 0 and path[0] == '.') return .file;
    if (mem.endsWith(
        u8,
        path,
        ".zig",
    )) return .file;

    return .dependency;
}
