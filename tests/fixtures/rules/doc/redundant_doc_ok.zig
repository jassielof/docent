const helper = @import("redundant_helper.zig");

// No doc comment here, completely fine
pub const my_helper = helper;

// No doc comment here, completely fine
pub const Foo = helper.Foo;

/// Doc comment on member that is NOT documented in target
pub const UndocumentedFoo = helper.UndocumentedFoo;
