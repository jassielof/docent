//! Aggregated diagnostics produced by linting one or more source files.

const std = @import("std");
const Diagnostic = @import("Diagnostic.zig");
const severity = @import("severity.zig");

/// Allocator used for the diagnostics list. Not used for message strings.
allocator: std.mem.Allocator,
/// Owns all diagnostic message strings. Freed in bulk on deinit.
msg_arena: std.heap.ArenaAllocator,
/// Collected diagnostics from all rules applied to a file or project.
diagnostics: std.ArrayList(Diagnostic) = .empty,

const LintResult = @This();

/// Creates an empty result. Message strings should be allocated via `messageAllocator`.
pub fn init(allocator: std.mem.Allocator) LintResult {
    return .{
        .allocator = allocator,
        .msg_arena = std.heap.ArenaAllocator.init(allocator),
    };
}

/// Frees the diagnostics list and the message arena.
pub fn deinit(self: *LintResult) void {
    self.diagnostics.deinit(self.allocator);
    self.msg_arena.deinit();
}

/// Returns the allocator to use for diagnostic message strings. Lifetime of returned strings is tied to this LintResult.
pub fn messageAllocator(self: *LintResult) std.mem.Allocator {
    return self.msg_arena.allocator();
}

/// Returns whether any diagnostic has error severity.
pub fn hasErrors(self: *const LintResult) bool {
    for (self.diagnostics.items) |d| {
        if (d.severity_level.isError()) return true;
    }

    return false;
}

/// Returns the number of diagnostics with error severity.
pub fn errorCount(self: *const LintResult) usize {
    var count: usize = 0;
    for (self.diagnostics.items) |d| {
        if (d.severity_level.isError()) count += 1;
    }

    return count;
}

/// Returns the number of diagnostics with warning severity.
pub fn warningCount(self: *const LintResult) usize {
    var count: usize = 0;
    for (self.diagnostics.items) |d| {
        if (d.severity_level == .warn) count += 1;
    }

    return count;
}
