//! The single_line_braces namespace contains the logic to wrap single-line control-flow bodies in braces.

const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;

/// The enforceBraces function wraps single-line control-flow bodies in braces.
///
/// Converts patterns like `if (cond) return;` into multi-line braced blocks.
/// Handles `if`, `else`, `while`, `for`, and their chained variants.
/// Already-braced bodies and `else if` chains are left unchanged.
pub fn enforceBraces(gpa: Allocator, input: []const u8) Allocator.Error![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(gpa);

    try output.ensureTotalCapacity(gpa, input.len + input.len / 4);

    var line_start: usize = 0;
    while (line_start < input.len) {
        const line_end = mem.indexOfScalar(u8, input[line_start..], '\n') orelse input.len - line_start;
        const full_line = input[line_start .. line_start + line_end];
        line_start += line_end + 1;

        const indent_len = leadingSpaces(full_line);
        const trimmed = mem.trimEnd(u8, full_line, " ");
        if (trimmed.len == 0) {
            try output.appendSlice(gpa, full_line);
            if (line_start <= input.len) try output.append(gpa, '\n');
            continue;
        }

        const content = full_line[indent_len..trimmed.len];
        const indent = full_line[0..indent_len];

        if (tryExpandSingleLine(gpa, &output, indent, content)) |expanded| {
            if (expanded) {
                if (line_start <= input.len) try output.append(gpa, '\n');
                continue;
            }
        } else |_| return error.OutOfMemory;

        try output.appendSlice(gpa, full_line);
        if (line_start <= input.len) try output.append(gpa, '\n');
    }

    return output.toOwnedSlice(gpa);
}

const keywords = [_][]const u8{ "if ", "while ", "for " };

fn tryExpandSingleLine(gpa: Allocator, output: *std.ArrayList(u8), indent: []const u8, content: []const u8) !bool {
    if (content.len == 0) return false;

    if (mem.startsWith(u8, content, "} else ")) {
        const after_else = content[7..];
        if (after_else.len == 0) return false;
        if (after_else[0] == '{') return false;

        for (keywords) |kw| {
            if (mem.startsWith(u8, after_else, kw)) return false;
        }

        try output.appendSlice(gpa, indent);
        try output.appendSlice(gpa, "} else {");
        try output.append(gpa, '\n');
        try output.appendSlice(gpa, indent);
        try output.appendSlice(gpa, "    ");
        try output.appendSlice(gpa, after_else);
        try output.append(gpa, '\n');
        try output.appendSlice(gpa, indent);
        try output.append(gpa, '}');
        return true;
    }

    for (keywords) |kw| {
        if (!mem.startsWith(u8, content, kw)) continue;

        const body_start = findBodyStart(content) orelse continue;
        const body = content[body_start..];
        if (body.len == 0 or body[0] == '{') continue;

        if (mem.startsWith(u8, content, "if ")) {
            if (findInlineElse(body)) |else_offset| {
                const if_body = body[0..else_offset];
                const after_else = else_offset + 5;
                const else_body_start = if (after_else < body.len and body[after_else] == ' ') after_else + 1 else after_else;
                const else_body = body[else_body_start..];

                try output.appendSlice(gpa, indent);
                try output.appendSlice(gpa, content[0..body_start]);
                try output.append(gpa, '{');
                try output.append(gpa, '\n');
                try output.appendSlice(gpa, indent);
                try output.appendSlice(gpa, "    ");
                try output.appendSlice(gpa, if_body);
                try output.append(gpa, '\n');
                try output.appendSlice(gpa, indent);
                try output.appendSlice(gpa, "} else {");
                try output.append(gpa, '\n');
                try output.appendSlice(gpa, indent);
                try output.appendSlice(gpa, "    ");
                try output.appendSlice(gpa, else_body);
                try output.append(gpa, '\n');
                try output.appendSlice(gpa, indent);
                try output.append(gpa, '}');
                return true;
            }
        }

        try output.appendSlice(gpa, indent);
        try output.appendSlice(gpa, content[0..body_start]);
        try output.append(gpa, '{');
        try output.append(gpa, '\n');
        try output.appendSlice(gpa, indent);
        try output.appendSlice(gpa, "    ");
        try output.appendSlice(gpa, body);
        try output.append(gpa, '\n');
        try output.appendSlice(gpa, indent);
        try output.append(gpa, '}');
        return true;
    }

    return false;
}

/// Finds where the body starts after a control-flow condition.
/// Skips past balanced parentheses to find the body portion.
fn findBodyStart(content: []const u8) ?usize {
    var i: usize = 0;
    while (i < content.len and content[i] != '(') : (i += 1) {}
    if (i >= content.len) return null;

    var depth: usize = 0;
    while (i < content.len) : (i += 1) {
        if (content[i] == '(') {
            depth += 1;
        } else if (content[i] == ')') {
            depth -= 1;
            if (depth == 0) {
                i += 1;
                break;
            }
        }
    }

    while (i < content.len and content[i] == ' ') : (i += 1) {}

    if (i < content.len and content[i] == '|') {
        while (i < content.len and content[i] != ' ') : (i += 1) {}
        while (i < content.len and content[i] == ' ') : (i += 1) {}
    }

    if (i >= content.len) return null;
    return i;
}

/// Finds ` else ` in a body string, skipping over balanced parentheses.
fn findInlineElse(body: []const u8) ?usize {
    var i: usize = 0;
    var depth: usize = 0;
    while (i < body.len) : (i += 1) {
        if (body[i] == '(') {
            depth += 1;
        } else if (body[i] == ')') {
            if (depth > 0) depth -= 1;
        } else if (depth == 0 and i + 5 <= body.len) {
            if (mem.eql(u8, body[i .. i + 5], " else")) {
                if (i + 5 == body.len or body[i + 5] == ' ') return i;
            }
        }
    }
    return null;
}

fn leadingSpaces(line: []const u8) usize {
    for (line, 0..) |c, i| {
        if (c != ' ') return i;
    }
    return line.len;
}
