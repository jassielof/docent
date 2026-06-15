//! The `blank_doc_comment` namespace checks for doc comments that are blank or empty.
//!
//! For guidance on how to write good documentation comments, see <https://ziglang.org/documentation/0.16.0/#Doc-Comment-Guidance>.

const std = @import("std");
const Ast = std.zig.Ast;
const vereda = @import("vereda");
const Diagnostic = @import("../../Diagnostic.zig");
const severity = @import("../../severity.zig");
const scan = @import("../../scan.zig");
const category = @import("../category.zig");
const alias = @import("../../scan/alias.zig");
const utils = @import("../utils.zig");
const doc = @import("../../doc.zig");

inline fn srcLoc() std.builtin.SourceLocation {
    return @src();
}

const rule_name = utils.ruleIdFromSrc(srcLoc());

/// The default_severity for the rule.
pub const default_severity: severity.Level = .warn;

/// Title for diagnostic prose (`Warning: {prose_title} on …`).
pub const prose_title = "Blank doc comment";

/// Full configuration for `blank_doc_comment`: severity and scan mode, with no rule-specific options.
pub const Rule = category.Rule(default_severity, struct {}, scan.Modes.public_api_surface);

/// Walks `tree` and appends diagnostics for vacuous doc comments.
///
/// When `is_module_entry` is set, blank `//!` blocks on the file are reported as module doc comments.
/// Whole-module re-exports without a line doc comment also resolve blank `//!` on the imported file.
/// See `docent.scan.alias` for resolution behavior.
pub fn check(
    tree: *const Ast,
    rule: Rule,
    file: []const u8,
    module_name: ?[]const u8,
    is_module_entry: bool,
    allocator: std.mem.Allocator,
    io: std.Io,
    msg_allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) !void {
    if (!rule.level.isActive()) return;
    const severity_level = rule.level;
    const public_api_only = rule.publicApiOnly();

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
            if (!doc.comment.isEmptyLine(slice)) all_empty = false;
        }

        if (all_empty) {
            const tok: Ast.TokenIndex = @intCast(block_start);
            const slice = tree.tokenSlice(tok);
            const loc = tree.tokenLocation(0, tok);
            const subject = if (tag == .container_doc_comment)
                try containerDocSubject(tree, file, module_name, is_module_entry, msg_allocator)
            else
                try doc.resolveDocCommentSubject(tree, @intCast(i), file, module_name, msg_allocator);
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
        doc.exposedSourceFileSubjectKind(tree),
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
                if (alias.getInfo(tree, init_node)) |info| {
                    if (info.field_name == null) {
                        var emit_ctx = BlankWholeModuleContext{
                            .severity_level = severity_level,
                            .allocator = allocator,
                            .msg_allocator = msg_allocator,
                            .diagnostics = diagnostics,
                        };
                        try alias.resolveWholeModuleReexport(
                            info,
                            file,
                            allocator,
                            io,
                            &emit_ctx,
                            doc.containerDocBlockIsFullyBlank,
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

fn onBlankWholeModuleReexport(ctx_ptr: *anyopaque, tree: *const Ast, file_path: []const u8) !void {
    const ctx: *BlankWholeModuleContext = @ptrCast(@alignCast(ctx_ptr));
    const source_basename = std.fs.path.basename(file_path);
    const subject_kind = doc.exposedSourceFileSubjectKind(tree);
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
        .file = try vereda.path.toPosixSeparators(ctx.msg_allocator, file_path),
        .line = line + 1,
        .column = column + 1,
        .source_line = if (tree.tokens.len > 0) try utils.dupSourceLine(tree, 0, ctx.msg_allocator) else "",
        .symbol_len = if (tree.tokens.len > 0) tree.tokenSlice(0).len else source_basename.len,
    });
}
