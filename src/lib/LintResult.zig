const std = @import("std");
const Diagnostic = @import("Diagnostic.zig");
const Severity = @import("Severity.zig");

allocator: std.mem.Allocator,
diagnostics: std.ArrayList(Diagnostic) = .empty,

const LintResult = @This();

pub fn init(allocator: std.mem.Allocator) LintResult {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *LintResult) void {
    self.diagnostics.deinit(self.allocator);
}

pub fn addDiagnostic(self: *LintResult, diag: Diagnostic) !void {
    try self.diagnostics.append(self.allocator, diag);
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
