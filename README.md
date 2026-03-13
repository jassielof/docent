# Zig Documentation Linter

A documentation linter for Zig. Enforces doc comments, doctests, and container documentation across your codebase with configurable severity levels — as a library, CLI, or build.zig step.

## Behavior

## Issues & Limitations

### Public API tracking

Considering the following case where I have 2 files, `src/lib/root.zig`, and `src/lib/Severity.zig`:

`root.zig` has:

```zig
const std = @import("std");

pub const Severity = @import("Severity.zig").Level;

// rest of the code...
```

`Severity.zig` has:

```zig
/// The severity level of a lint rule.
pub const Level = enum {
    allow,
    warn,
    deny,
    forbid,

    pub fn isActive(self: Level) bool {
        return self != .allow;
    }

    pub fn isError(self: Level) bool {
        return self == .deny or self == .forbid;
    }
};

```

In this case, using the linter on either `src/lib/root.zig` (the library entry point), or its directory `src/lib` will report the issue that the `pub const Severity` on `root.zig` is missing documentation, which shouldn't, as the documentation is on the `Level` enum in `Severity.zig`, and is inherited on the public API of `root.zig` as `Severity`. On the case on only checking for `src/lib/root.zig` I could understand that the linter won't know about the `Severity` file, but I'll need to check on Cargo doc to compare and validate if that should be expected behavior.

Regardless, in the case of checking the whole `src/lib` directory, the linter should be able to know that `Severity` is re-exporting `Level` and that it has documentation, and thus not report it as an issue.

You can easily test this by running `zig build cli -- --all-warn src/lib` and ripgrepping for the `missing documentation` issue on `root.zig` with the `Severity` constant.

For example the Cargo doc equivalent is somewhat:

```

