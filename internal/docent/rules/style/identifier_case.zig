//! The `identifier_case` namespace checks that identifiers follow the project's naming conventions.
//!
//! By default the conventions mirror the [Zig documentation style](https://ziglang.org/documentation/0.16.0/#Names), which is translated to:
//!
//! - `camelCase`: concrete functions (`options.functions`).
//! - `PascalCase`:
//!   - structures (structure files inherit this convention via `options.struct_file_case`)
//!   - unions
//!   - enumerations
//!   - error sets and unions, and its values (`options.types`)
//!   - generic (type-returning) functions (`options.types`)
//!
//! Configure per-category conventions under `[style.identifier_case]` with `namespaces`, `functions`, `types`, and `constants` (see `docent.schema.yaml`).
//!
//! ## Notes
//!
//! ### On errors
//!
//! Error-set values are checked as `PascalCase`, following the standard-library convention (`error.OutOfMemory`), even though they technically belong to the "value" category.
//!
//! ### Re-exported aliases
//!
//! Declarations whose initializer is a plain identifier, field access, call, or `@import(...)` are treated as aliases/re-exports, so checks must be conservative to avoid false positives. In particular, cases like `camelCase` globals that alias functions at the module root should not be misclassified — the effective kind comes from the original declaration, not the alias form.
//!
//! ### Quoted identifiers
//!
//! Identifiers written as `@"..."` are exempt from case checks because the string may contain any allowed spelling.
//!
//! ### Import paths
//!
//! For `@import("path.zig")`, the expected case follows the kind of the imported file: namespaces (no struct fields at file scope) use `snake_case`, while struct-at-file-scope modules use `PascalCase`. The binding should match the same convention. Member re-exports (`@import("path.zig").Level`) refer to a declaration, not the module, and are handled accordingly.
//!
//! ## Tiger Beetle's Style
//!
//! Tiger Beetle has its own style convention called [Tiger Style](https://tigerstyle.dev/), a solid reference point for _experience_.
//!
//! Check it out at:
//!
//! - <https://tigerstyle.dev/#nouns-and-verbs>
//! - <https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md#naming-things>
//!
//! It's worth noting it because it centers on 3 pillars: _Safety_, _Performance_, and _Experience_.

const std = @import("std");
const Ast = std.zig.Ast;
const vereda = @import("vereda");

const Diagnostic = @import("../../Diagnostic.zig");
const severity = @import("../../severity.zig");
const scan = @import("../../scan.zig");
const category = @import("../category.zig");
const utils = @import("../utils.zig");
const doc_comment = @import("doc_comment");
const naming_case = @import("identifier_style");

inline fn srcLoc() std.builtin.SourceLocation {
    return @src();
}

const rule_name = utils.ruleIdFromSrc(srcLoc());

/// Default severity `warn`: naming is advisory, so a fresh checkout sees casing issues without failing the build; raise it to `deny` or `forbid` in CI config.
pub const default_severity: severity.Level = .warn;

/// Title for diagnostic prose (`Warning: {prose_title} on …`).
pub const prose_title = "Identifier case";

/// Full configuration for the `identifier_case` rule.
///
/// Severity, scan mode, and the rule-specific knobs live at distinct levels on purpose: `level`
/// and `scan_mode` describe *how loud* and *over what surface* the rule runs, while `options` is
/// purely about *what* it checks. This struct is its own resolved shape — every field has a real
/// default, so `Rule{}` is the fully-defaulted value and TOML decoding only overwrites set keys.
/// Rule-specific knobs for `identifier_case`, held in the `options` sub-space of `Rule`.
pub const Options = struct {
    /// Field-less containers and namespace import bindings.
    namespaces: naming_case.Style = .snake,
    /// Concrete (non-type-returning) functions.
    functions: naming_case.Style = .camel,
    /// Structs, enums, unions, error sets, type aliases, and type-returning functions.
    types: naming_case.Style = .pascal,
    /// Container fields, variables, and global constants.
    constants: naming_case.Style = .snake,
    /// Expected case for struct-at-file-scope module filenames; default `PascalCase` mirrors the struct type name (`Report.zig` defines `Report`), while `snake_case` follows Tiger Style.
    struct_file_case: naming_case.Style = .pascal,
};

