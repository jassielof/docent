//! A fully compliant module with all public declarations documented.

/// Adds two numbers together.
pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

/// A point in 2D space.
pub const Point = struct {
    //! Represents a two-dimensional coordinate.

    /// The x coordinate.
    x: f64,
    /// The y coordinate.
    y: f64,
};

/// The application version.
pub const version = "1.0.0";

test add {
    const result = add(2, 3);
    _ = result;
}
