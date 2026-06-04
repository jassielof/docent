// TODO: implement score
//! The score sub-command provides similar functionality to [Go Report Card](https://goreportcard.com/).
//!
//! Among the extra things to be evaluated are (without considering what Docent provides):
//!
//! - Legal and community things, check the TODO on src/lib/score/{legal,community}.zig
//! - Formatting: whether the code is formatted. This will use `zig fmt --check <paths>...`, and considering it accepts multiple paths, it reads all valid zig/zon files, and directories (recursively) from the command. So, the score should consider all the files that are to be scanned by the Zig formatted, all the paths passed, and then the score is based on $(total_files - failed_files) / total_files$, the way `zig fmt --check` reports the results is basicallyy newline separated relative (to the passed paths) paths of each failed file. The score is 100% if no files failed obviously, and the decreases depending on the formula.
//! - Linting: Whether the code passes lints by category: documentation, style, and complexity. Each on its own, the score here can't be based on total files, as these lints scan strategy differs, it can be public API surface (meaning everything that is possible to be imported as an external library, so it depends on a module root, and everything that's publicly reachable from there). And the second strategy is similar to the previous, again by a module root, but here we include all reachable declarations whether they are public or not. Figure out the best method to score these. For example, the scan strategy is usually configurable, depending on the available configuration, but by default, documentation checks are public API only, while style and complexity checks are all reachable declarations (public and non-public API).
//!
//! Score will always exit successfully.