/// Full configuration for `identifier_case`: severity, scan mode, and the documented `Options` sub-space.
pub const Rule = category.Rule(default_severity, Options, scan.RuleScanConfig.reachability_traversal);

/// The expected case plus the diagnostic subject kind for a classified declaration.
const Classification = struct {
    case: naming_case.Style,
    kind: Diagnostic.SubjectKind,
};

/// Walks `tree` and appends a diagnostic for every identifier whose case does not match its category.
///
/// When `public_api_only` is set, only public declarations (and the members of public containers) are
/// checked; otherwise every declaration is checked. The `docent style` sub-command always passes
/// `false`, measuring every identifier reachable from the module roots.
pub fn check(
    tree: *const Ast,
    rule: Rule,
    file: []const u8,
    allocator: std.mem.Allocator,
    io: std.Io,
    msg_allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) std.mem.Allocator.Error!void {
    if (!rule.level.isActive()) return;
    const severity_level = rule.level;
    const options = rule.options;
    const public_api_only = rule.publicApiOnly();

    try checkStructFileName(tree, severity_level, file, options, allocator, msg_allocator, diagnostics);

    var namespace_cache = std.StringHashMap(bool).init(allocator);
    defer {
        var it = namespace_cache.keyIterator();
        while (it.next()) |key| allocator.free(key.*);
        namespace_cache.deinit();
    }

    for (tree.rootDecls()) |decl| {
        try checkNode(tree, decl, severity_level, file, public_api_only, options, .field, allocator, io, &namespace_cache, msg_allocator, diagnostics);
    }
}

fn checkNode(
    tree: *const Ast,
    node: Ast.Node.Index,
    severity_level: severity.Level,
    file: []const u8,
    public_api_only: bool,
    options: Options,
    member_field_kind: Diagnostic.SubjectKind,
    allocator: std.mem.Allocator,
    io: std.Io,
    namespace_cache: *std.StringHashMap(bool),
    msg_allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) std.mem.Allocator.Error!void {
    const tag = tree.nodeTag(node);

    if (tag == .fn_decl) {
        var buf: [1]Ast.Node.Index = undefined;
        if (tree.fullFnProto(&buf, node)) |proto| {
            if (utils.isPubVisibility(tree, proto.visib_token) or !public_api_only) {
                if (proto.name_token) |name_tok| {
                    const expected = if (isGenericFunction(tree, proto))
                        options.types
                    else
                        options.functions;
                    try checkName(tree, name_tok, expected, .function, severity_level, file, allocator, msg_allocator, diagnostics);
                }
            }
        }
        return;
    }

    if (tree.fullVarDecl(node)) |var_decl| {
        if (var_decl.ast.init_node.unwrap()) |init_node| {
            try checkImportFilenameExpr(tree, init_node, severity_level, file, options, allocator, io, namespace_cache, msg_allocator, diagnostics);
            try checkImportBinding(tree, var_decl, init_node, severity_level, file, options, allocator, io, namespace_cache, msg_allocator, diagnostics);
        }
        if (utils.isPubVisibility(tree, var_decl.visib_token) or !public_api_only) {
            const name_tok = var_decl.ast.mut_token + 1;
            if (classifyVarDecl(tree, var_decl, options)) |c| {
                try checkName(tree, name_tok, c.case, c.kind, severity_level, file, allocator, msg_allocator, diagnostics);
            }
            if (var_decl.ast.init_node.unwrap()) |init_node| {
                if (tree.nodeTag(init_node) == .error_set_decl) {
                    try checkErrorSetValues(tree, init_node, severity_level, file, options, allocator, msg_allocator, diagnostics);
                }
            }
        }
        try checkVarDeclInit(tree, var_decl, severity_level, file, public_api_only, options, allocator, io, namespace_cache, msg_allocator, diagnostics);
        return;
    }

    if (utils.isContainerDecl(tag)) {
        var buf: [2]Ast.Node.Index = undefined;
        if (tree.fullContainerDecl(&buf, node)) |container| {
            const child_kind: Diagnostic.SubjectKind = if (utils.isEnumContainer(tree, node)) .enumerator else member_field_kind;
            for (container.ast.members) |member| {
                try checkNode(tree, member, severity_level, file, public_api_only, options, child_kind, allocator, io, namespace_cache, msg_allocator, diagnostics);
            }
        }
        return;
    }

    if (tree.fullContainerField(node)) |field| {
        try checkName(tree, field.ast.main_token, options.constants, member_field_kind, severity_level, file, allocator, msg_allocator, diagnostics);
        return;
    }
}

