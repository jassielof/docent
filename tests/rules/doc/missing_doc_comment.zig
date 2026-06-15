//! `missing_doc_comment` — public declarations must have doc comments.

const std = @import("std");
const testing = std.testing;
const docent = @import("docent");
const harness = @import("../../harness.zig");
const utils = @import("../../utils.zig");

const ns = "doc";
const deny = docent.RuleSeverities{ .missing_doc_comment = .deny };

fn setCheckParameters(cfg: *docent.rules.doc.Doc) void {
    cfg.missing_doc_comment.options.check_parameters = true;
}

fn setCheckErrorsDisabled(cfg: *docent.rules.doc.Doc) void {
    cfg.missing_doc_comment.options.check_errors = false;
}

test "compliant_pub_declarations has no violations" {
    var result = try harness.lintRuleFixture(ns, &.{"compliant_pub_declarations.zig"}, deny, .{});
    defer result.deinit();
    try utils.expectRuleAbsent(result, "missing_doc_comment");
}

test "deny severity causes hasErrors" {
    var result = try harness.lintRuleFixture(ns, &.{"undocumented_pub_declarations.zig"}, deny, .{});
    defer result.deinit();
    try testing.expect(result.hasErrors());
    try testing.expect(result.errorCount() > 0);
}

test "undocumented_pub_declarations reports at least four diagnostics" {
    var result = try harness.lintRuleFixture(ns, &.{"undocumented_pub_declarations.zig"}, deny, .{});
    defer result.deinit();
    try testing.expect(utils.countRule(result, "missing_doc_comment") >= 4);
}

test "private_struct_members_allowed does not require private field docs" {
    var result = try harness.lintRuleFixture(ns, &.{"private_struct_members_allowed.zig"}, deny, .{});
    defer result.deinit();
    try utils.expectRuleAbsent(result, "missing_doc_comment");
}

test "pub_struct_undocumented_members reports undocumented public members" {
    var result = try harness.lintRuleFixture(ns, &.{"pub_struct_undocumented_members.zig"}, deny, .{});
    defer result.deinit();
    try utils.expectRuleCount(result, "missing_doc_comment", 3);
}

test "detects missing module doc comment on entry root" {
    var result = try harness.lintRuleFixtureDisplay(
        ns,
        &.{ "missing_module_doc_pub_fn_only.zig" },
        deny,
        .{ .module_name = "fixture" },
        "root.zig",
    );
    defer result.deinit();
    try utils.expectRuleCount(result, "missing_doc_comment", 2);
    try testing.expectEqual(.module, result.diagnostics.items[0].subject.?.kind);
    try testing.expectEqualStrings("fixture", result.diagnostics.items[0].subject.?.name);
}

test "no module doc diagnostic when //! present" {
    var result = try harness.lintRuleFixtureDisplay(
        ns,
        &.{ "missing_module_doc_with_doc.zig" },
        deny,
        .{ .module_name = "fixture" },
        "root.zig",
    );
    defer result.deinit();
    try utils.expectRuleCount(result, "missing_doc_comment", 1);
    try testing.expectEqual(.function, result.diagnostics.items[0].subject.?.kind);
}

test "no module doc check when require_module_doc is false" {
    var result = try harness.lintRuleFixture(ns, &.{ "missing_module_doc_pub_fn_only.zig" }, deny, .{});
    defer result.deinit();
    try utils.expectRuleCount(result, "missing_doc_comment", 1);
    try testing.expect(result.diagnostics.items[0].subject.?.kind != .module);
}

test "no extra module doc required inside pub const struct body" {
    var result = try harness.lintRuleFixtureDisplay(
        ns,
        &.{ "missing_module_doc_nested_struct_ok.zig" },
        deny,
        .{ .module_name = "mylib" },
        "root.zig",
    );
    defer result.deinit();
    try utils.expectRuleAbsent(result, "missing_doc_comment");
}

test "detects missing doc comment on pub fn, names the symbol" {
    var result = try harness.lintRuleFixture(ns, &.{ "missing_doc_pub_fn.zig" }, deny, .{});
    defer result.deinit();
    try utils.expectRuleCount(result, "missing_doc_comment", 1);
    try testing.expectEqualStrings("foo", result.diagnostics.items[0].subject.?.name);
    try testing.expectEqual(@as(usize, 3), result.diagnostics.items[0].symbol_len);
}

test "no diagnostic for documented pub fn" {
    var result = try harness.lintRuleFixture(ns, &.{ "missing_doc_pub_fn_ok.zig" }, deny, .{});
    defer result.deinit();
    try utils.expectRuleAbsent(result, "missing_doc_comment");
}

