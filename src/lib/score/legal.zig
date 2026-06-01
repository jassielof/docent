//! Legal file checker.
//!
//! TODO:
//! - Define core file: LICENSE (LICENSE, LICENSE.md, LICENSE.txt, LICENCE, etc.)
//! - Define extra files: NOTICE, COPYRIGHT, COPYING, TRADEMARK
//! - Detect which of the above are present in the project root
//! - Return core_found + extras slice for scoring

// The only thing worth noting: both files (legal and community) will be nearly identical in structure, so once you implement one, the other is essentially a copy with different file name lists. You might want to implement a shared FilePresenceCheck in a common file (e.g. checks/common.zig or just check.zig) that both call into, keeping the actual lists as the only thing that differs between them.
