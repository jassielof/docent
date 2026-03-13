const Severity = @import("Severity.zig");

rule: []const u8,
severity: Severity.Level,
message: []const u8,
file: []const u8,
line: usize,
column: usize,
/// The trimmed source line where the diagnostic occurs. Empty if unavailable.
source_line: []const u8 = "",
/// Length of the highlighted token for the ^~~~ span. Defaults to 1.
symbol_len: usize = 1,
