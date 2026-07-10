//! The markup namespace provides functionality for parsing Zig documentation comments markup.
//!
//! The markup format is strictly the one used in Zig (see <https://codeberg.org/ziglang/zig/src/tag/0.16.0/lib/docs>), which currently follows a subset of Markdown, but without a formal specification. This namespace tries to provide a formal specification and a stable API for parsing this markup format, plus additional functionality.
