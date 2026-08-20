//! The `private_doctest` namespace collects checks related to private documentation tests (doctests).
//!
//! Given that doctests serve partially as documentation examples, it's expected for them to reference public declarations.

const std = @import("std");
const Ast = std.zig.Ast;

const lint = @import("lint");
const category = lint.category;
const Diagnostic = lint.Diagnostic;
const scan = lint.scan;
const severity = lint.severity;

const utils = @import("../utils.zig");

inline fn srcLoc() std.builtin.SourceLocation {
    return @src();
}

const rule_name = utils.ruleIdFromSrc(srcLoc());

/// The default_severity for the rule.
pub const default_severity: severity.Level = .warn;

/// Title for diagnostic prose (`Warning: {prose_title} on …`).
pub const prose_title = "Private doctest";

/// Full configuration for `private_doctest`: severity and scan mode, with no rule-specific options.
pub const Rule = category.Rule(
    default_severity,
    struct {},
    scan.RuleScanConfig.public_declarations,
);

/// Walks `tree` and appends diagnostics when private items use public-style doctests.
pub fn check(
    tree: *const Ast,
    rule: Rule,
    file: []const u8,
    allocator: std.mem.Allocator,
    msg_allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) !void {
    if (!rule.level.isActive()) return;
    const severity_level = rule.level;

    var pub_names = std.StringHashMap(void).init(allocator);
    defer pub_names.deinit();

    var ident_tests: std.ArrayList(TestEntry) = .empty;
    defer ident_tests.deinit(allocator);

    for (tree.rootDecls()) |decl| {
        try collectDecl(
            tree,
            decl,
            allocator,
            &pub_names,
            &ident_tests,
        );
    }

    for (ident_tests.items) |entry| {
        if (!pub_names.contains(entry.name)) {
            const loc = tree.tokenLocation(0, entry.token);
            try diagnostics.append(allocator, .{
                .rule = rule_name,
                .severity_level = severity_level,
                .subject = try utils.ownedSubject(
                    msg_allocator,
                    .doctest,
                    entry.name,
                ),
                .detail = "references a non-public symbol",
                .file = file,
                .line = loc.line + 1,
                .column = loc.column + 1,
                .source_line = try utils.dupSourceLine(
                    tree,
                    entry.token,
                    msg_allocator,
                ),
                .symbol_len = entry.name.len,
            });
        }
    }
}

const TestEntry = struct { name: []const u8, token: Ast.TokenIndex };

fn collectDecl(
    tree: *const Ast,
    node: Ast.Node.Index,
    allocator: std.mem.Allocator,
    pub_names: *std.StringHashMap(void),
    ident_tests: *std.ArrayList(TestEntry),
) !void {
    const tag = tree.nodeTag(node);

    if (tag == .test_decl) {
        const name_token_opt: Ast.OptionalTokenIndex = tree.nodeData(node).opt_token_and_node[0];
        if (name_token_opt.unwrap()) |name_token| {
            if (tree.tokenTag(name_token) == .identifier) {
                try ident_tests.append(
                    allocator,
                    .{ .name = tree.tokenSlice(name_token), .token = name_token },
                );
            }
        }
        return;
    }

    if (tag == .fn_decl) {
        var buf: [1]Ast.Node.Index = undefined;
        if (tree.fullFnProto(&buf, node)) |proto| {
            if (proto.visib_token) |vt| {
                if (tree.tokenTag(vt) == .keyword_pub) {
                    if (proto.name_token) |nt| {
                        try pub_names.put(tree.tokenSlice(nt), {});
                    }
                }
            }
        }
        return;
    }

    if (tree.fullVarDecl(node)) |var_decl| {
        if (var_decl.visib_token) |vt| {
            if (tree.tokenTag(vt) == .keyword_pub) {
                const name_token = var_decl.ast.mut_token + 1;
                try pub_names.put(tree.tokenSlice(name_token), {});
            }
        }
        return;
    }
}

fn runCheck(
    source: [:0]const u8,
    rule: Rule,
    diagnostics: *std.ArrayList(Diagnostic),
    msg_allocator: std.mem.Allocator,
) !void {
    const allocator = std.testing.allocator;
    var tree = try std.zig.Ast.parse(
        allocator,
        source,
        .zig,
    );
    defer tree.deinit(allocator);

    try check(
        &tree,
        rule,
        "<test>",
        allocator,
        msg_allocator,
        diagnostics,
    );
}

const warn_rule: Rule = .{ .level = .warn };

test "detects doctest referencing private fn, names the symbol" {
    const source =
        \\fn foo() void {}
        \\test foo {}
    ;

    var msg_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer msg_arena.deinit();
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    try runCheck(
        source,
        warn_rule,
        &diagnostics,
        msg_arena.allocator(),
    );
    try std.testing.expectEqual(@as(usize, 1), diagnostics.items.len);
    try std.testing.expectEqualStrings("foo", diagnostics.items[0].subject.?.name);
}

test "no diagnostic when doctest references pub fn" {
    const source =
        \\/// Does something.
        \\pub fn foo() void {}
        \\test foo {}
    ;

    var msg_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer msg_arena.deinit();
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    try runCheck(
        source,
        warn_rule,
        &diagnostics,
        msg_arena.allocator(),
    );
    try std.testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}

test "no diagnostic for string-literal test names" {
    const source =
        \\test "some behavior" {}
    ;

    var msg_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer msg_arena.deinit();
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    try runCheck(
        source,
        warn_rule,
        &diagnostics,
        msg_arena.allocator(),
    );
    try std.testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}

comptime {
    std.testing.refAllDecls(@This());
}
