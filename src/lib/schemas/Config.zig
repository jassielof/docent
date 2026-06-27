//! Typed configuration schema for `.config/docent.toml`.
//!
//! Struct shapes mirror `schemas/docent.schema.yaml`. `decode` turns parsed TOML into these
//! types; `applyRuleSeverities` projects severity levels into `RuleSeverities`.

// NOTE: It'll be ideal to migrate to Ziggy once it's more stable.
const std = @import("std");
const toml = @import("toml");

const RuleSeverities = @import("../RuleSeverities.zig");
const scan = @import("../scan.zig");
const severity = @import("../severity.zig");
const rule_decode = @import("../rules/decode.zig");
const doc_rules = @import("../rules/doc.zig");
const style_rules = @import("../rules/style.zig");
const complexity_rules = @import("../rules/complexity.zig");
const naming_case = @import("../naming_case.zig");

pub const Error = rule_decode.Error;

pub const Doc = doc_rules.Doc;
pub const Style = style_rules.Style;
pub const Complexity = complexity_rules.Complexity;

doc: Doc = .{},
style: Style = .{},
complexity: Complexity = .{},
fmt: Fmt = .{},

pub const Fmt = struct {
    brace_style: BraceStyle = .k_r,
    single_line_braces: bool = false,
    trailing_comma: bool = false,
    logical_blank_lines: bool = false,
    sort_imports: bool = false,
    indent_width: u8 = 4,

    pub const BraceStyle = enum {
        k_r,
        allman,

        pub fn fromConfigString(text: []const u8) ?BraceStyle {
            if (std.mem.eql(u8, text, "k_r") or std.mem.eql(u8, text, "k&r")) return .k_r;
            if (std.mem.eql(u8, text, "allman")) return .allman;
            return null;
        }
    };
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
pub fn decode(root: toml.DynamicValue) Error!@This() {
    const table = rootTable(root) orelse return error.ConfigParseFailed;

    var cfg: @This() = .{};
    if (table.get("doc")) |value| try rule_decode.decodeInto(Doc, value, &cfg.doc);
    cfg.doc.resolveScanModes();
    if (table.get("style")) |value| try rule_decode.decodeInto(Style, value, &cfg.style);
    cfg.style.resolveScanModes();
    if (table.get("complexity")) |value| try rule_decode.decodeInto(Complexity, value, &cfg.complexity);
    cfg.complexity.resolveScanModes();
    if (table.get("fmt")) |value| try decodeFmt(value, &cfg.fmt);
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
    try applyLevel(&rule_set.redundant_doc_comment, section.redundant_doc_comment.level);
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

fn decodeFmt(value: toml.DynamicValue, out: *Fmt) Error!void {
    const table = switch (value) {
        .table => |t| t,
        else => return,
    };
    if (table.get("brace_style")) |bs_value| {
        const text = bs_value.stringSlice() orelse return error.ConfigParseFailed;
        out.brace_style = Fmt.BraceStyle.fromConfigString(text) orelse return error.ConfigParseFailed;
    }
    if (table.get("single_line_braces")) |v| {
        out.single_line_braces = switch (v) {
            .boolean => |b| b,
            else => return error.ConfigParseFailed,
        };
    }
    if (table.get("trailing_comma")) |v| {
        out.trailing_comma = switch (v) {
            .boolean => |b| b,
            else => return error.ConfigParseFailed,
        };
    }
    if (table.get("logical_blank_lines")) |v| {
        out.logical_blank_lines = switch (v) {
            .boolean => |b| b,
            else => return error.ConfigParseFailed,
        };
    }
    if (table.get("sort_imports")) |v| {
        out.sort_imports = switch (v) {
            .boolean => |b| b,
            else => return error.ConfigParseFailed,
        };
    }
    if (table.get("indent_width")) |v| {
        const n = switch (v) {
            .integer => |i| i,
            else => return error.ConfigParseFailed,
        };
        if (n < 1 or n > 16) return error.ConfigParseFailed;
        out.indent_width = @intCast(n);
    }
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
    try std.testing.expect(std.meta.eql(scan.RuleScanConfig.reachability_traversal, cfg.doc.scan_mode));
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
    try std.testing.expectEqual(naming_case.Style.snake, cfg.style.identifier_case.options.struct_file_case);
}

test "resolved style options read identifier case conventions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const root = try parseRoot(arena.allocator(),
        \\[style.identifier_case]
        \\namespaces = "PascalCase"
        \\functions = "camelCase"
        \\types = "PascalCase"
        \\constants = "snake_case"
    );

    const cfg = try decode(root);
    const opts = cfg.style.identifier_case.options;
    try std.testing.expectEqual(naming_case.Style.pascal, opts.namespaces);
    try std.testing.expectEqual(naming_case.Style.camel, opts.functions);
    try std.testing.expectEqual(naming_case.Style.pascal, opts.types);
    try std.testing.expectEqual(naming_case.Style.snake, opts.constants);
}

