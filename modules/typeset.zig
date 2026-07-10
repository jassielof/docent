//! Typeset support: walk a Zig module's public API and emit `docs.json` for
//! Typst PDF rendering (`typst/docent-docs/`).
//!
//! Built on vendored Zig compiler doc-generation internals (`vendor/`) — see
//! `vendor/VENDORED.md` for provenance and applied patches.
//!
//! Doc-comment markup parsing lives in the `doc_comment` module; this module
//! owns Typst conversion, JSON serialization, and dependency/std bundling.

pub const schema = @import("typeset/schema.zig");
pub const walker = @import("typeset/walker.zig");
pub const serialize = @import("typeset/serialize.zig");
pub const typst = @import("typeset/typst.zig");
pub const external_refs = @import("typeset/external_refs.zig");
pub const path_deps = @import("typeset/path_deps.zig");
pub const std_bundle = @import("typeset/std_bundle.zig");
