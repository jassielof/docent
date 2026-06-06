const std = @import("std");
const Ast = std.zig.Ast;
const vereda = @import("vereda");

const Diagnostic = @import("../../Diagnostic.zig");
const RuleSet = @import("../../RuleSet.zig");

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

/// When `public_api_only` is true, returns whether the declaration at `documented_first_token` is public API.
pub fn shouldCheckDocCommentTarget(
    tree: *const Ast,
    documented_first_token: Ast.TokenIndex,
    public_api_only: bool,
) bool {
    if (!public_api_only) return true;
    for (tree.rootDecls()) |decl| {
        if (findDocCommentVisibility(tree, documented_first_token, false, decl)) |visible| return visible;
    }
    return false;
}

fn findDocCommentVisibility(
    tree: *const Ast,
    documented_first_token: Ast.TokenIndex,
    inside_public_container: bool,
    node: Ast.Node.Index,
) ?bool {
    if (tree.firstToken(node) == documented_first_token) {
        return visibilityAtNode(tree, node, inside_public_container);
    }

    if (tree.fullVarDecl(node)) |var_decl| {
        const init_node = var_decl.ast.init_node.unwrap() orelse return null;
        if (isContainerDecl(tree.nodeTag(init_node))) {
            const child_inside = isPubVisibility(tree, var_decl.visib_token);
            var buf: [2]Ast.Node.Index = undefined;
            if (tree.fullContainerDecl(&buf, init_node)) |container| {
                for (container.ast.members) |member| {
                    if (findDocCommentVisibility(tree, documented_first_token, child_inside, member)) |visible| {
                        return visible;
                    }
                }
            }
        }
        return null;
    }

    const tag = tree.nodeTag(node);
    if (isContainerDecl(tag)) {
        var buf: [2]Ast.Node.Index = undefined;
        if (tree.fullContainerDecl(&buf, node)) |container| {
            for (container.ast.members) |member| {
                if (findDocCommentVisibility(tree, documented_first_token, inside_public_container, member)) |visible| {
                    return visible;
                }
            }
        }
    }

    return null;
}

fn visibilityAtNode(tree: *const Ast, node: Ast.Node.Index, inside_public_container: bool) bool {
    if (tree.fullContainerField(node) != null) return inside_public_container;

    if (tree.nodeTag(node) == .fn_decl) {
        var buf: [1]Ast.Node.Index = undefined;
        if (tree.fullFnProto(&buf, node)) |proto| return isPubVisibility(tree, proto.visib_token);
        return false;
    }

    if (tree.fullVarDecl(node)) |var_decl| return isPubVisibility(tree, var_decl.visib_token);

    return inside_public_container;
}

/// Resolves the declaration a `///` doc comment block documents, for diagnostic subjects.
pub fn resolveDocCommentSubject(
    tree: *const Ast,
    documented_first_token: Ast.TokenIndex,
    file: []const u8,
    module_name: ?[]const u8,
    msg_allocator: std.mem.Allocator,
) std.mem.Allocator.Error!Diagnostic.Subject {
    for (tree.rootDecls()) |decl| {
        if (try findSubjectInNode(tree, documented_first_token, null, decl, msg_allocator)) |subject| {
            return subject;
        }
    }
    _ = file;
    _ = module_name;
    return try ownedSubject(msg_allocator, .doc_comment, "");
}

fn findSubjectInNode(
    tree: *const Ast,
    documented_first_token: Ast.TokenIndex,
    enum_container: ?Ast.Node.Index,
    node: Ast.Node.Index,
    msg_allocator: std.mem.Allocator,
) std.mem.Allocator.Error!?Diagnostic.Subject {
    if (tree.firstToken(node) == documented_first_token) {
        return try subjectForDeclNode(tree, node, enum_container != null, msg_allocator);
    }

    if (tree.fullVarDecl(node)) |var_decl| {
        const init_node = var_decl.ast.init_node.unwrap() orelse return null;
        if (isContainerDecl(tree.nodeTag(init_node))) {
            const child_enum = if (isEnumContainer(tree, init_node)) init_node else enum_container;
            var buf: [2]Ast.Node.Index = undefined;
            if (tree.fullContainerDecl(&buf, init_node)) |container| {
                for (container.ast.members) |member| {
                    if (try findSubjectInNode(tree, documented_first_token, child_enum, member, msg_allocator)) |subject| {
                        return subject;
                    }
                }
            }
        }
        return null;
    }

    const tag = tree.nodeTag(node);
    if (isContainerDecl(tag)) {
        const child_enum = if (isEnumContainer(tree, node)) node else enum_container;
        var buf: [2]Ast.Node.Index = undefined;
        if (tree.fullContainerDecl(&buf, node)) |container| {
            for (container.ast.members) |member| {
                if (try findSubjectInNode(tree, documented_first_token, child_enum, member, msg_allocator)) |subject| {
                    return subject;
                }
            }
        }
    }

    return null;
}

