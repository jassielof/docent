# Docent: Zig Documentation Linter

Docent is a documentation linter for Zig.

Available as a CLI, library, and build integration step.

## Behavior & Rules

### Scanning

It expects a manifest file to be present in your current working directory, then scans the configured `.paths` entries.

Directory behavior:

- If a directory contains `root.zig`, Docent treats it as an entrypoint and lints files that are publicly reachable from that root via `pub const ... = @import("...")` chains.
- If a directory has no `root.zig`, Docent falls back to linting all `.zig` files in that directory tree.

### Severities

All rules accept one of these levels:

- `allow`: disable the rule.
- `warn`: emit a diagnostic but do not fail the run.
- `deny`: emit a diagnostic and count it as an error.
- `forbid`: same behavior as `deny` for now.

### Rule: missing_doc_comment

Checks public declarations for missing `///` documentation comments.

What it checks:

- Public functions.
- Public constants and variables.
- Fields inside container declarations.
- Nested members inside container literals (for example `pub const Foo = struct { ... }`).

Re-export behavior:

- For `pub const Foo = @import("other.zig").Bar`, the rule follows the import and checks docs on `Bar` in `other.zig`.
- If `Bar` is documented, no diagnostic is emitted.
- If `Bar` is undocumented, one diagnostic is emitted and points to `other.zig`.
- If resolution fails (missing file, package import, parse failure), the re-export is skipped to avoid false positives.

Current limit:

- Re-export resolution is currently one-hop and root-declaration based. It does not perform full project/API reachability traversal.

### Rule: empty_doc_comment

Checks for doc comments that are present but blank.

What it checks:

- `///` comments with only whitespace after the prefix.
- `//!` comments with only whitespace after the prefix.

### Rule: missing_doctest

Checks public function doctest coverage.

What it checks:

- Collects top-level `pub fn name(...)` declarations.
- Collects identifier-style tests `test name { ... }`.
- Emits a diagnostic when a public function has no matching identifier-style doctest.

Notes:

- String-literal test names (for example `test "name"`) are not counted as doctests for this rule.

### Rule: private_doctest

Checks that identifier-style doctests reference public symbols.

What it checks:

- Collects top-level public function names and public variable/constant names.
- For each `test name { ... }`, emits a diagnostic if `name` is not public.

### Rule: doctest_naming_mismatch

Checks for style mismatch when a doctest name matches a public function but is written as a string literal.

What it checks:

- If `pub fn foo(...)` exists and the file uses `test "foo"`, it suggests using `test foo`.

### Rule: missing_container_doc_comment

Checks `//!` container doc comments.

What it checks:

- File-level module container doc comment (`//!`) near the beginning of the file.
- Public container declarations assigned to `pub const` (for example `pub const Config = struct { ... }`) and recursively nested public containers.

Note:

- This rule exists for compatibility with current parser behavior around top-level/container doc comments and may evolve with Zig 0.16 changes.

### Re-export resolution

When a public declaration re-exports a symbol from another file using the
`pub const Foo = @import("other.zig").Bar` pattern, the linter follows the
import and evaluates the doc comment on the _original_ declaration rather than
on the re-export line:

- If `Bar` in `other.zig` has a `///` doc comment → no diagnostic.
- If `Bar` has no doc comment → one diagnostic pointing to `other.zig`, not to
  the re-export site.
- If the import path cannot be resolved (package imports such as `"std"`,
  missing files, parse errors) → the re-export is silently skipped; no false
  positive is emitted.

Current implementation detail:

- Re-export checks are performed while linting the current file and resolving
  directly imported files. The linter does not currently compute full
  transitive API reachability for the entire package graph.

## Credits

Mainly Rust/Cargo's documentation (and probably Clippy too) linter checks, while also taking inspiration from Go's linting.