/// Recurses into a `var`/`const` whose initializer is a container so its members are checked too.
fn checkVarDeclInit(
    tree: *const Ast,
    var_decl: Ast.full.VarDecl,
    severity_level: severity.Level,
    file: []const u8,
    public_api_only: bool,
    options: Options,
    allocator: std.mem.Allocator,
    io: std.Io,
    namespace_cache: *std.StringHashMap(bool),
    msg_allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) std.mem.Allocator.Error!void {
    if (public_api_only and !utils.isPubVisibility(tree, var_decl.visib_token)) return;

    const init_node = var_decl.ast.init_node.unwrap() orelse return;
    if (!utils.isContainerDecl(tree.nodeTag(init_node))) return;

    var buf: [2]Ast.Node.Index = undefined;
    if (tree.fullContainerDecl(&buf, init_node)) |container| {
        const child_kind: Diagnostic.SubjectKind = if (utils.isEnumContainer(tree, init_node)) .enumerator else .field;
        for (container.ast.members) |member| {
            try checkNode(tree, member, severity_level, file, public_api_only, options, child_kind, allocator, io, namespace_cache, msg_allocator, diagnostics);
        }
    }
}

const ImportLiteral = struct {
    path: []const u8,
    str_tok: Ast.TokenIndex,
};

/// When `node` is `@import("path.zig")` or `@import("path.zig").Field`, returns the path and string token.
fn getImportLiteral(tree: *const Ast, node: Ast.Node.Index) ?ImportLiteral {
    const tag = tree.nodeTag(node);
    if (tag == .field_access) {
        const fa = tree.nodeData(node).node_and_token;
        return getImportLiteral(tree, fa[0]);
    }

    if (tag != .builtin_call_two and tag != .builtin_call_two_comma) return null;

    const builtin_tok = tree.nodeMainToken(node);
    if (tree.tokenTag(builtin_tok) != .builtin) return null;
    if (!std.mem.eql(u8, tree.tokenSlice(builtin_tok), "@import")) return null;

    const args = tree.nodeData(node).opt_node_and_opt_node;
    const arg_node = args[0].unwrap() orelse return null;
    if (tree.nodeTag(arg_node) != .string_literal) return null;

    const str_tok = tree.nodeMainToken(arg_node);
    const raw = tree.tokenSlice(str_tok);
    if (raw.len < 2 or raw[0] != '"' or raw[raw.len - 1] != '"') return null;
    return .{
        .path = raw[1 .. raw.len - 1],
        .str_tok = str_tok,
    };
}

/// True when `node` is `@import("path.zig").Member` — a re-export of one declaration, not the module.
fn isImportMemberReexport(tree: *const Ast, node: Ast.Node.Index) bool {
    if (tree.nodeTag(node) != .field_access) return false;
    const fa = tree.nodeData(node).node_and_token;

    return getImportLiteral(tree, fa[0]) != null;
}

