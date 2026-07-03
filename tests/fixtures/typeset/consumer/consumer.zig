//! Fixture exercising `--external-refs`: references `example.grow` (from
//! tests/fixtures/typeset/example/example.zig), a module this fixture does
//! not itself import, to confirm the external-refs sidecar resolves it.

/// Calls something conceptually similar to `example.grow`.
pub fn touch() void {}
