const Severity = @import("Severity.zig");

rule: []const u8,
severity: Severity.Level,
message: []const u8,
file: []const u8,
line: usize,
column: usize,
