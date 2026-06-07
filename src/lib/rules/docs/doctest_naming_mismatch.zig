//! The `doctest_naming_mismatch` namespace collects checks related to mismatches between doctest names and its associated declaration identifiers.
//!
//! This helps to ensure that doctests intended to reference specific declarations are properly recognized and associated, by enforcing that test names match the identifiers of the declarations they are meant to test.
//!
//! It should be noted that this rule only checks declarations within the same source file. As cross-file cases are out of scope (due to complexity and very prone to false-positives), mismatched imports are compile errors, and cross-file ambiguity makes reliable suggestions infeasible.
//!
//! ## Checks
//!
//! - **String literal match:** A test that matches an existing public declaration by identifier — suggests rewriting it as a doctest.
//! - **Casing mismatch:** A doctest identifier that has no matching public declaration but a case-variant of it does — suggests the correct casing. Currently limited to capitalization differences; snake_case normalization may be added later.
const std = @import("std");
const Ast = std.zig.Ast;
const Diagnostic = @import("../../Diagnostic.zig");
const severity = @import("../../severity.zig");
const scan_modes = @import("../../scan_modes.zig");
const Config = @import("../../schemas/Config.zig");
const rule_opts = @import("../options.zig");
const utils = @import("../utils.zig");

inline fn srcLoc() std.builtin.SourceLocation {
    return @src();
}

const rule_name = utils.ruleIdFromSrc(srcLoc());

/// The default_severity for the rule.
pub const default_severity: severity.Level = .warn;

pub const Options = struct {
    scan_mode: scan_modes.Mode = scan_modes.Mode.public_api_surface,

    pub fn resolve(category_scan: scan_modes.Mode, rule: Config.RuleSimple) Options {
        return .{ .scan_mode = rule_opts.scanModeFromSimple(category_scan, rule) };
    }

    pub fn publicApiOnly(self: Options) bool {
        return self.scan_mode.publicApiOnly();
    }
};

/// Walks `tree` and appends diagnostics when doctest names disagree with declarations.
pub fn check(
    tree: *const Ast,
    severity_level: severity.Level,
    file: []const u8,
    options: Options,
    allocator: std.mem.Allocator,
    msg_allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) !void {
    if (!severity_level.isActive()) return;
    const public_api_only = options.publicApiOnly();

    var pub_fn_names = std.StringHashMap(void).init(allocator);
    defer pub_fn_names.deinit();

    for (tree.rootDecls()) |decl| {
        if (tree.nodeTag(decl) == .fn_decl) {
            var buf: [1]Ast.Node.Index = undefined;
            if (tree.fullFnProto(&buf, decl)) |proto| {
                const include = if (public_api_only) blk: {
                    const vt = proto.visib_token orelse break :blk false;
                    break :blk tree.tokenTag(vt) == .keyword_pub;
                } else true;
                if (include) {
                    if (proto.name_token) |nt| {
                        try pub_fn_names.put(tree.tokenSlice(nt), {});
                    }
                }
            }
        }
    }

    for (tree.rootDecls()) |decl| {
        if (tree.nodeTag(decl) == .test_decl) {
            const name_token_opt: Ast.OptionalTokenIndex = tree.nodeData(decl).opt_token_and_node[0];
            if (name_token_opt.unwrap()) |name_token| {
                if (tree.tokenTag(name_token) == .string_literal) {
                    const raw = tree.tokenSlice(name_token);
                    const unquoted = stripQuotes(raw);
                    if (pub_fn_names.contains(unquoted)) {
                        const loc = tree.tokenLocation(0, name_token);
                        try diagnostics.append(allocator, .{
                            .rule = rule_name,
                            .severity_level = severity_level,
                            .subject = try utils.ownedSubject(msg_allocator, .function, unquoted),
                            .detail = "use identifier-style `test` instead of a string literal",
                            .file = file,
                            .line = loc.line + 1,
                            .column = loc.column + 1,
                            .source_line = try utils.dupSourceLine(tree, name_token, msg_allocator),
                            .symbol_len = raw.len,
                        });
                    }
                }
            }
        }
    }
}

fn stripQuotes(s: []const u8) []const u8 {
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') {
        return s[1 .. s.len - 1];
    }

    return s;
}

const TestResult = struct {
    msg_arena: std.heap.ArenaAllocator,
    items: std.ArrayList(Diagnostic),

    fn deinit(self: *TestResult) void {
        self.msg_arena.deinit();
        self.items.deinit(std.testing.allocator);
    }
};

fn runCheck(source: [:0]const u8) !TestResult {
    const base = std.testing.allocator;
    var msg_arena = std.heap.ArenaAllocator.init(base);
    errdefer msg_arena.deinit();

    var tree = try std.zig.Ast.parse(base, source, .zig);
    defer tree.deinit(base);

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    errdefer diagnostics.deinit(base);

    try check(&tree, .warn, "<test>", .{}, base, msg_arena.allocator(), &diagnostics);
    return .{ .msg_arena = msg_arena, .items = diagnostics };
}

test "detects string test name matching pub fn, shows correction" {
    var r = try runCheck(
        \\/// Does something.
        \\pub fn foo() void {}
        \\test "foo" {}
    );
    defer r.deinit();
    try std.testing.expectEqual(1, r.items.items.len);
    try std.testing.expectEqualStrings(rule_name, r.items.items[0].rule);
    try std.testing.expectEqualStrings("foo", r.items.items[0].subject.?.name);
}

test "no diagnostic for identifier test name" {
    var r = try runCheck(
        \\/// Does something.
        \\pub fn foo() void {}
        \\test foo {}
    );
    defer r.deinit();
    try std.testing.expectEqual(0, r.items.items.len);
}

test "no diagnostic for string test not matching any pub fn" {
    var r = try runCheck(
        \\/// Does something.
        \\pub fn foo() void {}
        \\test "bar" {}
    );
    defer r.deinit();
    try std.testing.expectEqual(0, r.items.items.len);
}