test "no diagnostic for private fn" {
    var result = try harness.lintRuleFixture(ns, &.{ "missing_doc_private_fn_ok.zig" }, deny, .{});
    defer result.deinit();
    try utils.expectRuleAbsent(result, "missing_doc_comment");
}

test "detects missing doc comment on pub const, names the symbol" {
    var result = try harness.lintRuleFixture(ns, &.{ "missing_doc_pub_const.zig" }, deny, .{});
    defer result.deinit();
    try utils.expectRuleCount(result, "missing_doc_comment", 1);
    try testing.expectEqualStrings("answer", result.diagnostics.items[0].subject.?.name);
    try testing.expectEqual(.constant, result.diagnostics.items[0].subject.?.kind);
}

test "detects missing doc comment on pub const error set" {
    var result = try harness.lintRuleFixture(ns, &.{ "missing_doc_error_set.zig" }, deny, .{});
    defer result.deinit();
    try utils.expectRuleCount(result, "missing_doc_comment", 2);
    try testing.expectEqual(.error_set, result.diagnostics.items[0].subject.?.kind);
    try testing.expectEqualStrings("MyErr", result.diagnostics.items[0].subject.?.name);
    try testing.expectEqual(.error_value, result.diagnostics.items[1].subject.?.kind);
    try testing.expectEqualStrings("OutOfMemory", result.diagnostics.items[1].subject.?.name);
}

test "error members are skipped when check_errors is disabled" {
    var result = try harness.lintRuleFixtureConfigured(
        ns,
        &.{ "missing_doc_error_set.zig" },
        deny,
        .{},
        null,
        setCheckErrorsDisabled,
    );
    defer result.deinit();
    try utils.expectRuleCount(result, "missing_doc_comment", 1);
    try testing.expectEqual(.error_set, result.diagnostics.items[0].subject.?.kind);
}

test "documented error members are accepted" {
    var result = try harness.lintRuleFixture(ns, &.{ "missing_doc_error_set_documented_member.zig" }, deny, .{});
    defer result.deinit();
    try utils.expectRuleCount(result, "missing_doc_comment", 1);
    try testing.expectEqual(.error_set, result.diagnostics.items[0].subject.?.kind);
}

test "detects missing doc comment on container fields, names the field" {
    var result = try harness.lintRuleFixture(ns, &.{ "missing_doc_struct_fields.zig" }, deny, .{});
    defer result.deinit();
    try utils.expectRuleCount(result, "missing_doc_comment", 2);
    try testing.expectEqualStrings("x", result.diagnostics.items[0].subject.?.name);
    try testing.expectEqual(.field, result.diagnostics.items[0].subject.?.kind);
    try testing.expectEqualStrings("y", result.diagnostics.items[1].subject.?.name);
    try testing.expectEqual(.field, result.diagnostics.items[1].subject.?.kind);
}

test "detects missing doc comment on pub enum and enumerators" {
    var result = try harness.lintRuleFixture(ns, &.{ "missing_doc_pub_enum.zig" }, deny, .{});
    defer result.deinit();
    try utils.expectRuleCount(result, "missing_doc_comment", 3);
    try testing.expectEqual(.enumeration, result.diagnostics.items[0].subject.?.kind);
    try testing.expectEqualStrings("Color", result.diagnostics.items[0].subject.?.name);
    try testing.expectEqual(.enumerator, result.diagnostics.items[1].subject.?.kind);
    try testing.expectEqualStrings("red", result.diagnostics.items[1].subject.?.name);
    try testing.expectEqual(.enumerator, result.diagnostics.items[2].subject.?.kind);
    try testing.expectEqualStrings("green", result.diagnostics.items[2].subject.?.name);
}

test "no diagnostic for private const struct members and pub fn inside" {
    var result = try harness.lintRuleFixture(ns, &.{ "missing_doc_private_struct_ok.zig" }, deny, .{});
    defer result.deinit();
    try utils.expectRuleAbsent(result, "missing_doc_comment");
}

test "location points to name token, not keyword" {
    var result = try harness.lintRuleFixture(ns, &.{ "missing_doc_pub_fn_mycase.zig" }, deny, .{});
    defer result.deinit();
    try utils.expectRuleCount(result, "missing_doc_comment", 1);
    try testing.expectEqual(@as(usize, 8), result.diagnostics.items[0].column);
}

test "source_line is populated" {
    var result = try harness.lintRuleFixture(ns, &.{ "missing_doc_pub_fn.zig" }, deny, .{});
    defer result.deinit();
    try utils.expectRuleCount(result, "missing_doc_comment", 1);
    try testing.expectEqualStrings("pub fn foo() void {}", result.diagnostics.items[0].source_line);
}

