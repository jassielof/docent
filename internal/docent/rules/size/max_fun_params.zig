//! The `max_fun_params` namespace checks functions with more parameters than the configured limit.
//!
//! The maximum number of parameters in many tools and teams often default to around 5, to encourage simpler APIs. In Zig, however, it is common to pass interface parameters such as allocators, writers, and I/O interfaces as explicit dependencies. To be gentler on Zig codebases and more focused on true domain-specific parameters, the default limit here is set to 7.
//!
//! A function is flagged when its parameter count is *strictly greater* than the threshold. It is reported by `docent check size`. Like other size checks, it measures *every* function in the import-closure reachable from the module roots.

const std = @import("std");
const Ast = std.zig.Ast;

const Diagnostic = @import("../../Diagnostic.zig");
const severity = @import("../../severity.zig");
const scan = @import("../../scan.zig");
const category = @import("../category.zig");
const utils = @import("../utils.zig");

inline fn srcLoc() std.builtin.SourceLocation {
    return @src();
}

const rule_name = utils.ruleIdFromSrc(srcLoc());

/// Default severity `warn`: an overlong parameter list is an API smell worth surfacing without failing a fresh build.
pub const default_severity: severity.Level = .warn;

/// Title for diagnostic prose (`Warning: {prose_title} on …`).
pub const prose_title = "Maximum function parameters";

/// Rule-specific knobs for `max_fun_params`, held in the `options` sub-space of `Rule`.
pub const Options = struct {
    /// Maximum parameter count before a function is flagged; default `default_threshold` allows Zig's common explicit dependencies (allocator, writer, I/O).
    threshold: u32 = default_threshold,
};

/// Full configuration for `max_fun_params`: severity, scan mode, and the documented `Options` sub-space.
pub const Rule = category.Rule(default_severity, Options, scan.RuleScanConfig.reachability_traversal);

/// Default maximum parameter count; functions with more parameters are flagged.
pub const default_threshold: u32 = 7;

/// Walks `tree` and appends a diagnostic for each scanned function whose parameter count exceeds `threshold`.
///
/// When `public_api_only` is set, only `pub` functions (at the container level) are measured; otherwise every container-level function is measured.
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
    const threshold = rule.options.threshold;

    var fns: std.ArrayList(Ast.Node.Index) = .empty;
    defer fns.deinit(allocator);

    for (tree.rootDecls()) |decl| {
        try collectFunctions(tree, decl, public_api_only, allocator, &fns);
    }

    for (fns.items) |fn_node| {
        const param_count = functionParamCount(tree, fn_node);
        if (param_count <= threshold) continue;

        var buf: [1]Ast.Node.Index = undefined;
        const proto = tree.fullFnProto(&buf, fn_node) orelse continue;
        const name_tok = proto.name_token orelse continue;
        const name = tree.tokenSlice(name_tok);
        const loc = tree.tokenLocation(0, name_tok);

        try diagnostics.append(allocator, .{
            .rule = rule_name,
            .severity_level = severity_level,
            .subject = try utils.ownedSubject(msg_allocator, .function, name),
            .detail = try std.fmt.allocPrint(
                msg_allocator,
                "{d} parameters exceeds threshold {d}",
                .{ param_count, threshold },
            ),
            .file = file,
            .line = loc.line + 1,
            .column = loc.column + 1,
            .source_line = try utils.dupSourceLine(tree, name_tok, msg_allocator),
            .symbol_len = name.len,
        });
    }
}

fn collectFunctions(
    tree: *const Ast,
    node: Ast.Node.Index,
    public_api_only: bool,
    allocator: std.mem.Allocator,
    out: *std.ArrayList(Ast.Node.Index),
) !void {
    const tag = tree.nodeTag(node);

    if (tag == .fn_decl) {
        var buf: [1]Ast.Node.Index = undefined;
        if (tree.fullFnProto(&buf, node)) |proto| {
            const include = if (public_api_only) utils.isPubVisibility(tree, proto.visib_token) else true;
            if (include) try out.append(allocator, node);
        }
        return;
    }

    if (tree.fullVarDecl(node)) |var_decl| {
        if (var_decl.ast.init_node.unwrap()) |init_node| {
            if (utils.isContainerDecl(tree.nodeTag(init_node))) {
                var cbuf: [2]Ast.Node.Index = undefined;
                if (tree.fullContainerDecl(&cbuf, init_node)) |container| {
                    for (container.ast.members) |member| {
                        try collectFunctions(tree, member, public_api_only, allocator, out);
                    }
                }
            }
        }
        return;
    }

    if (utils.isContainerDecl(tag)) {
        var cbuf: [2]Ast.Node.Index = undefined;
        if (tree.fullContainerDecl(&cbuf, node)) |container| {
            for (container.ast.members) |member| {
                try collectFunctions(tree, member, public_api_only, allocator, out);
            }
        }
    }
}

fn functionParamCount(tree: *const Ast, fn_node: Ast.Node.Index) u32 {
    var buf: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buf, fn_node) orelse return 0;
    return @intCast(proto.ast.params.len);
}

test "counts parameters from the function prototype" {
    const count = count: {
        const source =
            \\fn f(a: u32, b: i32, comptime T: type) void {}
        ++ "\x00";
        var tree = try std.zig.Ast.parse(std.testing.allocator, source, .zig);
        defer tree.deinit(std.testing.allocator);
        for (tree.rootDecls()) |decl| {
            if (tree.nodeTag(decl) == .fn_decl) break :count functionParamCount(&tree, decl);
        }
        break :count 0;
    };
    try std.testing.expectEqual(@as(u32, 3), count);
}

test "inactive severity yields no diagnostics" {
    const base = std.testing.allocator;
    var tree = try std.zig.Ast.parse(base, "pub fn f(a: u32, b: u32, c: u32, d: u32, e: u32, f: u32, g: u32, h: u32) void {}", .zig);
    defer tree.deinit(base);
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(base);
    try check(&tree, .{ .level = .allow, .options = .{ .threshold = 7 } }, "<test>", base, base, &diagnostics);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}
