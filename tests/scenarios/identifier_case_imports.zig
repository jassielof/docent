//! `identifier_case` import-path scenarios requiring multi-file fixtures.

const std = @import("std");
const docent = @import("docent");
const harness = @import("../harness.zig");
const utils = @import("../utils.zig");

fn lintScenario(rel: []const u8, configure: ?*const fn (*docent.rules.style.Style) void) !docent.LintResult {
    const path = try harness.scenarioProjectPath("identifier_case_imports", rel);
    defer std.testing.allocator.free(path);
    const source = try harness.readFixtureFile(std.testing.allocator, std.testing.io, path);
    defer std.testing.allocator.free(source);
    const display = try harness.scenarioProjectPath("identifier_case_imports", "import_site.zig");
    defer std.testing.allocator.free(display);

    var style_cfg = docent.rules.style.Style.defaults();
    if (configure) |configure_fn| configure_fn(&style_cfg);
    return docent.lintStyleSource(std.testing.allocator, std.testing.io, source, display, style_cfg);
}

fn setSnakeStructFileCase(cfg: *docent.rules.style.Style) void {
    cfg.identifier_case.options.struct_file_case = .snake_case;
}

test "import member re-export does not flag PascalCase binding" {
    var result = try lintScenario("import_member_reexport.zig", null);
    defer result.deinit();
    try utils.expectRuleAbsent(result, "identifier_case");
}

test "PascalCase binding on namespace import is flagged" {
    var result = try lintScenario("import_bad_namespace_binding.zig", null);
    defer result.deinit();
    try std.testing.expect(utils.countRule(result, "identifier_case") >= 2);

    var found_binding = false;
    var found_filename = false;
    for (result.diagnostics.items) |d| {
        if (!std.mem.eql(u8, d.rule, "identifier_case")) continue;
        if (d.subject) |s| {
            if (s.kind == .namespace and std.mem.eql(u8, s.name, "Severity")) found_binding = true;
            if (s.kind == .source_file and std.mem.eql(u8, s.name, "BadNamespace.zig")) found_filename = true;
        }
        if (d.detail) |detail| {
            if (std.mem.indexOf(u8, detail, "bad_namespace.zig") != null) found_filename = true;
        }
    }
    try std.testing.expect(found_binding);
    try std.testing.expect(found_filename);
}

test "PascalCase basename on namespace import is flagged" {
    var result = try lintScenario("import_bad_namespace_filename.zig", null);
    defer result.deinit();
    try utils.expectRuleCount(result, "identifier_case", 1);
    try std.testing.expectEqual(.source_file, result.diagnostics.items[0].subject.?.kind);
    try std.testing.expectEqualStrings("BadNamespace.zig", result.diagnostics.items[0].subject.?.name);
    try std.testing.expect(std.mem.indexOf(u8, result.diagnostics.items[0].detail.?, "snake_case filename") != null);
}

test "snake_case basename on struct-at-file-scope import is not flagged" {
    var result = try lintScenario("import_snake_struct_file.zig", null);
    defer result.deinit();
    try utils.expectRuleAbsent(result, "identifier_case");
}

test "zig convention accepts PascalCase struct import paths" {
    var result = try lintScenario("import_pascal_struct_file.zig", null);
    defer result.deinit();
    try utils.expectRuleAbsent(result, "identifier_case");
}

test "zig convention flags snake_case struct import paths" {
    var result = try lintScenario("import_snake_struct_binding.zig", null);
    defer result.deinit();
    try std.testing.expect(utils.countRule(result, "identifier_case") >= 2);
}

test "snake_case struct import binding is flagged even under Tiger filenames" {
    var result = try lintScenario("import_snake_struct_binding.zig", setSnakeStructFileCase);
    defer result.deinit();
    var found_binding = false;
    for (result.diagnostics.items) |d| {
        if (!std.mem.eql(u8, d.rule, "identifier_case")) continue;
        if (d.subject) |s| {
            if (s.kind == .structure and std.mem.eql(u8, s.name, "init_options")) found_binding = true;
        }
    }
    try std.testing.expect(found_binding);
}

test "PascalCase binding on snake_case struct import path is clean under Tiger" {
    var result = try lintScenario("import_snake_struct_binding_ok.zig", setSnakeStructFileCase);
    defer result.deinit();
    try utils.expectRuleAbsent(result, "identifier_case");
}
