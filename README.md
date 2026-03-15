# Zig Documentation Linter

A documentation linter for Zig. Enforces doc comments, doctests, and container documentation across your codebase with configurable severity levels — as a library, CLI, or build.zig step.

## Behavior

## Granularity

Rust's missing docs is

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

## Credits

Mainly Rust/Cargo's documentation (and probably Clippy too) linter checks, while also taking inspiration from Go's linting.
