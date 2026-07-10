//! Test suite aggregator.
//!
//! No test logic is defined here, here we only import the test categories, and each test category imports its own rules to tests, there, the actual test logic is defined.
//!
//! - For each rule category, we have `rules/<category>.zig`.
//! - For each rule, we have `rules/<category>/<rule>.zig`.
//! - For each scenario, we have `scenarios/<scenario>.zig`.
//! - Fixture data lives under `fixtures/` in a flat layout, mirroring the `rules/` and `scenarios/` trees.
//!
//! Case ids are descriptive (for example `undocumented_pub_declarations.zig`, `reexport_undocumented_points_at_definition/`). There is no `valid/` / `invalid/` split; pass vs fail is defined by the test logic.

const std = @import("std");
const refAllDecls = std.testing.refAllDecls;

comptime {
    refAllDecls(@import("rules/doc.zig"));
    refAllDecls(@import("rules/complexity.zig"));
    refAllDecls(@import("rules/size.zig"));
    refAllDecls(@import("rules/style.zig"));
    refAllDecls(@import("rules/suppressions.zig"));
    refAllDecls(@import("scenarios.zig"));
    refAllDecls(@import("fmt.zig"));
}
