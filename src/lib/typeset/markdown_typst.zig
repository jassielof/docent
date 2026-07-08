//! Renders a parsed `markdown.Document` (from a Zig doc comment) to Typst
//! markup, instead of the HTML that `html_render.zig` produced upstream.
//!
//! Mechanical 1:1 mapping, mirroring `vendor/markdown/renderer.zig`'s
//! `Renderer.renderDefault` node-tag switch:
//!
//!   HTML                      Typst
//!   ------------------------  ------------------------------
//!   <strong>...</strong>      *...*
//!   <em>...</em>              _..._
//!   <code>...</code>          `...`
//!   <a href="U">T</a>         #link("U")[T]
//!   <h1..6>...</h1..6>        =, ==, ... heading markers
//!   <ul>/<ol><li>...          - item / + item
//!   <pre><code>...            ``` ... ```
//!   <blockquote>...           #quote(block: true)[...]
//!   <hr />                    #line(length: 100%)
//!
//! Tables are flattened to " | "-joined plain text -- real Typst
//! `#table(...)` rendering of doc-comment tables (as opposed to the
//! field/param tables `decl.typ` builds directly from schema data) is a
//! nice-to-have, not required by any locked milestone.
//!
//! Cross-reference resolution (v0.3): a `code_span` whose content resolves
//! is rendered as a link instead of plain `` `text` ``, and the resolved id
//! (or, for external hits, the raw dotted path) is recorded into
//! `link_targets`. Three resolution tiers, tried in order:
//!
//! 1. Same-module: resolves, relative to `origin`, to another *public* decl
//!    in the same walked module (`resolveDeclPath`, ported from the old
//!    WASM `main.zig`'s `resolve_decl_path`) -> `#link(label("<fqn>"))[...]`,
//!    an internal same-document jump. Only public targets are linked
//!    because only public decls get a rendered heading (and thus a label)
//!    in `typst/docent-docs/decl.typ`; linking to a private target would
//!    produce an unresolved-label compile error in Typst.
//! 2. `std.*` paths, when `--bundle-std` gave a `std_bundle.Collector`:
//!    resolved and walked locally (see `std_bundle.zig`'s module doc
//!    comment for the file-resolution heuristic and its explosion-bounding
//!    rule) -> `#link(label("<fqn>"))[...]`, an internal jump into the
//!    appendix, same as tier 1. Without `--bundle-std`, falls through to:
//! 3. `std.*` paths -> an external link straight to
//!    `https://ziglang.org/documentation/{version}/std/#<path>`, no lookup
//!    needed. See `external_refs.zig`'s module doc comment for why this
//!    isn't a local walk of the stdlib by default.
//! 4. `external_refs` table: an exact-match id from a dependency's own
//!    published sidecar (`--external-refs`, see `external_refs.zig`) -> an
//!    external link to that dependency's whole doc URL (not a specific
//!    anchor within it -- see `external_refs.zig` for why).
//!
//! All scoped to `doc` text only -- resolving identifiers embedded in
//! `signature` text would need `Walk.File.ident_decls` token-range lookups,
//! deferred as unneeded scope creep for now.

const std = @import("std");
const Writer = std.Io.Writer;

const markdown = @import("vendor/markdown.zig");
const Document = markdown.Document;
const walker = @import("walker.zig");
const Decl = walker.Decl;
const external_refs = @import("external_refs.zig");
const std_bundle = @import("std_bundle.zig");

const RenderError = Writer.Error || std.mem.Allocator.Error;

pub const Result = struct {
    markup: []const u8,
    /// Fully-qualified ids (or, for std/external hits, the raw dotted path)
    /// of decls linked to from `markup`, in first-seen order.
    link_targets: []const []const u8,
};

/// Renders `doc` to Typst markup, resolving code-span cross-references
/// relative to `origin` (the decl whose doc comment `doc` came from).
/// `zig_version` drives the fallback `std.*` link URL; `refs` (optional)
/// resolves dependency ids published via `--external-refs`; `std_collector`
/// (optional, only set for `--bundle-std` and only on the `Ctx` used for
/// primary/deps content -- see `std_bundle.zig`'s bounding rule) resolves
/// `std.*` paths to a local bundle instead of that fallback URL.
pub fn renderToTypst(
    allocator: std.mem.Allocator,
    io: std.Io,
    doc: Document,
    origin: Decl.Index,
    zig_version: []const u8,
    refs: ?*const external_refs.Table,
    std_collector: ?*std_bundle.Collector,
) !Result {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var link_targets: std.ArrayList([]const u8) = .empty;
    errdefer link_targets.deinit(allocator);

    var allocating = Writer.Allocating.fromArrayList(allocator, &out);
    var renderer: Renderer = .{
        .allocator = allocator,
        .io = io,
        .origin = origin,
        .link_targets = &link_targets,
        .zig_version = zig_version,
        .refs = refs,
        .std_collector = std_collector,
    };
    try renderer.renderNode(doc, .root, &allocating.writer);
    out = allocating.toArrayList();

    return .{
        .markup = try out.toOwnedSlice(allocator),
        .link_targets = try link_targets.toOwnedSlice(allocator),
    };
}

