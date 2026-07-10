//! Walks a `Decl` tree produced by `walker.zig` and emits a `schema.DocsFile`
//! per `schema.zig`.
//!
//! Ports the plain-Zig logic the old WASM `main.zig` computed on demand via
//! JS-exported functions (`decl_fqn`, `decl_category_name`,
//! `decl_fields_fallible`, `decl_params_fallible`, `decl_docs_html`) into
//! functions that build schema types directly, instead of HTML strings:
//!
//! - `id` / `name`: `Decl.fqn()` / `Decl.extra_info().name`.
//! - `kind` / `container_kind`: classify from `Decl.categorize()`
//!   (`Walk.Category`). Aliases (`.alias`) are resolved eagerly by following
//!   to the aliased decl for shape purposes (signature/fields/params/kind),
//!   while `id`/`name`/`doc` stay tied to the original declaration site --
//!   there is no `alias` `DeclKind` in the schema (see the planning
//!   session's schema review).
//! - `fields` / `params`: port of `decl_fields_fallible` / `decl_params_fallible`.
//! - `doc` / `doc_summary`: doc-comment token range parsed once via
//!   `vendor/markdown.zig`, rendered to Typst markup via `markdown_typst.zig`
//!   for `doc`, and to plain text (first paragraph only) via
//!   `vendor/markdown/renderer.zig`'s inline-text renderer for `doc_summary`.
//! - `source`: `std.zig.findLineColumn` against the decl's first token.
//! - `link_targets`: cross-reference ids resolved by `markdown_typst.zig`
//!   while rendering `doc`; see its module doc comment.
//! - Multiple modules: `emitPackage` builds one `DeclNode` per discovered
//!   build target (see `Module`), matching `schema.DocsFile.modules`.
//! - Private decls: `emitChildren` includes non-public members when
//!   `include_private` is set (see `Ctx`), otherwise public-only.

const std = @import("std");
const Ast = std.zig.Ast;
const Writer = std.Io.Writer;

const doc_comment = @import("doc_comment");
const comment = doc_comment.comment;
const markdown = doc_comment.markup;
const typst = @import("typst.zig");
const external_refs = @import("external_refs.zig");
const std_bundle = @import("std_bundle.zig");
const schema = @import("schema.zig");
const walker = @import("walker.zig");

const Walk = walker.Walk;
const Decl = walker.Decl;

/// One module to emit into a package's `docs.json`: a walked root `Decl`
/// paired with the name it should be reported under (`Decl.extra_info()`
/// reports an empty name for a file's root struct, see `vendor/Decl.zig`).
pub const Module = struct {
    root_decl: Decl.Index,
    name: []const u8,
};

/// Builds the full `schema.DocsFile` for a package's discovered modules and
/// bundled `.path` dependencies (see `../../cli/commands/typeset.zig` for
/// how `modules`/`appendix` are assembled via `status_plan.gather` and
/// `path_deps.zig`). Each module gets its own `expanded`-dedup scope -- see
/// `Ctx` -- since walking two modules never shares `Decl.Index` values (each
/// `walkModule` call registers files under its own module-name prefix), so
/// cross-module dedup would be a no-op anyway.
pub fn emitPackage(
    allocator: std.mem.Allocator,
    io: std.Io,
    modules: []const Module,
    appendix: []const Module,
    include_private: bool,
    external_refs_table: ?*const external_refs.Table,
    std_collector: ?*std_bundle.Collector,
    zig_version: []const u8,
    tool_version: []const u8,
    generated_at: []const u8,
) !schema.DocsFile {
    const module_nodes = try emitModuleList(allocator, io, modules, include_private, external_refs_table, std_collector, zig_version);

    var appendix_nodes: std.ArrayList(schema.DeclNode) = .empty;
    errdefer appendix_nodes.deinit(allocator);
    try appendix_nodes.appendSlice(
        allocator,
        try emitModuleList(allocator, io, appendix, include_private, external_refs_table, std_collector, zig_version),
    );

    // Drain `std.*` references discovered while emitting `modules`/`appendix`
    // above (see `std_bundle.zig`). Uses a `std_bundle`-less `Ctx` for each
    // one's own emission, so a std file's own doc comments can't trigger a
    // second hop -- see std_bundle.zig's module doc comment for why that's
    // the one rule that keeps this bounded.
    if (std_collector) |collector| {
        for (collector.pending.items) |p| {
            var ctx: Ctx = .{
                .expanded = .init(allocator),
                .include_private = false,
                .zig_version = zig_version,
                .refs = null,
                .std_bundle = null,
                .io = io,
            };
            defer ctx.expanded.deinit();

            var node = try emitDecl(allocator, p.root_decl, &ctx);
            if (node.name.len == 0) node.name = try allocator.dupe(u8, p.name);
            try appendix_nodes.append(allocator, node);
        }
    }

    return .{
        .schema_version = 2,
        .generator = .{
            .zig_version = zig_version,
            .tool_version = tool_version,
            .generated_at = generated_at,
        },
        .modules = module_nodes,
        .appendix = try appendix_nodes.toOwnedSlice(allocator),
    };
}