fn checkStructFileName(
    tree: *const Ast,
    severity_level: severity.Level,
    file: []const u8,
    options: Options,
    allocator: std.mem.Allocator,
    msg_allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) std.mem.Allocator.Error!void {
    const file_case = options.struct_file_case;
    const base = std.fs.path.basename(file);
    if (std.mem.eql(u8, base, "root.zig") or std.mem.eql(u8, base, "main.zig")) return;
    if (!std.mem.endsWith(u8, base, ".zig")) return;
    const stem = base[0 .. base.len - ".zig".len];

    if (!doc_comment.fileIsNamespace(tree)) {
        if (file_case.matches(stem)) return;

        const expected_stem = try naming_case.suggestFilenameStem(msg_allocator, stem, file_case);
        defer msg_allocator.free(expected_stem);

        const report_tok: Ast.TokenIndex = if (tree.rootDecls().len > 0) tree.firstToken(tree.rootDecls()[0]) else 0;
        const loc = tree.tokenLocation(0, report_tok);
        const detail = try std.fmt.allocPrint(
            msg_allocator,
            "struct file should use {s} filename \"{s}.zig\"",
            .{ file_case.label(), expected_stem },
        );
        try diagnostics.append(allocator, .{
            .rule = rule_name,
            .severity_level = severity_level,
            .subject = try utils.ownedSubject(msg_allocator, .source_file, base),
            .detail = detail,
            .file = file,
            .line = loc.line + 1,
            .column = loc.column + 1,
            .source_line = try utils.dupSourceLine(tree, report_tok, msg_allocator),
            .symbol_len = stem.len,
        });
        return;
    }

    for (tree.rootDecls()) |decl| {
        const var_decl = tree.fullVarDecl(decl) orelse continue;
        const init_node = var_decl.ast.init_node.unwrap() orelse continue;
        if (!utils.isContainerDecl(tree.nodeTag(init_node))) continue;

        var buf: [2]Ast.Node.Index = undefined;
        const container = tree.fullContainerDecl(&buf, init_node) orelse continue;
        if (tree.tokenTag(container.ast.main_token) != .keyword_struct) continue;
        if (!containerHasFields(tree, container)) continue;

        const name_tok = var_decl.ast.mut_token + 1;
        const name = tree.tokenSlice(name_tok);
        if (isExemptName(name)) continue;

        const snake_from_name = try naming_case.pascalCaseStemToSnake(msg_allocator, name);
        defer msg_allocator.free(snake_from_name);
        const expected_stem = try naming_case.identifierToFilenameStem(msg_allocator, name, file_case);
        defer msg_allocator.free(expected_stem);

        // Only dedicated struct modules pair a filename stem with the struct name.
        // Under PascalCase filenames, require an exact stem match (Report.zig + Report).
        // Snake-case stem pairing (init_options.zig + InitOptions) applies only with
        // struct_file_case = snake_case (Tiger Style), not when a namespace file
        // happens to share a stem with the snake_case form of an inner struct (report.zig + Report).
        const stem_pairs_with_struct = std.mem.eql(u8, stem, expected_stem) or
            (file_case == .snake and std.mem.eql(u8, stem, snake_from_name));
        if (!stem_pairs_with_struct) continue;
        if (std.mem.eql(u8, stem, expected_stem)) continue;

        const loc = tree.tokenLocation(0, name_tok);
        const detail = try std.fmt.allocPrint(
            msg_allocator,
            "struct file should use {s} filename \"{s}.zig\" for struct '{s}'",
            .{ file_case.label(), expected_stem, name },
        );
        try diagnostics.append(allocator, .{
            .rule = rule_name,
            .severity_level = severity_level,
            .subject = try utils.ownedSubject(msg_allocator, .structure, name),
            .detail = detail,
            .file = file,
            .line = loc.line + 1,
            .column = loc.column + 1,
            .source_line = try utils.dupSourceLine(tree, name_tok, msg_allocator),
            .symbol_len = name.len,
        });
    }
}

