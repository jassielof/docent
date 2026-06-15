//! The `missing_doctest` namespace collects checks related to missing documentation tests (doctests).
//!
//! This helps to ensure that declarations have corresponding doctests, that serve as both documentation example and unit tests.
//!
//! See: <https://ziglang.org/documentation/0.16.0/#Doctests>.

const std = @import("std");
const Ast = std.zig.Ast;
const Diagnostic = @import("../../Diagnostic.zig");
const severity = @import("../../severity.zig");
const scanning = @import("../../scanning.zig");
const category = @import("../category.zig");
const utils = @import("../utils.zig");

inline fn srcLoc() std.builtin.SourceLocation {
    return @src();
}

const rule_name = utils.ruleIdFromSrc(srcLoc());

/// The default_severity for the rule.
pub const default_severity: severity.Level = .allow;

/// Title for diagnostic prose (`Warning: {prose_title} on …`).
pub const prose_title = "Missing doctest";

/// Full configuration for `missing_doctest`: severity and scan mode, with no rule-specific options.
pub const Rule = category.Rule(default_severity, struct {}, scanning.Modes.public_api_surface);

/// Walks `tree` and appends diagnostics for public functions without matching doctests.
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
    const public_api_only = rule.publicApiOnly();

    var pub_fns = std.StringHashMap(Ast.TokenIndex).init(allocator);
    defer pub_fns.deinit();

    var tested_names = std.StringHashMap(void).init(allocator);
    defer tested_names.deinit();

    for (tree.rootDecls()) |decl| {
        try collectDecl(tree, decl, public_api_only, &pub_fns, &tested_names);
    }

    var iter = pub_fns.iterator();
    while (iter.next()) |entry| {
        if (!tested_names.contains(entry.key_ptr.*)) {
            const name_tok = entry.value_ptr.*;
            const name = entry.key_ptr.*;
            const loc = tree.tokenLocation(0, name_tok);
            try diagnostics.append(allocator, .{
                .rule = rule_name,
                .severity_level = severity_level,
                .subject = try utils.ownedSubject(msg_allocator, .function, name),
                .file = file,
                .line = loc.line + 1,
                .column = loc.column + 1,
                .source_line = try utils.dupSourceLine(tree, name_tok, msg_allocator),
                .symbol_len = name.len,
            });
        }
    }
}

fn collectDecl(
    tree: *const Ast,
    node: Ast.Node.Index,
    public_api_only: bool,
    pub_fns: *std.StringHashMap(Ast.TokenIndex),
    tested_names: *std.StringHashMap(void),
) !void {
    const tag = tree.nodeTag(node);

    if (tag == .test_decl) {
        const name_token_opt: Ast.OptionalTokenIndex = tree.nodeData(node).opt_token_and_node[0];
        if (name_token_opt.unwrap()) |name_token| {
            if (tree.tokenTag(name_token) == .identifier) {
                try tested_names.put(tree.tokenSlice(name_token), {});
            }
        }
        return;
    }

    if (tag == .fn_decl) {
        var buf: [1]Ast.Node.Index = undefined;
        if (tree.fullFnProto(&buf, node)) |proto| {
            const include = if (public_api_only) blk: {
                const vt = proto.visib_token orelse break :blk false;
                break :blk tree.tokenTag(vt) == .keyword_pub;
            } else true;
            if (include) {
                if (proto.name_token) |nt| {
                    try pub_fns.put(tree.tokenSlice(nt), nt);
                }
            }
        }
        return;
    }
}
