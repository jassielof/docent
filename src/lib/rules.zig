//! The rules namespace organizes the various linting rules that can be applied to source code.

pub const style = @import("rules/style.zig");
pub const complexity = @import("rules/complexity.zig");
pub const docs = @import("rules/docs.zig");
