//! Legal file presence scoring (LICENSE and related files).

const std = @import("std");
const presence = @import("presence.zig");

pub const core_variants = [_][]const u8{
    "LICENSE",
    "LICENSE.md",
    "LICENSE.txt",
    "LICENCE",
    "LICENCE.md",
    "LICENCE.txt",
    "COPYING",
};

pub const extra_variants = [_][]const u8{
    "NOTICE",
    "NOTICE.md",
    "NOTICE.txt",
    "COPYRIGHT",
    "TRADEMARK",
    "TRADEMARK.md",
};

pub const Report = presence.Report;

/// Scans `project_root` for legal files.
pub fn scan(allocator: std.mem.Allocator, io: std.Io, project_root: []const u8) !Report {
    return presence.scan(allocator, io, project_root, &core_variants, &extra_variants);
}

/// Returns 100 when a core license file exists, otherwise 0.
pub fn percentage(report: Report) f64 {
    return if (report.core_found) 100.0 else 0.0;
}
