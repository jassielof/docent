//! `identifier_case` — identifiers should follow the Zig naming-case conventions.

const std = @import("std");
const docent = @import("docent");
const harness = @import("../../harness.zig");
const utils = @import("../../utils.zig");

const ns = "style";
const warn = docent.RuleSeverities{ .identifier_case = .warn };
const reachability = docent.scanning.Modes.reachability_traversal;
const public_api = docent.scanning.Modes.public_api_surface;

fn setSnakeStructFileCase(cfg: *docent.rules.style.Style) void {
    cfg.identifier_case.options.struct_file_case = .snake;
}

fn setPascalNamespaces(cfg: *docent.rules.style.Style) void {
    cfg.identifier_case.options.namespaces = .pascal;
}

test "concrete function should be camelCase" {
    var result = try harness.lintStyleRuleFixture(ns, &.{ "identifier_case_bad_function_camel.zig" }, warn, reachability, null, null);
    defer result.deinit();
    try utils.expectRuleCount(result, "identifier_case", 1);
    try std.testing.expectEqual(.function, result.diagnostics.items[0].subject.?.kind);
    try std.testing.expectEqualStrings("DoThing", result.diagnostics.items[0].subject.?.name);
}

test "well-cased concrete function is clean" {
    var result = try harness.lintStyleRuleFixture(ns, &.{ "identifier_case_good_function_camel.zig" }, warn, reachability, null, null);
    defer result.deinit();
    try utils.expectRuleAbsent(result, "identifier_case");
}

test "type-returning function should be PascalCase" {
    var result = try harness.lintStyleRuleFixture(ns, &.{ "identifier_case_bad_generic_function.zig" }, warn, reachability, null, null);
    defer result.deinit();
    try utils.expectRuleCount(result, "identifier_case", 1);
    try std.testing.expectEqualStrings("list", result.diagnostics.items[0].subject.?.name);
}

test "well-cased generic function is clean" {
    var result = try harness.lintStyleRuleFixture(ns, &.{ "identifier_case_good_generic_function.zig" }, warn, reachability, null, null);
    defer result.deinit();
    try utils.expectRuleAbsent(result, "identifier_case");
}

test "global constant should be snake_case" {
    var result = try harness.lintStyleRuleFixture(ns, &.{ "identifier_case_bad_constant.zig" }, warn, reachability, null, null);
    defer result.deinit();
    try utils.expectRuleCount(result, "identifier_case", 1);
    try std.testing.expectEqual(.constant, result.diagnostics.items[0].subject.?.kind);
}

test "struct with fields should be PascalCase" {
    var result = try harness.lintStyleRuleFixture(ns, &.{ "identifier_case_bad_struct_name.zig" }, warn, reachability, null, null);
    defer result.deinit();
    try utils.expectRuleCount(result, "identifier_case", 1);
    try std.testing.expectEqual(.structure, result.diagnostics.items[0].subject.?.kind);
}

test "field-less container is a namespace and should be snake_case" {
    var result = try harness.lintStyleRuleFixture(ns, &.{ "identifier_case_bad_namespace_name.zig" }, warn, reachability, null, null);
    defer result.deinit();
    try utils.expectRuleCount(result, "identifier_case", 1);
    try std.testing.expectEqual(.namespace, result.diagnostics.items[0].subject.?.kind);
}

test "namespaces option overrides default convention" {
    var result = try harness.lintStyleRuleFixture(ns, &.{ "identifier_case_bad_namespace_name.zig" }, warn, reachability, null, setPascalNamespaces);
    defer result.deinit();
    try utils.expectRuleAbsent(result, "identifier_case");
}

test "struct fields should be snake_case" {
    var result = try harness.lintStyleRuleFixture(ns, &.{ "identifier_case_bad_field.zig" }, warn, reachability, null, null);
    defer result.deinit();
    try utils.expectRuleCount(result, "identifier_case", 1);
    try std.testing.expectEqual(.field, result.diagnostics.items[0].subject.?.kind);
}

test "enum should be PascalCase and camel or Pascal enumerators are exempt" {
    var result = try harness.lintStyleRuleFixture(ns, &.{ "identifier_case_bad_enum_name.zig" }, warn, reachability, null, null);
    defer result.deinit();
    try utils.expectRuleCount(result, "identifier_case", 1);
    try std.testing.expectEqual(.enumeration, result.diagnostics.items[0].subject.?.kind);
}

test "error set should be PascalCase and error values too" {
    var result = try harness.lintStyleRuleFixture(ns, &.{ "identifier_case_bad_error_set.zig" }, warn, reachability, null, null);
    defer result.deinit();
    try utils.expectRuleCount(result, "identifier_case", 2);
    try std.testing.expectEqual(.error_set, result.diagnostics.items[0].subject.?.kind);
    try std.testing.expectEqual(.error_value, result.diagnostics.items[1].subject.?.kind);
}

