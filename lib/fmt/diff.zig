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
        "example.zig",
        "same\nchange\nsame\n",
        "same\nchanged\nsame\n",
        .none,
    );

    try std.testing.expectEqualStrings(
        \\from example.zig:
        \\   2 | - change
        \\  ...
        \\   2 | + changed
        \\
        \\
    ,
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
        file_path,
        writer,
        profile,
    );
    try writer.writeAll(":\n");

    for (hunks.items) |hunk| {
        for (hunk.removed_start..hunk.removed_end) |i| {
            try writeLineNumber(
                writer,
                i + 1,
                profile,
            );
            try removed_style.renderWithProfile(
                "- ",
                writer,
                profile,
            );
            try removed_style.renderWithProfile(
                orig_lines.items[i],
                writer,
                profile,
            );
            try writer.writeAll("\n");
        }

        if (hunk.removed_end > hunk.removed_start and hunk.added_end > hunk.added_start) {
            try dimmed_style.renderWithProfile(
                "  ...\n",
                writer,
                profile,
            );
        }

        for (hunk.added_start..hunk.added_end) |i| {
            try writeLineNumber(
                writer,
                i + 1,
                profile,
            );
            try added_style.renderWithProfile(
                "+ ",
                writer,
                profile,
            );
            try added_style.renderWithProfile(
                fmt_lines.items[i],
                writer,
                profile,
            );
            try writer.writeAll("\n");
        }

        try writer.writeAll("\n");
    }
}

fn writeLineNumber(
    writer: *std.Io.Writer,
    line: usize,
    profile: carnaval.ColorProfile,
) !void {
    var buf: [16]u8 = undefined;
    const text = std.fmt.bufPrint(
        &buf,
        "{d: >4} | ",
        .{line},
    ) catch return;
    try dimmed_style.renderWithProfile(
        text,
        writer,
        profile,
    );
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
