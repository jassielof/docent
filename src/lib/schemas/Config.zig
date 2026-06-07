//! Typed configuration schema for `.config/docent.toml`.
//!
//! Struct shapes mirror `schemas/docent.schema.yaml`. `decode` turns parsed TOML into these
//! types; `applyRuleSeverities` projects severity levels into `RuleSeverities`.
const std = @import("std");
const toml = @import("toml");

const RuleSeverities = @import("../RuleSeverities.zig");
const scanning = @import("../scanning.zig");
const severity = @import("../severity.zig");
const rule_config = @import("../rules/config.zig");
const docs_rules = @import("../rules/docs.zig");
const style_rules = @import("../rules/style.zig");
const complexity_rules = @import("../rules/complexity.zig");

pub const Error = rule_config.Error;

pub const Docs = docs_rules.Section;
pub const Style = style_rules.Section;
pub const Complexity = complexity_rules.Section;

docs: Docs = .{},
style: Style = .{},
complexity: Complexity = .{},

/// Parses TOML config text into the dynamic value tree.
pub fn parseRoot(allocator: std.mem.Allocator, text: []const u8) Error!toml.DynamicValue {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");

    if (trimmed.len == 0) {
        const empty = try toml.Table.create(allocator);
        return .{ .table = empty };
    }

    return toml.parseValue(allocator, text) catch return error.ConfigParseFailed;
}

/// Decodes a parsed TOML root into the typed configuration schema.
pub fn decode(root: toml.DynamicValue) Error!@This() {
    const table = rootTable(root) orelse return error.ConfigParseFailed;

    var cfg: @This() = .{};
    if (sectionTable(table, "docs")) |section| cfg.docs = try docs_rules.decodeSection(section);
    if (sectionTable(table, "style")) |section| cfg.style = try style_rules.decodeSection(section);
    if (sectionTable(table, "complexity")) |section| cfg.complexity = try complexity_rules.decodeSection(section);
    return cfg;
}

/// Applies configured severity levels to `rule_set`. Omitted rules keep library defaults.
pub fn applyRuleSeverities(cfg: @This(), rule_set: *RuleSeverities) Error!void {
    try applyDocsSeverities(cfg.docs, rule_set);
    try applyStyleSeverities(cfg.style, rule_set);
    try applyComplexitySeverities(cfg.complexity, rule_set);
}

fn applyDocsSeverities(section: Docs, rule_set: *RuleSeverities) Error!void {
    try applyLevel(&rule_set.missing_doc_comment, section.missing_doc_comment.level);
    try applyLevel(&rule_set.blank_doc_comment, section.blank_doc_comment.level);
    try applyLevel(&rule_set.trailing_blank_doc_comment, section.trailing_blank_doc_comment.level);
    try applyLevel(&rule_set.missing_summary_terminal_punctuation, section.missing_summary_terminal_punctuation.level);
    try applyLevel(&rule_set.missing_doctest, section.missing_doctest.level);
    try applyLevel(&rule_set.private_doctest, section.private_doctest.level);
    try applyLevel(&rule_set.doctest_naming_mismatch, section.doctest_naming_mismatch.level);
    try applyLevel(&rule_set.invalid_leading_phrase, section.invalid_leading_phrase.level);
}

fn applyStyleSeverities(section: Style, rule_set: *RuleSeverities) Error!void {
    try applyLevel(&rule_set.identifier_case, section.identifier_case.level);
    try applyLevel(&rule_set.line_length_limit, section.line_length_limit.level);
}

fn applyComplexitySeverities(section: Complexity, rule_set: *RuleSeverities) Error!void {
    try applyLevel(&rule_set.cognitive_complexity, section.cognitive_complexity.level);
    try applyLevel(&rule_set.cyclomatic_complexity, section.cyclomatic_complexity.level);
    try applyLevel(&rule_set.max_fun_params, section.max_function_parameters.level);
}

