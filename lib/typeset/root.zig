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

pub const external_refs = @import("external_refs.zig");
pub const path_deps = @import("path_deps.zig");
pub const schema = @import("schema.zig");
pub const serialize = @import("serialize.zig");
pub const std_bundle = @import("std_bundle.zig");
pub const typst = @import("typst.zig");
pub const Walk = @import("Walk.zig");
pub const Decl = Walk.Decl;
pub const walker = @import("walker.zig");
