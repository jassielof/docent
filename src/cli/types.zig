//! Shared CLI types used by the root command and `docent check` subcommands.

pub const OutputMode = enum {
    pretty,
    minimal,
    json,
};

pub const FailFast = enum {
    none,
    @"error",
    warn,
    any,
};

/// The default `--fail-fast` behavior is to not fail fast.
pub const default_fail_fast = FailFast.none;
