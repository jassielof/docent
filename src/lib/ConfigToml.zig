//! Parses `.config/docent.toml` into rule severities and per-command options.

const std = @import("std");
const toml = @import("toml");

const RuleSet = @import("RuleSet.zig");
const severity = @import("severity.zig");
const ComplexityOptions = @import("ComplexityOptions.zig");
const DocsOptions = @import("DocsOptions.zig");

pub const Error = error{
    ConfigParseFailed,
    InvalidSeverity,
    OutOfMemory,
};

const SectionRule = struct {
    config_key: []const u8,
    rule_field: []const u8,
};

const docs_rules = [_]SectionRule{
    .{ .config_key = "missing_doc_comment", .rule_field = "missing_doc_comment" },
    .{ .config_key = "blank_doc_comment", .rule_field = "blank_doc_comment" },
    .{ .config_key = "trailing_blank_doc_comment", .rule_field = "trailing_blank_doc_comment" },
    .{ .config_key = "missing_summary_terminal_punctuation", .rule_field = "missing_summary_terminal_punctuation" },
    .{ .config_key = "missing_doctest", .rule_field = "missing_doctest" },
    .{ .config_key = "private_doctest", .rule_field = "private_doctest" },
    .{ .config_key = "doctest_naming_mismatch", .rule_field = "doctest_naming_mismatch" },
    .{ .config_key = "invalid_leading_phrase", .rule_field = "invalid_leading_phrase" },
};

const style_rules = [_]SectionRule{
    .{ .config_key = "identifier_case", .rule_field = "identifier_case" },
};

const complexity_rules = [_]SectionRule{
    .{ .config_key = "cognitive_complexity", .rule_field = "cognitive_complexity" },
    .{ .config_key = "cyclomatic_complexity", .rule_field = "cyclomatic_complexity" },
    .{ .config_key = "max_function_parameters", .rule_field = "max_fun_params" },
};

const ThresholdRule = struct {
    config_key: []const u8,
    options_field: []const u8,
};

const complexity_thresholds = [_]ThresholdRule{
    .{ .config_key = "cognitive_complexity", .options_field = "cognitive_threshold" },
    .{ .config_key = "cyclomatic_complexity", .options_field = "cyclomatic_threshold" },
    .{ .config_key = "max_function_parameters", .options_field = "max_fun_params_threshold" },
};

/// Parses TOML config text into the dynamic value tree.
pub fn parseRoot(allocator: std.mem.Allocator, text: []const u8) Error!toml.DynamicValue {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) {
        const empty = try toml.Table.create(allocator);
        return .{ .table = empty };
    }

    return toml.parseValue(allocator, text) catch return error.ConfigParseFailed;
}

/// Applies `[docs]`, `[style]`, and `[complexity]` rule severities to `rule_set`.
pub fn applyRuleSet(root: toml.DynamicValue, rule_set: *RuleSet) Error!void {
    const table = rootTable(root) orelse return error.ConfigParseFailed;

    if (sectionTable(table, "docs")) |docs| try applySectionRules(rule_set, docs, &docs_rules);
    if (sectionTable(table, "style")) |style| try applySectionRules(rule_set, style, &style_rules);
    if (sectionTable(table, "complexity")) |complexity| try applySectionRules(rule_set, complexity, &complexity_rules);
}

/// Applies documentation rule options from the `[docs]` section.
pub fn applyDocsOptions(root: toml.DynamicValue, options: *DocsOptions) Error!void {
    const table = rootTable(root) orelse return error.ConfigParseFailed;
    const docs = sectionTable(table, "docs") orelse return;

    if (docs.get("missing_doc_comment")) |rule_value| {
        if (ruleValueBool(rule_value, "check_parameters")) |enabled| {
            options.require_function_param_docs = enabled;
        }
    }
}

/// Applies complexity thresholds from the `[complexity]` section.
pub fn applyComplexityOptions(root: toml.DynamicValue, options: *ComplexityOptions) Error!void {
    const table = rootTable(root) orelse return error.ConfigParseFailed;
    const complexity = sectionTable(table, "complexity") orelse return;

    inline for (complexity_thresholds) |mapping| {
        if (complexity.get(mapping.config_key)) |rule_value| {
            if (ruleValueU32(rule_value, "threshold")) |threshold| {
                @field(options, mapping.options_field) = threshold;
            }
        }
    }
}

/// Returns whether doc rules should restrict checks to public declarations (default: true).
pub fn docsPublicApiOnly(root: toml.DynamicValue) Error!bool {
    return scanModePublicApiOnly(root, "docs", true);
}

/// Returns whether complexity rules should restrict checks to public declarations (default: false).
pub fn complexityPublicApiOnly(root: toml.DynamicValue) Error!bool {
    return scanModePublicApiOnly(root, "complexity", false);
}

/// Returns whether style rules should restrict checks to public declarations (default: false).
pub fn stylePublicApiOnly(root: toml.DynamicValue) Error!bool {
    return scanModePublicApiOnly(root, "style", false);
}

fn rootTable(root: toml.DynamicValue) ?*const toml.Table {
    return switch (root) {
        .table => |table| table,
        else => null,
    };
}

fn sectionTable(root: *const toml.Table, key: []const u8) ?*const toml.Table {
    const value = root.get(key) orelse return null;
    return switch (value) {
        .table => |table| table,
        else => null,
    };
}

fn applySectionRules(
    rule_set: *RuleSet,
    section: *const toml.Table,
    comptime rules: []const SectionRule,
) Error!void {
    inline for (rules) |mapping| {
        if (section.get(mapping.config_key)) |rule_value| {
            try applyRuleToSet(rule_set, mapping.rule_field, rule_value);
        }
    }
}

