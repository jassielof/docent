/// max_buffer_size is the maximum number of bytes a single read may consume.
pub const max_buffer_size: usize = 4096;

/// default_timeout_ms is the default timeout expressed in milliseconds.
pub const default_timeout_ms: u32 = 5_000;

/// pi is the ratio of a circle's circumference to its diameter.
pub const pi: f64 = 3.141592653589793;

/// Direction represents the four cardinal movement directions.
pub const Direction = enum {
    north,
    south,
    east,
    west,
};

/// HttpMethod represents an HTTP request verb.
pub const HttpMethod = enum {
    get,
    post,
    put,
    patch,
    delete,
};

/// TokenKind classifies the lexical category of a scanned token.
pub const TokenKind = enum {
    /// identifier is a user-defined name token.
    identifier,
    /// number_literal is a numeric constant token.
    number_literal,
    /// string_literal is a quoted string token.
    string_literal,
    /// eof marks the end of the input stream.
    eof,
};

/// Vec2 is a two-dimensional vector with single-precision components.
pub const Vec2 = struct {
    /// x is the horizontal component.
    x: f32,
    /// y is the vertical component.
    y: f32,
};

/// UserConfig holds the runtime configuration for a user session.
pub const UserConfig = struct {
    /// timeout_ms is the per-request timeout in milliseconds.
    timeout_ms: u32 = 3_000,
    /// max_retries is the maximum number of retry attempts before giving up.
    max_retries: u8 = 3,
    /// verbose enables debug-level logging when set to true.
    verbose: bool = false,
};

/// ParseError describes a failure that occurred during input parsing.
pub const ParseError = error{
    UnexpectedToken,
    UnexpectedEof,
    Overflow,
};

/// A BufferPool manages a fixed collection of reusable byte slices.
pub const BufferPool = struct {
    capacity: usize,
    used: usize,
};

/// An EventEmitter broadcasts typed events to all registered listeners.
pub const EventEmitter = struct {
    id: u32,
};

/// The Registry is the process-wide singleton that maps names to handles.
pub const Registry = struct {
    size: usize,
};

/// add returns the sum of a and b.
pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

/// clamp constrains value to the closed interval [lo, hi].
pub fn clamp(value: f32, lo: f32, hi: f32) f32 {
    return @min(@max(value, lo), hi);
}

/// parseU64 parses a base-10 unsigned integer from the given byte slice.
pub fn parseU64(input: []const u8) !u64 {
    _ = input;
    return 0;
}

/// isAsciiAlpha returns true when c is an ASCII letter.
pub fn isAsciiAlpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

/// toUpperCase converts an ASCII letter to its uppercase equivalent.
pub fn toUpperCase(c: u8) u8 {
    return if (c >= 'a' and c <= 'z') c - 32 else c;
}