fn applyLevel(slot: *severity.Level, configured: ?severity.Level) Error!void {
    const level = configured orelse return;
    if (slot.* == .forbid and level != .forbid) return;
    slot.* = level;
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

test "decode reads nested rule tables and section options" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const root = try parseRoot(arena.allocator(),
        \\[docs.missing_doc_comment]
        \\level = "deny"
        \\check_parameters = true
        \\
        \\[docs]
        \\missing_doctest = "allow"
        \\scan_mode = "all"
        \\
        \\[complexity.cognitive_complexity]
        \\level = "deny"
        \\threshold = 12
    );

    const cfg = try decode(root);
    try std.testing.expectEqual(@as(?severity.Level, .deny), cfg.docs.missing_doc_comment.level);
    try std.testing.expectEqual(@as(?bool, true), cfg.docs.missing_doc_comment.check_parameters);
    try std.testing.expectEqual(@as(?severity.Level, .allow), cfg.docs.missing_doctest.level);
    try std.testing.expectEqual(scanning.Modes.reachability_traversal, cfg.docs.scan_mode.?);
    try std.testing.expectEqual(@as(?severity.Level, .deny), cfg.complexity.cognitive_complexity.level);
    try std.testing.expectEqual(@as(?u32, 12), cfg.complexity.cognitive_complexity.threshold);
}

test "resolved style options read line_length_limit settings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const root = try parseRoot(arena.allocator(),
        \\[style.line_length_limit]
        \\max_length = 80
        \\ignore_trailing_comments = true
    );

    const cfg = try decode(root);
    const style_options = style_rules.Options.resolve(cfg.style);
    try std.testing.expectEqual(@as(u32, 80), style_options.line_length_limit.max_length);
    try std.testing.expect(style_options.line_length_limit.ignore_trailing_comments);
}

test "resolved style options read struct_file_case" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const root = try parseRoot(arena.allocator(),
        \\[style.identifier_case]
        \\struct_file_case = "snake_case"
    );

    const cfg = try decode(root);
    const style_options = style_rules.Options.resolve(cfg.style);
    try std.testing.expectEqual(style_rules.identifier_case.FilenameCase.snake_case, style_options.identifier_case.struct_file_case);
}

test "resolved docs options read invalid_leading_phrase settings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const root = try parseRoot(arena.allocator(),
        \\[docs.invalid_leading_phrase]
        \\mode = "strict"
        \\require_article = true
        \\require_backticks = true
    );

    const cfg = try decode(root);
    const docs_options = docs_rules.Options.resolve(cfg.docs);
    try std.testing.expectEqual(docs_rules.invalid_leading_phrase.Mode.strict, docs_options.invalid_leading_phrase.mode);
    try std.testing.expect(docs_options.invalid_leading_phrase.require_article);
    try std.testing.expect(docs_options.invalid_leading_phrase.require_backticks);
}

test "resolved docs options read check_parameters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const root = try parseRoot(arena.allocator(),
        \\[docs.missing_doc_comment]
        \\level = "warn"
        \\check_parameters = true
    );

    const cfg = try decode(root);
    const docs_options = docs_rules.Options.resolve(cfg.docs);
    try std.testing.expect(docs_options.missing_doc_comment.check_parameters);
}

test "resolved complexity options read thresholds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const root = try parseRoot(arena.allocator(),
        \\[complexity.cognitive_complexity]
        \\threshold = 12
        \\
        \\[complexity.max_function_parameters]
        \\threshold = 5
    );

    const cfg = try decode(root);
    const complexity_options = complexity_rules.Options.resolve(cfg.complexity);
    try std.testing.expectEqual(@as(u32, 12), complexity_options.cognitive.threshold);
    try std.testing.expectEqual(@as(u32, 5), complexity_options.max_fun_params.threshold);
    try std.testing.expectEqual(@as(u32, 10), complexity_options.cyclomatic.threshold);
}

test "scan modes default and override" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const empty = try parseRoot(arena.allocator(), "");
    const empty_cfg = try decode(empty);
    try std.testing.expectEqual(docs_rules.default_scan_mode, empty_cfg.docs.scan_mode orelse docs_rules.default_scan_mode);

    const root = try parseRoot(arena.allocator(),
        \\[docs]
        \\scan_mode = "all"
        \\
        \\[complexity]
        \\scan_mode = "public"
    );
    const cfg = try decode(root);
    try std.testing.expectEqual(scanning.Modes.reachability_traversal, cfg.docs.scan_mode.?);
    try std.testing.expectEqual(scanning.Modes.public_api_surface, cfg.complexity.scan_mode.?);
}

test "applyRuleSeverities respects forbid and defaults" {
    var rule_set: RuleSeverities = .{ .missing_doc_comment = .forbid };
    const cfg: @This() = .{
        .docs = .{ .missing_doc_comment = .{ .level = .warn } },
    };
    try applyRuleSeverities(cfg, &rule_set);
    try std.testing.expect(rule_set.missing_doc_comment == .forbid);
}
