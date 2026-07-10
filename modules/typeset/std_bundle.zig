//! Lazily bundles referenced stdlib declarations into the appendix, as an
//! alternative to `markdown_typst.zig`'s default `ziglang.org` link for
//! `std.*` references (opt in via `docent typeset --bundle-std`).
//!
//! Bounding rule -- the one thing that prevents unbounded stdlib expansion:
//! resolution only ever triggers from references made in a decl this run is
//! *already* emitting through the normal `modules`/`appendix` pipeline --
//! never from references discovered inside an already-bundled std file's
//! own doc comments. So referencing `std.zig.Ast` pulls in exactly
//! `zig/Ast.zig`'s own declarations (one file, however large), however many
//! `std.*` names *that* file's own docs happen to mention -- those render
//! as plain unlinked code, not a further pull-in. `json_emit.zig` enforces
//! this structurally: the `Ctx` used to emit a std-bundled entry's own
//! subtree has `std_bundle` set to `null`, so `markdown_typst.zig` has no
//! way to trigger a second hop from within it.
//!
//! File resolution: unlike a local package, std files aren't pre-walked --
//! there's no `../scan/reach.zig`-style closure to draw from, and walking
//! one shouldn't recursively pull in std's own `@import` graph either (that
//! would silently reintroduce the exact explosion this module exists to
//! avoid -- `vendor/Walk.zig`'s `categorize()` only resolves an `@import` if
//! the target file *happens* to already be registered, so a plain
//! single-file `Walk.add_file` call is inherently safe: unresolvable
//! references inside it just degrade to plain text, nothing gets fetched
//! on demand). Given a dotted path like `std.zig.Ast`, this probes
//! candidate files on disk under `std_dir` (from `zig env`), trying
//! progressively shorter prefixes (in case a trailing segment names a decl
//! inside a shorter file, e.g. `std.ArrayList` -> `array_list.zig`) and a
//! snake_case variant of the candidate filename (std doesn't consistently
//! name files after the PascalCase symbols they export). The first
//! candidate that exists on disk is walked once; any trailing path segments
//! beyond the matched file resolve via the same `Decl.lookup`/`get_child`
//! machinery already used for intra-package references -- nested types
//! like `std.zig.Ast.Node.Tag` resolve for free, since that's just
//! container-nesting within the one walked file. A reference that needs a
//! *second* file hop to fully resolve (rare -- most std namespacing matches
//! the directory/file layout directly) fails gracefully to plain text
//! rather than chasing further hops.

const std = @import("std");

const walker = @import("walker.zig");
const Walk = walker.Walk;
const Decl = walker.Decl;

pub const StdRoot = struct {
    /// `lib/std` -- where `mem.zig`, `zig.zig`, `zig/Ast.zig`, etc. live.
    dir: []const u8,
};

/// Runs `zig env` and extracts `std_dir`. Returns `null` (not an error) if
/// `zig` isn't on PATH or the field can't be found -- callers should just
/// skip std bundling in that case, the same graceful-degradation philosophy
/// used everywhere else in this pipeline.
pub fn discover(allocator: std.mem.Allocator, io: std.Io) ?StdRoot {
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "zig", "env" },
    }) catch return null;

    const std_dir_raw = extractZonString(result.stdout, ".std_dir") orelse return null;
    const std_dir = unescapeZonString(allocator, std_dir_raw) catch return null;

    return .{ .dir = std_dir };
}

/// Extracts the string value of `.key = "..."` from `zig env`'s ZON-ish
/// output (not JSON -- Zig removed the JSON output mode).
fn extractZonString(text: []const u8, key: []const u8) ?[]const u8 {
    const key_idx = std.mem.indexOf(u8, text, key) orelse return null;
    var i = key_idx + key.len;
    while (i < text.len and text[i] != '"') : (i += 1) {
        if (text[i] == '\n') return null; // no `=` before end of line: not a match
    }
    if (i >= text.len) return null;
    const start = i + 1;

    var j = start;
    var escaped = false;
    while (j < text.len) : (j += 1) {
        if (escaped) {
            escaped = false;
            continue;
        }
        switch (text[j]) {
            '\\' => escaped = true,
            '"' => return text[start..j],
            else => {},
        }
    }
    return null;
}

fn unescapeZonString(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] == '\\' and i + 1 < raw.len) {
            i += 1;
            try out.append(allocator, raw[i]);
        } else {
            try out.append(allocator, raw[i]);
        }
    }
    return try out.toOwnedSlice(allocator);
}

/// A module discovered via `resolve`, awaiting full emission as an
/// appendix entry (see `json_emit.zig`'s draining loop in `emitPackage`).
pub const Pending = struct {
    root_decl: Decl.Index,
    /// Module name to register/report under (the matched file's own dotted
    /// prefix, e.g. `"std.zig"` for `zig/Ast.zig`, so ids read naturally as
    /// `std.zig.Ast...`, matching how the reference was actually written).
    name: []const u8,
};

