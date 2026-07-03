//! `docent typeset` support library: walks a Zig module's public API and
//! emits `docs.json` (see `schema.zig`) for rendering by the Typst template
//! under `typst/docent-docs/`.
//!
//! Built on vendored Zig compiler doc-generation internals (`vendor/`) — see
//! `vendor/VENDORED.md` for provenance and applied patches.

pub const schema = @import("typeset/schema.zig");
pub const walker = @import("typeset/walker.zig");
pub const json_emit = @import("typeset/json_emit.zig");
pub const markdown_typst = @import("typeset/markdown_typst.zig");
pub const external_refs = @import("typeset/external_refs.zig");