fn checkImportBinding(
    tree: *const Ast,
    var_decl: Ast.full.VarDecl,
    init_node: Ast.Node.Index,
    severity_level: severity.Level,
    file: []const u8,
    options: Options,
    allocator: std.mem.Allocator,
    io: std.Io,
    namespace_cache: *std.StringHashMap(bool),
    msg_allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) std.mem.Allocator.Error!void {
    if (isImportMemberReexport(tree, init_node)) return;

    const lit = getImportLiteral(tree, init_node) orelse return;
    if (!std.mem.endsWith(u8, lit.path, ".zig")) return;

    const file_kind = try resolveImportedFileKind(lit.path, file, allocator, io, namespace_cache) orelse return;
    const expected = if (file_kind == .namespace) options.namespaces else options.types;
    const kind: Diagnostic.SubjectKind = if (file_kind == .namespace) .namespace else .structure;

    const name_tok = var_decl.ast.mut_token + 1;
    try checkName(tree, name_tok, expected, kind, severity_level, file, allocator, msg_allocator, diagnostics);
}

fn checkImportFilenameExpr(
    tree: *const Ast,
    node: Ast.Node.Index,
    severity_level: severity.Level,
    file: []const u8,
    options: Options,
    allocator: std.mem.Allocator,
    io: std.Io,
    namespace_cache: *std.StringHashMap(bool),
    msg_allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) std.mem.Allocator.Error!void {
    const lit = getImportLiteral(tree, node) orelse return;
    try checkImportFilename(tree, lit, severity_level, file, options, allocator, io, namespace_cache, msg_allocator, diagnostics);
}

fn checkImportFilename(
    tree: *const Ast,
    lit: ImportLiteral,
    severity_level: severity.Level,
    file: []const u8,
    options: Options,
    allocator: std.mem.Allocator,
    io: std.Io,
    namespace_cache: *std.StringHashMap(bool),
    msg_allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) std.mem.Allocator.Error!void {
    if (!std.mem.endsWith(u8, lit.path, ".zig")) return;
    if (std.fs.path.isAbsolute(lit.path)) return;

    const basename = std.fs.path.basename(lit.path);
    if (basename.len <= ".zig".len) return;

    const stem = basename[0 .. basename.len - ".zig".len];
    const file_kind = try resolveImportedFileKind(lit.path, file, allocator, io, namespace_cache) orelse return;
    const loc = tree.tokenLocation(0, lit.str_tok);

    if (file_kind == .structure and !options.struct_file_case.matches(stem)) {
        const expected_stem = try naming_case.suggestFilenameStem(msg_allocator, stem, options.struct_file_case);
        defer msg_allocator.free(expected_stem);
        const expected = try std.fmt.allocPrint(msg_allocator, "{s}.zig", .{expected_stem});
        try diagnostics.append(allocator, .{
            .rule = rule_name,
            .severity_level = severity_level,
            .subject = try utils.ownedSubject(msg_allocator, .source_file, basename),
            .detail = try std.fmt.allocPrint(
                msg_allocator,
                "struct file should use {s} filename; expected \"{s}\"",
                .{ options.struct_file_case.label(), expected },
            ),
            .file = file,
            .line = loc.line + 1,
            .column = loc.column + 1,
            .source_line = try utils.dupSourceLine(tree, lit.str_tok, msg_allocator),
            .symbol_len = lit.path.len,
        });
        return;
    }

    if (options.namespaces.matches(stem)) return;
    if (file_kind != .namespace) return;

    const detail: []const u8 = if (options.namespaces == .snake) blk: {
        const snake_stem = try naming_case.pascalCaseStemToSnake(msg_allocator, stem);
        defer msg_allocator.free(snake_stem);
        const expected = try std.fmt.allocPrint(msg_allocator, "{s}.zig", .{snake_stem});
        break :blk try std.fmt.allocPrint(msg_allocator, "namespace file should use snake_case filename; expected \"{s}\"", .{expected});
    } else blk: {
        break :blk try std.fmt.allocPrint(msg_allocator, "namespace file should use {s} filename", .{options.namespaces.label()});
    };

    try diagnostics.append(allocator, .{
        .rule = rule_name,
        .severity_level = severity_level,
        .subject = try utils.ownedSubject(msg_allocator, .source_file, basename),
        .detail = detail,
        .file = file,
        .line = loc.line + 1,
        .column = loc.column + 1,
        .source_line = try utils.dupSourceLine(tree, lit.str_tok, msg_allocator),
        .symbol_len = lit.path.len,
    });
}