fn subjectForDeclNode(
    tree: *const Ast,
    node: Ast.Node.Index,
    in_enum_container: bool,
    msg_allocator: std.mem.Allocator,
) std.mem.Allocator.Error!?Diagnostic.Subject {
    if (tree.fullContainerField(node)) |field| {
        const name = tree.tokenSlice(field.ast.main_token);
        const kind: Diagnostic.SubjectKind = if (in_enum_container) .enumerator else .field;
        return try ownedSubject(msg_allocator, kind, name);
    }

    if (tree.nodeTag(node) == .fn_decl) {
        var buf: [1]Ast.Node.Index = undefined;
        if (tree.fullFnProto(&buf, node)) |proto| {
            const name_tok = proto.name_token orelse return null;
            return try ownedSubject(msg_allocator, .function, tree.tokenSlice(name_tok));
        }
        return null;
    }

    if (tree.fullVarDecl(node)) |var_decl| {
        const name_tok = var_decl.ast.mut_token + 1;
        const kind = varDeclSubjectKind(tree, var_decl);
        return try ownedSubject(msg_allocator, kind, tree.tokenSlice(name_tok));
    }

    return null;
}

fn varDeclSubjectKind(tree: *const Ast, var_decl: Ast.full.VarDecl) Diagnostic.SubjectKind {
    if (tree.tokenTag(var_decl.ast.mut_token) != .keyword_const) return .variable;
    const init_node = var_decl.ast.init_node.unwrap() orelse return .constant;
    if (tree.nodeTag(init_node) == .error_set_decl) return .error_set;
    if (isEnumContainer(tree, init_node)) return .enumeration;
    return .constant;
}

/// Text after the `///` or `//!` prefix, trimmed of leading horizontal whitespace.
pub fn docCommentLineBody(slice: []const u8) []const u8 {
    const prefix: []const u8 = if (std.mem.startsWith(u8, slice, "//!"))
        "//!"
    else if (std.mem.startsWith(u8, slice, "///"))
        "///"
    else
        return slice;

    return std.mem.trim(u8, slice[prefix.len..], " \t");
}

/// True when `text` ends with `.`, `!`, or `?` (after trimming trailing whitespace).
pub fn endsWithTerminalPunctuation(text: []const u8) bool {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return true;
    return switch (trimmed[trimmed.len - 1]) {
        '.', '!', '?' => true,
        else => false,
    };
}

/// True when a `///` or `//!` token has no text after the doc-comment prefix.
pub fn isEmptyDocCommentLine(slice: []const u8) bool {
    const prefix: []const u8 = if (std.mem.startsWith(u8, slice, "//!"))
        "//!"
    else if (std.mem.startsWith(u8, slice, "///"))
        "///"
    else
        return false;

    const rest = slice[prefix.len..];
    return std.mem.trim(u8, rest, " \t\r\n").len == 0;
}

/// True when the file has no structure fields at file scope.
pub fn fileIsNamespace(tree: *const Ast) bool {
    for (tree.rootDecls()) |decl| {
        if (tree.fullContainerField(decl) != null) return false;
    }
    return true;
}

/// Subject kind for an exposed implicit struct or namespace source file.
pub fn exposedSourceFileSubjectKind(tree: *const Ast) Diagnostic.SubjectKind {
    return if (fileIsNamespace(tree)) .namespace else .structure;
}

/// True when `start_token` begins a `//!` container doc comment block.
pub fn hasContainerDocComment(tree: *const Ast, start_token: Ast.TokenIndex) bool {
    const tags = tree.tokens.items(.tag);
    if (start_token >= tags.len) return false;
    return tags[start_token] == .container_doc_comment;
}

/// True when the file begins with a `//!` block whose lines are all blank or whitespace-only.
pub fn containerDocBlockIsFullyBlank(tree: *const Ast) bool {
    const tags = tree.tokens.items(.tag);
    if (tags.len == 0 or tags[0] != .container_doc_comment) return false;

    var i: usize = 0;
    while (i < tags.len and tags[i] == .container_doc_comment) : (i += 1) {
        const tok: Ast.TokenIndex = @intCast(i);
        if (!isEmptyDocCommentLine(tree.tokenSlice(tok))) return false;
    }
    return true;
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

/// Returns the canonical rule identifier from the basename of `src.file` (without `.zig`).
///
/// Call from each rule module via a file-local `srcLoc()` that returns `@src()` — `@src()` cannot
/// be used directly at module scope.
pub fn ruleIdFromSrc(comptime src: std.builtin.SourceLocation) []const u8 {
    const base = comptime std.fs.path.basename(src.file);
    if (!std.mem.endsWith(u8, base, ".zig"))
        @compileError("rule module path must end with .zig: " ++ src.file);
    const id = base[0 .. base.len - ".zig".len];
    comptime assertIsRuleSetField(id);
    return id;
}

/// Returns a canonical rule identifier when the file stem differs from the `RuleSet` field name.
pub fn ruleIdWithName(comptime id: []const u8) []const u8 {
    comptime assertIsRuleSetField(id);
    return id;
}

fn assertIsRuleSetField(comptime name: []const u8) void {
    for (RuleSet.fieldNames()) |field| {
        if (std.mem.eql(u8, field, name)) return;
    }
    @compileError("unknown rule id '" ++ name ++ "' (no matching RuleSet field)");
}
