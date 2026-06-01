//! The score sub-command provides similar functionality to [Go Report Card](https://goreportcard.com/).
//!
//! Among the extra things to be evaluated are (without considering what Docent provides):
//! - The presence of a LICENSE (or NOTICE) and README files, not just presence but also that they are not empty. This is
//! - Formatting: whether the code is formatted. This will use `zig fmt --check <paths>...`, and considering it accepts multiple paths, it reads all valid zig/zon files, and directories (recursively) from the command. So, the score should consider all the files that are to be scanned by the Zig formatted, all the paths passed, and then the score is based on $(total_files - failed_files) / total_files$, the way `zig fmt --check` reports the results is basicallyy newline separated relative (to the passed paths) paths of each failed file. The score is 100% if no files failed obviously, and the decreases depending on the formula.
//!
//! Score will always exit successfully.
