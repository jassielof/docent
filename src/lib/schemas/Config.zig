//! Typed configuration schema for `.config/docent.toml`.
//!
//! Struct shapes mirror `schemas/docent.schema.yaml`. `decode` turns parsed TOML into these
//! types; `applyRuleSeverities` projects severity levels into `RuleSeverities`.
const std = @import("std");
const toml = @import("toml");

const RuleSeverities = @import("../RuleSeverities.zig");
const scanning = @import("../scanning.zig");
const severity = @import("../severity.zig");

pub const Error = error{
    ConfigParseFailed,
    InvalidSeverity,
    InvalidScanMode,
    OutOfMemory,
};

const rules = @import("../rules.zig");

/// Rule with only severity and an optional scan-mode override.
pub const RuleSimple = struct {
    level: ?severity.Level = null,
    scan_mode: ?scanning.Modes = null,
};

/// Threshold rule shared by complexity rules.
pub const RuleThreshold = struct {
    level: ?severity.Level = null,
    scan_mode: ?scanning.Modes = null,
    threshold: ?u32 = null,
};

/// `[docs.missing_doc_comment]` options.
pub const MissingDocCommentRule = struct {
    level: ?severity.Level = null,
    scan_mode: ?scanning.Modes = null,
    check_parameters: ?bool = null,
};

/// Leading-phrase strictness for `[docs.invalid_leading_phrase]`.
pub const LeadingPhraseMode = enum {
    relaxed,
    canonical,
    strict,
};

/// `[docs.invalid_leading_phrase]` options.
pub const InvalidLeadingPhraseRule = struct {
    level: ?severity.Level = null,
    scan_mode: ?scanning.Modes = null,
    mode: ?LeadingPhraseMode = null,
    require_article: ?bool = null,
    require_backticks: ?bool = null,
};

/// `[style.identifier_case]` options.
pub const IdentifierCaseRule = struct {
    level: ?severity.Level = null,
    scan_mode: ?scanning.Modes = null,
    allow_snake_case_struct_files: ?bool = null,
};

/// `[style.line_length_limit]` options.
pub const LineLengthLimitRule = struct {
    level: ?severity.Level = null,
    scan_mode: ?scanning.Modes = null,
    max_length: ?u32 = null,
    ignore_trailing_comments: ?bool = null,
};

pub const Docs = struct {
    scan_mode: ?scanning.Modes = null,
    missing_doc_comment: MissingDocCommentRule = .{},
    blank_doc_comment: RuleSimple = .{},
    trailing_blank_doc_comment: RuleSimple = .{},
    missing_summary_terminal_punctuation: RuleSimple = .{},
    missing_doctest: RuleSimple = .{},
    private_doctest: RuleSimple = .{},
    doctest_naming_mismatch: RuleSimple = .{},
    invalid_leading_phrase: InvalidLeadingPhraseRule = .{},
};

pub const Style = struct {
    scan_mode: ?scanning.Modes = null,
    identifier_case: IdentifierCaseRule = .{},
    line_length_limit: LineLengthLimitRule = .{},
};

pub const Complexity = struct {
    scan_mode: ?scanning.Modes = null,
    cognitive_complexity: RuleThreshold = .{},
    cyclomatic_complexity: RuleThreshold = .{},
    max_function_parameters: RuleThreshold = .{},
};