fn emitModuleList(
    allocator: std.mem.Allocator,
    io: std.Io,
    modules: []const Module,
    include_private: bool,
    external_refs_table: ?*const external_refs.Table,
    std_collector: ?*std_bundle.Collector,
    zig_version: []const u8,
) ![]const schema.DeclNode {
    var nodes: std.ArrayList(schema.DeclNode) = .empty;
    errdefer nodes.deinit(allocator);

    for (modules) |m| {
        var ctx: Ctx = .{
            .expanded = .init(allocator),
            .include_private = include_private,
            .zig_version = zig_version,
            .refs = external_refs_table,
            .std_bundle = std_collector,
            .io = io,
        };
        defer ctx.expanded.deinit();

        var node = try emitDecl(allocator, m.root_decl, &ctx);
        if (node.name.len == 0) node.name = try allocator.dupe(u8, m.name);
        try nodes.append(allocator, node);
    }

    return try nodes.toOwnedSlice(allocator);
}

/// Serializes `docs_file` as pretty-printed JSON to `output_path`, creating
/// parent directories as needed.
pub fn writeToFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    docs_file: schema.DocsFile,
    output_path: []const u8,
) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    var allocating = Writer.Allocating.fromArrayList(allocator, &buf);
    try std.json.Stringify.value(docs_file, .{ .whitespace = .indent_2 }, &allocating.writer);
    buf = allocating.toArrayList();

    if (std.fs.path.dirname(output_path)) |dir| {
        try std.Io.Dir.cwd().createDirPath(io, dir);
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = output_path, .data = buf.items });
}

const Classification = struct {
    kind: schema.DeclKind,
    container_kind: ?schema.ContainerKind,
    /// The decl to read shape (signature/fields/params) from -- the same as
    /// the input decl unless it was an alias.
    resolved: Decl.Index,
};

/// Classifies `decl_index`, following `.alias` categories to the real decl.
/// Bounded to guard against pathological alias cycles in malformed input.
fn classify(decl_index: Decl.Index) Classification {
    var current = decl_index;
    var hops: u8 = 0;
    while (hops < 16) : (hops += 1) {
        const decl = current.get();
        switch (decl.categorize()) {
            .alias => |aliasee| {
                current = aliasee;
                continue;
            },
            .namespace, .container => |node| return .{
                .kind = .container,
                .container_kind = containerKindOfNode(decl.file.get_ast(), node),
                .resolved = current,
            },
            .global_variable => return .{ .kind = .@"var", .container_kind = null, .resolved = current },
            .function, .type_function => return .{ .kind = .@"fn", .container_kind = null, .resolved = current },
            .error_set => return .{ .kind = .error_set, .container_kind = null, .resolved = current },
            .global_const, .primitive => return .{ .kind = .@"const", .container_kind = null, .resolved = current },
            .type, .type_type => return .{ .kind = .type_alias, .container_kind = null, .resolved = current },
        }
    }
    return .{ .kind = .@"const", .container_kind = null, .resolved = current };
}

