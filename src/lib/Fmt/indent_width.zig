const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;

/// Re-indents source from the standard 4-space width to the target width.
///
/// Only leading whitespace is affected. Each group of 4 consecutive leading
/// spaces is replaced with `target_width` spaces. Partial groups (trailing
/// spaces that don't complete a full indent level) are preserved as-is.
pub fn reindent(gpa: Allocator, input: []const u8, target_width: u8) Allocator.Error![]u8 {
    std.debug.assert(target_width > 0);
    if (target_width == 4) {
        return gpa.dupe(u8, input);
    }

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(gpa);

    const estimate: usize = if (target_width > 4)
        input.len + input.len / 4
    else
        input.len;
    try output.ensureTotalCapacity(gpa, estimate);

    var line_start: usize = 0;
    while (line_start < input.len) {
        const line_end = mem.indexOfScalar(u8, input[line_start..], '\n') orelse input.len - line_start;
        const full_line = input[line_start .. line_start + line_end];
        line_start += line_end + 1;

        const leading = leadingSpaces(full_line);
        const levels = leading / 4;
        const remainder = leading % 4;

        var i: usize = 0;
        while (i < levels) : (i += 1) {
            var j: u8 = 0;
            while (j < target_width) : (j += 1) {
                try output.append(gpa, ' ');
            }
        }

        i = 0;
        while (i < remainder) : (i += 1) {
            try output.append(gpa, ' ');
        }

        try output.appendSlice(gpa, full_line[leading..]);
        if (line_start <= input.len) try output.append(gpa, '\n');
    }

    return output.toOwnedSlice(gpa);
}

fn leadingSpaces(line: []const u8) usize {
    for (line, 0..) |c, i| {
        if (c != ' ') return i;
    }
    return line.len;
}
