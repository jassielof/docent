pub fn no_doc() void {}

///
pub fn empty_doc() void {}

/// Documented function.
pub fn documented() void {}

fn private_helper() void {}

test private_helper {}

/// Has a doctest but uses string name.
pub fn string_tested() void {}

test "string_tested" {}
