const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;

/// Enforces logical blank line separation (vertical whitespace discipline).
///
/// Rules applied:
/// 1. One blank line after a closing `}` before the next statement
///    (unless followed by `}`, `else`, `catch`, or `)` continuation).
/// 2. One blank line after `return`/`continue`/`break` statements
///    (unless at end of block).
/// 3. No blank line immediately after `{`.
/// 4. No blank line immediately before `}`.
/// 5. Never two consecutive blank lines.
pub fn enforceLogicalBlankLines(gpa: Allocator, input: []const u8) Allocator.Error![]u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(gpa);

    var line_start: usize = 0;
    while (line_start < input.len) {
        const line_end = mem.indexOfScalar(u8, input[line_start..], '\n') orelse input.len - line_start;
        try lines.append(gpa, input[line_start .. line_start + line_end]);
        line_start += line_end + 1;
    }

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(gpa);
    try output.ensureTotalCapacity(gpa, input.len + input.len / 8);

    var prev_was_blank = false;
    var prev_content: ?[]const u8 = null;

    for (lines.items, 0..) |line, i| {
        const trimmed = mem.trimStart(u8, mem.trimEnd(u8, line, " "), " ");
        const is_blank = trimmed.len == 0;

        if (is_blank) {
            if (prev_was_blank) continue;
            if (prev_content) |pc| {
                if (mem.endsWith(u8, pc, "{")) continue;
            }
            if (i + 1 < lines.items.len) {
                const next_trimmed = mem.trimStart(u8, mem.trimEnd(u8, lines.items[i + 1], " "), " ");
                if (next_trimmed.len > 0 and next_trimmed[0] == '}') continue;
            }

            try output.appendSlice(gpa, line);
            try output.append(gpa, '\n');
            prev_was_blank = true;
            continue;
        }

        if (prev_content) |pc| {
            if (!prev_was_blank and needsBlankAfter(pc) and !suppressesBlank(trimmed)) {
                try output.append(gpa, '\n');
            }
        }

        try output.appendSlice(gpa, line);
        try output.append(gpa, '\n');
        prev_was_blank = false;
        prev_content = trimmed;
    }

    return output.toOwnedSlice(gpa);
}

fn needsBlankAfter(prev_trimmed: []const u8) bool {
    if (prev_trimmed.len == 0) return false;

    if (prev_trimmed.len >= 1 and prev_trimmed[prev_trimmed.len - 1] == '}') {
        if (mem.eql(u8, prev_trimmed, "}") or
            mem.eql(u8, prev_trimmed, "};") or
            mem.endsWith(u8, prev_trimmed, "};") or
            mem.eql(u8, prev_trimmed, "}"))
        {
            return true;
        }
    }

    if (isFlowTerminator(prev_trimmed)) return true;

    return false;
}

fn isFlowTerminator(trimmed: []const u8) bool {
    if (mem.startsWith(u8, trimmed, "return ") or mem.eql(u8, trimmed, "return;")) return true;
    if (mem.startsWith(u8, trimmed, "continue ") or mem.eql(u8, trimmed, "continue;")) return true;
    if (mem.eql(u8, trimmed, "break;") or mem.startsWith(u8, trimmed, "break ")) return true;
    return false;
}

fn suppressesBlank(next_trimmed: []const u8) bool {
    if (next_trimmed.len == 0) return true;
    if (next_trimmed[0] == '}') return true;
    if (mem.startsWith(u8, next_trimmed, "} ")) return true;
    if (mem.startsWith(u8, next_trimmed, "else")) return true;
    if (mem.startsWith(u8, next_trimmed, "catch")) return true;
    if (next_trimmed[0] == ')') return true;
    return false;
}
