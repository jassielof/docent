//! Pcre2 API definitions.

/// Public Pcre2 type.
pub const Pcre2 = struct {
    //! Pcre2 container docs.

    /// Matches a pattern.
    pub fn matches(_: []const u8) bool {
        return true;
    }

    test matches {
        _ = Pcre2.matches("x");
    }
};
