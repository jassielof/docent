//! Fixture for the v0.2 milestone: containers within containers, field
//! tables, and error sets -- exercises the parts of docs.json that the v0.1
//! fixture (tests/fixtures/typeset/example/example.zig) deliberately left
//! untouched. Still avoids generics per the v0.1/v0.2 risk memo.

/// Errors returned while resizing a `Buffer`.
pub const ResizeError = error{
    /// The requested size exceeds the buffer's fixed capacity.
    TooLarge,
    /// The allocator ran out of memory.
    OutOfMemory,
};

/// A fixed-capacity byte buffer.
pub const Buffer = struct {
    /// The backing storage.
    data: [64]u8 = undefined,
    /// Number of bytes currently in use.
    len: usize = 0,

    /// Appends `byte` to the buffer.
    pub fn append(self: *Buffer, byte: u8) ResizeError!void {
        if (self.len >= self.data.len) return ResizeError.TooLarge;
        self.data[self.len] = byte;
        self.len += 1;
    }

    /// Resets the buffer to empty.
    pub fn clear(self: *Buffer) void {
        self.len = 0;
    }
};
