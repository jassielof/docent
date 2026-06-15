//! Scenario: reference config presets (Tiger Style, Go Doc Comments).

const std = @import("std");
const docent = @import("docent");

fn presetConfigPath(allocator: std.mem.Allocator, io: std.Io, name: []const u8) ![]const u8 {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const rel = try std.fmt.allocPrint(allocator, "tests/fixtures/config/presets/{s}.toml", .{name});
    defer allocator.free(rel);
    const len = try std.Io.Dir.cwd().realPathFile(io, rel, &buf);
    return allocator.dupe(u8, buf[0..len]);
}

test "tiger style preset enforces snake_case and line length forbid" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const config_path = try presetConfigPath(allocator, io, "tiger-style");
    defer allocator.free(config_path);

    const style = try docent.config.loadStyleOptions(allocator, io, config_path);
    try std.testing.expectEqual(docent.naming_case.Style.snake, style.identifier_case.options.struct_file_case);
    try std.testing.expect(style.identifier_case.level == .deny);
    try std.testing.expect(style.line_length_limit.level == .forbid);
    try std.testing.expectEqual(@as(u32, 100), style.line_length_limit.options.max_length);
}

test "godoc preset loads documentation grammar and zig naming defaults" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const config_path = try presetConfigPath(allocator, io, "godoc");
    defer allocator.free(config_path);

    const cfg = try docent.config.loadConfig(allocator, io, config_path);

    try std.testing.expect(cfg.doc.scan_mode == .public_api_surface);
    try std.testing.expect(cfg.doc.invalid_leading_phrase.options.mode == .canonical);
    try std.testing.expect(!cfg.doc.invalid_leading_phrase.options.require_article);
    try std.testing.expect(cfg.doc.missing_doctest.level == .allow);

    try std.testing.expect(cfg.style.line_length_limit.options.ignore_leading_comments);
    try std.testing.expect(cfg.style.line_length_limit.options.ignore_trailing_comments);
}
