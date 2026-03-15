//! Lib doc

#![warn(missing_docs)]
#![warn(rustdoc::missing_crate_level_docs)]
mod severity;
pub use severity::Level as SeverityLevel;

/// Hola
pub fn add(left: u64, right: u64) -> u64 {
    private_add(left, right)
}

/// Adios
fn private_add(left: u64, right: u64) -> u64 {
    left + right
}
