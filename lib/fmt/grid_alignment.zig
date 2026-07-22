//! Grid alignment: column-align `:` and `=` in contiguous field/decl groups.
//!
//! Zig's AST renderer left-flushes identifiers, so this pass must stay
//! opt-in and is re-applied every format run when enabled. Operates on
//! already-rendered source as a text transform.
//!
//! MVP scopes:
//! - Contiguous struct/enum field lines (`name: Type` / `name: Type = value`)
//! - Contiguous `const`/`var`/`pub const` declaration runs
//! - Multi-line function parameter lists (one param per line)
//!
//! Not in scope: aligning trailing comments, or fighting brace style.

const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;

const format_test_assertions = @import("format_test_assertions.zig");

const AlignKind = enum {
    colon,
    equals,
    none,
};

const LineInfo = struct {
    raw: []const u8,
    kind: AlignKind,
    /// Byte index of `:` or `=` within `raw` (first alignment target).
    target: usize,
    /// For `name: Type = value`, also align `=` after the type.
    equals_after_colon: ?usize = null,
};

test "aligns fields and declarations" {
    const gpa = std.testing.allocator;
    const input =
        \\const std = @import("std");
        \\
        \\const Point = struct {
        \\    x: i32,
        \\    longer_name: i32,
        \\    z: i32 = 0,
        \\};
        \\
        \\const a = 1;
        \\const longer = 2;
        \\const b = 3;
        \\
    ;
    const expected =
        \\const std = @import("std");
        \\
        \\const Point = struct {
        \\    x          : i32,
        \\    longer_name: i32,
        \\    z          : i32 = 0,
        \\};
        \\
        \\const a      = 1;
        \\const longer = 2;
        \\const b      = 3;
        \\
    ;

    const formatted = try alignGrid(gpa, input);
    defer gpa.free(formatted);
    try std.testing.expectEqualStrings(expected, formatted);
    try format_test_assertions.expectValidZig(formatted);

    const formatted_expected = try alignGrid(gpa, expected);
    defer gpa.free(formatted_expected);
    try format_test_assertions.expectIdempotent(expected, formatted_expected);
}

test "does not alter a single-line group" {
    const gpa = std.testing.allocator;
    const expected =
        \\const only = 1;
        \\
    ;

    const formatted = try alignGrid(gpa, expected);
    defer gpa.free(formatted);
    try std.testing.expectEqualStrings(expected, formatted);
    try format_test_assertions.expectValidZig(formatted);

    const formatted_expected = try alignGrid(gpa, expected);
    defer gpa.free(formatted_expected);
    try format_test_assertions.expectIdempotent(expected, formatted_expected);
}

/// Aligns `:` / `=` columns in contiguous groups. Caller owns the returned slice.
pub fn alignGrid(gpa: Allocator, input: []const u8) Allocator.Error![]u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(gpa);

    var line_start: usize = 0;
    while (line_start < input.len) {
        const rel_end = mem.indexOfScalar(
            u8,
            input[line_start..],
            '\n',
        ) orelse input.len - line_start;
        try lines.append(gpa, input[line_start .. line_start + rel_end]);
        line_start += rel_end + 1;
    }

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(gpa);
    try output.ensureTotalCapacity(gpa, input.len + input.len / 8);

    var i: usize = 0;
    while (i < lines.items.len) {
        const info = classifyLine(lines.items[i]);
        if (info.kind == .none) {
            try output.appendSlice(gpa, lines.items[i]);
            try output.append(gpa, '\n');
            i += 1;
            continue;
        }

        // Collect contiguous group of the same kind (colon groups can mix
        // colon-only and colon+equals; equals-only groups are separate).
        const group_kind = info.kind;
        var group_end = i + 1;
        while (group_end < lines.items.len) {
            const next = classifyLine(lines.items[group_end]);
            if (next.kind != group_kind) break;
            // Blank line breaks the group.
            if (mem.trim(
                u8,
                lines.items[group_end],
                " \t",
            ).len == 0) break;
            group_end += 1;
        }

        if (group_end - i >= 2) {
            try emitAlignedGroup(
                gpa,
                &output,
                lines.items[i..group_end],
                group_kind,
            );
        } else {
            try output.appendSlice(gpa, lines.items[i]);
            try output.append(gpa, '\n');
            group_end = i + 1;
        }
        i = group_end;
    }

    // Match input trailing-newline behavior: if input had no trailing newline
    // and we always appended `\n`, strip the final one when original lacked it.
    if (input.len == 0) return output.toOwnedSlice(gpa);
    if (input[input.len - 1] != '\n' and output.items.len > 0 and output.items[output.items.len - 1] == '\n') {
        _ = output.pop();
    }

    return output.toOwnedSlice(gpa);
}

