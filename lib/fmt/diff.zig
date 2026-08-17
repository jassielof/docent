const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;

const carnaval = @import("carnaval");
const dmp = @import("dmp");

const removed_style = carnaval.Style.init().fg(.{ .ansi16 = .red });
const added_style = carnaval.Style.init().fg(.{ .ansi16 = .green });
const location_style = carnaval.Style.init().fg(.{ .ansi16 = .cyan });
const dimmed_style = carnaval.Style.init().dimmed();

test "reports a changed line once when surrounding lines repeat" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    try writeDiff(
        std.testing.io,
        &output.writer,
        "lib/fmt\\example.zig",
        "same\nchange\nsame\n",
        "same\nchanged\nsame\n",
        .none,
    );

    try std.testing.expectEqualStrings(
        \\from lib/fmt/example.zig:
        \\2 | -change
        \\2 | +changed
        \\
        \\
    ,
        output.writer.buffered(),
    );
}

test "renders diagnostic paths with forward slashes" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    try writeDisplayPath(
        &output.writer,
        "lib/fmt\\Formatter.zig",
    );

    try std.testing.expectEqualStrings(
        "lib/fmt/Formatter.zig",
        output.writer.buffered(),
    );
}

pub fn writeDiff(
    io: std.Io,
    writer: *std.Io.Writer,
    file_path: []const u8,
    original: []const u8,
    formatted: []const u8,
    profile: carnaval.ColorProfile,
) !void {
    const display_path = try std.mem.replaceOwned(
        u8,
        std.heap.page_allocator,
        file_path,
        "\\",
        "/",
    );
    defer std.heap.page_allocator.free(display_path);

    var orig_lines: std.ArrayList([]const u8) = .empty;
    var fmt_lines: std.ArrayList([]const u8) = .empty;
    defer orig_lines.deinit(std.heap.page_allocator);
    defer fmt_lines.deinit(std.heap.page_allocator);

    splitLines(
        std.heap.page_allocator,
        original,
        &orig_lines,
    ) catch return;
    splitLines(
        std.heap.page_allocator,
        formatted,
        &fmt_lines,
    ) catch return;

    var hunks: std.ArrayList(Hunk) = .empty;
    defer hunks.deinit(std.heap.page_allocator);
    collectHunks(
        std.heap.page_allocator,
        io,
        original,
        formatted,
        orig_lines.items.len,
        fmt_lines.items.len,
        &hunks,
    ) catch return;

    if (hunks.items.len == 0) return;

    try writer.writeAll("from ");
    try location_style.renderWithProfile(
        display_path,
        writer,
        profile,
    );
    try writer.writeAll(":\n");

    const width = maxLineNumberWidth(hunks.items);

    for (hunks.items, 0..) |hunk, hunk_index| {
        if (hunk_index != 0) {
            try writeGapMarker(
                writer,
                width,
                profile,
            );
        }

        const removed_count = hunk.removed_end - hunk.removed_start;
        const added_count = hunk.added_end - hunk.added_start;
        const pair_count = @max(removed_count, added_count);

        for (0..pair_count) |i| {
            if (i < removed_count) {
                try writeLineNumber(
                    writer,
                    hunk.removed_start + i + 1,
                    width,
                    profile,
                );
                try removed_style.renderWithProfile(
                    "-",
                    writer,
                    profile,
                );
                try removed_style.renderWithProfile(
                    orig_lines.items[hunk.removed_start + i],
                    writer,
                    profile,
                );
                try writer.writeAll("\n");
            }

            if (i < added_count) {
                try writeLineNumber(
                    writer,
                    hunk.added_start + i + 1,
                    width,
                    profile,
                );
                try added_style.renderWithProfile(
                    "+",
                    writer,
                    profile,
                );
                try added_style.renderWithProfile(
                    fmt_lines.items[hunk.added_start + i],
                    writer,
                    profile,
                );
                try writer.writeAll("\n");
            }
        }
    }

    try writer.writeAll("\n");
}

/// Writes `path` using forward slashes for stable, copyable diagnostics.
/// The original path remains untouched for filesystem operations.
pub fn writeDisplayPath(
    writer: *std.Io.Writer,
    path: []const u8,
) !void {
    const display_path = try std.mem.replaceOwned(
        u8,
        std.heap.page_allocator,
        path,
        "\\",
        "/",
    );
    defer std.heap.page_allocator.free(display_path);
    try writer.writeAll(display_path);
}

fn writeLineNumber(
    writer: *std.Io.Writer,
    line: usize,
    width: usize,
    profile: carnaval.ColorProfile,
) !void {
    var num_buf: [20]u8 = undefined;
    const num_text = std.fmt.bufPrint(
        &num_buf,
        "{d}",
        .{line},
    ) catch return;

    var buf: [32]u8 = undefined;
    const pad = if (width > num_text.len) width - num_text.len else 0;
    @memset(buf[0..pad], ' ');
    @memcpy(buf[pad..][0..num_text.len], num_text);
    buf[pad + num_text.len] = ' ';
    buf[pad + num_text.len + 1] = '|';
    buf[pad + num_text.len + 2] = ' ';

    try dimmed_style.renderWithProfile(
        buf[0 .. pad + num_text.len + 3],
        writer,
        profile,
    );
}

