const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;

/// Sorts the leading top-level import block by const identifier.
///
/// Imports are regrouped into three blank-line-separated categories:
/// 1. `std` / `builtin` (the reserved standard imports)
/// 2. dependencies (named modules from the build script, e.g. `fangz`, `toml`)
/// 3. local (relative paths, `.zig` files, and the reserved `root` module)
///
/// Within each category, imports are sorted case-insensitively by their const
/// identifier. Import aliases (e.g. `const Ast = std.zig.Ast;`) are placed
/// directly beneath the import they derive from, sorted among themselves.
///
/// Only the contiguous leading block is touched; re-exports and aliases that
/// appear below real code are left untouched.
pub fn sortImports(gpa: Allocator, input: []const u8) Allocator.Error![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var lines: std.ArrayList([]const u8) = .empty;
    {
        var line_start: usize = 0;
        while (line_start < input.len) {
            const line_end = mem.indexOfScalar(u8, input[line_start..], '\n') orelse input.len - line_start;
            try lines.append(arena, input[line_start .. line_start + line_end]);
            line_start += line_end + 1;
        }
    }
    const had_trailing_newline = input.len > 0 and input[input.len - 1] == '\n';

    const first_import = findFirstImport(lines.items) orelse return gpa.dupe(u8, input);

    // Back up over comment lines attached to the first import.
    var region_start = first_import;
    while (region_start > 0 and isAttachableComment(lines.items[region_start - 1])) {
        region_start -= 1;
    }

    var items: std.ArrayList(Decl) = .empty;
    var binding_index = std.StringHashMap(usize).init(arena);

    var pending: std.ArrayList([]const u8) = .empty;
    var i = region_start;
    var region_end: usize = lines.items.len;

    while (i < lines.items.len) {
        const line = lines.items[i];
        const trimmed = mem.trimStart(u8, mem.trimEnd(u8, line, " \t"), " \t");

        if (trimmed.len == 0) {
            if (pending.items.len > 0) {
                region_end = i - pending.items.len;
                pending.clearRetainingCapacity();
                break;
            }
            i += 1;
            continue;
        }

        if (isAttachableComment(line)) {
            try pending.append(arena, line);
            i += 1;
            continue;
        }

        if (parseDecl(line)) |decl| {
            if (decl.import_str != null) {
                try binding_index.put(decl.binding, items.items.len);
                try items.append(arena, .{
                    .binding = decl.binding,
                    .line = line,
                    .comments = try pending.toOwnedSlice(arena),
                    .import_str = decl.import_str,
                    .category = categorize(decl.import_str.?),
                    .head = "",
                    .aliases = .empty,
                });
                pending = .empty;
                i += 1;
                continue;
            }

            // Potential alias: only counts if its head names a known binding.
            if (decl.head.len > 0 and binding_index.contains(decl.head)) {
                try binding_index.put(decl.binding, items.items.len);
                try items.append(arena, .{
                    .binding = decl.binding,
                    .line = line,
                    .comments = try pending.toOwnedSlice(arena),
                    .import_str = null,
                    .category = .local,
                    .head = decl.head,
                    .aliases = .empty,
                });
                pending = .empty;
                i += 1;
                continue;
            }
        }

        // Anything else ends the region; pending comments belong to it.
        region_end = i - pending.items.len;
        break;
    } else {
        // Loop finished without a break: trailing comments belong to the rest.
        region_end = lines.items.len - pending.items.len;
    }

    // Attach each alias to its root import.
    for (items.items, 0..) |item, idx| {
        if (item.import_str != null) continue;
        if (resolveRootImport(items.items, binding_index, idx)) |root_idx| {
            try items.items[root_idx].aliases.append(arena, idx);
        }
    }

    var out_lines: std.ArrayList([]const u8) = .empty;

    // Prefix: untouched lines before the region.
    for (lines.items[0..region_start]) |line| try out_lines.append(arena, line);

    const categories = [_]Category{ .std_lib, .dependency, .local };
    var first_group = true;
    for (categories) |cat| {
        var group: std.ArrayList(usize) = .empty;
        for (items.items, 0..) |item, idx| {
            if (item.import_str != null and item.category == cat) try group.append(arena, idx);
        }
        if (group.items.len == 0) continue;

        sortByBinding(items.items, group.items);

        if (!first_group) try out_lines.append(arena, "");
        first_group = false;

        for (group.items) |idx| {
            const imp = items.items[idx];
            for (imp.comments) |c| try out_lines.append(arena, c);
            try out_lines.append(arena, imp.line);

            sortByBinding(items.items, imp.aliases.items);
            for (imp.aliases.items) |alias_idx| {
                const alias = items.items[alias_idx];
                for (alias.comments) |c| try out_lines.append(arena, c);
                try out_lines.append(arena, alias.line);
            }
        }
    }

    // Rest: skip leading blank lines, then keep one separator.
    var rest_start = region_end;
    while (rest_start < lines.items.len and isBlank(lines.items[rest_start])) rest_start += 1;
    if (rest_start < lines.items.len) {
        if (!first_group) try out_lines.append(arena, "");
        for (lines.items[rest_start..]) |line| try out_lines.append(arena, line);
    }

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(gpa);
    for (out_lines.items, 0..) |line, idx| {
        if (idx > 0) try output.append(gpa, '\n');
        try output.appendSlice(gpa, line);
    }
    if (had_trailing_newline) try output.append(gpa, '\n');

    return output.toOwnedSlice(gpa);
}

