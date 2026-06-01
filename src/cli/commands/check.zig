//! TODO: Check will run all lint rules. It won't print diagnostics, but rather a simple summary, categorized by check type and severity, along with total number of found issues. It'll return a non-zero exit code if any issues are found, and zero if no issues are found.
//! The format I was thinking it's mostly:
//! ```
//! Documentation comments:
//! - n <severity>[<rule_id>]
//! Style:
//! - n <severity>[<rule_id>]
//! Complexity:
//! - n <severity>[<rule_id>]
//! ```

