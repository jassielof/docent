//! Model type used by the public API.

const Self = @This();

/// Name of the model.
name: []const u8,

/// Returns the model name.
pub fn getName(self: Self) []const u8 {
    return self.name;
}

test getName {
    const m: Self = .{ .name = "docent" };
    _ = m.getName();
}
