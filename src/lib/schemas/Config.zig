//! Typed configuration schema for `.config/docent.toml`.
//!
//! Struct shapes mirror `schemas/docent.schema.yaml`. `decode` turns parsed TOML into these
//! types; `applyRuleSeverities` projects severity levels into `RuleSeverities`.
const std = @import("std");
const toml = @import("toml");

const RuleSeverities = @import("../RuleSeverities.zig");
const scanning = @import("../scanning.zig");
const severity = @import("../severity.zig");
const rule_decode = @import("../rules/decode.zig");
const doc_rules = @import("../rules/doc.zig");
const style_rules = @import("../rules/style.zig");
const complexity_rules = @import("../rules/complexity.zig");

pub const Error = rule_decode.Error;

pub const Doc = doc_rules.Doc;
pub const Style = style_rules.Style;
pub const Complexity = complexity_rules.Complexity;

doc: Doc = .{},
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
    if (table.get("doc")) |value| try rule_decode.decodeInto(Doc, value, &cfg.doc);
    cfg.doc.resolveScanModes();
    if (table.get("style")) |value| try rule_decode.decodeInto(Style, value, &cfg.style);
    cfg.style.resolveScanModes();
    if (table.get("complexity")) |value| try rule_decode.decodeInto(Complexity, value, &cfg.complexity);
    cfg.complexity.resolveScanModes();
    return cfg;
}

/// Applies configured severity levels to `rule_set`. Omitted rules keep library defaults.
pub fn applyRuleSeverities(cfg: @This(), rule_set: *RuleSeverities) Error!void {
    try applyDocSeverities(cfg.doc, rule_set);
    try applyStyleSeverities(cfg.style, rule_set);
    try applyComplexitySeverities(cfg.complexity, rule_set);
}

fn applyStyleSeverities(section: Style, rule_set: *RuleSeverities) Error!void {
    try applyLevel(&rule_set.identifier_case, section.identifier_case.level);
    try applyLevel(&rule_set.line_length_limit, section.line_length_limit.level);
}

fn applyDocSeverities(section: Doc, rule_set: *RuleSeverities) Error!void {
    try applyLevel(&rule_set.missing_doc_comment, section.missing_doc_comment.level);
    try applyLevel(&rule_set.blank_doc_comment, section.blank_doc_comment.level);
    try applyLevel(&rule_set.trailing_blank_doc_comment, section.trailing_blank_doc_comment.level);
    try applyLevel(&rule_set.missing_summary_terminal_punctuation, section.missing_summary_terminal_punctuation.level);
    try applyLevel(&rule_set.missing_doctest, section.missing_doctest.level);
    try applyLevel(&rule_set.private_doctest, section.private_doctest.level);
    try applyLevel(&rule_set.doctest_naming_mismatch, section.doctest_naming_mismatch.level);
    try applyLevel(&rule_set.invalid_leading_phrase, section.invalid_leading_phrase.level);
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

test "decode reads nested rule tables and section options" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const root = try parseRoot(arena.allocator(),
        \\[doc.missing_doc_comment]
        \\level = "deny"
        \\check_parameters = true
        \\
        \\[doc]
        \\missing_doctest = "allow"
        \\scan_mode = "all"
        \\
        \\[complexity.cognitive_complexity]
        \\level = "deny"
        \\threshold = 12
    );

    const cfg = try decode(root);
    try std.testing.expectEqual(severity.Level.deny, cfg.doc.missing_doc_comment.level);
    try std.testing.expect(cfg.doc.missing_doc_comment.options.check_parameters);
    try std.testing.expectEqual(severity.Level.allow, cfg.doc.missing_doctest.level);
    try std.testing.expectEqual(scanning.Modes.reachability_traversal, cfg.doc.scan_mode);
    try std.testing.expectEqual(severity.Level.deny, cfg.complexity.cognitive_complexity.level);
    try std.testing.expectEqual(@as(u32, 12), cfg.complexity.cognitive_complexity.options.threshold);
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
    try std.testing.expectEqual(@as(u32, 80), cfg.style.line_length_limit.options.max_length);
    try std.testing.expect(cfg.style.line_length_limit.options.ignore_trailing_comments);
}

test "resolved style options read struct_file_case" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const root = try parseRoot(arena.allocator(),
        \\[style.identifier_case]
        \\struct_file_case = "snake_case"
    );

    const cfg = try decode(root);
    try std.testing.expectEqual(style_rules.identifier_case.FilenameCase.snake_case, cfg.style.identifier_case.options.struct_file_case);
}

test "resolved docs options read invalid_leading_phrase settings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const root = try parseRoot(arena.allocator(),
        \\[doc.invalid_leading_phrase]
        \\mode = "strict"
        \\require_article = true
        \\require_backticks = true
    );

    const cfg = try decode(root);
    const phrase = cfg.doc.invalid_leading_phrase.options;
    try std.testing.expectEqual(doc_rules.invalid_leading_phrase.Mode.strict, phrase.mode);
    try std.testing.expect(phrase.require_article);
    try std.testing.expect(phrase.require_backticks);
}

test "resolved style options read struct_file_case quoted identifier" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const root = try parseRoot(arena.allocator(),
        \\[style.identifier_case]
        \\struct_file_case = '@"kebab-case"'
    );

    const cfg = try decode(root);
    try std.testing.expectEqual(style_rules.identifier_case.FilenameCase.@"kebab-case", cfg.style.identifier_case.options.struct_file_case);
}

test "resolved docs options read check_parameters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const root = try parseRoot(arena.allocator(),
        \\[doc.missing_doc_comment]
        \\level = "warn"
        \\check_parameters = true
    );

    const cfg = try decode(root);
    try std.testing.expect(cfg.doc.missing_doc_comment.options.check_parameters);
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
    try std.testing.expectEqual(@as(u32, 12), cfg.complexity.cognitive_complexity.options.threshold);
    try std.testing.expectEqual(@as(u32, 5), cfg.complexity.max_function_parameters.options.threshold);
    try std.testing.expectEqual(@as(u32, 10), cfg.complexity.cyclomatic_complexity.options.threshold);
}

test "scan modes default and override" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const empty = try parseRoot(arena.allocator(), "");
    const empty_cfg = try decode(empty);
    try std.testing.expectEqual(doc_rules.default_scan_mode, empty_cfg.doc.scan_mode);

    const root = try parseRoot(arena.allocator(),
        \\[doc]
        \\scan_mode = "all"
        \\
        \\[complexity]
        \\scan_mode = "public"
    );
    const cfg = try decode(root);
    try std.testing.expectEqual(scanning.Modes.reachability_traversal, cfg.doc.scan_mode);
    try std.testing.expectEqual(scanning.Modes.public_api_surface, cfg.complexity.scan_mode);
}

test "applyRuleSeverities respects forbid and defaults" {
    var rule_set: RuleSeverities = .{ .missing_doc_comment = .forbid };
    const cfg: @This() = .{
        .doc = .{ .missing_doc_comment = .{ .level = .warn } },
    };
    try applyRuleSeverities(cfg, &rule_set);
    try std.testing.expect(rule_set.missing_doc_comment == .forbid);
}
