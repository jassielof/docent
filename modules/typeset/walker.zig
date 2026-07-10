//! Native filesystem driver for the vendored `Walk`/`Decl` machinery.
//!
//! Replaces the WASM entry point's `unpack()` (tar-over-JS-boundary ingestion)
//! with plain `std.Io.Dir` reads. Discovery of which files belong to the
//! module reuses `../scan/reach.zig`'s `collectReachablePublicFiles` --
//! the same "follow `pub const X = @import(\"Y.zig\")` chains" traversal
//! Docent's own lint-target selection already relies on, so it's exercised
//! by that code path too rather than being new, single-purpose logic.
//!
//! Each discovered file is registered with `vendor.Walk.add_file` under a
//! `<module_name>/<path relative to the module root's directory>` key.
//! This mirrors the upstream WASM tool's own convention: it unpacks a tar
//! archive whose entries are naturally namespaced under a package-name
//! folder (`std/mem.zig`, `std/mem/Allocator.zig`, ...), and registers only
//! the *package root* file in `Walk.modules` -- every other file's `Decl.fqn`
//! falls back to deriving its prefix straight from that namespaced file key
//! (`vendor/Decl.zig`'s `append_path`), not from a `Walk.modules` lookup.
//! Confirmed empirically: without the `module_name/` prefix, a decl nested
//! inside a re-exported file (e.g. `ScanMode` inside `scan.zig`, re-exported
//! from `root.zig` as `pub const scan = @import("scan.zig");`) gets an id
//! like `"src.lib.scan.ScanMode"` (derived from the raw filesystem path)
//! instead of `"docent.scan.ScanMode"`.
//!
//! The key also has to stay consistent with `vendor/Walk.zig`'s own
//! `@import` resolution formula (`resolvePosix(current_file_key, "..",
//! raw_import_string)`, see `categorize_builtin_call`) so that once every
//! file in the closure is registered, `Decl.categorize()` resolves
//! cross-file `@import` aliases the same way it already resolves same-file
//! identifiers. `categorize()` is lazy/on-demand, so registration order
//! doesn't matter, only that every reachable file ends up registered under
//! the *right* key before anything asks to categorize a decl.
//!
//! `Walk`'s global tables (`files`/`decls`/`modules`) are process-lifetime
//! state, matching the vendored allocator patch (`std.heap.page_allocator`,
//! never freed) -- this is fine for a one-shot CLI invocation.

const std = @import("std");

pub const Walk = @import("vendor/Walk.zig");
pub const Decl = Walk.Decl;

const docent = @import("docent");
const reach = docent.scan.reach;
const target = docent.scan.target;

/// Maps each synthetic `Walk.files` key (see the module doc comment) back to
/// the real, cwd-relative filesystem path it was read from, so
/// `json_emit.zig` can report accurate `SourceLoc.file` values instead of
/// the `<module_name>/...`-namespaced key `Decl.fqn` needs internally.
pub var real_paths: std.StringHashMapUnmanaged([]const u8) = .empty;

/// Looks up the real filesystem path for a `Walk.files` key registered by
/// `walkModule`. Falls back to `key` itself if not found (shouldn't happen
/// for any file this module actually walked).
pub fn realPathForKey(key: []const u8) []const u8 {
    return real_paths.get(key) orelse key;
}

/// Walks every file publicly reachable from `module_root_path` (including
/// itself), populating the vendored `Walk.files` / `Walk.decls` /
/// `Walk.modules` global tables, and returns the module's root `Decl.Index`.
///
/// `allocator` is used both for path/bookkeeping allocations and to read
/// each source file into memory; all of it is retained for the process
/// lifetime because the resulting `Ast`s borrow from it directly (see
/// `vendor/Walk.zig`'s `parse`) and because `Walk.add_file` stores each path
/// key by reference, not by copy.
pub fn walkModule(
    allocator: std.mem.Allocator,
    io: std.Io,
    module_root_path: []const u8,
    module_name: []const u8,
) !Decl.Index {
    var reachable = try reach.collectReachablePublicFiles(allocator, io, module_root_path);
    defer reach.deinitOwnedPaths(allocator, &reachable);

    if (reachable.items.len == 0) return error.ModuleRootNotFound;

    // `collectReachableGeneric` always appends the (canonicalized) root path
    // first, before crawling its imports -- see reach.zig.
    const root_abs = reachable.items[0];
    const root_dir_abs = std.fs.path.dirname(root_abs) orelse root_abs;
    const root_dir_arg = std.fs.path.dirname(module_root_path) orelse ".";
    const root_basename = std.fs.path.basename(module_root_path);

    var root_file_index: ?Walk.File.Index = null;

    for (reachable.items, 0..) |abs_path, i| {
        const paths = if (i == 0)
            Paths{
                .key = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ module_name, root_basename }),
                .display = try allocator.dupe(u8, module_root_path),
            }
        else
            try moduleRelativeKey(allocator, module_name, root_dir_abs, root_dir_arg, abs_path);

        if (Walk.files.contains(paths.key)) continue;

        const source = try std.Io.Dir.cwd().readFileAllocOptions(
            io,
            abs_path,
            allocator,
            .limited(std.math.maxInt(u32)),
            .of(u8),
            null,
        );

        const file_index = try Walk.add_file(paths.key, source);
        try real_paths.put(std.heap.page_allocator, paths.key, paths.display);
        if (i == 0) root_file_index = file_index;
    }

    const found_root = root_file_index orelse return error.ModuleRootNotFound;
    try Walk.modules.put(std.heap.page_allocator, module_name, found_root);
    return Walk.File.Index.findRootDecl(found_root);
}

const Paths = struct {
    /// The `Walk.files` registration key -- `<module_name>/...`-namespaced.
    key: []const u8,
    /// The real, user-facing path to report in `SourceLoc.file`.
    display: []const u8,
};

/// Computes the path key a sibling file should be registered under: `file_abs`
/// re-expressed relative to `root_dir_abs`, with `module_name` substituted in
/// as the namespace prefix (see the module doc comment for why that
/// substitution -- not the real directory name -- is what `Decl.fqn` needs).
/// The display path uses the same relative suffix, but keeps `root_dir_arg`
/// (how the user actually referred to the root) as its prefix.
fn moduleRelativeKey(
    allocator: std.mem.Allocator,
    module_name: []const u8,
    root_dir_abs: []const u8,
    root_dir_arg: []const u8,
    file_abs: []const u8,
) !Paths {
    const rel = try target.pathRelativeTo(allocator, root_dir_abs, file_abs);
    defer allocator.free(rel);

    // `pathRelativeTo` returns an unchanged dupe of `file_abs` when it isn't
    // under `root_dir_abs` -- an unusual layout (import escaping the
    // module's own directory tree) that this key scheme can't represent
    // exactly. Fall back to a flattened, still-unique posix-ish key; nothing
    // crashes, but `@import` resolution for decls reached only through such
    // a file may not resolve.
    if (std.mem.eql(u8, rel, file_abs)) {
        const posix_abs = try posixify(allocator, file_abs);
        return .{
            .key = try std.fmt.allocPrint(allocator, "{s}/_external/{s}", .{ module_name, posix_abs }),
            .display = posix_abs,
        };
    }

    return .{
        .key = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ module_name, rel }),
        .display = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root_dir_arg, rel }),
    };
}

fn posixify(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const out = try allocator.dupe(u8, path);
    for (out) |*c| {
        if (c.* == '\\' or c.* == ':') c.* = '_';
    }
    return out;
}