test "re-export with unresolvable import is silently skipped (no false positive)" {
    var result = try harness.lintRuleFixture(ns, &.{ "missing_doc_unresolvable_reexport.zig" }, deny, .{});
    defer result.deinit();
    try utils.expectRuleAbsent(result, "missing_doc_comment");
}

test "re-export through local import alias is recognized" {
    var result = try harness.lintRuleFixture(ns, &.{ "missing_doc_local_reexport_alias.zig" }, deny, .{});
    defer result.deinit();
    try utils.expectRuleAbsent(result, "missing_doc_comment");
}

test "function parameters are not checked by default" {
    var result = try harness.lintRuleFixture(ns, &.{ "missing_doc_fn_params_default_ok.zig" }, deny, .{});
    defer result.deinit();
    try utils.expectRuleAbsent(result, "missing_doc_comment");
}

test "undocumented function parameters are reported when enabled" {
    var result = try harness.lintRuleFixtureConfigured(
        ns,
        &.{ "missing_doc_fn_params_partial.zig" },
        deny,
        .{},
        null,
        setCheckParameters,
    );
    defer result.deinit();
    try utils.expectRuleCount(result, "missing_doc_comment", 1);
    try testing.expectEqual(.parameter, result.diagnostics.items[0].subject.?.kind);
    try testing.expectEqualStrings("value", result.diagnostics.items[0].subject.?.name);
}

test "all documented function parameters are accepted when enabled" {
    var result = try harness.lintRuleFixtureConfigured(
        ns,
        &.{ "missing_doc_fn_params_all_ok.zig" },
        deny,
        .{},
        null,
        setCheckParameters,
    );
    defer result.deinit();
    try utils.expectRuleAbsent(result, "missing_doc_comment");
}

test "unnamed and varargs parameters are skipped when enabled" {
    var result = try harness.lintRuleFixtureConfigured(
        ns,
        &.{ "missing_doc_fn_params_varargs.zig" },
        deny,
        .{},
        null,
        setCheckParameters,
    );
    defer result.deinit();
    try utils.expectRuleCount(result, "missing_doc_comment", 1);
    try testing.expectEqualStrings("args", result.diagnostics.items[0].subject.?.name);
}

test "missing_module_doc_on_entry reports missing module doc comment" {
    var result = try harness.lintRuleFixtureDisplay(
        ns,
        &.{ "missing_module_doc_on_entry.zig" },
        deny,
        .{ .module_name = "fixture" },
        "root.zig",
    );
    defer result.deinit();
    try utils.expectRuleCount(result, "missing_doc_comment", 3);

    var module_doc_count: usize = 0;
    for (result.diagnostics.items) |d| {
        if (std.mem.eql(u8, d.rule, "missing_doc_comment") and
            d.subject != null and d.subject.?.kind == .module and
            std.mem.eql(u8, d.subject.?.name, "fixture"))
        {
            module_doc_count += 1;
        }
    }
    try testing.expectEqual(@as(usize, 1), module_doc_count);
}

test "lintSource honors require_function_param_docs option" {
    const source: [:0]const u8 =
        \\/// Does something.
        \\pub fn foo(allocator: std.mem.Allocator) void {
        \\    _ = allocator;
        \\}
    ;
    var doc_cfg = docent.rules.doc.Doc.defaults();
    doc_cfg.missing_doc_comment.level = .deny;
    doc_cfg.missing_doc_comment.options.check_parameters = true;
    var result = try docent.lintSource(
        std.testing.allocator,
        std.testing.io,
        source,
        "<test>",
        .{},
        &.{},
        doc_cfg,
    );
    defer result.deinit();
    try utils.expectRuleCount(result, "missing_doc_comment", 1);
    try testing.expectEqual(.parameter, result.diagnostics.items[0].subject.?.kind);
    try testing.expectEqualStrings("allocator", result.diagnostics.items[0].subject.?.name);
}

test "unresolvable import produces no false positive in single-file mode" {
    const source: [:0]const u8 =
        "//! Module.\npub const Foo = @import(\"definitely_nonexistent_xyz.zig\").Bar;";
    var doc_cfg = docent.rules.doc.Doc.defaults();
    doc_cfg.missing_doc_comment.level = .deny;
    var result = try docent.lintSource(
        std.testing.allocator,
        std.testing.io,
        source,
        "<fake-file.zig>",
        .{},
        &.{},
        doc_cfg,
    );
    defer result.deinit();
    try utils.expectRuleAbsent(result, "missing_doc_comment");
}