/// Marks a skipped gap between two hunks that aren't adjacent, using a
/// blank field the same width as the line-number column so it lines up.
fn writeGapMarker(
    writer: *std.Io.Writer,
    width: usize,
    profile: carnaval.ColorProfile,
) !void {
    var buf: [32]u8 = undefined;
    @memset(buf[0..width], ' ');
    const text = std.fmt.bufPrint(
        buf[width..],
        " | ...\n",
        .{},
    ) catch return;

    try dimmed_style.renderWithProfile(
        buf[0 .. width + text.len],
        writer,
        profile,
    );
}

/// The column width needed to right-align every line number referenced
/// across `hunks`, matching how narrow diffs stay compact.
fn maxLineNumberWidth(hunks: []const Hunk) usize {
    var max_line: usize = 1;
    for (hunks) |hunk| {
        max_line = @max(max_line, hunk.removed_end);
        max_line = @max(max_line, hunk.added_end);
    }
    var digits: usize = 1;
    var v = max_line;
    while (v >= 10) : (v /= 10) digits += 1;
    return digits;
}

const Hunk = struct {
    removed_start: usize,
    removed_end: usize,
    added_start: usize,
    added_end: usize,
};

fn collectHunks(
    alloc: Allocator,
    io: std.Io,
    original: []const u8,
    formatted: []const u8,
    orig_line_count: usize,
    formatted_line_count: usize,
    hunks: *std.ArrayList(Hunk),
) !void {
    const engine: dmp.Diff = .init(io, alloc);
    var edits = try engine.diff(
        original,
        formatted,
        true,
        .none,
    );
    defer dmp.Diff.deinitEditList(alloc, &edits);

    // The raw Myers diff can interleave textually-identical lines as
    // delete/insert pairs separated by a trivial equality (e.g. a lone
    // newline) instead of grouping the real change into one block. This
    // merges those semantically-empty equalities into their neighboring
    // edits so nearby changes render as a single hunk.
    try dmp.Diff.cleanupSemantic(alloc, &edits);

    var original_offset: usize = 0;
    var formatted_offset: usize = 0;
    var active: ?ByteHunk = null;

    for (edits.items) |edit| {
        switch (edit.operation) {
            .equal => {
                if (active) |hunk| {
                    try appendHunk(
                        alloc,
                        hunks,
                        hunk,
                        original,
                        formatted,
                        orig_line_count,
                        formatted_line_count,
                    );
                    active = null;
                }
                original_offset += edit.text.len;
                formatted_offset += edit.text.len;
            },
            .delete => {
                if (active == null) active = .{
                    .original_start = original_offset,
                    .original_end = original_offset,
                    .formatted_start = formatted_offset,
                    .formatted_end = formatted_offset,
                };
                active.?.original_end += edit.text.len;
                original_offset += edit.text.len;
            },
            .insert => {
                if (active == null) active = .{
                    .original_start = original_offset,
                    .original_end = original_offset,
                    .formatted_start = formatted_offset,
                    .formatted_end = formatted_offset,
                };
                active.?.formatted_end += edit.text.len;
                formatted_offset += edit.text.len;
            },
        }
    }
    if (active) |hunk| {
        try appendHunk(
            alloc,
            hunks,
            hunk,
            original,
            formatted,
            orig_line_count,
            formatted_line_count,
        );
    }
}

const ByteHunk = struct {
    original_start: usize,
    original_end: usize,
    formatted_start: usize,
    formatted_end: usize,
};

fn appendHunk(
    alloc: Allocator,
    hunks: *std.ArrayList(Hunk),
    hunk: ByteHunk,
    original: []const u8,
    formatted: []const u8,
    orig_line_count: usize,
    formatted_line_count: usize,
) !void {
    try hunks.append(alloc, .{
        .removed_start = lineAt(original, hunk.original_start),
        .removed_end = lineRangeEnd(
            original,
            hunk.original_start,
            hunk.original_end,
            orig_line_count,
        ),
        .added_start = lineAt(formatted, hunk.formatted_start),
        .added_end = lineRangeEnd(
            formatted,
            hunk.formatted_start,
            hunk.formatted_end,
            formatted_line_count,
        ),
    });
}

fn lineAt(text: []const u8, offset: usize) usize {
    var line: usize = 0;
    for (text[0..@min(offset, text.len)]) |byte| {
        if (byte == '\n') line += 1;
    }
    return line;
}

fn lineRangeEnd(
    text: []const u8,
    start: usize,
    end: usize,
    line_count: usize,
) usize {
    const start_line = lineAt(text, start);
    if (end > start) return lineAt(text, end - 1) + 1;
    return @min(start_line + 1, line_count);
}

fn splitLines(
    alloc: Allocator,
    text: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    var pos: usize = 0;
    while (pos < text.len) {
        const end = mem.indexOfScalar(
            u8,
            text[pos..],
            '\n',
        ) orelse text.len - pos;
        try out.append(alloc, text[pos .. pos + end]);
        pos += end + 1;
    }
}
