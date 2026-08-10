//! The scan namespace offers utilities for scanning and analyzing Zig modules.
//!
//! Docent has two product-level scan models:
//!
//! - **Module API (check / typeset):** starts strictly from a module root
//!   declared in `build.zig` (`root_source_file`), then runs reachability
//!   analysis over the import/declaration graph. Orphan `.zig` files that are
//!   never reached from a module root are ignored.
//! - **Filesystem (fmt):** recursive directory walk over every `.zig` / `.zon`
//!   file on disk, including orphans. Path `include` / `exclude` live under
//!   `[fmt]` in `.config/docent.toml`.
//!
//! Traversal for check rules operates under a `RuleScanConfig` composed of:
//!
//! - **ScanMode:**
//!   - `reachability`: module-root reachability (the check/typeset model).
//!   - `filesystem`: recursive walk including orphans (available for explicit
//!     opt-in / multi-path CLI escape hatches; not what TOML `scan_mode`
//!     `"public"` / `"all"` select).
//!
//! - **Visibility:** (only applicable to `.reachability`)
//!   - `public_only`: inspects only publicly visible (`pub`) declarations.
//!   - `include_internal`: extends past `pub` boundaries to collect internal
//!     declarations in already-reachable files.
//!
//! TOML `scan_mode = "public"` maps to `public_api_surface`; `"all"` maps to
//! `reachability_traversal`. Both stay on the module-API graph.

const lint = @import("lint");

pub const ScanMode = lint.scan.ScanMode;
pub const Visibility = lint.scan.Visibility;
pub const RuleScanConfig = lint.scan.RuleScanConfig;

pub const alias = @import("scan/alias.zig");