fn containerKindOfNode(ast: *const Ast, node: Ast.Node.Index) ?schema.ContainerKind {
    if (ast.nodeTag(node) == .root) return .module;
    var buf: [2]Ast.Node.Index = undefined;
    const full = ast.fullContainerDecl(&buf, node) orelse return null;
    return switch (ast.tokenTag(full.ast.main_token)) {
        .keyword_struct => .@"struct",
        .keyword_enum => .@"enum",
        .keyword_union => .@"union",
        .keyword_opaque => .@"opaque",
        else => null,
    };
}

/// Per-`emitPackage`-call scratch state threaded through `emitDecl`/`emitChildren`.
const Ctx = struct {
    /// Guards against re-expanding the same target's `decls` twice when
    /// multiple re-export sites alias it (see the `.container` case below).
    expanded: std.AutoHashMap(Decl.Index, void),
    /// When true, `emitChildren` also emits non-public members.
    include_private: bool,
    /// Drives the fallback `std.*` link URL when `std_bundle` is null; see
    /// `markdown_typst.zig`.
    zig_version: []const u8,
    /// Loaded `--external-refs` sidecars, consulted by `markdown_typst.zig`
    /// for dependency cross-references. Null when none were given.
    refs: ?*const external_refs.Table,
    /// `--bundle-std`'s collector, consulted by `markdown_typst.zig` to
    /// resolve `std.*` locally instead of linking to ziglang.org. Left
    /// `null` on the `Ctx` used to emit a std-bundled entry's own subtree
    /// (see `emitPackage`'s draining loop) -- that's the structural
    /// enforcement of `std_bundle.zig`'s "only one hop" rule.
    std_bundle: ?*std_bundle.Collector,
    io: std.Io,
};

fn emitDecl(allocator: std.mem.Allocator, decl_index: Decl.Index, ctx: *Ctx) anyerror!schema.DeclNode {
    const original = decl_index.get();
    const info = original.extra_info();

    var id_buf: std.ArrayList(u8) = .empty;
    defer id_buf.deinit(std.heap.page_allocator);
    try original.fqn(&id_buf);
    const id = try allocator.dupe(u8, id_buf.items);
    const name = try allocator.dupe(u8, info.name);

    const cls = classify(decl_index);
    const target = cls.resolved.get();
    const target_ast = target.file.get_ast();

    var signature: ?[]const u8 = null;
    var return_type: ?[]const u8 = null;
    var params: ?[]const schema.ParamNode = null;
    var fields: ?[]const schema.FieldNode = null;
    var decls: ?[]const schema.DeclNode = null;

    switch (cls.kind) {
        .@"fn" => {
            const proto_node = fnProtoNode(target_ast, target.ast_node);
            signature = try allocator.dupe(u8, stripLeadingModifiers(nodeSource(target_ast, proto_node)));

            var buf: [1]Ast.Node.Index = undefined;
            if (target_ast.fullFnProto(&buf, proto_node)) |full| {
                if (full.ast.return_type.unwrap()) |rt|
                    return_type = try allocator.dupe(u8, returnTypeSource(target_ast, rt));
                params = try emitParams(allocator, target_ast, full);
            }
        },
        .@"const", .@"var", .type_alias => {
            signature = try allocator.dupe(u8, stripLeadingModifiers(nodeSource(target_ast, target.ast_node)));
        },
        .error_set => {
            const node = switch (target.categorize()) {
                .error_set => |n| n,
                else => target.ast_node,
            };
            fields = try emitErrorSetFields(allocator, target_ast, node);
        },
        .container => {
            const node = switch (target.categorize()) {
                .namespace, .container => |n| n,
                else => target.ast_node,
            };
            fields = try emitContainerFields(allocator, target_ast, node, cls.container_kind);

            // Only structs and the module root act as namespaces that can
            // hold further sub-decls; enums/unions/opaques are value-shaped
            // -- their members are already fully captured as `fields`
            // (tags/variants), and any `pub fn` attached directly to one is
            // an edge case not surfaced as a flattened id in v1 (rather than
            // silently pretending they're organizational containers).
            const is_namespace_kind = cls.container_kind == .@"struct" or cls.container_kind == .module;

            // Multiple `pub const X = @import("Y.zig")` re-exports of the
            // *same* underlying file (e.g. `docent.typeset` re-exporting
            // `walker`/`json_emit`/`markdown_typst`, all of which alias the
            // same vendored `Decl`/`Walk` types) would otherwise recurse
            // into and emit the same target's children more than once --
            // producing duplicate ids, which is a hard Typst compile error
            // once `decl.typ` attaches a `#label(decl.id)` to each one.
            // Expand a given target's subtree only the first time it's
            // reached; later re-export sites still get their own (unique)
            // DeclNode, just without a duplicated `decls` listing.
            if (is_namespace_kind) {
                const gop = try ctx.expanded.getOrPut(cls.resolved);
                if (!gop.found_existing) {
                    decls = try emitChildren(allocator, cls.resolved, ctx);
                }
            }
        },
        .field => unreachable, // `classify` never produces `.field`; struct/enum/union members surface as `FieldNode`, not `DeclNode`.
    }

    const doc_pair = try renderDocComment(allocator, original.file.get_ast(), info.first_doc_comment, decl_index, ctx);

    return .{
        .id = id,
        .name = name,
        .kind = cls.kind,
        .container_kind = cls.container_kind,
        .visibility = if (info.is_pub) .public else .private,
        .source = sourceLocOf(original),
        .signature = signature,
        .return_type = return_type,
        .params = params,
        .fields = fields,
        .doc = doc_pair.doc,
        .doc_summary = doc_pair.summary,
        .link_targets = doc_pair.link_targets,
        .decls = decls,
    };
}