test "inline type-expression alias should be PascalCase" {
    var result = try harness.lintStyleRuleFixture(ns, &.{ "identifier_case_bad_type_alias.zig" }, warn, reachability, null, null);
    defer result.deinit();
    try utils.expectRuleCount(result, "identifier_case", 1);
    try std.testing.expectEqualStrings("should be PascalCase", result.diagnostics.items[0].detail.?);
}

test "well-cased inline type alias is clean" {
    var result = try harness.lintStyleRuleFixture(ns, &.{ "identifier_case_good_type_alias.zig" }, warn, reachability, null, null);
    defer result.deinit();
    try utils.expectRuleAbsent(result, "identifier_case");
}

test "idiomatic error set is clean" {
    var result = try harness.lintStyleRuleFixture(ns, &.{ "identifier_case_good_error_set.zig" }, warn, reachability, null, null);
    defer result.deinit();
    try utils.expectRuleAbsent(result, "identifier_case");
}

test "function alias re-export is skipped" {
    var result = try harness.lintStyleRuleFixture(ns, &.{ "identifier_case_reexport_alias_ok.zig" }, warn, reachability, null, null);
    defer result.deinit();
    try utils.expectRuleAbsent(result, "identifier_case");
}

test "quoted identifiers are exempt" {
    var result = try harness.lintStyleRuleFixture(ns, &.{ "identifier_case_quoted_identifier_ok.zig" }, warn, reachability, null, null);
    defer result.deinit();
    try utils.expectRuleAbsent(result, "identifier_case");
}

test "private declarations skipped under public_api_only" {
    var result = try harness.lintStyleRuleFixture(ns, &.{ "identifier_case_private_skipped_public_api.zig" }, warn, public_api, null, null);
    defer result.deinit();
    try utils.expectRuleAbsent(result, "identifier_case");
}

test "private declarations checked when public_api_only is false" {
    var result = try harness.lintStyleRuleFixture(ns, &.{ "identifier_case_private_checked_reachability.zig" }, warn, reachability, null, null);
    defer result.deinit();
    try utils.expectRuleCount(result, "identifier_case", 1);
}

test "detail explains expected case" {
    var result = try harness.lintStyleRuleFixture(ns, &.{ "identifier_case_bad_function_camel.zig" }, warn, reachability, null, null);
    defer result.deinit();
    try utils.expectRuleCount(result, "identifier_case", 1);
    try std.testing.expectEqualStrings("should be camelCase", result.diagnostics.items[0].detail.?);
}

test "struct_file_case snake_case accepts snake_case implicit struct file stem" {
    var result = try harness.lintStyleRuleFixture(ns, &.{ "init_options.zig" }, warn, public_api, "init_options.zig", setSnakeStructFileCase);
    defer result.deinit();
    try utils.expectRuleAbsent(result, "identifier_case");
}

test "default struct_file_case flags snake_case struct file stem" {
    var result = try harness.lintStyleRuleFixture(ns, &.{ "init_options.zig" }, warn, public_api, "init_options.zig", null);
    defer result.deinit();
    try utils.expectRuleCount(result, "identifier_case", 1);
}

test "default struct_file_case accepts PascalCase struct file stem" {
    var result = try harness.lintStyleRuleFixture(ns, &.{ "init_options.zig" }, warn, public_api, "InitOptions.zig", null);
    defer result.deinit();
    try utils.expectRuleAbsent(result, "identifier_case");
}

test "namespace module helper struct does not require matching filename" {
    var result = try harness.lintStyleRuleFixture(ns, &.{ "identifier_case_namespace_helper_struct_ok.zig" }, warn, public_api, "max_fun_params.zig", null);
    defer result.deinit();
    try utils.expectRuleAbsent(result, "identifier_case");
}

test "namespace struct with coincidental snake_case stem is not a struct file pairing" {
    var result = try harness.lintStyleRuleFixture(ns, &.{ "identifier_case_namespace_coincidental_stem_ok.zig" }, warn, public_api, "report.zig", null);
    defer result.deinit();
    try utils.expectRuleAbsent(result, "identifier_case");
}

test "paired PascalCase struct name with snake_case filename stem is accepted under Tiger" {
    var result = try harness.lintStyleRuleFixture(ns, &.{ "identifier_case_paired_struct_snake_file.zig" }, warn, public_api, "init_options.zig", setSnakeStructFileCase);
    defer result.deinit();
    try utils.expectRuleAbsent(result, "identifier_case");
}

test "PascalCase struct file stem is accepted by default" {
    var result = try harness.lintStyleRuleFixture(ns, &.{ "identifier_case_paired_struct_snake_file.zig" }, warn, public_api, "InitOptions.zig", null);
    defer result.deinit();
    try utils.expectRuleAbsent(result, "identifier_case");
}