const ImportedFileKind = enum {
    namespace,
    structure,
};

/// Classifies a resolved `.zig` import target, or returns null when the file cannot be read or parsed.
fn resolveImportedFileKind(
    import_path: []const u8,
    current_file: []const u8,
    allocator: std.mem.Allocator,
    io: std.Io,
    cache: *std.StringHashMap(bool),
) std.mem.Allocator.Error!?ImportedFileKind {
    const base_dir = std.fs.path.dirname(current_file) orelse ".";
    const joined = try std.fs.path.join(allocator, &.{ base_dir, import_path });
    defer allocator.free(joined);

    const abs = vereda.path.toPosixSeparators(allocator, joined) catch return null;
    defer allocator.free(abs);

    if (cache.get(abs)) |cached| return if (cached) .namespace else .structure;

    const is_namespace = blk: {
        const source = std.Io.Dir.cwd().readFileAllocOptions(
            io,
            abs,
            allocator,
            .limited(std.math.maxInt(u32)),
            .of(u8),
            0,
        ) catch break :blk null;
        defer allocator.free(source);

        var imported = std.zig.Ast.parse(allocator, source, .zig) catch break :blk null;
        defer imported.deinit(allocator);

        break :blk doc_comment.fileIsNamespace(&imported);
    };

    const is_namespace_val = is_namespace orelse return null;

    const cache_key = try allocator.dupe(u8, abs);
    try cache.put(cache_key, is_namespace_val);
    return if (is_namespace_val) .namespace else .structure;
}

/// Determines the expected case for the *name* of a `var`/`const`, or null when it should be skipped.
fn classifyVarDecl(tree: *const Ast, var_decl: Ast.full.VarDecl, options: Options) ?Classification {
    const is_const = tree.tokenTag(var_decl.ast.mut_token) == .keyword_const;
    const init_node = var_decl.ast.init_node.unwrap() orelse return null;
    const tag = tree.nodeTag(init_node);
    const types_case = options.types;
    const namespaces_case = options.namespaces;
    const constants_case = options.constants;

    if (utils.isContainerDecl(tag)) {
        var buf: [2]Ast.Node.Index = undefined;
        const container = tree.fullContainerDecl(&buf, init_node) orelse return null;
        return switch (tree.tokenTag(container.ast.main_token)) {
            .keyword_enum => .{ .case = types_case, .kind = .enumeration },
            .keyword_union => .{ .case = types_case, .kind = .@"union" },
            // A field-less struct/opaque is a namespace; one with fields is a structure.
            .keyword_struct, .keyword_opaque => if (containerHasFields(tree, container))
                .{ .case = types_case, .kind = .structure }
            else
                .{ .case = namespaces_case, .kind = .namespace },
            else => .{ .case = types_case, .kind = .structure },
        };
    }

    if (tag == .error_set_decl) return .{ .case = types_case, .kind = .error_set };

    // Inline type expressions (`[]const u8`, `?T`, `fn () void`, …) define a type and use PascalCase.
    if (isTypeExpr(tag)) return .{ .case = types_case, .kind = .type_alias };

    // Aliases/re-exports resolve to a declaration elsewhere; skip to avoid false positives.
    if (isAliasInit(tag)) return null;

    return .{ .case = constants_case, .kind = if (is_const) .constant else .variable };
}