fn applyRuleToSet(rule_set: *RuleSet, comptime field: []const u8, value: toml.DynamicValue) Error!void {
    const level_name = std.mem.trim(u8, try ruleLevelName(value), " \t\r\n");
    if (level_name.len == 0) return;

    const level = std.meta.stringToEnum(severity.Level, level_name) orelse return error.InvalidSeverity;
    setRuleLevel(rule_set, field, level);
}

fn ruleLevelName(value: toml.DynamicValue) Error![]const u8 {
    return switch (value) {
        .string => |string_value| string_value.bytes,
        .table => |table| {
            const level_value = table.get("level") orelse return "";
            return level_value.stringSlice() orelse return error.ConfigParseFailed;
        },
        .boolean, .integer, .float, .array => return "",
        else => return error.ConfigParseFailed,
    };
}

fn ruleValueBool(value: toml.DynamicValue, key: []const u8) ?bool {
    return switch (value) {
        .table => |table| {
            const field_value = table.get(key) orelse return null;
            return switch (field_value) {
                .boolean => |enabled| enabled,
                else => null,
            };
        },
        else => null,
    };
}

fn ruleValueU32(value: toml.DynamicValue, key: []const u8) ?u32 {
    return switch (value) {
        .table => |table| {
            const field_value = table.get(key) orelse return null;
            return switch (field_value) {
                .integer => |integer_value| std.math.cast(u32, integer_value) orelse null,
                else => null,
            };
        },
        else => null,
    };
}

fn scanModePublicApiOnly(root: toml.DynamicValue, section_key: []const u8, default_public_api_only: bool) Error!bool {
    const table = rootTable(root) orelse return error.ConfigParseFailed;
    const section = sectionTable(table, section_key) orelse return default_public_api_only;
    const scan_mode = section.get("scan_mode") orelse return default_public_api_only;
    const mode = scan_mode.stringSlice() orelse return error.ConfigParseFailed;

    if (std.mem.eql(u8, mode, "public")) return true;
    if (std.mem.eql(u8, mode, "all")) return false;
    return error.ConfigParseFailed;
}

fn setRuleLevel(rule_set: *RuleSet, comptime field: []const u8, level: severity.Level) void {
    const current = @field(rule_set.*, field);
    if (current == .forbid and level != .forbid) return;
    @field(rule_set, field) = level;
}

test "applyRuleSet reads manifest fixture file from disk" {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const rel = "tests/fixtures/scenarios/manifest_with_deps/.config/docent.toml";
    const len = std.Io.Dir.cwd().realPathFile(std.testing.io, rel, &buf) catch return error.SkipZigTest;
    const config_path = buf[0..len];

    const config_text = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        config_path,
        std.testing.allocator,
        .limited(1024 * 1024),
    ) catch return error.SkipZigTest;
    defer std.testing.allocator.free(config_text);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const root = try parseRoot(arena.allocator(), config_text);
    var rule_set: RuleSet = .{};
    try applyRuleSet(root, &rule_set);

    try std.testing.expect(rule_set.missing_doc_comment == .deny);
    try std.testing.expect(rule_set.missing_doctest == .allow);
}

test "applyRuleSet reads manifest fixture config" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const root = try parseRoot(arena.allocator(),
        \\[docs.missing_doc_comment]
        \\level = "deny"
        \\
        \\[docs]
        \\missing_doctest = "allow"
    );

    var rule_set: RuleSet = .{};
    try applyRuleSet(root, &rule_set);

    try std.testing.expect(rule_set.missing_doc_comment == .deny);
    try std.testing.expect(rule_set.missing_doctest == .allow);
}

test "applyRuleSet reads docs and complexity sections" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const root = try parseRoot(arena.allocator(),
        \\[docs.missing_doc_comment]
        \\level = "deny"
        \\
        \\[docs]
        \\missing_doctest = "allow"
        \\
        \\[complexity.cognitive_complexity]
        \\level = "deny"
    );

    var rule_set: RuleSet = .{};
    try applyRuleSet(root, &rule_set);

    try std.testing.expect(rule_set.missing_doc_comment == .deny);
    try std.testing.expect(rule_set.missing_doctest == .allow);
    try std.testing.expect(rule_set.cognitive_complexity == .deny);
    try std.testing.expect(rule_set.blank_doc_comment == .warn);
}

test "applyDocsOptions reads check_parameters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const root = try parseRoot(arena.allocator(),
        \\[docs.missing_doc_comment]
        \\level = "warn"
        \\check_parameters = true
    );

    var options: DocsOptions = .{};
    try applyDocsOptions(root, &options);
    try std.testing.expect(options.require_function_param_docs);
}

test "applyComplexityOptions reads thresholds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const root = try parseRoot(arena.allocator(),
        \\[complexity.cognitive_complexity]
        \\threshold = 12
        \\
        \\[complexity.max_function_parameters]
        \\threshold = 5
    );

    var options: ComplexityOptions = .{};
    try applyComplexityOptions(root, &options);
    try std.testing.expectEqual(@as(u32, 12), options.cognitive_threshold);
    try std.testing.expectEqual(@as(u32, 5), options.max_fun_params_threshold);
    try std.testing.expectEqual(@as(u32, 10), options.cyclomatic_threshold);
}

test "scan modes default and override" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const empty = try parseRoot(arena.allocator(), "");
    try std.testing.expect(try docsPublicApiOnly(empty));
    try std.testing.expect(!try complexityPublicApiOnly(empty));

    const root = try parseRoot(arena.allocator(),
        \\[docs]
        \\scan_mode = "all"
        \\
        \\[complexity]
        \\scan_mode = "public"
    );
    try std.testing.expect(!try docsPublicApiOnly(root));
    try std.testing.expect(try complexityPublicApiOnly(root));
}