/// Emits every direct member of the container at `container_index`,
/// restricted to public members unless `ctx.include_private` is set.
fn emitChildren(
    allocator: std.mem.Allocator,
    container_index: Decl.Index,
    ctx: *Ctx,
) ![]const schema.DeclNode {
    var list: std.ArrayList(schema.DeclNode) = .empty;
    errdefer list.deinit(allocator);

    for (Walk.decls.items, 0..) |*d, i| {
        if (d.parent != container_index) continue;
        if (!d.is_pub() and !ctx.include_private) continue;
        const child_index: Decl.Index = @enumFromInt(i);
        try list.append(allocator, try emitDecl(allocator, child_index, ctx));
    }

    return try list.toOwnedSlice(allocator);
}

fn fnProtoNode(ast: *const Ast, node: Ast.Node.Index) Ast.Node.Index {
    return switch (ast.nodeTag(node)) {
        .fn_decl => ast.nodeData(node).node_and_node[0],
        else => node,
    };
}

/// Raw source text spanning `node`, from its first token through the end of
/// its last token.
fn nodeSource(ast: *const Ast, node: Ast.Node.Index) []const u8 {
    const first = ast.firstToken(node);
    const last = ast.lastToken(node);
    const start = ast.tokenStart(first);
    const end = ast.tokenStart(last) + ast.tokenSlice(last).len;
    return ast.source[start..end];
}

/// Like `nodeSource`, but for a fn's return type node: includes a preceding
/// `!` token (inferred error union sigil), which is not part of the return
/// type node's own span.
fn returnTypeSource(ast: *const Ast, node: Ast.Node.Index) []const u8 {
    const first = ast.firstToken(node);
    const start = if (first > 0 and ast.tokenTag(first - 1) == .bang)
        ast.tokenStart(first - 1)
    else
        ast.tokenStart(first);
    const last = ast.lastToken(node);
    const end = ast.tokenStart(last) + ast.tokenSlice(last).len;
    return ast.source[start..end];
}

