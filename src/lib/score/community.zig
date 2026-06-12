//! Community health file presence scoring (README and related files).

const std = @import("std");
const presence = @import("presence.zig");

pub const core_variants = [_][]const u8{
    "README.md",
    "README.adoc",
    "README.txt",
    "README",
    "Readme.md",
};

pub const extra_variants = [_][]const u8{
    "CONTRIBUTING",
    "CONTRIBUTING.md",
    "CODE_OF_CONDUCT",
    "CODE_OF_CONDUCT.md",
    "SECURITY",
    "SECURITY.md",
    "SUPPORT",
    "SUPPORT.md",
    "FUNDING",
    "FUNDING.yml",
    "FUNDING.yaml",
};

pub const Report = presence.Report;

/// Scans `project_root` for community health files.
pub fn scan(allocator: std.mem.Allocator, io: std.Io, project_root: []const u8) !Report {
    return presence.scan(allocator, io, project_root, &core_variants, &extra_variants);
}

/// Returns 100 when a core README exists, otherwise 0.
pub fn percentage(report: Report) f64 {
    return if (report.core_found) 100.0 else 0.0;
}