pub const Root = struct {
    docs: Docs = .{},
    style: Style = .{},
    complexity: Complexity = .{},
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

/// Decodes a parsed TOML root into the typed configuration schema.
pub fn decode(root: toml.DynamicValue) Error!Root {
    const table = rootTable(root) orelse return error.ConfigParseFailed;

    var cfg: Root = .{};
    if (sectionTable(table, "docs")) |docs| cfg.docs = try decodeDocs(docs);
    if (sectionTable(table, "style")) |style| cfg.style = try decodeStyle(style);
    if (sectionTable(table, "complexity")) |complexity| cfg.complexity = try decodeComplexity(complexity);
    return cfg;
}

/// Applies configured severity levels to `rule_set`. Omitted rules keep library defaults.
pub fn applyRuleSeverities(cfg: Root, rule_set: *RuleSeverities) Error!void {
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

fn decodeDocs(section: *const toml.Table) Error!Docs {
    var docs: Docs = .{};
    if (section.get("scan_mode")) |value| docs.scan_mode = try decodeScanModeValue(value);
    if (section.get("missing_doc_comment")) |value| docs.missing_doc_comment = try decodeMissingDocComment(value);
    if (section.get("blank_doc_comment")) |value| docs.blank_doc_comment = try decodeRuleSimple(value);
    if (section.get("trailing_blank_doc_comment")) |value| docs.trailing_blank_doc_comment = try decodeRuleSimple(value);
    if (section.get("missing_summary_terminal_punctuation")) |value| docs.missing_summary_terminal_punctuation = try decodeRuleSimple(value);
    if (section.get("missing_doctest")) |value| docs.missing_doctest = try decodeRuleSimple(value);
    if (section.get("private_doctest")) |value| docs.private_doctest = try decodeRuleSimple(value);
    if (section.get("doctest_naming_mismatch")) |value| docs.doctest_naming_mismatch = try decodeRuleSimple(value);
    if (section.get("invalid_leading_phrase")) |value| docs.invalid_leading_phrase = try decodeInvalidLeadingPhrase(value);
    return docs;
}

fn decodeStyle(section: *const toml.Table) Error!Style {
    var style: Style = .{};
    if (section.get("scan_mode")) |value| style.scan_mode = try decodeScanModeValue(value);
    if (section.get("identifier_case")) |value| style.identifier_case = try decodeIdentifierCase(value);
    if (section.get("line_length_limit")) |value| style.line_length_limit = try decodeLineLengthLimit(value);
    return style;
}

fn decodeComplexity(section: *const toml.Table) Error!Complexity {
    var complexity: Complexity = .{};
    if (section.get("scan_mode")) |value| complexity.scan_mode = try decodeScanModeValue(value);
    if (section.get("cognitive_complexity")) |value| complexity.cognitive_complexity = try decodeRuleThreshold(value);
    if (section.get("cyclomatic_complexity")) |value| complexity.cyclomatic_complexity = try decodeRuleThreshold(value);
    if (section.get("max_function_parameters")) |value| complexity.max_function_parameters = try decodeRuleThreshold(value);
    return complexity;
}

fn decodeRuleSimple(value: toml.DynamicValue) Error!RuleSimple {
    return .{
        .level = try decodeLevelValue(value),
        .scan_mode = decodeScanModeField(value),
    };
}

fn decodeRuleThreshold(value: toml.DynamicValue) Error!RuleThreshold {
    return .{
        .level = try decodeLevelValue(value),
        .scan_mode = decodeScanModeField(value),
        .threshold = decodeThresholdField(value),
    };
}

fn decodeMissingDocComment(value: toml.DynamicValue) Error!MissingDocCommentRule {
    return .{
        .level = try decodeLevelValue(value),
        .scan_mode = decodeScanModeField(value),
        .check_parameters = decodeBoolField(value, "check_parameters"),
    };
}

fn decodeInvalidLeadingPhrase(value: toml.DynamicValue) Error!InvalidLeadingPhraseRule {
    return .{
        .level = try decodeLevelValue(value),
        .scan_mode = decodeScanModeField(value),
        .mode = decodeLeadingPhraseModeField(value),
        .require_article = decodeBoolField(value, "require_article"),
        .require_backticks = decodeBoolField(value, "require_backticks"),
    };
}

fn decodeIdentifierCase(value: toml.DynamicValue) Error!IdentifierCaseRule {
    return .{
        .level = try decodeLevelValue(value),
        .scan_mode = decodeScanModeField(value),
        .allow_snake_case_struct_files = decodeBoolField(value, "allow_snake_case_struct_files"),
    };
}

fn decodeLineLengthLimit(value: toml.DynamicValue) Error!LineLengthLimitRule {
    return .{
        .level = try decodeLevelValue(value),
        .scan_mode = decodeScanModeField(value),
        .max_length = decodeU32Field(value, "max_length"),
        .ignore_trailing_comments = decodeBoolField(value, "ignore_trailing_comments"),
    };
}

fn decodeLevelValue(value: toml.DynamicValue) Error!?severity.Level {
    const level_name = std.mem.trim(u8, try ruleLevelName(value), " \t\r\n");
    if (level_name.len == 0) return null;
    return std.meta.stringToEnum(severity.Level, level_name) orelse return error.InvalidSeverity;
}

fn decodeScanModeValue(value: toml.DynamicValue) Error!scanning.Modes {
    const mode = value.stringSlice() orelse return error.ConfigParseFailed;
    return scanning.Modes.fromConfigString(mode) orelse return error.InvalidScanMode;
}

fn decodeScanModeField(value: toml.DynamicValue) ?scanning.Modes {
    return switch (value) {
        .table => |table| blk: {
            const field_value = table.get("scan_mode") orelse return null;
            const mode = field_value.stringSlice() orelse return null;
            break :blk scanning.Modes.fromConfigString(mode);
        },
        else => null,
    };
}

fn decodeThresholdField(value: toml.DynamicValue) ?u32 {
    return decodeU32Field(value, "threshold");
}

fn decodeU32Field(value: toml.DynamicValue, key: []const u8) ?u32 {
    return switch (value) {
        .table => |table| blk: {
            const field_value = table.get(key) orelse return null;
            break :blk switch (field_value) {
                .integer => |integer_value| std.math.cast(u32, integer_value) orelse null,
                else => null,
            };
        },
        else => null,
    };
}

fn decodeBoolField(value: toml.DynamicValue, key: []const u8) ?bool {
    return switch (value) {
        .table => |table| blk: {
            const field_value = table.get(key) orelse return null;
            break :blk switch (field_value) {
                .boolean => |enabled| enabled,
                else => null,
            };
        },
        else => null,
    };
}

fn decodeLeadingPhraseModeField(value: toml.DynamicValue) ?LeadingPhraseMode {
    const mode_name = decodeStringField(value, "mode") orelse return null;
    return std.meta.stringToEnum(LeadingPhraseMode, mode_name);
}

fn decodeStringField(value: toml.DynamicValue, key: []const u8) ?[]const u8 {
    return switch (value) {
        .table => |table| blk: {
            const field_value = table.get(key) orelse return null;
            break :blk field_value.stringSlice();
        },
        else => null,
    };
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
    const style_options = @import("../rules/style.zig").Options.resolve(cfg.style);
    try std.testing.expectEqual(@as(u32, 80), style_options.line_length_limit.max_length);
    try std.testing.expect(style_options.line_length_limit.ignore_trailing_comments);
}

test "resolved style options read allow_snake_case_struct_files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const root = try parseRoot(arena.allocator(),
        \\[style.identifier_case]
        \\allow_snake_case_struct_files = true
    );

    const cfg = try decode(root);
    const style_options = @import("../rules/style.zig").Options.resolve(cfg.style);
    try std.testing.expect(style_options.identifier_case.allow_snake_case_struct_files);
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
    const docs_options = @import("../rules/docs.zig").Options.resolve(cfg.docs);
    try std.testing.expectEqual(LeadingPhraseMode.strict, docs_options.invalid_leading_phrase.mode);
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
    const docs_options = @import("../rules/docs.zig").Options.resolve(cfg.docs);
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
    const complexity_options = @import("../rules/complexity.zig").Options.resolve(cfg.complexity);
    try std.testing.expectEqual(@as(u32, 12), complexity_options.cognitive.threshold);
    try std.testing.expectEqual(@as(u32, 5), complexity_options.max_fun_params.threshold);
    try std.testing.expectEqual(@as(u32, 10), complexity_options.cyclomatic.threshold);
}

test "scan modes default and override" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const empty = try parseRoot(arena.allocator(), "");
    const empty_cfg = try decode(empty);
    try std.testing.expectEqual(rules.docs.default_scan_mode, empty_cfg.docs.scan_mode orelse rules.docs.default_scan_mode);

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
    const cfg: Root = .{
        .docs = .{ .missing_doc_comment = .{ .level = .warn } },
    };
    try applyRuleSeverities(cfg, &rule_set);
    try std.testing.expect(rule_set.missing_doc_comment == .forbid);
}