/// Strips a leading `pub ` from a decl's raw source span -- visibility is
/// already carried by `DeclNode.visibility`, so the signature text doesn't
/// need to repeat it (matches the Appendix A example, which omits `pub`).
fn stripLeadingModifiers(source: []const u8) []const u8 {
    if (std.mem.startsWith(u8, source, "pub ")) return source["pub ".len..];
    return source;
}

fn emitParams(allocator: std.mem.Allocator, ast: *const Ast, full: Ast.full.FnProto) ![]const schema.ParamNode {
    var list: std.ArrayList(schema.ParamNode) = .empty;
    errdefer list.deinit(allocator);

    for (full.ast.params) |param_node| {
        try list.append(allocator, .{
            .name = try allocator.dupe(u8, paramName(ast, param_node)),
            .type = try allocator.dupe(u8, nodeSource(ast, param_node)),
            .doc = null,
        });
    }

    return try list.toOwnedSlice(allocator);
}

/// Port of the old WASM `main.zig`'s `decl_param_html_fallible` name lookup:
/// a param node only covers its type expression, so the name is found by
/// walking backward past the `:` that precedes it.
fn paramName(ast: *const Ast, param_node: Ast.Node.Index) []const u8 {
    const first = ast.firstToken(param_node);
    if (first == 0) return "";
    const colon = first - 1;
    if (ast.tokenTag(colon) != .colon) return "";
    if (colon == 0) return "";
    const name_token = colon - 1;
    if (ast.tokenTag(name_token) != .identifier) return "";
    return ast.tokenSlice(name_token);
}

/// `is_enum` matters because Zig's AST reuses a `container_field`'s
/// `type_expr` slot to hold a copy of the tag name identifier for a bare
/// enum member (e.g. `reachability,` parses with `type_expr` pointing at an
/// `identifier` node whose text is literally "reachability") -- confirmed
/// empirically, not documented behavior. Enum members have no real per-tag
/// type, so `type_expr` is ignored entirely for them; `value_expr` still
/// holds an explicit backing value (`reachability = 3,`) when present.
fn emitContainerFields(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    node: Ast.Node.Index,
    container_kind: ?schema.ContainerKind,
) ![]const schema.FieldNode {
    var list: std.ArrayList(schema.FieldNode) = .empty;
    errdefer list.deinit(allocator);

    const is_enum = container_kind == .@"enum";

    var buf: [2]Ast.Node.Index = undefined;
    const container_decl = ast.fullContainerDecl(&buf, node) orelse return try list.toOwnedSlice(allocator);

    for (container_decl.ast.members) |member| {
        const field = ast.fullContainerField(member) orelse continue;
        try list.append(allocator, .{
            .name = try allocator.dupe(u8, ast.tokenSlice(field.ast.main_token)),
            .type = if (!is_enum) if (field.ast.type_expr.unwrap()) |t| try allocator.dupe(u8, nodeSource(ast, t)) else null else null,
            .value = if (field.ast.value_expr.unwrap()) |v| try allocator.dupe(u8, nodeSource(ast, v)) else null,
            .doc = null,
        });
    }

    return try list.toOwnedSlice(allocator);
}

/// Port of the old WASM `main.zig`'s `addErrorsFromNode`, minus the HTML
/// output and the "prefer the member with docs" merge logic (no
/// `merge_error_sets` support yet -- see the module doc comment).
fn emitErrorSetFields(allocator: std.mem.Allocator, ast: *const Ast, node: Ast.Node.Index) ![]const schema.FieldNode {
    var list: std.ArrayList(schema.FieldNode) = .empty;
    errdefer list.deinit(allocator);

    if (ast.nodeTag(node) != .error_set_decl) return try list.toOwnedSlice(allocator);

    const error_token = ast.nodeMainToken(node);
    var tok = error_token + 2; // skip `error` and `{`
    while (true) : (tok += 1) switch (ast.tokenTag(tok)) {
        .doc_comment, .comma => {},
        .identifier => try list.append(allocator, .{
            .name = try allocator.dupe(u8, ast.tokenSlice(tok)),
            .type = null,
            .value = null,
            .doc = null,
        }),
        .r_brace => break,
        else => break, // Malformed/unsupported shape (e.g. merge_error_sets); stop rather than looping.
    };

    return try list.toOwnedSlice(allocator);
}

