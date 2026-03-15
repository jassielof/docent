// Activate every relevant lint at the level you want to observe.
// Swap warn <-> deny <-> allow per rule to see the behavior change.
#![warn(missing_docs)]
#![warn(rustdoc::missing_crate_level_docs)]
#![warn(rustdoc::private_intra_doc_links)]
#![warn(rustdoc::private_doc_tests)]
// Nightly only — comment out on stable:
// #![warn(rustdoc::missing_doc_code_examples)]

// ── missing_docs ────────────────────────────────────────────────────────────

/// This function IS documented — no warning.
pub fn documented() {}

// No doc comment — triggers missing_docs
pub fn undocumented() {}

/// This struct IS documented.
pub struct DocumentedStruct {
    /// Field is documented.
    pub field_a: u32,
    // No doc comment — triggers missing_docs on the field
    pub field_b: u32,
}

// No doc comment — triggers missing_docs on the struct AND its fields
pub struct UndocumentedStruct {
    pub field_x: u32,
}

/// Documented enum.
pub enum DocumentedEnum {
    /// Variant A documented.
    VariantA,
    // No doc — triggers missing_docs
    VariantB,
}

// No doc — triggers missing_docs
pub enum UndocumentedEnum {
    VariantX,
}

// Private items: missing_docs does NOT fire on these
fn private_fn() {}
struct PrivateStruct {
    field: u32,
}

// ── rustdoc::missing_crate_level_docs ───────────────────────────────────────
// Triggered by the ABSENCE of a //! at the top of this file.
// Add `//! My crate.` as the very first line to silence it.

// ── private_doc_tests ───────────────────────────────────────────────────────
mod private_module {
    /// A private function with a doctest — triggers private_doc_tests
    ///
    /// ```
    /// assert_eq!(2 + 2, 4);
    /// ```
    fn private_with_doctest() {}
}

/// A public function with a doctest — no warning.
///
/// ```
/// assert_eq!(2 + 2, 4);
/// ```
pub fn public_with_doctest() {}

// ── rustdoc::private_intra_doc_links ────────────────────────────────────────
/// This links to a private item: [`private_fn`] — triggers the lint.
pub fn links_to_private() {}
