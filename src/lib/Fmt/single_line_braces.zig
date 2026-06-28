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
    var all_lines: std.ArrayList([]const u8) = .empty;
    defer all_lines.deinit(gpa);
    {
        var pos: usize = 0;
        while (pos < input.len) {
            const end = mem.indexOfScalar(u8, input[pos..], '\n') orelse input.len - pos;
            try all_lines.append(gpa, input[pos .. pos + end]);
            pos += end + 1;
        }
    }

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(gpa);
    try output.ensureTotalCapacity(gpa, input.len + input.len / 4);

    var li: usize = 0;
    while (li < all_lines.items.len) {
        const full_line = all_lines.items[li];
        const indent_len = leadingSpaces(full_line);
        const trimmed = mem.trimEnd(u8, full_line, " ");

        if (trimmed.len == 0) {
            try output.appendSlice(gpa, full_line);
            try output.append(gpa, '\n');
            li += 1;
            continue;
        }

        const content = full_line[indent_len..trimmed.len];
        const indent = full_line[0..indent_len];

        if (tryExpandSingleLine(gpa, &output, indent, content)) |expanded| {
            if (expanded) {
                try output.append(gpa, '\n');
                li += 1;
                continue;
            }
        } else |_| return error.OutOfMemory;

        const consumed = try tryExpandMultiLine(gpa, &output, all_lines.items, li);
        if (consumed > 0) {
            li += consumed;
            continue;
        }

        try output.appendSlice(gpa, full_line);
        try output.append(gpa, '\n');
        li += 1;
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
                const needs_semi = if_body.len > 0 and if_body[if_body.len - 1] != ';';

                try output.appendSlice(gpa, indent);
                try output.appendSlice(gpa, content[0..body_start]);
                try output.append(gpa, '{');
                try output.append(gpa, '\n');
                try output.appendSlice(gpa, indent);
                try output.appendSlice(gpa, "    ");
                try output.appendSlice(gpa, if_body);
                if (needs_semi) try output.append(gpa, ';');
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

/// Handles multi-line unbraced control flow, e.g.:
/// ```
///   const x = if (CONDITION)
///       BODY
///   else
///       OTHER_BODY;
/// ```
fn tryExpandMultiLine(gpa: Allocator, output: *std.ArrayList(u8), lines: []const []const u8, start: usize) !usize {
    const first = lines[start];
    const indent_len = leadingSpaces(first);
    const trimmed = mem.trimEnd(u8, first, " ");
    const content = first[indent_len..trimmed.len];
    const indent = first[0..indent_len];

    const has_assign = mem.indexOf(u8, content, " = ") != null;
    if (!has_assign) return 0;

    const if_pos = mem.indexOf(u8, content, "if (") orelse return 0;
    const after_if = content[if_pos..];

    const body_start_opt = findBodyStart(after_if);
    if (body_start_opt) |bs| {
        if (bs < after_if.len) return 0;
    }
    const header_end = if_pos + (body_start_opt orelse after_if.len);

    if (start + 1 >= lines.len) return 0;

    const body_line_raw = lines[start + 1];
    const body_trimmed = mem.trimStart(u8, mem.trimEnd(u8, body_line_raw, " "), " ");
    if (body_trimmed.len == 0 or body_trimmed[0] == '{') return 0;

    var consumed: usize = 2;

    var else_line_raw: ?[]const u8 = null;
    var else_body_raw: ?[]const u8 = null;

    if (start + 2 < lines.len) {
        const candidate = mem.trimStart(u8, mem.trimEnd(u8, lines[start + 2], " "), " ");
        if (mem.eql(u8, candidate, "else")) {
            else_line_raw = lines[start + 2];
            consumed = 3;
            if (start + 3 < lines.len) {
                else_body_raw = lines[start + 3];
                consumed = 4;
            }
        }
    }

    try output.appendSlice(gpa, indent);
    try output.appendSlice(gpa, content[0..header_end]);
    try output.appendSlice(gpa, " {\n");

    try output.appendSlice(gpa, indent);
    try output.appendSlice(gpa, "    ");
    const body_needs_semi = body_trimmed.len > 0 and body_trimmed[body_trimmed.len - 1] != ';' and else_line_raw != null;
    try output.appendSlice(gpa, body_trimmed);
    if (body_needs_semi) try output.append(gpa, ';');
    try output.append(gpa, '\n');

    if (else_line_raw != null) {
        try output.appendSlice(gpa, indent);
        try output.appendSlice(gpa, "} else {\n");

        if (else_body_raw) |eb| {
            const eb_trimmed = mem.trimStart(u8, mem.trimEnd(u8, eb, " "), " ");
            try output.appendSlice(gpa, indent);
            try output.appendSlice(gpa, "    ");
            try output.appendSlice(gpa, eb_trimmed);
            try output.append(gpa, '\n');
        }

        try output.appendSlice(gpa, indent);
        try output.appendSlice(gpa, "};\n");
    } else {
        try output.appendSlice(gpa, indent);
        try output.appendSlice(gpa, "}\n");
    }

    return consumed;
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
