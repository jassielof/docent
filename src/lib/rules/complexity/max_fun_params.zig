//! The `max_fun_params` namespace checks functions with more parameters than the configured limit.
//!
//! The maximum number of parameters in many tools and teams often default to around 5, to encourage simpler APIs. In Zig, however, it is common to pass interface parameters such as allocators, writers, and I/O interfaces as explicit dependencies. To be gentler on Zig codebases and more focused on true domain-specific parameters, the default limit here is set to 7.
//!
//! A function is flagged when its parameter count is *strictly greater* than the threshold. It is reported by `docent check complexity`. Like the other complexity checks, it measures *every* function in the import-closure reachable from the module roots.

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
    scan_mode: scan_modes.Mode = scan_modes.Mode.reachability_traversal,
    threshold: u32 = default_threshold,

    pub fn resolve(category_scan: scan_modes.Mode, rule: Config.RuleThreshold) Options {
        return .{
            .scan_mode = rule_opts.scanModeFromThreshold(category_scan, rule),
            .threshold = rule.threshold orelse default_threshold,
        };
    }

    pub fn publicApiOnly(self: Options) bool {
        return self.scan_mode.publicApiOnly();
    }
};

/// Default maximum parameter count (functions with more parameters are flagged).
pub const default_threshold: u32 = 7;

/// Walks `tree` and appends a diagnostic for each scanned function whose parameter count exceeds `threshold`.
///
/// When `public_api_only` is set, only `pub` functions (at the container level) are measured; otherwise every container-level function is measured.
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
    const threshold = options.threshold;

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

const TestResult = struct {
    msg_arena: std.heap.ArenaAllocator,
    items: std.ArrayList(Diagnostic),

    fn deinit(self: *TestResult) void {
        self.msg_arena.deinit();
        self.items.deinit(std.testing.allocator);
    }
};

fn runCheck(source: [:0]const u8, threshold: u32, options: Options) !TestResult {
    const base = std.testing.allocator;
    var msg_arena = std.heap.ArenaAllocator.init(base);
    errdefer msg_arena.deinit();

    var tree = try std.zig.Ast.parse(base, source, .zig);
    defer tree.deinit(base);

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    errdefer diagnostics.deinit(base);

    var opts = options;
    opts.threshold = threshold;
    try check(&tree, .warn, "<test>", opts, base, msg_arena.allocator(), &diagnostics);
    return .{ .msg_arena = msg_arena, .items = diagnostics };
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

test "function within threshold is accepted" {
    var r = try runCheck("pub fn ok(a: u32, b: u32, c: u32) void {}", 7, .{});
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 0), r.items.items.len);
}

test "function above threshold is reported" {
    var r = try runCheck(
        \\pub fn too_many(a: u32, b: u32, c: u32, d: u32, e: u32, f: u32, g: u32, h: u32) void {}
    , 7, .{});
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 1), r.items.items.len);
    try std.testing.expectEqualStrings(rule_name, r.items.items[0].rule);
    try std.testing.expectEqualStrings("too_many", r.items.items[0].subject.?.name);
    try std.testing.expect(std.mem.indexOf(u8, r.items.items[0].detail.?, "8 parameters") != null);
}

test "exactly at threshold is accepted" {
    var r = try runCheck(
        \\pub fn seven(a: u32, b: u32, c: u32, d: u32, e: u32, f: u32, g: u32) void {}
    , 7, .{});
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 0), r.items.items.len);
}

test "private functions are measured when public_api_only is false" {
    var r = try runCheck(
        \\fn hidden(a: u32, b: u32, c: u32, d: u32, e: u32, f: u32, g: u32, h: u32) void {}
    , 7, .{});
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 1), r.items.items.len);
}

test "private functions are skipped under public_api_only" {
    var r = try runCheck(
        \\fn hidden(a: u32, b: u32, c: u32, d: u32, e: u32, f: u32, g: u32, h: u32) void {}
    , 7, .{ .scan_mode = .public_api_surface });
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 0), r.items.items.len);
}

test "inactive severity yields no diagnostics" {
    const base = std.testing.allocator;
    var tree = try std.zig.Ast.parse(base, "pub fn f(a: u32, b: u32, c: u32, d: u32, e: u32, f: u32, g: u32, h: u32) void {}", .zig);
    defer tree.deinit(base);
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(base);
    try check(&tree, .allow, "<test>", .{ .threshold = 7 }, base, base, &diagnostics);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}
