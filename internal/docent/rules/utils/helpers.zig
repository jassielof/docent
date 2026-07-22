const std = @import("std");
const Ast = std.zig.Ast;
const doc_comment = @import("doc_comment");

const Diagnostic = @import("../../Diagnostic.zig");
const RuleSeverities = @import("../../RuleSeverities.zig");

/// Extracts a copy of the source line containing `token`, trimmed of trailing
/// CR/LF. Allocates from `allocator` — caller is responsible for freeing.
/// Copies `name` into `allocator` for use in `Diagnostic.subject`.
pub fn ownedSubject(
    allocator: std.mem.Allocator,
    kind: Diagnostic.SubjectKind,
    name: []const u8,
) !Diagnostic.Subject {
    return .{ .kind = kind, .name = try allocator.dupe(u8, name) };
}

/// Maps a `doc_comment.Subject` onto a lint `Diagnostic.Subject` (same name pointer).
pub fn diagnosticSubjectFromDoc(subject: doc_comment.Subject) Diagnostic.Subject {
    return .{
        .kind = switch (subject.kind) {
            .function => .function,
            .constant => .constant,
            .variable => .variable,
            .error_set => .error_set,
            .enumeration => .enumeration,
            .field => .field,
            .enumerator => .enumerator,
            .doc_comment => .doc_comment,
            .structure => .structure,
            .namespace => .namespace,
        },
        .name = subject.name,
    };
}

/// Maps `doc_comment.SubjectKind` for exposed source files onto diagnostic kinds.
pub fn diagnosticSubjectKindFromDoc(kind: doc_comment.SubjectKind) Diagnostic.SubjectKind {
    return switch (kind) {
        .function => .function,
        .constant => .constant,
        .variable => .variable,
        .error_set => .error_set,
        .enumeration => .enumeration,
        .field => .field,
        .enumerator => .enumerator,
        .doc_comment => .doc_comment,
        .structure => .structure,
        .namespace => .namespace,
    };
}

/// Display name for module-level diagnostics (`root.zig`, package name, or file stem).
pub fn moduleDisplayName(file: []const u8, module_name: ?[]const u8) []const u8 {
    if (module_name) |name| return name;

    const base = std.fs.path.basename(file);
    if (std.mem.eql(
        u8,
        base,
        "root.zig",
    )) {
        if (std.fs.path.dirname(file)) |dir| {
            const parent = std.fs.path.basename(dir);
            if (parent.len > 0 and !std.mem.eql(
                u8,
                parent,
                ".",
            ) and !std.mem.eql(
                u8,
                parent,
                "..",
            )) {
                return parent;
            }
        }
    }

    if (std.mem.endsWith(
        u8,
        base,
        ".zig",
    )) return base[0 .. base.len - ".zig".len];
    return base;
}

pub fn isContainerDecl(tag: Ast.Node.Tag) bool {
    return switch (tag) {
        .container_decl,
        .container_decl_trailing,
        .container_decl_two,
        .container_decl_two_trailing,
        .container_decl_arg,
        .container_decl_arg_trailing,
        .tagged_union,
        .tagged_union_trailing,
        .tagged_union_two,
        .tagged_union_two_trailing,
        .tagged_union_enum_tag,
        .tagged_union_enum_tag_trailing,
        => true,
        else => false,
    };
}

pub fn isEnumContainer(tree: *const Ast, container_node: Ast.Node.Index) bool {
    var buf: [2]Ast.Node.Index = undefined;
    const container = tree.fullContainerDecl(&buf, container_node) orelse return false;
    return tree.tokenTag(container.ast.main_token) == .keyword_enum;
}

pub fn isPubVisibility(tree: *const Ast, visib_token: ?Ast.TokenIndex) bool {
    const vt = visib_token orelse return false;
    return tree.tokenTag(vt) == .keyword_pub;
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
    const trimmed = std.mem.trimEnd(
        u8,
        raw,
        "\r",
    );

    return allocator.dupe(u8, trimmed);
}

/// Returns the canonical rule identifier from the basename of `src.file` (without `.zig`).
///
/// Call from each rule module via a file-local `srcLoc()` that returns `@src()` — `@src()` cannot be used directly at module scope.
pub fn ruleIdFromSrc(comptime src: std.builtin.SourceLocation) []const u8 {
    const base = comptime std.fs.path.basename(src.file);
    if (!std.mem.endsWith(
        u8,
        base,
        ".zig",
    ))
        @compileError("rule module path must end with .zig: " ++ src.file);
    const id = base[0 .. base.len - ".zig".len];
    comptime assertIsRuleSeverityField(id);
    return id;
}

/// Returns a canonical rule identifier when the file stem differs from the `RuleSeverities` field name.
pub fn ruleIdWithName(comptime id: []const u8) []const u8 {
    comptime assertIsRuleSeverityField(id);
    return id;
}

fn assertIsRuleSeverityField(comptime name: []const u8) void {
    for (RuleSeverities.fieldNames()) |field| {
        if (std.mem.eql(
            u8,
            field,
            name,
        )) return;
    }

    @compileError("Unknown rule ID '" ++ name ++ "' (no matching RuleSeverities field)");
}
