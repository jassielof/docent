//! The reusable rule-checking engine: per-rule `check()` functions plus the shared types they're
//! built on (`Diagnostic`, `severity.Level`, `scan.RuleScanConfig`, `category.Rule`).
//!
//! This is deliberately separate from `internal/docent`, which wraps this engine with CLI-only
//! concerns (TOML config loading, suppression comments, output rendering, project/target
//! discovery) - a consumer that only wants to check a single already-in-memory source file against
//! a rule (like a language server) can depend on this module directly, without any of that.
//!
//! ## Rule categories
//!
//! Several rules are inspired by established style guides, linting tools/rules, and best practices
//! from other languages, such as Go, Rust, Sonar Source, etc. Go's standard library is notable for
//! its strict and consistent documentation guidelines, as well as its tooling ecosystem, such as
//! _Golang CI Lint_'s aggregation approach, reflects a culture of broad, opinionated quality checks
//! across style, complexity, and documentation simultaneously.
//!
//! Rust on the other hand, has both its own toolchain, the compiler lints plus Clippy, which
//! expands on the compiler's capabilities with a wide range of lints covering style, complexity,
//! and documentation. Although their documentation linting rules tend to focus on narrower aspects
//! and syntax issues rather than style (like Go), they are still valuable for ensuring that
//! documentation is present and correctly formatted and influence this project's design.
//!
//! For examples, check the test suite.

const std = @import("std");

pub const Diagnostic = @import("Diagnostic.zig");
pub const severity = @import("severity.zig");
pub const SeverityLevel = severity.Level;
pub const scan = @import("scan.zig");
pub const category = @import("category.zig");
pub const LintResult = @import("LintResult.zig");
pub const LintOptions = @import("LintOptions.zig");
pub const RuleSeverities = @import("RuleSeverities.zig");

pub const complexity = @import("complexity.zig");
pub const doc = @import("doc.zig");
pub const size = @import("size.zig");
pub const style = @import("style.zig");

comptime {
    std.testing.refAllDecls(@This());
}
