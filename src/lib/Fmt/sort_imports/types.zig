const std = @import("std");
const Ast = std.zig.Ast;

pub const Visibility = enum { internal, public };

pub const SourceKind = enum {
    // TODO: `builtin` will be renamed to `lang` in a future Zig version.
    // Track the upstream rename and update the classifier accordingly.
    builtin_mod,
    stdlib,
    dependency,
    root_mod,
    file,
    conditional,
};

pub const ImportShape = enum {
    direct,
    inline_field,
    alias,
    reexport,
    conditional,
};

pub const ImportEntry = struct {
    node: Ast.Node.Index,
    visibility: Visibility,
    kind: SourceKind,
    shape: ImportShape,
    left: []const u8,
    right: []const u8,
    module: []const u8,
    parent: ?usize,
    comment_lines: []const []const u8,
    source_text: []const u8,
};
