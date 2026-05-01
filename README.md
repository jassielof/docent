# Docent: Zig Documentation Linter

Docent is a documentation linter for Zig.

Available as a CLI, library, and build integration step (#1).

## Behavior & Rules

### Scanning

<!-- TODO: I need a way to add ignored paths, for example, dependencies, I usually put them under modules/ and they end up being scanned too. -->

It expects a manifest file to be present in your current working directory, then scans the configured `.paths` entries.

Directory behavior:

- If a directory contains `root.zig`, Docent treats it as an entrypoint and lints files that are publicly reachable from that root via `pub const ... = @import("...")` chains.
- If a directory has no `root.zig`, Docent treats each top-level `.zig` file as a module entrypoint and lints the union of their publicly reachable files.
- If no top-level `.zig` files exist, Docent falls back to linting all `.zig` files in that directory tree.

Reachability notes:

- Traversal is recursive across imported files, so multi-hop public chains are included.
- Imports reachable only through non-public declarations are excluded.
- Package imports (for example `@import("std")`) are not treated as local lint targets.

Build script defaults:

- `build.zig` and files under `build/` are ignored by default.
  - Instead of files within the build directory, it's mostly all of those files that are used/imported by the main build script (`build.zig`).
- This avoids false-positive API checks from build tooling paths that are commonly present in `build.zig.zon` `.paths`.
- CLI users can opt in with `--include-build-scripts`.
- Library users can opt in via `docent.targeting.Options{ .include_build_scripts = true }`.
- Build integration users can opt in via `docent.addLintStep(..., .{ .include_build_scripts = true, ... })`.

### Severities

All rules accept one of these levels:

- **Allow:** Rule is disabled. No diagnostics are emitted.
- **Warn:** Diagnostics are emitted, but they do not cause the process to exit with an error code.
- **Deny:** Diagnostics are emitted, and the process exits with an error code.
- **Forbid:** Similar to "Deny", but the rule cannot be overriden by a subsequent configuration.

The distinction between "Deny" and "Forbid" matter for locking a rule in CI regardless of any local flag overrides. For example, setting "Forbid" in the manifest cannot be weakened to any other level in the command line.

<!-- TODO: Document the default rules and their severities. -->
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
<!-- TODO: Check this and document in the src/lib/RuleSet.zig and add tests cases, there's already a reexport_un/documented and I think it might be fixed already, double check and confirm.-->

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
  missing files, parse errors) → the re-export is silently skipped; no false positive is emitted.

Current implementation detail:

- Re-export checks are performed while linting the current file and resolving directly imported files. The linter does not currently compute full transitive API reachability for the entire package graph.

## References

### Rust

The user already has the two core Rust links. A third Clippy-specific lint is worth adding for private item coverage, since `rustc`'s `missing_docs` only covers public items: [github](https://github.com/rust-lang/rust-clippy/blob/master/clippy_lints/src/missing_doc.rs)

- <https://doc.rust-lang.org/rustdoc/lints.html> — full list of `rustdoc` lints (`missing_docs`, `missing_doc_code_examples`, `broken_intra_doc_links`, etc.) [doc.rust-lang](https://doc.rust-lang.org/rustdoc/lints.html)
  - Zig docs seem to support intra links
- <https://doc.rust-lang.org/beta/rustc/lints/listing/allowed-by-default.html#missing-docs> — `rustc`-level `missing_docs` lint details (allowed by default, enable with `#![warn/deny(missing_docs)]`) [bsdwatch](https://bsdwatch.net/docs/sharedocs/rust/html/rustdoc/lints.html)
- <https://rust-lang.github.io/rust-clippy/master/index.html#missing_docs_in_private_items> — Clippy's `MISSING_DOCS_IN_PRIVATE_ITEMS` (restriction lint), which extends coverage to private items that `rustc` ignores [github](https://github.com/rust-lang/rust-clippy/blob/master/clippy_lints/src/missing_doc.rs)

### Go

Go has no compiler-level equivalent to `#![deny(missing_docs)]`. The canonical approach is through external linters, backed by the official doc comment spec: [go](https://go.dev/doc/comment)

- <https://go.dev/doc/comment> — official Go doc comment syntax specification (paragraphs, headings, links, lists, code blocks, and formatting rules enforced by `gofmt`) [go](https://go.dev/doc/comment)
- <https://pkg.go.dev/go/doc/comment> — `go/doc/comment` standard library package for parsing and reformatting doc comments programmatically [pkg.go](https://pkg.go.dev/go/doc/comment)
- <https://github.com/godoc-lint/godoc-lint> — dedicated godoc lint checker with rules like `require-doc`, `start-with-name`, `deprecated`, `max-len`, `no-unused-link`, and `require-stdlib-doclink` [github](https://github.com/godoc-lint/godoc-lint)
- <https://golangci-lint.run/docs/linters/> — `golangci-lint` integrates `godoclint` as a configurable linter runner with YAML-based rule configuration [golangci-lint](https://golangci-lint.run/docs/linters/)

## Credits

Mainly Rust/Cargo's documentation (and probably Clippy too) linter checks, while also taking inspiration from Go's linting.
