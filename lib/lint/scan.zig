//! Declares which declarations each rule inspects in every file found by Docent's directory walk.

const std = @import("std");

pub const Visibility = enum {
    public_only,
    include_internal,

    pub fn isPublicOnly(self: Visibility) bool {
        return self == .public_only;
    }
};

pub const RuleScanConfig = struct {
    visibility: Visibility,

    pub const public_declarations = RuleScanConfig{
        .visibility = .public_only,
    };
    pub const all_declarations = RuleScanConfig{
        .visibility = .include_internal,
    };

    pub fn publicDeclarationsOnly(self: RuleScanConfig) bool {
        return self.visibility.isPublicOnly();
    }

    pub fn fromConfigString(text: []const u8) ?RuleScanConfig {
        if (std.mem.eql(
            u8,
            text,
            "public",
        )) return public_declarations;
        if (std.mem.eql(
            u8,
            text,
            "all",
        )) return all_declarations;
        return null;
    }

    pub fn configString(self: RuleScanConfig) []const u8 {
        return switch (self.visibility) {
            .public_only => "public",
            .include_internal => "all",
        };
    }
};
