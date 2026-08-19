//! Checking and converting between string casing conventions (`snake_case`, `camelCase`, `PascalCase`, `kebab-case`).
//!
//! This module is deliberately split in two:
//!
//! - `check` — exact convention checks (`Style.matches`, `isSnake`, `isCamel`, `isPascal`, `isKebab`).
//! - `convert` — heuristic word-boundary conversion (`pascalCaseStemToSnake`, `pascalCaseStemToKebab`, `identifierToFilenameStem`, `suggestFilenameStem`). See `convert.zig`'s module docs for where the heuristic can diverge from what a human would write; callers that surface suggestions (e.g. `identifier_case`) should present them as advisory, not authoritative.
//!
//! Operates on ASCII bytes only; non-ASCII bytes are passed through unchanged and never considered part of a case transition.

const std = @import("std");

pub const check = @import("check.zig");
pub const isCamel = check.isCamel;
pub const isKebab = check.isKebab;
pub const isPascal = check.isPascal;
pub const isSnake = check.isSnake;
pub const Style = check.Style;
pub const convert = @import("convert.zig");
pub const identifierToFilenameStem = convert.identifierToFilenameStem;
pub const pascalCaseStemToSnake = convert.pascalCaseStemToSnake;
pub const suggestFilenameStem = convert.suggestFilenameStem;

comptime {
    std.testing.refAllDecls(@This());
}