pub const Collector = struct {
    root: StdRoot,
    /// Dotted prefix (e.g. `"std.zig"`) -> already-walked root decl, so a
    /// second reference into the same file doesn't re-walk or re-queue it.
    walked: std.StringHashMapUnmanaged(Decl.Index) = .empty,
    pending: std.ArrayListUnmanaged(Pending) = .empty,

    /// Resolves `path` (e.g. `"std.zig.Ast"` or `"std.mem.Allocator.alloc"`)
    /// against `self.root`, walking at most one new file. Returns the
    /// resolved decl, queuing its containing file for appendix emission if
    /// this is the first reference to reach it. Returns `null` if no
    /// candidate file matches, or the trailing segments (if any) don't
    /// resolve within it -- callers fall back to plain unlinked text.
    pub fn resolve(self: *Collector, allocator: std.mem.Allocator, io: std.Io, path: []const u8) !?Decl.Index {
        var it = std.mem.splitScalar(u8, path, '.');
        _ = it.first(); // "std"
        var segments: std.ArrayList([]const u8) = .empty;
        defer segments.deinit(allocator);
        while (it.next()) |seg| try segments.append(allocator, seg);
        if (segments.items.len == 0) return null;

        const found = try self.locateFile(allocator, io, segments.items) orelse return null;

        var current = found.root_decl;
        for (segments.items[found.matched_len..]) |seg| {
            switch (current.get().categorize()) {
                .alias => |aliasee| current = aliasee,
                else => {},
            }
            current = current.get().get_child(seg) orelse return null;
        }
        return current;
    }

    const Located = struct {
        root_decl: Decl.Index,
        /// How many leading `segments` were consumed to name the file --
        /// the rest resolve via `get_child` within it.
        matched_len: usize,
    };

    fn locateFile(self: *Collector, allocator: std.mem.Allocator, io: std.Io, segments: []const []const u8) !?Located {
        var k = segments.len;
        while (k >= 1) : (k -= 1) {
            const prefix = segments[0..k];
            const module_name = try joinDotted(allocator, prefix);

            if (self.walked.get(module_name)) |decl| {
                return .{ .root_decl = decl, .matched_len = k };
            }

            if (try self.tryWalkCandidate(allocator, io, prefix, module_name)) |decl| {
                return .{ .root_decl = decl, .matched_len = k };
            }
        }
        return null;
    }

    fn tryWalkCandidate(
        self: *Collector,
        allocator: std.mem.Allocator,
        io: std.Io,
        prefix: []const []const u8,
        module_name: []const u8,
    ) !?Decl.Index {
        const dirs = prefix[0 .. prefix.len - 1];
        const base = prefix[prefix.len - 1];

        for ([2][]const u8{ base, toSnakeCase(allocator, base) catch base }) |filename_base| {
            const rel = try joinPathZig(allocator, dirs, filename_base);
            defer allocator.free(rel);
            const abs = try std.fs.path.join(allocator, &.{ self.root.dir, rel });
            defer allocator.free(abs);

            const stat = std.Io.Dir.cwd().statFile(io, abs, .{}) catch continue;
            if (stat.kind != .file) continue;

            const source = std.Io.Dir.cwd().readFileAllocOptions(
                io,
                abs,
                allocator,
                .limited(std.math.maxInt(u32)),
                .of(u8),
                null,
            ) catch continue;

            const key = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ module_name, std.fs.path.basename(abs) });
            const decl = Walk.add_file(key, source) catch continue;
            try Walk.modules.put(std.heap.page_allocator, module_name, decl);
            try self.walked.put(allocator, module_name, Walk.File.Index.findRootDecl(decl));
            const root_decl = Walk.File.Index.findRootDecl(decl);
            try self.pending.append(allocator, .{ .root_decl = root_decl, .name = module_name });
            return root_decl;
        }
        return null;
    }
};

fn joinDotted(allocator: std.mem.Allocator, segments: []const []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "std");
    for (segments) |seg| {
        try out.append(allocator, '.');
        try out.appendSlice(allocator, seg);
    }
    return try out.toOwnedSlice(allocator);
}

fn joinPathZig(allocator: std.mem.Allocator, dirs: []const []const u8, filename_base: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (dirs) |d| {
        try out.appendSlice(allocator, d);
        try out.append(allocator, '/');
    }
    try out.appendSlice(allocator, filename_base);
    try out.appendSlice(allocator, ".zig");
    return try out.toOwnedSlice(allocator);
}

/// `SomeName` -> `some_name`. Std files are usually named after the value
/// they export in snake_case even when the export itself is PascalCase
/// (`std.ArrayList` lives in `array_list.zig`).
fn toSnakeCase(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (name, 0..) |c, i| {
        if (std.ascii.isUpper(c)) {
            if (i != 0) try out.append(allocator, '_');
            try out.append(allocator, std.ascii.toLower(c));
        } else {
            try out.append(allocator, c);
        }
    }
    return try out.toOwnedSlice(allocator);
}