const Renderer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    origin: Decl.Index,
    link_targets: *std.ArrayList([]const u8),
    zig_version: []const u8,
    refs: ?*const external_refs.Table,
    std_collector: ?*std_bundle.Collector,

    fn renderNode(self: *Renderer, doc: Document, node: Document.Node.Index, writer: *Writer) RenderError!void {
        const data = doc.nodes.items(.data)[@intFromEnum(node)];
        switch (doc.nodes.items(.tag)[@intFromEnum(node)]) {
            .root => for (doc.extraChildren(data.container.children)) |child|
                try self.renderNode(doc, child, writer),

            .list => {
                const ordered = data.list.start.asNumber() != null;
                for (doc.extraChildren(data.list.children)) |item| {
                    try writer.writeAll(if (ordered) "+ " else "- ");
                    try self.renderListItemBody(doc, item, writer);
                    try writer.writeAll("\n");
                }
                try writer.writeAll("\n");
            },
            .list_item => unreachable, // Handled inline by `.list`, via `renderListItemBody`.

            .table => {
                for (doc.extraChildren(data.container.children)) |row| try self.renderNode(doc, row, writer);
                try writer.writeAll("\n");
            },
            .table_row => {
                var first = true;
                for (doc.extraChildren(data.container.children)) |cell| {
                    if (!first) try writer.writeAll(" | ");
                    first = false;
                    try self.renderNode(doc, cell, writer);
                }
                try writer.writeAll("\n");
            },
            .table_cell => for (doc.extraChildren(data.table_cell.children)) |child|
                try self.renderNode(doc, child, writer),

            .heading => {
                var level: u3 = 0;
                while (level < data.heading.level) : (level += 1) try writer.writeByte('=');
                try writer.writeByte(' ');
                for (doc.extraChildren(data.heading.children)) |child| try self.renderNode(doc, child, writer);
                try writer.writeAll("\n\n");
            },
            .code_block => {
                const tag = doc.string(data.code_block.tag);
                const content = doc.string(data.code_block.content);
                try writer.writeAll("```");
                try writer.writeAll(tag);
                try writer.writeByte('\n');
                try writer.writeAll(content);
                try writer.writeAll("```\n\n");
            },
            .blockquote => {
                try writer.writeAll("#quote(block: true)[\n");
                for (doc.extraChildren(data.container.children)) |child| try self.renderNode(doc, child, writer);
                try writer.writeAll("]\n\n");
            },
            .paragraph => {
                for (doc.extraChildren(data.container.children)) |child| try self.renderNode(doc, child, writer);
                try writer.writeAll("\n\n");
            },
            .thematic_break => try writer.writeAll("#line(length: 100%)\n\n"),

            .link => {
                try writer.writeAll("#link(\"");
                try writeEscapedString(doc.string(data.link.target), writer);
                try writer.writeAll("\")[");
                for (doc.extraChildren(data.link.children)) |child| try self.renderNode(doc, child, writer);
                try writer.writeAll("]");
            },
            .autolink => {
                const target = doc.string(data.text.content);
                try writer.writeAll("#link(\"");
                try writeEscapedString(target, writer);
                try writer.writeAll("\")");
            },
            .image => {
                try writer.writeAll("#image(\"");
                try writeEscapedString(doc.string(data.link.target), writer);
                try writer.writeAll("\")");
            },
            .strong => {
                try writer.writeByte('*');
                for (doc.extraChildren(data.container.children)) |child| try self.renderNode(doc, child, writer);
                try writer.writeByte('*');
            },
            .emphasis => {
                try writer.writeByte('_');
                for (doc.extraChildren(data.container.children)) |child| try self.renderNode(doc, child, writer);
                try writer.writeByte('_');
            },
            .code_span => try self.renderCodeSpan(doc.string(data.text.content), writer),
            .text => try writeEscapedTypstText(doc.string(data.text.content), writer),
            .line_break => try writer.writeAll(" \\\n"),
        }
    }

    /// Renders a code span, linking it if its content resolves via one of
    /// the three tiers described in the module doc comment.
    fn renderCodeSpan(self: *Renderer, content: []const u8, writer: *Writer) RenderError!void {
        if (resolveDeclPath(self.origin, content)) |target| {
            if (target.get().is_pub()) {
                try self.writeInternalLink(target, content, writer);
                return;
            }
        }

        if (looksLikeDottedPath(content)) {
            if (isStdPath(content)) {
                if (self.std_collector) |collector| {
                    if (collector.resolve(self.allocator, self.io, content) catch null) |target| {
                        try self.writeInternalLink(target, content, writer);
                        return;
                    }
                    // Unresolvable even with local bundling on: per the
                    // design discussion, this falls back to plain text, not
                    // the ziglang.org URL -- `--bundle-std` means "no
                    // external links for std", not "external links when
                    // bundling happens to miss."
                } else {
                    const url = try std.fmt.allocPrint(
                        self.allocator,
                        "https://ziglang.org/documentation/{s}/std/#{s}",
                        .{ self.zig_version, content },
                    );
                    try self.link_targets.append(self.allocator, content);
                    try writeExternalLink(url, content, writer);
                    return;
                }
            } else if (self.refs) |table| {
                if (table.get(content)) |url| {
                    try self.link_targets.append(self.allocator, content);
                    try writeExternalLink(url, content, writer);
                    return;
                }
            }
        }

        try writer.writeByte('`');
        try writer.writeAll(content);
        try writer.writeByte('`');
    }

    /// Writes an internal same-document link to `target`'s label, used for
    /// both same-module resolution and `--bundle-std` hits.
    fn writeInternalLink(self: *Renderer, target: Decl.Index, content: []const u8, writer: *Writer) RenderError!void {
        var fqn_buf: std.ArrayList(u8) = .empty;
        defer fqn_buf.deinit(std.heap.page_allocator);
        try target.get().fqn(&fqn_buf);
        const fqn = try self.allocator.dupe(u8, fqn_buf.items);
        try self.link_targets.append(self.allocator, fqn);

        try writer.writeAll("#link(label(\"");
        try writeEscapedString(fqn, writer);
        try writer.writeAll("\"))[`");
        try writer.writeAll(content);
        try writer.writeAll("`]");
    }

    /// Renders a `list_item`'s block children, collapsing a tight list's sole
    /// paragraph child down to its inline content (no blank-line gap) --
    /// mirrors `Renderer.renderDefault`'s `.list_item` handling in
    /// `vendor/markdown/renderer.zig`.
    fn renderListItemBody(self: *Renderer, doc: Document, item: Document.Node.Index, writer: *Writer) RenderError!void {
        const item_data = doc.nodes.items(.data)[@intFromEnum(item)];
        for (doc.extraChildren(item_data.list_item.children)) |child| {
            const child_tag = doc.nodes.items(.tag)[@intFromEnum(child)];
            if (item_data.list_item.tight and child_tag == .paragraph) {
                const para_data = doc.nodes.items(.data)[@intFromEnum(child)];
                for (doc.extraChildren(para_data.container.children)) |para_child|
                    try self.renderNode(doc, para_child, writer);
            } else {
                try self.renderNode(doc, child, writer);
            }
        }
    }
};

