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
const scan = @import("../../scan.zig");
const severity = @import("../../severity.zig");
const category = @import("../category.zig");
const utils = @import("../utils.zig");

inline fn srcLoc() std.builtin.SourceLocation {
    return @src();
}

const rule_name = utils.ruleIdFromSrc(srcLoc());

/// The default_severity for the rule.
pub const default_severity: severity.Level = .warn;

/// Title for diagnostic prose (`Warning: {prose_title} on …`).
pub const prose_title = "Doctest naming mismatch";

/// Full configuration for `doctest_naming_mismatch`: severity and scan mode, with no rule-specific options.
pub const Rule = category.Rule(
    default_severity,
    struct {},
    scan.RuleScanConfig.public_api_surface,
);

/// Walks `tree` and appends diagnostics when doctest names disagree with declarations.
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
                            .subject = try utils.ownedSubject(
                                msg_allocator,
                                .function,
                                unquoted,
                            ),
                            .detail = "use identifier-style `test` instead of a string literal",
                            .file = file,
                            .line = loc.line + 1,
                            .column = loc.column + 1,
                            .source_line = try utils.dupSourceLine(
                                tree,
                                name_token,
                                msg_allocator,
                            ),
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