fn sourceLocOf(decl: *const Decl) schema.SourceLoc {
    const ast = decl.file.get_ast();
    const offset = ast.tokenStart(ast.firstToken(decl.ast_node));
    const loc = std.zig.findLineColumn(ast.source, offset);
    return .{
        // `decl.file.path()` is the `<module_name>/...`-namespaced key
        // `walker.zig` registers files under (see its module doc comment for
        // why); `realPathForKey` maps it back to the real filesystem path.
        .file = walker.realPathForKey(decl.file.path()),
        .line = @intCast(loc.line + 1),
        .col = @intCast(loc.column + 1),
    };
}

const DocPair = struct {
    doc: ?[]const u8,
    summary: ?[]const u8,
    link_targets: ?[]const []const u8,
};

fn renderDocComment(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    first_doc_comment: Ast.OptionalTokenIndex,
    origin: Decl.Index,
    ctx: *Ctx,
) !DocPair {
    const first = first_doc_comment.unwrap() orelse return .{ .doc = null, .summary = null, .link_targets = null };
    // `Decl.findFirstDocComment` (vendor/Decl.zig) returns the boundary
    // token it stopped scanning backward at *unconditionally* -- when there
    // is no preceding doc comment at all, that boundary token is the decl's
    // own first token (e.g. `pub`), not a doc-comment token. Callers must
    // check the tag themselves; the vendored WASM `main.zig`'s `render_docs`
    // did this implicitly via its loop's `else => break` on the first
    // iteration. An undocumented decl is the common case for re-export
    // lines like `pub const scan = @import("scan.zig");`.
    const doc_kind = ast.tokenTag(first);
    if (doc_kind != .doc_comment and doc_kind != .container_doc_comment)
        return .{ .doc = null, .summary = null, .link_targets = null };

    var parser = try markdown.Parser.init(allocator);
    defer parser.deinit();

    var it = first;
    while (ast.tokenTag(it) == doc_kind) : (it += 1) {
        try parser.feedLine(comment.lineBody(ast.tokenSlice(it)));
    }

    var doc = try parser.endInput();
    defer doc.deinit(allocator);

    const render_result = try typst.renderToTypst(allocator, ctx.io, doc, origin, ctx.zig_version, ctx.refs, ctx.std_bundle);
    defer allocator.free(render_result.markup);
    const rendered = try allocator.dupe(u8, std.mem.trimEnd(u8, render_result.markup, " \t\r\n"));
    const summary = try firstParagraphPlainText(allocator, doc);

    return .{
        .doc = rendered,
        .summary = summary,
        .link_targets = if (render_result.link_targets.len > 0) render_result.link_targets else null,
    };
}

/// Plain-text rendering of `doc`'s first paragraph (or `null` if the doc
/// doesn't start with one), per the schema's "markup stripped" requirement
/// for `doc_summary`.
fn firstParagraphPlainText(allocator: std.mem.Allocator, doc: markdown.Document) !?[]const u8 {
    const root_data = doc.nodes.items(.data)[@intFromEnum(markdown.Document.Node.Index.root)];
    const children = doc.extraChildren(root_data.container.children);
    if (children.len == 0) return null;

    const first = children[0];
    if (doc.nodes.items(.tag)[@intFromEnum(first)] != .paragraph) return null;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var allocating = Writer.Allocating.fromArrayList(allocator, &out);

    const para_data = doc.nodes.items(.data)[@intFromEnum(first)];
    for (doc.extraChildren(para_data.container.children)) |child| {
        markdown.renderInlineNodeText(doc, child, &allocating.writer) catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory,
        };
    }
    out = allocating.toArrayList();

    const text = try out.toOwnedSlice(allocator);
    if (text.len == 0) {
        allocator.free(text);
        return null;
    }
    return text;
}
