//! Typeset support: walk a Zig module's public API and emit `docs.json` for
//! Typst PDF rendering (`typst/docent-docs/`).
//!
//! Module discovery follows the same **module-API** model as `docent check`:
//! start from `build.zig` module roots, then traverse reachability (orphans
//! are ignored). See `Walk.zig` / `Decl.zig` for the
//! declaration graph machinery.
//!
//! Doc-comment markup parsing lives in the `doc_comment` module; this module
//! owns Typst conversion (including MiTeX math and Codly-friendly code
//! fences), JSON serialization, and dependency/std bundling.

pub const schema = @import("typeset/schema.zig");
pub const walker = @import("typeset/walker.zig");
pub const serialize = @import("typeset/serialize.zig");
pub const typst = @import("typeset/typst.zig");
pub const external_refs = @import("typeset/external_refs.zig");
pub const path_deps = @import("typeset/path_deps.zig");
pub const std_bundle = @import("typeset/std_bundle.zig");
pub const Walk = @import("typeset/Walk.zig");
pub const Decl = Walk.Decl;
