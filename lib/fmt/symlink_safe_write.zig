//! Writes formatted output back to disk without destroying symlinks
//! ([zig#36209](https://codeberg.org/ziglang/zig/issues/36209)).
//!
//! `std.Io.Dir.createFileAtomic` (what Docent, and upstream `zig fmt`, normally use to write
//! formatted output) writes into a fresh temp file in the same directory and `rename()`s it
//! over the target path. That rename replaces whatever directory entry currently sits at that
//! path -- if the path is a symlink, the symlink itself is discarded and replaced with a
//! regular file containing the formatted text, silently breaking the link.
//!
//! `write` checks whether `sub_path` is a symlink first:
//!
//! - Regular files still go through the atomic rename path, which is safest against partial
//!   writes (a crash mid-write leaves the original file untouched).
//! - Symlinks are written through directly: `Dir.createFile` follows the link the same way
//!   `open()` would, truncating and overwriting the link's *target* in place, so the symlink
//!   itself survives. Because this is not atomic, a failure partway through the write could
//!   leave the target truncated; `write` follows up with a best-effort restore of `original`
//!   (already held in memory by the caller, no re-read needed) so the file isn't left corrupt.

const std = @import("std");
const Io = std.Io;

/// Writes `output` to `sub_path` inside `dir`, preserving `sub_path` as a symlink if it
/// already is one. `original` is the source content already read from `sub_path`, used to
/// restore the file if a direct (symlink) write fails partway through.
pub fn write(
    io: Io,
    dir: Io.Dir,
    sub_path: []const u8,
    permissions: Io.File.Permissions,
    original: []const u8,
    output: []const u8,
) !void {
    if (!isSymlink(
        io,
        dir,
        sub_path,
    )) {
        var af = try dir.createFileAtomic(
            io,
            sub_path,
            .{ .permissions = permissions, .replace = true },
        );
        defer af.deinit(io);

        try af.file.writeStreamingAll(io, output);
        try af.replace(io);
        return;
    }

    try writeThroughSymlink(
        io,
        dir,
        sub_path,
        original,
        output,
    );
}

fn isSymlink(
    io: Io,
    dir: Io.Dir,
    sub_path: []const u8,
) bool {
    const lstat = dir.statFile(
        io,
        sub_path,
        .{ .follow_symlinks = false },
    ) catch return false;
    return lstat.kind == .sym_link;
}

fn writeThroughSymlink(
    io: Io,
    dir: Io.Dir,
    sub_path: []const u8,
    original: []const u8,
    output: []const u8,
) !void {
    var target = try dir.createFile(
        io,
        sub_path,
        .{ .truncate = true },
    );
    var closed = false;
    defer if (!closed) target.close(io);

    if (target.writeStreamingAll(io, output)) |_| {
        target.close(io);
        closed = true;
        return;
    } else |write_err| {
        target.close(io);
        closed = true;

        var restore = dir.createFile(
            io,
            sub_path,
            .{ .truncate = true },
        ) catch |restore_open_err| {
            std.log.err(
                "write failed ({s}) and the symlink target could not be reopened to restore its original contents ({s}); the file may now be empty or truncated",
                .{ @errorName(write_err), @errorName(restore_open_err) },
            );
            return write_err;
        };
        defer restore.close(io);

        restore.writeStreamingAll(io, original) catch |restore_err| {
            std.log.err(
                "write failed ({s}) and restoring the original contents also failed ({s}); the symlink target is left in a corrupt state",
                .{ @errorName(write_err), @errorName(restore_err) },
            );
            return write_err;
        };

        std.log.err("write failed ({s}); original contents were restored", .{@errorName(write_err)});
        return write_err;
    }
}

test "preserves a symlink and formats through it (zig#36209)" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const original = "const  a = 1;\n";
    const formatted = "const a = 1;\n";

    try tmp.dir.writeFile(io, .{ .sub_path = "target.zig", .data = original });
    tmp.dir.symLink(
        io,
        "target.zig",
        "link.zig",
        .{},
    ) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };

    const before = try tmp.dir.statFile(
        io,
        "link.zig",
        .{ .follow_symlinks = false },
    );
    try std.testing.expectEqual(Io.File.Kind.sym_link, before.kind);

    try write(
        io,
        tmp.dir,
        "link.zig",
        .default_file,
        original,
        formatted,
    );

    const after = try tmp.dir.statFile(
        io,
        "link.zig",
        .{ .follow_symlinks = false },
    );
    try std.testing.expectEqual(Io.File.Kind.sym_link, after.kind);

    const via_link = try tmp.dir.readFileAlloc(
        io,
        "link.zig",
        gpa,
        .unlimited,
    );
    defer gpa.free(via_link);
    try std.testing.expectEqualStrings(formatted, via_link);

    const via_target = try tmp.dir.readFileAlloc(
        io,
        "target.zig",
        gpa,
        .unlimited,
    );
    defer gpa.free(via_target);
    try std.testing.expectEqualStrings(formatted, via_target);
}

test "atomically replaces a regular file" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const original = "const  a = 1;\n";
    const formatted = "const a = 1;\n";

    try tmp.dir.writeFile(io, .{ .sub_path = "plain.zig", .data = original });

    try write(
        io,
        tmp.dir,
        "plain.zig",
        .default_file,
        original,
        formatted,
    );

    const st = try tmp.dir.statFile(
        io,
        "plain.zig",
        .{ .follow_symlinks = false },
    );
    try std.testing.expect(st.kind != .sym_link);

    const content = try tmp.dir.readFileAlloc(
        io,
        "plain.zig",
        gpa,
        .unlimited,
    );
    defer gpa.free(content);
    try std.testing.expectEqualStrings(formatted, content);
}
