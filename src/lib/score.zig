pub const community = @import("score/community.zig");
pub const format = @import("score/format.zig");
pub const grade = @import("score/grade.zig");
pub const legal = @import("score/legal.zig");
pub const lint = @import("score/lint.zig");
pub const presence = @import("score/presence.zig");
pub const report = @import("score/report.zig");

pub const Report = report.Report;
pub const Check = report.Check;
pub const Options = report.Options;

/// Builds a weighted score report for a lint plan.
pub const gather = report.gather;
