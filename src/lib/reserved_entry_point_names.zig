//! The reserved_entry_point_names namespace provides constants for the reserved entry point symbol names in Zig, These help identify the type of module being scanned. See https://ziglang.org/documentation/0.16.0/#Entry-Point.

/// The build_system_script entry point is a public function named `build`.
pub const build_system_script = "build";
/// The executable module entry point is a public function named `main`.
pub const executable_module = "main";