test "resolved docs options read invalid_leading_phrase settings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const root = try parseRoot(arena.allocator(),
        \\[doc.invalid_leading_phrase]
        \\require_kind = true
        \\require_article = true
        \\require_backticks = true
    );

    const cfg = try decode(root);
    const phrase = cfg.doc.invalid_leading_phrase.options;
    try std.testing.expect(phrase.require_kind);
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
    try std.testing.expectEqual(naming_case.Style.kebab, cfg.style.identifier_case.options.struct_file_case);
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
    try std.testing.expect(std.meta.eql(doc_rules.default_scan_mode, empty_cfg.doc.scan_mode));

    const root = try parseRoot(arena.allocator(),
        \\[doc]
        \\scan_mode = "all"
        \\
        \\[complexity]
        \\scan_mode = "public"
    );
    const cfg = try decode(root);
    try std.testing.expect(std.meta.eql(scan.RuleScanConfig.reachability_traversal, cfg.doc.scan_mode));
    try std.testing.expect(std.meta.eql(scan.RuleScanConfig.public_api_surface, cfg.complexity.scan_mode));
}

test "decode reads fmt options" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const root = try parseRoot(arena.allocator(),
        \\[fmt]
        \\brace_style = "allman"
        \\single_line_braces = true
        \\trailing_comma = true
        \\logical_blank_lines = true
        \\sort_imports = true
        \\indent_width = 2
    );
    const cfg = try decode(root);
    try std.testing.expectEqual(Fmt.BraceStyle.allman, cfg.fmt.brace_style);
    try std.testing.expect(cfg.fmt.single_line_braces);
    try std.testing.expect(cfg.fmt.trailing_comma);
    try std.testing.expect(cfg.fmt.logical_blank_lines);
    try std.testing.expect(cfg.fmt.sort_imports);
    try std.testing.expectEqual(@as(u8, 2), cfg.fmt.indent_width);

    const empty = try parseRoot(arena.allocator(), "");
    const empty_cfg = try decode(empty);
    try std.testing.expectEqual(Fmt.BraceStyle.k_r, empty_cfg.fmt.brace_style);
    try std.testing.expect(!empty_cfg.fmt.single_line_braces);
    try std.testing.expect(!empty_cfg.fmt.trailing_comma);
    try std.testing.expect(!empty_cfg.fmt.logical_blank_lines);
    try std.testing.expect(!empty_cfg.fmt.sort_imports);
    try std.testing.expectEqual(@as(u8, 4), empty_cfg.fmt.indent_width);
}

test "applyRuleSeverities respects forbid and defaults" {
    var rule_set: RuleSeverities = .{ .missing_doc_comment = .forbid };
    const cfg: @This() = .{
        .doc = .{ .missing_doc_comment = .{ .level = .warn } },
    };
    try applyRuleSeverities(cfg, &rule_set);
    try std.testing.expect(rule_set.missing_doc_comment == .forbid);
}