/// Checks each error-set value (e.g. `error{ OutOfMemory }`) against the configured type convention.
fn checkErrorSetValues(
    tree: *const Ast,
    node: Ast.Node.Index,
    severity_level: severity.Level,
    file: []const u8,
    options: Options,
    allocator: std.mem.Allocator,
    msg_allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) std.mem.Allocator.Error!void {
    const expected = options.types;
    const first = tree.firstToken(node);
    const last = tree.lastToken(node);
    var tok = first;
    while (tok <= last) : (tok += 1) {
        switch (tree.tokenTag(tok)) {
            .identifier, .string_literal => {
                const name = tree.tokenSlice(tok);
                if (isExemptName(name)) continue;
                try checkName(tree, tok, expected, .error_value, severity_level, file, allocator, msg_allocator, diagnostics);
            },
            else => {},
        }
    }
}

fn checkName(
    tree: *const Ast,
    name_tok: Ast.TokenIndex,
    expected: naming_case.Style,
    kind: Diagnostic.SubjectKind,
    severity_level: severity.Level,
    file: []const u8,
    allocator: std.mem.Allocator,
    msg_allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) std.mem.Allocator.Error!void {
    const name = tree.tokenSlice(name_tok);
    if (isExemptName(name)) return;
    if (kind == .enumerator and (naming_case.isCamel(name) or naming_case.isPascal(name))) return;
    if (expected.matches(name)) return;

    const loc = tree.tokenLocation(0, name_tok);
    try diagnostics.append(allocator, .{
        .rule = rule_name,
        .severity_level = severity_level,
        .subject = try utils.ownedSubject(msg_allocator, kind, name),
        .detail = try std.fmt.allocPrint(msg_allocator, "should be {s}", .{expected.label()}),
        .file = file,
        .line = loc.line + 1,
        .column = loc.column + 1,
        .source_line = try utils.dupSourceLine(tree, name_tok, msg_allocator),
        .symbol_len = name.len,
    });
}

/// True for type-constructor functions (those that return `type`), which use `PascalCase`.
fn isGenericFunction(tree: *const Ast, proto: Ast.full.FnProto) bool {
    const return_type = proto.ast.return_type.unwrap() orelse return false;
    if (tree.nodeTag(return_type) != .identifier) return false;
    return std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(return_type)), "type");
}

/// True when a container declaration declares at least one field (as opposed to only declarations).
fn containerHasFields(tree: *const Ast, container: Ast.full.ContainerDecl) bool {
    for (container.ast.members) |member| {
        if (tree.fullContainerField(member) != null) return true;
    }
    return false;
}

/// True when an initializer is an inline type expression (so the binding defines a type).
fn isTypeExpr(tag: Ast.Node.Tag) bool {
    return switch (tag) {
        .ptr_type,
        .ptr_type_aligned,
        .ptr_type_bit_range,
        .ptr_type_sentinel,
        .array_type,
        .array_type_sentinel,
        .optional_type,
        .error_union,
        .anyframe_type,
        .merge_error_sets,
        .fn_proto,
        .fn_proto_one,
        .fn_proto_simple,
        .fn_proto_multi,
        => true,
        else => false,
    };
}

/// True when an initializer merely references a declaration defined elsewhere.
fn isAliasInit(tag: Ast.Node.Tag) bool {
    return switch (tag) {
        .identifier,
        .field_access,
        .call,
        .call_comma,
        .call_one,
        .call_one_comma,
        .builtin_call,
        .builtin_call_comma,
        .builtin_call_two,
        .builtin_call_two_comma,
        => true,
        else => false,
    };
}

/// Identifiers exempt from case checks: empty, the discard `_`, and quoted `@"..."` identifiers.
fn isExemptName(name: []const u8) bool {
    if (name.len == 0) return true;
    if (name[0] == '@') return true;
    return std.mem.eql(u8, name, "_");
}

test "inactive severity yields no diagnostics" {
    const base = std.testing.allocator;
    var tree = try std.zig.Ast.parse(base, "pub fn DoThing() void {}", .zig);
    defer tree.deinit(base);
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(base);
    try check(&tree, .{ .level = .allow }, "<test>", base, std.testing.io, base, &diagnostics);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}
