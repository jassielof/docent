const std = @import("std");

const docent = @import("docent");
const fangz = @import("fangz");

pub const RuleConfigError = error{
    InvalidSeverity,
    UnknownRule,
};

/// Applies a single `key=severity` override to the rule set (used by project config loaders and tests).
pub fn applyRuleOverride(rs: *docent.RuleSet, kv: fangz.KeyValuePair) RuleConfigError!void {
    const sev = std.meta.stringToEnum(docent.Severity, kv.value) orelse return error.InvalidSeverity;
    inline for (@typeInfo(docent.RuleSet).@"struct".fields) |f| {
        if (std.mem.eql(u8, f.name, kv.key)) {
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
