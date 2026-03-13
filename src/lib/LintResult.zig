const std = @import("std");
const Diagnostic = @import("Diagnostic.zig");
const Severity = @import("Severity.zig");

allocator: std.mem.Allocator,
/// Owns all diagnostic message strings. Freed in bulk on deinit.
msg_arena: std.heap.ArenaAllocator,
diagnostics: std.ArrayList(Diagnostic) = .empty,

const LintResult = @This();

pub fn init(allocator: std.mem.Allocator) LintResult {
    return .{
        .allocator = allocator,
        .msg_arena = std.heap.ArenaAllocator.init(allocator),
    };
}

pub fn deinit(self: *LintResult) void {
    self.diagnostics.deinit(self.allocator);
    self.msg_arena.deinit();
}

/// Returns the allocator to use for diagnostic message strings.
/// Lifetime of returned strings is tied to this LintResult.
pub fn messageAllocator(self: *LintResult) std.mem.Allocator {
    return self.msg_arena.allocator();
}

pub fn hasErrors(self: *const LintResult) bool {
    for (self.diagnostics.items) |d| {
        if (d.severity.isError()) return true;
    }
    return false;
}

pub fn errorCount(self: *const LintResult) usize {
    var count: usize = 0;
    for (self.diagnostics.items) |d| {
        if (d.severity.isError()) count += 1;
    }
    return count;
}

pub fn warningCount(self: *const LintResult) usize {
    var count: usize = 0;
    for (self.diagnostics.items) |d| {
        if (d.severity == .warn) count += 1;
    }
    return count;
}
