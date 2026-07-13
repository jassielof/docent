const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;

const types = @import("types.zig");
const ImportEntry = types.ImportEntry;
const sorter = @import("sorter.zig");
const Group = sorter.Group;
const SuperGroup = sorter.SuperGroup;
const SortedGroups = sorter.SortedGroups;

pub fn render(arena: Allocator, groups: SortedGroups, entries: []const ImportEntry) ![]const u8 {
    var output: std.ArrayList(u8) = .empty;

    var any = false;
    try renderSuperGroup(arena, &output, &groups.internal, entries, &any);

    // Single blank line before the public block — same gap as between
    // categories. An extra newline here would create a double blank line,
    // which Zig's AST renderer collapses back to one.
    if (superGroupHasEntries(&groups.public)) {
        try renderPublicGroup(arena, &output, &groups.public, entries, &any);
    }

    return output.toOwnedSlice(arena);
}

fn renderSuperGroup(arena: Allocator, output: *std.ArrayList(u8), sg: *const SuperGroup, entries: []const ImportEntry, any: *bool) !void {
    try renderGroupIfNonEmpty(arena, output, &sg.builtin_group, entries, any);
    try renderGroupIfNonEmpty(arena, output, &sg.stdlib_group, entries, any);

    for (sg.dep_keys.items) |key| {
        if (sg.dep_groups.getPtr(key)) |grp| {
            try renderGroupIfNonEmpty(arena, output, grp, entries, any);
        }
    }

    try renderGroupIfNonEmpty(arena, output, &sg.root_group, entries, any);
    try renderGroupIfNonEmpty(arena, output, &sg.file_group, entries, any);
    try renderGroupIfNonEmpty(arena, output, &sg.conditional_group, entries, any);
}

fn renderPublicGroup(arena: Allocator, output: *std.ArrayList(u8), sg: *const SuperGroup, entries: []const ImportEntry, any: *bool) !void {
    var pub_direct: std.ArrayList(usize) = .empty;
    for (sg.file_group.indices.items) |idx| {
        try pub_direct.append(arena, idx);
    }
    for (sg.builtin_group.indices.items) |idx| try pub_direct.append(arena, idx);
    for (sg.stdlib_group.indices.items) |idx| try pub_direct.append(arena, idx);
    for (sg.dep_keys.items) |key| {
        if (sg.dep_groups.getPtr(key)) |grp| {
            for (grp.indices.items) |idx| try pub_direct.append(arena, idx);
        }
    }
    for (sg.root_group.indices.items) |idx| try pub_direct.append(arena, idx);

    const S = struct {
        entries: []const ImportEntry,
        fn lessThan(ctx: @This(), a: usize, b: usize) bool {
            return cmpIgnoreCase(ctx.entries[a].right, ctx.entries[b].right) == .lt or
                (cmpIgnoreCase(ctx.entries[a].right, ctx.entries[b].right) == .eq and
                    cmpIgnoreCase(ctx.entries[a].left, ctx.entries[b].left) == .lt);
        }
    };
    mem.sort(usize, pub_direct.items, S{ .entries = entries }, S.lessThan);

    if (pub_direct.items.len > 0) {
        if (any.*) try output.append(arena, '\n');
        for (pub_direct.items) |idx| {
            try renderEntry(arena, output, entries, idx);
        }
        any.* = true;
    }

    for (sg.inline_field_keys.items) |key| {
        if (sg.inline_field_groups.getPtr(key)) |grp| {
            if (grp.indices.items.len > 0) {
                if (any.*) try output.append(arena, '\n');
                for (grp.indices.items) |idx| {
                    try renderEntry(arena, output, entries, idx);
                }
                any.* = true;
            }
        }
    }

    if (sg.conditional_group.indices.items.len > 0) {
        try renderGroupIfNonEmpty(arena, output, &sg.conditional_group, entries, any);
    }

    if (sg.reexport_group.indices.items.len > 0) {
        if (any.*) try output.append(arena, '\n');
        for (sg.reexport_group.indices.items) |idx| {
            try renderEntry(arena, output, entries, idx);
        }
        any.* = true;
    }
}

fn renderGroupIfNonEmpty(arena: Allocator, output: *std.ArrayList(u8), group: *const Group, entries: []const ImportEntry, any: *bool) !void {
    if (group.indices.items.len == 0) return;
    if (any.*) try output.append(arena, '\n');
    for (group.indices.items) |idx| {
        try renderEntry(arena, output, entries, idx);
    }
    any.* = true;
}

fn renderEntry(arena: Allocator, output: *std.ArrayList(u8), entries: []const ImportEntry, idx: usize) !void {
    const entry = entries[idx];
    for (entry.comment_lines) |comment| {
        try output.appendSlice(arena, comment);
        try output.append(arena, '\n');
    }
    try output.appendSlice(arena, entry.source_text);

    var children: std.ArrayList(usize) = .empty;
    for (entries, 0..) |other, other_idx| {
        if (other.parent) |p| {
            if (p == idx) try children.append(arena, other_idx);
        }
    }

    const S = struct {
        entries: []const ImportEntry,
        fn lessThan(ctx: @This(), a: usize, b: usize) bool {
            return cmpIgnoreCase(ctx.entries[a].left, ctx.entries[b].left) == .lt;
        }
    };
    mem.sort(usize, children.items, S{ .entries = entries }, S.lessThan);

    for (children.items) |child_idx| {
        try renderEntry(arena, output, entries, child_idx);
    }
}

fn superGroupHasEntries(sg: *const SuperGroup) bool {
    if (sg.builtin_group.indices.items.len > 0) return true;
    if (sg.stdlib_group.indices.items.len > 0) return true;
    if (sg.root_group.indices.items.len > 0) return true;
    if (sg.file_group.indices.items.len > 0) return true;
    if (sg.conditional_group.indices.items.len > 0) return true;
    if (sg.reexport_group.indices.items.len > 0) return true;
    if (sg.dep_keys.items.len > 0) return true;
    if (sg.inline_field_keys.items.len > 0) return true;
    return false;
}

fn cmpIgnoreCase(a: []const u8, b: []const u8) std.math.Order {
    const n = @min(a.len, b.len);
    for (a[0..n], b[0..n]) |ca, cb| {
        const la = std.ascii.toLower(ca);
        const lb = std.ascii.toLower(cb);
        if (la < lb) return .lt;
        if (la > lb) return .gt;
    }
    if (a.len < b.len) return .lt;
    if (a.len > b.len) return .gt;
    return .eq;
}
