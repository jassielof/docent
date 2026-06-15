//! The rules namespace organizes the various linting rules that can be applied to source code by category.
//!
//! Several rules are inspired by established style guides, linting tools/rules, and best practices from other languages, such as Go, Rust, Sonar Source, etc. Go's standard library is notable for its strict and consistent documentation guidelines, as well as its tooling ecosystem, such as _Golang CI Lint_'s aggregation approach, reflects a culture of broad, opinionated quality checks across style, complexity, and documentation simultaneously.
//!
//! Rust on the other hand, has both its own toolchain, the compiler lints plus Clippy, which expands on the compiler's capabilities with a wide range of lints covering style, complexity, and documentation. Although their documentation linting rules tend to focus on narrower aspects and syntax issues rather than style (like Go), they are still valuable for ensuring that documentation is present and correctly formatted and influence this project's design.
//!
//! ## Examples
//!
//! For examples, check the test suite.

pub const style = @import("rules/style.zig");
pub const complexity = @import("rules/complexity.zig");
pub const doc = @import("rules/doc.zig");
