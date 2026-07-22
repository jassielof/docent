const std = @import("std");

const fangz = @import("fangz");

const RuleSeverities = @import("RuleSeverities.zig");
const SeverityLevel = @import("severity.zig").Level;

pub const RuleConfigError = error{
    InvalidSeverity,
    UnknownRule,
};

/// Applies a single `key=severity` override to the rule set (used by project config loaders and tests).
pub fn applyRuleOverride(rs: *RuleSeverities, kv: fangz.KeyValuePair) RuleConfigError!void {
    const sev = std.meta.stringToEnum(SeverityLevel, kv.value) orelse
        return error.InvalidSeverity;

    inline for (@typeInfo(RuleSeverities).@"struct".fields) |f| {
        if (std.mem.eql(
            u8,
            f.name,
            kv.key,
        )) {
            const current = @field(rs, f.name);
            if (current == .forbid and sev != .forbid) return;
            @field(rs, f.name) = sev;
            return;
        }
    }

    return error.UnknownRule;
}

pub fn formatRuleConfigError(err: RuleConfigError) []const u8 {
    return switch (err) {
        error.InvalidSeverity => "invalid severity (must be one of allow, warn, deny, forbid)",
        error.UnknownRule => "unknown rule name",
    };
}
