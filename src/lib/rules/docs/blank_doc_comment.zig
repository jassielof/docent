//! The `blank_doc_comment` namespace checks for doc comments that are blank or empty.
//!
//! For guidance on how to write good documentation comments, see <https://ziglang.org/documentation/0.16.0/#Doc-Comment-Guidance>.

const std = @import("std");
const Ast = std.zig.Ast;
const Diagnostic = @import("../../Diagnostic.zig");
const severity = @import("../../severity.zig");
const scan_modes = @import("../../scan_modes.zig");
const Config = @import("../../schemas/Config.zig");
const reexport = @import("../../reexport.zig");
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

/// Walks `tree` and appends diagnostics for vacuous doc comments.
///
/// When `is_module_entry` is set, blank `//!` blocks on the file are reported as module doc comments.
/// Whole-module re-exports without a line doc comment also resolve blank `//!` on the imported file.
/// See `docent.reexport` for resolution behavior.
pub fn check(
    tree: *const Ast,
    severity_level: severity.Level,
    file: []const u8,
    module_name: ?[]const u8,
    is_module_entry: bool,
    options: Options,
    allocator: std.mem.Allocator,
    io: std.Io,
    msg_allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) !void {
    if (!severity_level.isActive()) return;
    const public_api_only = options.publicApiOnly();

    const tags = tree.tokens.items(.tag);
    var i: usize = 0;
    while (i < tags.len) {
        const tag = tags[i];
        if (tag != .doc_comment and tag != .container_doc_comment) {
            i += 1;
            continue;
        }

        const block_start = i;
        var all_empty = true;

        while (i < tags.len and tags[i] == tag) : (i += 1) {
            const tok: Ast.TokenIndex = @intCast(i);
            const slice = tree.tokenSlice(tok);
            if (!utils.isEmptyDocCommentLine(slice)) all_empty = false;
        }

        if (all_empty) {
            const tok: Ast.TokenIndex = @intCast(block_start);
            const slice = tree.tokenSlice(tok);
            const loc = tree.tokenLocation(0, tok);
            const subject = if (tag == .container_doc_comment)
                try containerDocSubject(tree, file, module_name, is_module_entry, msg_allocator)
            else
                try utils.resolveDocCommentSubject(tree, @intCast(i), file, module_name, msg_allocator);
            try diagnostics.append(allocator, .{
                .rule = rule_name,
                .severity_level = severity_level,
                .subject = subject,
                .file = file,
                .line = loc.line + 1,
                .column = loc.column + 1,
                .source_line = try utils.dupSourceLine(tree, tok, msg_allocator),
                .symbol_len = slice.len,
            });
        }
    }

    for (tree.rootDecls()) |decl| {
        try checkReexportedWholeModules(tree, decl, file, public_api_only, severity_level, allocator, io, msg_allocator, diagnostics);
    }
}

fn containerDocSubject(
    tree: *const Ast,
    file: []const u8,
    module_name: ?[]const u8,
    is_module_entry: bool,
    msg_allocator: std.mem.Allocator,
) std.mem.Allocator.Error!Diagnostic.Subject {
    if (is_module_entry) {
        return try utils.ownedSubject(msg_allocator, .module, utils.moduleDisplayName(file, module_name));
    }
    return try utils.ownedSubject(
        msg_allocator,
        utils.exposedSourceFileSubjectKind(tree),
        std.fs.path.basename(file),
    );
}

fn isPubVisibility(tree: *const Ast, visib_token: ?Ast.TokenIndex) bool {
    const vt = visib_token orelse return false;
    return tree.tokenTag(vt) == .keyword_pub;
}

fn shouldCheckDecl(tree: *const Ast, visib_token: ?Ast.TokenIndex, public_api_only: bool) bool {
    if (!public_api_only) return true;
    return isPubVisibility(tree, visib_token);
}

fn hasDocComment(tree: *const Ast, first_token: Ast.TokenIndex) bool {
    if (first_token == 0) return false;
    return tree.tokenTag(first_token - 1) == .doc_comment;
}

fn checkReexportedWholeModules(
    tree: *const Ast,
    node: Ast.Node.Index,
    file: []const u8,
    public_api_only: bool,
    severity_level: severity.Level,
    allocator: std.mem.Allocator,
    io: std.Io,
    msg_allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) std.mem.Allocator.Error!void {
    if (tree.fullVarDecl(node)) |var_decl| {
        if (shouldCheckDecl(tree, var_decl.visib_token, public_api_only) and
            !hasDocComment(tree, var_decl.firstToken()))
        {
            if (var_decl.ast.init_node.unwrap()) |init_node| {
                if (reexport.getInfo(tree, init_node)) |info| {
                    if (info.field_name == null) {
                        var emit_ctx = BlankWholeModuleContext{
                            .severity_level = severity_level,
                            .allocator = allocator,
                            .msg_allocator = msg_allocator,
                            .diagnostics = diagnostics,
                        };
                        try reexport.resolveWholeModuleReexport(
                            info,
                            file,
                            allocator,
                            io,
                            &emit_ctx,
                            containerDocBlockIsFullyBlank,
                            onBlankWholeModuleReexport,
                        );
                    }
                }
            }
        }

        const init_node = var_decl.ast.init_node.unwrap() orelse return;
        if (!utils.isContainerDecl(tree.nodeTag(init_node))) return;

        var buf: [2]Ast.Node.Index = undefined;
        if (tree.fullContainerDecl(&buf, init_node)) |container| {
            for (container.ast.members) |member| {
                try checkReexportedWholeModules(tree, member, file, public_api_only, severity_level, allocator, io, msg_allocator, diagnostics);
            }
        }
        return;
    }

    const tag = tree.nodeTag(node);
    if (utils.isContainerDecl(tag)) {
        var buf: [2]Ast.Node.Index = undefined;
        if (tree.fullContainerDecl(&buf, node)) |container| {
            for (container.ast.members) |member| {
                try checkReexportedWholeModules(tree, member, file, public_api_only, severity_level, allocator, io, msg_allocator, diagnostics);
            }
        }
    }
}

