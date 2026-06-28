//! The trailing_comma namespace contains the logic to add trailing commas to lists.
//!
//! This is based on the that Zig suggests to add trailing commas, or basically break the list elements into one-per-line, when there are 3 or more items in a single-line list. See <https://ziglang.org/documentation/0.16.0/#Whitespace>.

const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;

/// The addTrailingCommas function adds trailing commas to single-line lists with 3 or more items.
///
/// Scans for balanced `(...)` and `{...}` groups that fit on one line, counts top-level commas inside, and inserts a trailing comma when there are 3+ items. On a subsequent `zig fmt` run the trailing comma causes the formatter to expand the list to one-item-per-line.
pub fn addTrailingCommas(gpa: Allocator, input: []const u8) Allocator.Error![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(gpa);

    try output.ensureTotalCapacity(gpa, input.len + input.len / 8);

    var line_start: usize = 0;
    while (line_start < input.len) {
        const line_end = mem.indexOfScalar(u8, input[line_start..], '\n') orelse input.len - line_start;
        const full_line = input[line_start .. line_start + line_end];
        line_start += line_end + 1;

        try processLine(gpa, &output, full_line);
        if (line_start <= input.len) try output.append(gpa, '\n');
    }

    return output.toOwnedSlice(gpa);
}

fn processLine(gpa: Allocator, output: *std.ArrayList(u8), line: []const u8) !void {
    var pos: usize = 0;

    while (pos < line.len) {
        const c = line[pos];

        if (c == '/' and pos + 1 < line.len and line[pos + 1] == '/') {
            try output.appendSlice(gpa, line[pos..]);
            return;
        }

        if (c == '\'' or c == '"') {
            const end = skipStringLiteral(line, pos);
            try output.appendSlice(gpa, line[pos..end]);
            pos = end;
            continue;
        }

        if (c == '(' or c == '{') {
            const close: u8 = if (c == '(') ')' else '}';
            if (findMatchingClose(line, pos, c, close)) |close_pos| {
                const inner = line[pos + 1 .. close_pos];
                const commas = countTopLevelCommas(inner);

                if (commas >= 2 and !hasTrailingComma(inner)) {
                    try output.append(gpa, c);
                    try processLine(gpa, output, inner);
                    const out_len = output.items.len;
                    const trailing_spaces = trailingSpaceCount(output.items);
                    try output.insertSlice(gpa, out_len - trailing_spaces, ",");
                    try output.append(gpa, close);
                    pos = close_pos + 1;
                    continue;
                }
            }
        }

        try output.append(gpa, c);
        pos += 1;
    }
}

fn findMatchingClose(line: []const u8, start: usize, open: u8, close: u8) ?usize {
    var depth: usize = 0;
    var i = start;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (c == '\'' or c == '"') {
            i = skipStringLiteral(line, i) - 1;
            continue;
        }
        if (c == open) {
            depth += 1;
        } else if (c == close) {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

fn countTopLevelCommas(inner: []const u8) usize {
    var count: usize = 0;
    var depth_paren: usize = 0;
    var depth_brace: usize = 0;
    var i: usize = 0;
    while (i < inner.len) : (i += 1) {
        const c = inner[i];
        if (c == '\'' or c == '"') {
            i = skipStringLiteral(inner, i) - 1;
            continue;
        }
        switch (c) {
            '(' => depth_paren += 1,
            ')' => {
                if (depth_paren > 0) depth_paren -= 1;
            },
            '{' => depth_brace += 1,
            '}' => {
                if (depth_brace > 0) depth_brace -= 1;
            },
            ',' => {
                if (depth_paren == 0 and depth_brace == 0) count += 1;
            },
            else => {},
        }
    }
    return count;
}

fn hasTrailingComma(inner: []const u8) bool {
    const trimmed = mem.trimEnd(u8, inner, " ");
    return trimmed.len > 0 and trimmed[trimmed.len - 1] == ',';
}

fn trailingSpaceCount(items: []const u8) usize {
    var count: usize = 0;
    var i = items.len;
    while (i > 0) {
        i -= 1;
        if (items[i] == ' ') {
            count += 1;
        } else break;
    }
    return count;
}

fn skipStringLiteral(line: []const u8, start: usize) usize {
    const quote = line[start];
    var i = start + 1;
    while (i < line.len) : (i += 1) {
        if (line[i] == '\\') {
            i += 1;
            continue;
        }
        if (line[i] == quote) return i + 1;
    }
    return line.len;
}
