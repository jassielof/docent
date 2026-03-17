# Docent: Zig Documentation Linter

Docent is a documentation linter for Zig.

Available as a CLI, library, and build integration step.

## Behavior & Rules

### Scanning

It expects a manifest file to be present in your current working directory, then it'll automatically scan all the source files in the paths property that are or have valid Zig source files.

### Missing docs

### Granularity

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