const BlankWholeModuleContext = struct {
    severity_level: severity.Level,
    allocator: std.mem.Allocator,
    msg_allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
};

fn containerDocBlockIsFullyBlank(tree: *const Ast) bool {
    return utils.containerDocBlockIsFullyBlank(tree);
}

fn onBlankWholeModuleReexport(ctx_ptr: *anyopaque, tree: *const Ast, file_path: []const u8) !void {
    const ctx: *BlankWholeModuleContext = @ptrCast(@alignCast(ctx_ptr));
    const source_basename = std.fs.path.basename(file_path);
    const subject_kind = utils.exposedSourceFileSubjectKind(tree);
    var line: usize = 0;
    var column: usize = 0;
    if (tree.tokens.len > 0) {
        const loc = tree.tokenLocation(0, 0);
        line = loc.line;
        column = loc.column;
    }

    try ctx.diagnostics.append(ctx.allocator, .{
        .rule = rule_name,
        .severity_level = ctx.severity_level,
        .subject = try utils.ownedSubject(ctx.msg_allocator, subject_kind, source_basename),
        .file = try utils.normalizePathSeparators(ctx.msg_allocator, file_path),
        .line = line + 1,
        .column = column + 1,
        .source_line = if (tree.tokens.len > 0) try utils.dupSourceLine(tree, 0, ctx.msg_allocator) else "",
        .symbol_len = if (tree.tokens.len > 0) tree.tokenSlice(0).len else source_basename.len,
    });
}

const TestResult = struct {
    msg_arena: std.heap.ArenaAllocator,
    items: std.ArrayList(Diagnostic),

    fn deinit(self: *TestResult) void {
        self.msg_arena.deinit();
        self.items.deinit(std.testing.allocator);
    }
};

fn runCheck(source: [:0]const u8, is_module_entry: bool) !TestResult {
    const base = std.testing.allocator;
    var msg_arena = std.heap.ArenaAllocator.init(base);
    errdefer msg_arena.deinit();

    var tree = try std.zig.Ast.parse(base, source, .zig);
    defer tree.deinit(base);

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    errdefer diagnostics.deinit(base);

    try check(&tree, .warn, "<test>", null, is_module_entry, .{}, base, std.testing.io, msg_arena.allocator(), &diagnostics);
    return .{ .msg_arena = msg_arena, .items = diagnostics };
}

test "detects blank /// comment" {
    var r = try runCheck("///\npub fn foo() void {}", false);
    defer r.deinit();
    try std.testing.expectEqual(1, r.items.items.len);
    try std.testing.expectEqualStrings(rule_name, r.items.items[0].rule);
    try std.testing.expectEqual(.function, r.items.items[0].subject.?.kind);
    try std.testing.expectEqualStrings("foo", r.items.items[0].subject.?.name);
    try std.testing.expectEqual(@as(usize, 3), r.items.items[0].symbol_len);
}

test "detects blank /// on enum enumerator" {
    var r = try runCheck(
        \\pub const Color = enum {
        \\    ///
        \\    red,
        \\};
    ,
        false,
    );
    defer r.deinit();
    try std.testing.expectEqual(1, r.items.items.len);
    try std.testing.expectEqual(.enumerator, r.items.items[0].subject.?.kind);
    try std.testing.expectEqualStrings("red", r.items.items[0].subject.?.name);
}

test "detects blank /// with spaces" {
    var r = try runCheck("///   \npub fn foo() void {}", false);
    defer r.deinit();
    try std.testing.expectEqual(1, r.items.items.len);
}

test "no diagnostic for non-empty doc comment" {
    var r = try runCheck("/// Does something.\npub fn foo() void {}", false);
    defer r.deinit();
    try std.testing.expectEqual(0, r.items.items.len);
}

test "detects blank //! comment on module entry" {
    var r = try runCheck("//!", true);
    defer r.deinit();
    try std.testing.expectEqual(1, r.items.items.len);
    try std.testing.expectEqual(.module, r.items.items[0].subject.?.kind);
}

test "blank //! on non-entry file uses namespace subject" {
    var r = try runCheck("//!\npub const x = 1;", false);
    defer r.deinit();
    try std.testing.expectEqual(1, r.items.items.len);
    try std.testing.expectEqual(.namespace, r.items.items[0].subject.?.kind);
}

test "detects fully blank multiline /// comment block once" {
    var r = try runCheck("///\n///   \npub fn foo() void {}", false);
    defer r.deinit();
    try std.testing.expectEqual(1, r.items.items.len);
}

test "no diagnostic for multiline block with at least one non-empty line" {
    var r = try runCheck("/// This should\n///\n/// be valid\npub fn foo() void {}", false);
    defer r.deinit();
    try std.testing.expectEqual(0, r.items.items.len);
}

test "member re-export does not trigger whole-module blank check" {
    var r = try runCheck("pub const Level = @import(\"severity.zig\").Level;", false);
    defer r.deinit();
    try std.testing.expectEqual(0, r.items.items.len);
}