const Category = enum(u2) { std_lib = 0, dependency = 1, local = 2 };

const Decl = struct {
    binding: []const u8,
    line: []const u8,
    comments: [][]const u8,
    import_str: ?[]const u8,
    category: Category,
    head: []const u8,
    aliases: std.ArrayList(usize),
};

const ParsedDecl = struct {
    binding: []const u8,
    import_str: ?[]const u8,
    head: []const u8,
};

fn findFirstImport(lines: []const []const u8) ?usize {
    for (lines, 0..) |line, i| {
        const decl = parseDecl(line) orelse continue;
        if (decl.import_str != null) return i;
    }
    return null;
}

/// Parses `(pub )?const IDENT = RHS;` returning the binding and either the
/// `@import` string (for imports) or the RHS head identifier (for aliases).
fn parseDecl(line: []const u8) ?ParsedDecl {
    var s = mem.trimStart(u8, mem.trimEnd(u8, line, " \t"), " \t");

    if (mem.startsWith(u8, s, "pub ")) s = s[4..];
    if (!mem.startsWith(u8, s, "const ")) return null;
    s = s[6..];

    const eq = mem.indexOfScalar(u8, s, '=') orelse return null;
    const binding = mem.trimEnd(u8, s[0..eq], " \t");
    if (binding.len == 0 or !isIdentifier(binding)) return null;

    var rhs = mem.trimStart(u8, s[eq + 1 ..], " \t");
    const semi = mem.indexOfScalar(u8, rhs, ';') orelse return null;
    rhs = mem.trimEnd(u8, rhs[0..semi], " \t");
    if (rhs.len == 0) return null;

    if (mem.startsWith(u8, rhs, "@import(")) {
        const inner = rhs["@import(".len..];
        const q1 = mem.indexOfScalar(u8, inner, '"') orelse return null;
        const after = inner[q1 + 1 ..];
        const q2 = mem.indexOfScalar(u8, after, '"') orelse return null;
        return .{ .binding = binding, .import_str = after[0..q2], .head = "" };
    }

    return .{ .binding = binding, .import_str = null, .head = leadingIdentifier(rhs) };
}

fn resolveRootImport(items: []const Decl, binding_index: std.StringHashMap(usize), start: usize) ?usize {
    var idx = start;
    var guard: usize = 0;
    while (items[idx].import_str == null) {
        const next = binding_index.get(items[idx].head) orelse return null;
        idx = next;
        guard += 1;
        if (guard > items.len) return null;
    }
    return idx;
}

fn categorize(import_str: []const u8) Category {
    if (mem.eql(u8, import_str, "std") or mem.eql(u8, import_str, "builtin")) return .std_lib;
    if (mem.eql(u8, import_str, "root")) return .local;
    if (mem.indexOfScalar(u8, import_str, '/') != null) return .local;
    if (import_str.len > 0 and import_str[0] == '.') return .local;
    if (mem.endsWith(u8, import_str, ".zig")) return .local;
    return .dependency;
}

fn sortByBinding(items: []const Decl, indices: []usize) void {
    std.mem.sort(usize, indices, items, lessThanBinding);
}

fn lessThanBinding(items: []const Decl, a: usize, b: usize) bool {
    return lessThanIgnoreCase(items[a].binding, items[b].binding);
}

fn lessThanIgnoreCase(a: []const u8, b: []const u8) bool {
    const n = @min(a.len, b.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const ca = std.ascii.toLower(a[i]);
        const cb = std.ascii.toLower(b[i]);
        if (ca != cb) return ca < cb;
    }
    return a.len < b.len;
}

fn leadingIdentifier(s: []const u8) []const u8 {
    var end: usize = 0;
    while (end < s.len and isIdentChar(s[end])) : (end += 1) {}
    return s[0..end];
}

fn isIdentifier(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (!isIdentChar(c)) return false;
    }
    return true;
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn isAttachableComment(line: []const u8) bool {
    const t = mem.trimStart(u8, mem.trimEnd(u8, line, " \t"), " \t");
    if (!mem.startsWith(u8, t, "//")) return false;
    // Module doc comments (`//!`) are file-level; never attach them.
    if (mem.startsWith(u8, t, "//!")) return false;
    return true;
}

fn isBlank(line: []const u8) bool {
    return mem.trimStart(u8, mem.trimEnd(u8, line, " \t"), " \t").len == 0;
}
