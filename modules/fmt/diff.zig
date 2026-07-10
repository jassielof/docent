const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;

const carnaval = @import("carnaval");

const removed_style = carnaval.Style.init().fg(.{ .ansi16 = .red });
const added_style = carnaval.Style.init().fg(.{ .ansi16 = .green });
const location_style = carnaval.Style.init().fg(.{ .ansi16 = .cyan });
const dimmed_style = carnaval.Style.init().dimmed();

pub fn writeDiff(
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

    splitLines(std.heap.page_allocator, original, &orig_lines) catch return;
    splitLines(std.heap.page_allocator, formatted, &fmt_lines) catch return;

    var hunks: std.ArrayList(Hunk) = .empty;
    defer hunks.deinit(std.heap.page_allocator);
    collectHunks(std.heap.page_allocator, orig_lines.items, fmt_lines.items, &hunks) catch return;

    if (hunks.items.len == 0) return;

    try writer.writeAll("from ");
    try location_style.renderWithProfile(file_path, writer, profile);
    try writer.writeAll(":\n");

    for (hunks.items) |hunk| {
        for (hunk.removed_start..hunk.removed_end) |i| {
            try writeLineNumber(writer, i + 1, profile);
            try removed_style.renderWithProfile("- ", writer, profile);
            try removed_style.renderWithProfile(orig_lines.items[i], writer, profile);
            try writer.writeAll("\n");
        }

        if (hunk.removed_end > hunk.removed_start and hunk.added_end > hunk.added_start) {
            try dimmed_style.renderWithProfile("  ...\n", writer, profile);
        }

        for (hunk.added_start..hunk.added_end) |i| {
            try writeLineNumber(writer, i + 1, profile);
            try added_style.renderWithProfile("+ ", writer, profile);
            try added_style.renderWithProfile(fmt_lines.items[i], writer, profile);
            try writer.writeAll("\n");
        }

        try writer.writeAll("\n");
    }
}

fn writeLineNumber(writer: *std.Io.Writer, line: usize, profile: carnaval.ColorProfile) !void {
    var buf: [16]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d: >4} | ", .{line}) catch return;
    try dimmed_style.renderWithProfile(text, writer, profile);
}

const Hunk = struct {
    removed_start: usize,
    removed_end: usize,
    added_start: usize,
    added_end: usize,
};

fn collectHunks(
    alloc: Allocator,
    orig: []const []const u8,
    formatted: []const []const u8,
    hunks: *std.ArrayList(Hunk),
) !void {
    var oi: usize = 0;
    var fi: usize = 0;

    while (oi < orig.len and fi < formatted.len) {
        if (mem.eql(u8, orig[oi], formatted[fi])) {
            oi += 1;
            fi += 1;
            continue;
        }

        var removed_end = oi;
        var added_end = fi;

        const sync = findSync(orig[oi..], formatted[fi..]);
        removed_end = oi + sync.orig_skip;
        added_end = fi + sync.fmt_skip;

        try hunks.append(alloc, .{
            .removed_start = oi,
            .removed_end = removed_end,
            .added_start = fi,
            .added_end = added_end,
        });

        oi = removed_end;
        fi = added_end;
    }

    if (oi < orig.len) {
        try hunks.append(alloc, .{
            .removed_start = oi,
            .removed_end = orig.len,
            .added_start = formatted.len,
            .added_end = formatted.len,
        });
    }

    if (fi < formatted.len) {
        try hunks.append(alloc, .{
            .removed_start = orig.len,
            .removed_end = orig.len,
            .added_start = fi,
            .added_end = formatted.len,
        });
    }
}

const SyncResult = struct { orig_skip: usize, fmt_skip: usize };

fn findSync(orig: []const []const u8, formatted: []const []const u8) SyncResult {
    const max_look = @min(orig.len, @min(formatted.len, 50));
    var best_oi: usize = orig.len;
    var best_fi: usize = formatted.len;
    var best_cost: usize = orig.len + formatted.len;

    for (1..max_look) |fi| {
        for (0..@min(orig.len, max_look)) |oi| {
            if (mem.eql(u8, orig[oi], formatted[fi])) {
                const cost = oi + fi;
                if (cost < best_cost) {
                    best_cost = cost;
                    best_oi = oi;
                    best_fi = fi;
                }
                break;
            }
        }
    }

    for (1..@min(orig.len, max_look)) |oi| {
        for (0..@min(formatted.len, max_look)) |fi| {
            if (mem.eql(u8, orig[oi], formatted[fi])) {
                const cost = oi + fi;
                if (cost < best_cost) {
                    best_cost = cost;
                    best_oi = oi;
                    best_fi = fi;
                }
                break;
            }
        }
    }

    if (best_oi == orig.len and best_fi == formatted.len) {
        return .{ .orig_skip = 1, .fmt_skip = 1 };
    }

    return .{ .orig_skip = best_oi, .fmt_skip = best_fi };
}

fn splitLines(alloc: Allocator, text: []const u8, out: *std.ArrayList([]const u8)) !void {
    var pos: usize = 0;
    while (pos < text.len) {
        const end = mem.indexOfScalar(u8, text[pos..], '\n') orelse text.len - pos;
        try out.append(alloc, text[pos .. pos + end]);
        pos += end + 1;
    }
}
