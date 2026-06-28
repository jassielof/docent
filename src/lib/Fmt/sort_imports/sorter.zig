const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;

const types = @import("types.zig");
const ImportEntry = types.ImportEntry;
const SourceKind = types.SourceKind;
const Visibility = types.Visibility;
const ImportShape = types.ImportShape;

pub const Group = struct {
    indices: std.ArrayList(usize),
};

pub const SortedGroups = struct {
    internal: SuperGroup,
    public: SuperGroup,
};

pub const SuperGroup = struct {
    builtin_group: Group,
    stdlib_group: Group,
    dep_keys: std.ArrayList([]const u8),
    dep_groups: std.StringHashMap(Group),
    root_group: Group,
    file_group: Group,
    conditional_group: Group,
    inline_field_keys: std.ArrayList([]const u8),
    inline_field_groups: std.StringHashMap(Group),
    reexport_group: Group,
};

pub fn buildGroups(arena: Allocator, entries: []const ImportEntry) !SortedGroups {
    var result = SortedGroups{
        .internal = initSuperGroup(arena),
        .public = initSuperGroup(arena),
    };

    for (entries, 0..) |entry, idx| {
        if (entry.parent != null) continue;

        const sg = if (entry.visibility == .public) &result.public else &result.internal;

        switch (entry.kind) {
            .builtin_mod => try sg.builtin_group.indices.append(arena, idx),
            .stdlib => try sg.stdlib_group.indices.append(arena, idx),
            .dependency => {
                const key = if (entry.module.len > 0) entry.module else entry.right;
                if (!sg.dep_groups.contains(key)) {
                    try sg.dep_groups.put(key, .{ .indices = .empty });
                    try sg.dep_keys.append(arena, key);
                }
                var grp = sg.dep_groups.getPtr(key).?;
                try grp.indices.append(arena, idx);
            },
            .root_mod => try sg.root_group.indices.append(arena, idx),
            .file => {
                if (entry.shape == .inline_field) {
                    const key = entry.module;
                    if (!sg.inline_field_groups.contains(key)) {
                        try sg.inline_field_groups.put(key, .{ .indices = .empty });
                        try sg.inline_field_keys.append(arena, key);
                    }
                    var grp = sg.inline_field_groups.getPtr(key).?;
                    try grp.indices.append(arena, idx);
                } else if (entry.shape == .reexport) {
                    try sg.reexport_group.indices.append(arena, idx);
                } else {
                    try sg.file_group.indices.append(arena, idx);
                }
            },
            .conditional => try sg.conditional_group.indices.append(arena, idx),
        }
    }

    sortSuperGroup(&result.internal, entries);
    sortSuperGroup(&result.public, entries);

    return result;
}

fn initSuperGroup(arena: Allocator) SuperGroup {
    return .{
        .builtin_group = .{ .indices = .empty },
        .stdlib_group = .{ .indices = .empty },
        .dep_keys = .empty,
        .dep_groups = std.StringHashMap(Group).init(arena),
        .root_group = .{ .indices = .empty },
        .file_group = .{ .indices = .empty },
        .conditional_group = .{ .indices = .empty },
        .inline_field_keys = .empty,
        .inline_field_groups = std.StringHashMap(Group).init(arena),
        .reexport_group = .{ .indices = .empty },
    };
}

fn sortSuperGroup(sg: *SuperGroup, entries: []const ImportEntry) void {
    sortGroupByLeft(sg.builtin_group.indices.items, entries);
    sortGroupByLeft(sg.stdlib_group.indices.items, entries);
    sortGroupByLeft(sg.root_group.indices.items, entries);
    sortGroupByRight(sg.file_group.indices.items, entries);
    sortGroupByLeft(sg.conditional_group.indices.items, entries);
    sortGroupByLeft(sg.reexport_group.indices.items, entries);

    mem.sort([]const u8, sg.dep_keys.items, {}, lessThanIgnoreCaseCtx);
    for (sg.dep_keys.items) |key| {
        if (sg.dep_groups.getPtr(key)) |grp| {
            sortGroupByLeft(grp.indices.items, entries);
        }
    }

    mem.sort([]const u8, sg.inline_field_keys.items, {}, lessThanIgnoreCaseCtx);
    for (sg.inline_field_keys.items) |key| {
        if (sg.inline_field_groups.getPtr(key)) |grp| {
            sortGroupByLeft(grp.indices.items, entries);
        }
    }
}

fn sortGroupByLeft(indices: []usize, entries: []const ImportEntry) void {
    const S = struct {
        entries: []const ImportEntry,
        fn lessThan(ctx: @This(), a: usize, b: usize) bool {
            return lessThanIgnoreCase(ctx.entries[a].left, ctx.entries[b].left);
        }
    };
    mem.sort(usize, indices, S{ .entries = entries }, S.lessThan);
}

fn sortGroupByRight(indices: []usize, entries: []const ImportEntry) void {
    const S = struct {
        entries: []const ImportEntry,
        fn lessThan(ctx: @This(), a: usize, b: usize) bool {
            const cmp = cmpIgnoreCase(ctx.entries[a].right, ctx.entries[b].right);
            if (cmp != .eq) return cmp == .lt;
            return lessThanIgnoreCase(ctx.entries[a].left, ctx.entries[b].left);
        }
    };
    mem.sort(usize, indices, S{ .entries = entries }, S.lessThan);
}

fn lessThanIgnoreCaseCtx(_: void, a: []const u8, b: []const u8) bool {
    return lessThanIgnoreCase(a, b);
}

fn lessThanIgnoreCase(a: []const u8, b: []const u8) bool {
    return cmpIgnoreCase(a, b) == .lt;
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