fn emitAlignedGroup(
    gpa: Allocator,
    output: *std.ArrayList(u8),
    group: []const []const u8,
    kind: AlignKind,
) !void {
    var infos: std.ArrayList(LineInfo) = .empty;
    defer infos.deinit(gpa);

    var max_before: usize = 0;
    var max_between_colon_eq: usize = 0;
    var any_equals_after: bool = false;

    for (group) |raw| {
        const info = classifyLine(raw);
        try infos.append(gpa, info);
        const before = displayWidth(raw[0..info.target]);
        if (before > max_before) max_before = before;
        if (info.equals_after_colon) |eq| {
            any_equals_after = true;
            // Width of type part between `: ` and `=`.
            const after_colon = eq;
            // Skip ": " (colon + optional spaces already at target).
            var type_start = info.target + 1;
            while (type_start < after_colon and raw[type_start] == ' ') type_start += 1;
            const type_width = displayWidth(raw[type_start..after_colon]);
            if (type_width > max_between_colon_eq) max_between_colon_eq = type_width;
        }
    }

    for (infos.items) |info| {
        const raw = info.raw;
        // Left part up to (but not including) the alignment target.
        try output.appendSlice(gpa, raw[0..info.target]);
        const before = displayWidth(raw[0..info.target]);
        try appendSpaces(
            gpa,
            output,
            max_before - before,
        );
        try output.append(gpa, raw[info.target]); // ':' or '='

        if (kind == .colon) {
            // Ensure single space after colon.
            var rest_start = info.target + 1;
            while (rest_start < raw.len and raw[rest_start] == ' ') rest_start += 1;

            if (info.equals_after_colon) |eq| {
                try output.append(gpa, ' ');
                const type_part = raw[rest_start..eq];
                try output.appendSlice(gpa, type_part);
                if (any_equals_after) {
                    const type_width = displayWidth(type_part);
                    try appendSpaces(
                        gpa,
                        output,
                        max_between_colon_eq - type_width,
                    );
                }
                var after_eq = eq + 1;
                while (after_eq < raw.len and raw[after_eq] == ' ') after_eq += 1;
                try output.append(gpa, '=');
                try output.append(gpa, ' ');
                try output.appendSlice(gpa, raw[after_eq..]);
            } else {
                try output.append(gpa, ' ');
                try output.appendSlice(gpa, raw[rest_start..]);
            }
        } else {
            // equals-only: single space after '='.
            var rest_start = info.target + 1;
            while (rest_start < raw.len and raw[rest_start] == ' ') rest_start += 1;
            try output.append(gpa, ' ');
            try output.appendSlice(gpa, raw[rest_start..]);
        }

        try output.append(gpa, '\n');
    }
}

fn classifyLine(raw: []const u8) LineInfo {
    const trimmed = mem.trim(
        u8,
        raw,
        " \t",
    );
    if (trimmed.len == 0) return .{
        .raw = raw,
        .kind = .none,
        .target = 0,
    };
    if (mem.startsWith(
        u8,
        trimmed,
        "//",
    ) or mem.startsWith(
        u8,
        trimmed,
        "///",
    ) or mem.startsWith(
        u8,
        trimmed,
        "//!",
    )) {
        return .{
            .raw = raw,
            .kind = .none,
            .target = 0,
        };
    }

    // Multi-line function params: `name: Type,` or `name: Type`
    // Struct fields: same pattern, optionally with `= value,`
    // Declarations: `const name = value;` / `pub const name = value;`

    if (findTopLevelChar(raw, ':')) |colon| {
        // Avoid `::` or labels in weird places — require identifier-ish before colon.
        if (colon > 0 and isIdentChar(raw[colon - 1])) {
            const eq_after = findTopLevelCharFrom(
                raw,
                '=',
                colon + 1,
            );
            return .{
                .raw = raw,
                .kind = .colon,
                .target = colon,
                .equals_after_colon = eq_after,
            };
        }
    }

    // `const`/`var`/`comptime` decls with `=`.
    if (looksLikeDecl(trimmed)) {
        if (findTopLevelChar(raw, '=')) |eq| {
            return .{
                .raw = raw,
                .kind = .equals,
                .target = eq,
            };
        }
    }

    return .{
        .raw = raw,
        .kind = .none,
        .target = 0,
    };
}

fn looksLikeDecl(trimmed: []const u8) bool {
    const prefixes = [_][]const u8{
        "pub const ",
        "pub var ",
        "const ",
        "var ",
        "comptime ",
    };
    for (prefixes) |p| {
        if (mem.startsWith(
            u8,
            trimmed,
            p,
        )) return true;
    }
    return false;
}

fn findTopLevelChar(line: []const u8, needle: u8) ?usize {
    return findTopLevelCharFrom(
        line,
        needle,
        0,
    );
}

fn findTopLevelCharFrom(
    line: []const u8,
    needle: u8,
    start: usize,
) ?usize {
    var depth_paren: usize = 0;
    var depth_brace: usize = 0;
    var depth_bracket: usize = 0;
    var i = start;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (c == '/' and i + 1 < line.len and line[i + 1] == '/') break;
        if (c == '\'' or c == '"') {
            i = skipStringLiteral(line, i) - 1;
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
            '[' => depth_bracket += 1,
            ']' => {
                if (depth_bracket > 0) depth_bracket -= 1;
            },
            else => {
                if (c == needle and depth_paren == 0 and depth_brace == 0 and depth_bracket == 0) {
                    return i;
                }
            },
        }
    }
    return null;
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn displayWidth(s: []const u8) usize {
    // ASCII-oriented: byte length is fine for Zig source identifiers.
    return s.len;
}

fn appendSpaces(
    gpa: Allocator,
    output: *std.ArrayList(u8),
    count: usize,
) !void {
    var j: usize = 0;
    while (j < count) : (j += 1) {
        try output.append(gpa, ' ');
    }
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
