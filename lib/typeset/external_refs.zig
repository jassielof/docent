//! Cross-package reference resolution, without walking another package's
//! source (see the design discussion this ports: bundling the whole stdlib
//! or every dependency into one docs.json, the way the upstream WASM tool's
//! tar-archive approach does, doesn't fit a PDF -- it works there because
//! it's a lazily-rendered website shipped with the compiler itself).
//!
//! Two distinct reference kinds, both resolved in `markdown_typst.zig`'s
//! `renderCodeSpan` after same-module resolution (`resolveDeclPath`) fails:
//!
//! - `std.*` -- resolved to `https://ziglang.org/documentation/{version}/std/#<path>`
//!   directly from the dotted path text, no lookup table needed. Verified
//!   against the real doc site's `main.js`: it parses `location.hash` as
//!   `#fully.qualified.name` for declaration navigation.
//! - Named dependencies -- resolved via a small sidecar JSON a dependency's
//!   *own* `docent typeset --refs-output <path>` run produces: just
//!   `{id -> this package's own doc URL}` for its public API, not the
//!   dependency's full docs.json. The consuming package loads one or more
//!   of these via `--external-refs <path>` (repeatable) into a `Table`, and
//!   an exact-match hit on a code span's full dotted text links to that
//!   URL. This deliberately only gets you to *the right document* (the
//!   dependency's whole PDF), not a specific anchor within it -- Typst
//!   labels are compile-unit-scoped, so a precise same-document jump isn't
//!   available across two independently-compiled PDFs without a shared
//!   build step neither side has today.

const std = @import("std");

const schema = @import("schema.zig");

/// The sidecar file format: `package`/`doc_url` describe where this
/// package's own generated docs live; `ids` is every id its own
/// `docs.json` emitted (from `collectIds`), all pointing at `doc_url`.
pub const RefsFile = struct {
    package: []const u8,
    doc_url: []const u8,
    ids: []const []const u8,
};

/// Recursively collects every id in `modules` (and their `decls`) into `out`.
pub fn collectIds(allocator: std.mem.Allocator, modules: []const schema.DeclNode, out: *std.ArrayList([]const u8)) !void {
    for (modules) |m| try collectIdsFrom(allocator, m, out);
}

fn collectIdsFrom(allocator: std.mem.Allocator, decl: schema.DeclNode, out: *std.ArrayList([]const u8)) !void {
    try out.append(allocator, decl.id);
    if (decl.decls) |children| {
        for (children) |child| try collectIdsFrom(allocator, child, out);
    }
}

/// Writes a `RefsFile` sidecar covering `modules`, so a dependent package
/// can later resolve links into `doc_url` without walking this package's
/// source.
pub fn writeRefsFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    package: []const u8,
    doc_url: []const u8,
    modules: []const schema.DeclNode,
    output_path: []const u8,
) !void {
    var ids: std.ArrayList([]const u8) = .empty;
    defer ids.deinit(allocator);
    try collectIds(allocator, modules, &ids);

    const refs: RefsFile = .{ .package = package, .doc_url = doc_url, .ids = ids.items };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var allocating = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
    try std.json.Stringify.value(refs, .{ .whitespace = .indent_2 }, &allocating.writer);
    buf = allocating.toArrayList();

    if (std.fs.path.dirname(output_path)) |dir| {
        try std.Io.Dir.cwd().createDirPath(io, dir);
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = output_path, .data = buf.items });
}

/// A merged lookup table over one or more loaded `RefsFile`s: id -> doc_url.
pub const Table = struct {
    entries: std.StringHashMapUnmanaged([]const u8) = .empty,

    pub fn get(self: *const Table, id: []const u8) ?[]const u8 {
        return self.entries.get(id);
    }

    /// Loads the sidecar at `path` and merges its ids into this table.
    /// First-loaded wins on id collisions across multiple sidecars.
    pub fn loadFile(self: *Table, allocator: std.mem.Allocator, io: std.Io, path: []const u8) !void {
        const source = try std.Io.Dir.cwd().readFileAllocOptions(
            io,
            path,
            allocator,
            .limited(std.math.maxInt(u32)),
            .of(u8),
            0,
        );

        const parsed = try std.json.parseFromSlice(RefsFile, allocator, source, .{});

        for (parsed.value.ids) |id| {
            const gop = try self.entries.getOrPut(allocator, id);
            if (!gop.found_existing) gop.value_ptr.* = parsed.value.doc_url;
        }
    }
};
