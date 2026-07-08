//! Example module for schema validation.
//!
//! Deliberately avoids generics and complex error unions -- see the planning
//! session's risk memo (naming collisions in `id` for generic instantiations
//! are a v0.2+ problem, not something the v0.1 fixture should exercise).

/// Default initial capacity for `List`.
pub const default_capacity: usize = 16;

/// Grows the list's backing storage to at least `new_len`.
pub fn grow(self: *List, allocator: Allocator, new_len: usize) !void {
    _ = self;
    _ = allocator;
    _ = new_len;
}

const Allocator = @import("std").mem.Allocator;

const List = struct {
    items: []u8 = &.{},
};