/// Port of the old WASM `main.zig`'s `resolve_decl_path`: successively looks
/// up each dotted component starting from `origin`'s enclosing scope.
/// Returns `null` for anything that isn't a resolvable decl path (most code
/// spans -- parameter names, expressions, etc. -- fall in this bucket, and
/// that's expected).
fn resolveDeclPath(origin: Decl.Index, path: []const u8) ?Decl.Index {
    var components = std.mem.splitScalar(u8, path, '.');
    var current = origin.get().lookup(components.first()) orelse return null;
    while (components.next()) |component| {
        switch (current.get().categorize()) {
            .alias => |aliasee| current = aliasee,
            else => {},
        }
        current = current.get().get_child(component) orelse return null;
    }
    return current;
}

/// True for a plain dotted identifier chain (`std.mem.Allocator`), false for
/// anything with punctuation suggesting a call/expression/literal
/// (`std.debug.print("{}", .{x})`) -- those aren't decl references, and
/// blindly prefix-matching them against `std.*`/`external_refs` would
/// produce nonsense links.
fn looksLikeDottedPath(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '_', '.' => {},
        else => return false,
    };
    return true;
}

/// True when `path` is `std` or starts with `std.` -- see the module doc
/// comment for the (verified) URL/anchor format this feeds into.
fn isStdPath(path: []const u8) bool {
    return std.mem.eql(u8, path, "std") or std.mem.startsWith(u8, path, "std.");
}

fn writeExternalLink(url: []const u8, content: []const u8, writer: *Writer) Writer.Error!void {
    try writer.writeAll("#link(\"");
    try writeEscapedString(url, writer);
    try writer.writeAll("\")[`");
    try writer.writeAll(content);
    try writer.writeAll("`]");
}

/// Escapes plain doc-comment text so it can't be misread as Typst markup.
fn writeEscapedTypstText(text: []const u8, writer: *Writer) Writer.Error!void {
    for (text) |c| switch (c) {
        '\\', '#', '*', '_', '`', '<', '@', '$', '[', ']' => {
            try writer.writeByte('\\');
            try writer.writeByte(c);
        },
        else => try writer.writeByte(c),
    };
}

/// Escapes a string destined for a Typst string literal (link/image targets,
/// and cross-reference label ids).
fn writeEscapedString(text: []const u8, writer: *Writer) Writer.Error!void {
    for (text) |c| switch (c) {
        '"', '\\' => {
            try writer.writeByte('\\');
            try writer.writeByte(c);
        },
        else => try writer.writeByte(c),
    };
}
