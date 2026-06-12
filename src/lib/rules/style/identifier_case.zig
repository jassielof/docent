//! The `identifier_case` namespace checks that identifiers follow the project's naming conventions.
//!
//! By default the conventions mirror the [Zig documentation style](https://ziglang.org/documentation/0.16.0/#Names), which is translated to:
//!
//! - `snake_case`:
//!   - namespaces (field-less structures)
//!   - global variables and constants
//!   - fields or values from:
//!     - structures
//!     - unions
//!     - enumerations (its enumerators)
//!     - function parameters
//! - `camelCase`: concrete functions.
//! - `PascalCase`:
//!   - structures
//!   - unions
//!   - enumerations
//!   - error sets and unions, and its values
//!   - generic (type-returning) functions
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

const Diagnostic = @import("../../Diagnostic.zig");
const severity = @import("../../severity.zig");
const scanning = @import("../../scanning.zig");
const toml = @import("toml");
const rule_config = @import("../config.zig");
const rule_opts = @import("../options.zig");
const utils = @import("../utils.zig");

inline fn srcLoc() std.builtin.SourceLocation {
    return @src();
}

const rule_name = utils.ruleIdFromSrc(srcLoc());

/// The default_severity for the rule.
pub const default_severity: severity.Level = .warn;

/// Filename case convention for struct-at-file-scope modules.
pub const FilenameCase = enum {
    snake_case,
    /// Quoted import identifiers (`@"..."`); config value is literally `@"kebab-case"`.
    @"kebab-case",
};

/// Raw configuration for this rule from `docent.toml`.
pub const Config = struct {
    level: ?severity.Level = null,
    scan_mode: ?scanning.Modes = null,
    /// Case convention for struct file basenames. When omitted, defaults to snake_case; use `@"kebab-case"` for quoted-identifier imports.
    struct_file_case: ?FilenameCase = null,
};

pub fn decodeConfig(value: toml.DynamicValue) rule_config.Error!Config {
    const case_name = rule_config.decodeStringField(value, "struct_file_case");
    return .{
        .level = try rule_config.decodeLevelValue(value),
        .scan_mode = rule_config.decodeScanModeField(value),
        .struct_file_case = if (case_name) |name| decodeFilenameCase(name) else null,
    };
}

fn decodeFilenameCase(name: []const u8) ?FilenameCase {
    if (std.mem.eql(u8, name, "@\"kebab-case\"")) return .@"kebab-case";
    return std.meta.stringToEnum(FilenameCase, name);
}

/// Resolved options for the identifier case rule.
pub const Options = struct {
    /// Which declarations this rule inspects; inherits the style category `scan_mode` unless overridden for this rule.
    scan_mode: scanning.Modes = scanning.Modes.reachability_traversal,
    /// Expected case for struct-at-file-scope module filenames.
    struct_file_case: FilenameCase = .snake_case,

    pub fn resolve(category_scan: scanning.Modes, rule: Config) Options {
        return .{
            .scan_mode = rule_opts.scanModeFromRule(category_scan, rule),
            .struct_file_case = rule.struct_file_case orelse .snake_case,
        };
    }

    pub fn publicApiOnly(self: Options) bool {
        return self.scan_mode.publicApiOnly();
    }
};

/// A naming convention an identifier is expected to follow.
const Case = enum {
    snake,
    camel,
    pascal,

    fn label(self: Case) []const u8 {
        return switch (self) {
            .snake => "snake_case",
            .camel => "camelCase",
            .pascal => "PascalCase",
        };
    }

    fn matches(self: Case, name: []const u8) bool {
        return switch (self) {
            .snake => isSnakeCase(name),
            .camel => isCamelCase(name),
            .pascal => isPascalCase(name),
        };
    }
};

/// The expected case plus the diagnostic subject kind for a classified declaration.
const Classification = struct {
    case: Case,
    kind: Diagnostic.SubjectKind,
};

/// Walks `tree` and appends a diagnostic for every identifier whose case does not match its category.
///
/// When `public_api_only` is set, only public declarations (and the members of public containers) are
/// checked; otherwise every declaration is checked. The `docent style` sub-command always passes
/// `false`, measuring every identifier reachable from the module roots.
pub fn check(
    tree: *const Ast,
    severity_level: severity.Level,
    file: []const u8,
    options: Options,
    allocator: std.mem.Allocator,
    io: std.Io,
    msg_allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) std.mem.Allocator.Error!void {
    if (!severity_level.isActive()) return;
    const public_api_only = options.publicApiOnly();

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
                    const expected: Case = if (isGenericFunction(tree, proto)) .pascal else .camel;
                    try checkName(tree, name_tok, expected, .function, severity_level, file, allocator, msg_allocator, diagnostics);
                }
            }
        }
        return;
    }

    if (tree.fullVarDecl(node)) |var_decl| {
        if (var_decl.ast.init_node.unwrap()) |init_node| {
            try checkImportFilenameExpr(tree, init_node, severity_level, file, options, allocator, io, namespace_cache, msg_allocator, diagnostics);
            try checkImportBinding(tree, var_decl, init_node, severity_level, file, allocator, io, namespace_cache, msg_allocator, diagnostics);
        }
        if (utils.isPubVisibility(tree, var_decl.visib_token) or !public_api_only) {
            const name_tok = var_decl.ast.mut_token + 1;
            if (classifyVarDecl(tree, var_decl)) |c| {
                try checkName(tree, name_tok, c.case, c.kind, severity_level, file, allocator, msg_allocator, diagnostics);
            }
            if (var_decl.ast.init_node.unwrap()) |init_node| {
                if (tree.nodeTag(init_node) == .error_set_decl) {
                    try checkErrorSetValues(tree, init_node, severity_level, file, allocator, msg_allocator, diagnostics);
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
        try checkName(tree, field.ast.main_token, .snake, member_field_kind, severity_level, file, allocator, msg_allocator, diagnostics);
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

    if (!utils.fileIsNamespace(tree)) {
        if (stemMatchesFilenameCase(stem, file_case)) return;

        const expected_stem = try suggestStructImportStem(msg_allocator, stem, file_case);
        defer msg_allocator.free(expected_stem);

        const report_tok: Ast.TokenIndex = if (tree.rootDecls().len > 0) tree.firstToken(tree.rootDecls()[0]) else 0;
        const loc = tree.tokenLocation(0, report_tok);
        const detail = try std.fmt.allocPrint(
            msg_allocator,
            "struct file should use {s} filename \"{s}.zig\"",
            .{ filenameCaseLabel(file_case), expected_stem },
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

        const snake_from_name = try pascalCaseStemToSnake(msg_allocator, name);
        defer msg_allocator.free(snake_from_name);
        const expected_stem = try identifierToFilenameStem(msg_allocator, name, file_case);
        defer msg_allocator.free(expected_stem);

        // Only dedicated struct modules pair a filename stem with the struct name.
        if (!std.mem.eql(u8, stem, snake_from_name) and !std.mem.eql(u8, stem, expected_stem)) continue;
        if (std.mem.eql(u8, stem, expected_stem)) continue;

        const loc = tree.tokenLocation(0, name_tok);
        const detail = try std.fmt.allocPrint(
            msg_allocator,
            "struct file should use {s} filename \"{s}.zig\" for struct '{s}'",
            .{ filenameCaseLabel(file_case), expected_stem, name },
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
    const expected: Case = if (file_kind == .namespace) .snake else .pascal;
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

    if (file_kind == .structure and !stemMatchesFilenameCase(stem, options.struct_file_case)) {
        const expected_stem = try suggestStructImportStem(msg_allocator, stem, options.struct_file_case);
        defer msg_allocator.free(expected_stem);
        const expected = try std.fmt.allocPrint(msg_allocator, "{s}.zig", .{expected_stem});
        try diagnostics.append(allocator, .{
            .rule = rule_name,
            .severity_level = severity_level,
            .subject = try utils.ownedSubject(msg_allocator, .source_file, basename),
            .detail = try std.fmt.allocPrint(
                msg_allocator,
                "struct file should use {s} filename; expected \"{s}\"",
                .{ filenameCaseLabel(options.struct_file_case), expected },
            ),
            .file = file,
            .line = loc.line + 1,
            .column = loc.column + 1,
            .source_line = try utils.dupSourceLine(tree, lit.str_tok, msg_allocator),
            .symbol_len = lit.path.len,
        });
        return;
    }

    if (isSnakeCase(stem)) return;
    if (file_kind != .namespace) return;

    const snake_stem = try pascalCaseStemToSnake(msg_allocator, stem);
    defer msg_allocator.free(snake_stem);
    const expected = try std.fmt.allocPrint(msg_allocator, "{s}.zig", .{snake_stem});

    try diagnostics.append(allocator, .{
        .rule = rule_name,
        .severity_level = severity_level,
        .subject = try utils.ownedSubject(msg_allocator, .source_file, basename),
        .detail = try std.fmt.allocPrint(msg_allocator, "namespace file should use snake_case filename; expected \"{s}\"", .{expected}),
        .file = file,
        .line = loc.line + 1,
        .column = loc.column + 1,
        .source_line = try utils.dupSourceLine(tree, lit.str_tok, msg_allocator),
        .symbol_len = lit.path.len,
    });
}

/// Converts a PascalCase or mixed-case stem to `snake_case` for filename suggestions.
fn pascalCaseStemToSnake(allocator: std.mem.Allocator, stem: []const u8) std.mem.Allocator.Error![]u8 {
    if (stem.len == 0) return try allocator.dupe(u8, "");

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    for (stem, 0..) |c, i| {
        const is_upper = c >= 'A' and c <= 'Z';
        if (is_upper) {
            if (i > 0) {
                const prev = stem[i - 1];
                const next: u8 = if (i + 1 < stem.len) stem[i + 1] else 0;
                const prev_lower = prev >= 'a' and prev <= 'z';
                const next_lower = next >= 'a' and next <= 'z';
                const prev_upper = prev >= 'A' and prev <= 'Z';
                if (prev_lower or (prev_upper and next_lower)) {
                    try out.append(allocator, '_');
                }
            }
            try out.append(allocator, c + 32);
        } else {
            try out.append(allocator, c);
        }
    }

    return try out.toOwnedSlice(allocator);
}

fn filenameCaseLabel(case: FilenameCase) []const u8 {
    return switch (case) {
        .snake_case => "snake_case",
        .@"kebab-case" => "@\"kebab-case\"",
    };
}

fn stemMatchesFilenameCase(stem: []const u8, case: FilenameCase) bool {
    return switch (case) {
        .snake_case => isSnakeCase(stem),
        .@"kebab-case" => isKebabCase(stem),
    };
}

fn isKebabCase(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| {
        if (!((c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '-')) return false;
    }
    return true;
}

fn identifierToFilenameStem(allocator: std.mem.Allocator, name: []const u8, case: FilenameCase) std.mem.Allocator.Error![]u8 {
    return switch (case) {
        .snake_case => pascalCaseStemToSnake(allocator, name),
        .@"kebab-case" => pascalCaseStemToKebab(allocator, name),
    };
}

fn suggestStructImportStem(allocator: std.mem.Allocator, stem: []const u8, case: FilenameCase) std.mem.Allocator.Error![]u8 {
    if (stemMatchesFilenameCase(stem, case)) return allocator.dupe(u8, stem);
    const pascal = try snakeOrKebabStemToPascal(allocator, stem);
    defer allocator.free(pascal);
    return identifierToFilenameStem(allocator, pascal, case);
}

fn pascalCaseStemToKebab(allocator: std.mem.Allocator, stem: []const u8) std.mem.Allocator.Error![]u8 {
    const snake = try pascalCaseStemToSnake(allocator, stem);
    defer allocator.free(snake);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (snake) |c| {
        try out.append(allocator, if (c == '_') '-' else c);
    }
    return try out.toOwnedSlice(allocator);
}

fn snakeOrKebabStemToPascal(allocator: std.mem.Allocator, stem: []const u8) std.mem.Allocator.Error![]u8 {
    if (isPascalCase(stem) or isCamelCase(stem)) return allocator.dupe(u8, stem);
    if (isKebabCase(stem)) {
        var snake: std.ArrayList(u8) = .empty;
        errdefer snake.deinit(allocator);
        for (stem) |c| try snake.append(allocator, if (c == '-') '_' else c);
        const snake_slice = try snake.toOwnedSlice(allocator);
        defer allocator.free(snake_slice);
        return snakeCaseStemToPascal(allocator, snake_slice);
    }
    return snakeCaseStemToPascal(allocator, stem);
}

/// Converts a `snake_case` stem to PascalCase for struct filename suggestions.
fn snakeCaseStemToPascal(allocator: std.mem.Allocator, stem: []const u8) std.mem.Allocator.Error![]u8 {
    if (stem.len == 0) return try allocator.dupe(u8, "");

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var capitalize_next = true;
    for (stem) |c| {
        if (c == '_') {
            capitalize_next = true;
            continue;
        }
        if (capitalize_next and c >= 'a' and c <= 'z') {
            try out.append(allocator, c - 32);
            capitalize_next = false;
        } else if (capitalize_next and c >= 'A' and c <= 'Z') {
            try out.append(allocator, c);
            capitalize_next = false;
        } else {
            try out.append(allocator, c);
            capitalize_next = false;
        }
    }

    return try out.toOwnedSlice(allocator);
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

    const abs = utils.normalizePathSeparators(allocator, joined) catch return null;
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

        break :blk utils.fileIsNamespace(&imported);
    };

    const is_namespace_val = is_namespace orelse return null;

    const cache_key = try allocator.dupe(u8, abs);
    try cache.put(cache_key, is_namespace_val);
    return if (is_namespace_val) .namespace else .structure;
}

/// Determines the expected case for the *name* of a `var`/`const`, or null when it should be skipped.
fn classifyVarDecl(tree: *const Ast, var_decl: Ast.full.VarDecl) ?Classification {
    const is_const = tree.tokenTag(var_decl.ast.mut_token) == .keyword_const;
    const init_node = var_decl.ast.init_node.unwrap() orelse return null;
    const tag = tree.nodeTag(init_node);

    if (utils.isContainerDecl(tag)) {
        var buf: [2]Ast.Node.Index = undefined;
        const container = tree.fullContainerDecl(&buf, init_node) orelse return null;
        return switch (tree.tokenTag(container.ast.main_token)) {
            .keyword_enum => .{ .case = .pascal, .kind = .enumeration },
            .keyword_union => .{ .case = .pascal, .kind = .@"union" },
            // A field-less struct/opaque is a namespace; one with fields is a structure.
            .keyword_struct, .keyword_opaque => if (containerHasFields(tree, container))
                .{ .case = .pascal, .kind = .structure }
            else
                .{ .case = .snake, .kind = .namespace },
            else => .{ .case = .pascal, .kind = .structure },
        };
    }

    if (tag == .error_set_decl) return .{ .case = .pascal, .kind = .error_set };

    // Inline type expressions (`[]const u8`, `?T`, `fn () void`, …) define a type and use PascalCase.
    if (isTypeExpr(tag)) return .{ .case = .pascal, .kind = .type_alias };

    // Aliases/re-exports resolve to a declaration elsewhere; skip to avoid false positives.
    if (isAliasInit(tag)) return null;

    return .{ .case = .snake, .kind = if (is_const) .constant else .variable };
}

/// Checks each error-set value (e.g. `error{ OutOfMemory }`) as `PascalCase`.
fn checkErrorSetValues(
    tree: *const Ast,
    node: Ast.Node.Index,
    severity_level: severity.Level,
    file: []const u8,
    allocator: std.mem.Allocator,
    msg_allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) std.mem.Allocator.Error!void {
    const first = tree.firstToken(node);
    const last = tree.lastToken(node);
    var tok = first;
    while (tok <= last) : (tok += 1) {
        switch (tree.tokenTag(tok)) {
            .identifier, .string_literal => {
                const name = tree.tokenSlice(tok);
                if (isExemptName(name)) continue;
                try checkName(tree, tok, .pascal, .error_value, severity_level, file, allocator, msg_allocator, diagnostics);
            },
            else => {},
        }
    }
}

fn checkName(
    tree: *const Ast,
    name_tok: Ast.TokenIndex,
    expected: Case,
    kind: Diagnostic.SubjectKind,
    severity_level: severity.Level,
    file: []const u8,
    allocator: std.mem.Allocator,
    msg_allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) std.mem.Allocator.Error!void {
    const name = tree.tokenSlice(name_tok);
    if (isExemptName(name)) return;
    if (kind == .enumerator and (isCamelCase(name) or isPascalCase(name))) return;
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

fn isSnakeCase(name: []const u8) bool {
    for (name) |c| {
        if (c >= 'A' and c <= 'Z') return false;
    }
    return true;
}

fn isCamelCase(name: []const u8) bool {
    if (name.len == 0) return true;
    if (!(name[0] >= 'a' and name[0] <= 'z')) return false;
    for (name) |c| {
        if (c == '_') return false;
    }
    return true;
}

fn isPascalCase(name: []const u8) bool {
    if (name.len == 0) return true;
    if (!(name[0] >= 'A' and name[0] <= 'Z')) return false;
    for (name) |c| {
        if (c == '_') return false;
    }
    return true;
}

const TestResult = struct {
    msg_arena: std.heap.ArenaAllocator,
    items: std.ArrayList(Diagnostic),

    fn deinit(self: *TestResult) void {
        self.msg_arena.deinit();
        self.items.deinit(std.testing.allocator);
    }

    fn count(self: TestResult) usize {
        return self.items.items.len;
    }
};

fn runCheck(source: [:0]const u8, scan_mode: scanning.Modes) !TestResult {
    const base = std.testing.allocator;
    var msg_arena = std.heap.ArenaAllocator.init(base);
    errdefer msg_arena.deinit();

    var tree = try std.zig.Ast.parse(base, source, .zig);
    defer tree.deinit(base);

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    errdefer diagnostics.deinit(base);

    try check(&tree, .warn, "<test>", .{ .scan_mode = scan_mode }, base, std.testing.io, msg_arena.allocator(), &diagnostics);
    return .{ .msg_arena = msg_arena, .items = diagnostics };
}

test "pascalCaseStemToSnake inserts word boundaries" {
    const stem = try pascalCaseStemToSnake(std.testing.allocator, "DiagnosticMessage");
    defer std.testing.allocator.free(stem);
    try std.testing.expectEqualStrings("diagnostic_message", stem);

    const reach = try pascalCaseStemToSnake(std.testing.allocator, "Reachability");
    defer std.testing.allocator.free(reach);
    try std.testing.expectEqualStrings("reachability", reach);
}

test "import member re-export does not flag PascalCase binding" {
    const base = std.testing.allocator;
    var msg_arena = std.heap.ArenaAllocator.init(base);
    defer msg_arena.deinit();

    const source =
        \\pub const SeverityLevel = @import("severity.zig").Level;
    ++ "\x00";
    var tree = try std.zig.Ast.parse(base, source, .zig);
    defer tree.deinit(base);

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(base);

    try check(
        &tree,
        .warn,
        "src/lib/root.zig",
        .{},
        base,
        std.testing.io,
        msg_arena.allocator(),
        &diagnostics,
    );
    try std.testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}

test "PascalCase binding on namespace import is flagged" {
    const base = std.testing.allocator;
    var msg_arena = std.heap.ArenaAllocator.init(base);
    defer msg_arena.deinit();

    const source =
        \\const Severity = @import("BadNamespace.zig");
    ++ "\x00";
    var tree = try std.zig.Ast.parse(base, source, .zig);
    defer tree.deinit(base);

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(base);

    try check(
        &tree,
        .warn,
        "tests/fixtures/style/import_site.zig",
        .{},
        base,
        std.testing.io,
        msg_arena.allocator(),
        &diagnostics,
    );
    try std.testing.expectEqual(@as(usize, 2), diagnostics.items.len);

    var found_binding = false;
    var found_filename = false;
    for (diagnostics.items) |d| {
        if (d.subject) |s| {
            if (s.kind == .namespace and std.mem.eql(u8, s.name, "Severity")) found_binding = true;
            if (s.kind == .source_file and std.mem.eql(u8, s.name, "BadNamespace.zig")) found_filename = true;
        }
        if (d.detail) |detail| {
            if (std.mem.indexOf(u8, detail, "bad_namespace.zig") != null) found_filename = true;
        }
    }
    try std.testing.expect(found_binding);
    try std.testing.expect(found_filename);
}

test "snake_case predicates" {
    try std.testing.expect(isSnakeCase("foo_bar"));
    try std.testing.expect(isSnakeCase("pi"));
    try std.testing.expect(!isSnakeCase("fooBar"));
    try std.testing.expect(!isSnakeCase("MAX"));

    try std.testing.expect(isCamelCase("parseInt"));
    try std.testing.expect(isCamelCase("foo"));
    try std.testing.expect(!isCamelCase("parse_int"));
    try std.testing.expect(!isCamelCase("ParseInt"));

    try std.testing.expect(isPascalCase("ArrayList"));
    try std.testing.expect(!isPascalCase("array_list"));
    try std.testing.expect(!isPascalCase("arrayList"));
}

test "concrete function should be camelCase" {
    var r = try runCheck("pub fn DoThing() void {}", .reachability_traversal);
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 1), r.count());
    try std.testing.expectEqual(.function, r.items.items[0].subject.?.kind);
    try std.testing.expectEqualStrings("DoThing", r.items.items[0].subject.?.name);
}

test "well-cased concrete function is clean" {
    var r = try runCheck("pub fn doThing() void {}", .reachability_traversal);
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 0), r.count());
}

test "type-returning function should be PascalCase" {
    var r = try runCheck("pub fn list() type { return struct {}; }", .reachability_traversal);
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 1), r.count());
    try std.testing.expectEqualStrings("list", r.items.items[0].subject.?.name);
}

test "well-cased generic function is clean" {
    var r = try runCheck("pub fn List() type { return struct {}; }", .reachability_traversal);
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 0), r.count());
}

test "global constant should be snake_case" {
    var r = try runCheck("pub const MaxSize = 10;", .reachability_traversal);
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 1), r.count());
    try std.testing.expectEqual(.constant, r.items.items[0].subject.?.kind);
}

test "struct with fields should be PascalCase" {
    var r = try runCheck(
        \\pub const my_struct = struct {
        \\    x: u32,
        \\};
    , .reachability_traversal);
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 1), r.count());
    try std.testing.expectEqual(.structure, r.items.items[0].subject.?.kind);
    try std.testing.expectEqualStrings("my_struct", r.items.items[0].subject.?.name);
}

test "field-less container is a namespace and should be snake_case" {
    var r = try runCheck(
        \\pub const Helpers = struct {
        \\    pub fn ok() void {}
        \\};
    , .reachability_traversal);
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 1), r.count());
    try std.testing.expectEqual(.namespace, r.items.items[0].subject.?.kind);
    try std.testing.expectEqualStrings("Helpers", r.items.items[0].subject.?.name);
}

test "struct fields should be snake_case" {
    var r = try runCheck(
        \\pub const Point = struct {
        \\    X: u32,
        \\    y: u32,
        \\};
    , .reachability_traversal);
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 1), r.count());
    try std.testing.expectEqual(.field, r.items.items[0].subject.?.kind);
    try std.testing.expectEqualStrings("X", r.items.items[0].subject.?.name);
}

test "enum should be PascalCase and camel or Pascal enumerators are exempt" {
    var r = try runCheck(
        \\pub const color = enum {
        \\    Red,
        \\    green,
        \\};
    , .reachability_traversal);
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 1), r.count());
    try std.testing.expectEqual(.enumeration, r.items.items[0].subject.?.kind);
    try std.testing.expectEqualStrings("color", r.items.items[0].subject.?.name);
}

test "error set should be PascalCase and error values too" {
    var r = try runCheck("pub const my_error = error{ out_of_memory };", .reachability_traversal);
    defer r.deinit();
    // `my_error` (should be PascalCase) and `out_of_memory` (should be PascalCase).
    try std.testing.expectEqual(@as(usize, 2), r.count());
    try std.testing.expectEqual(.error_set, r.items.items[0].subject.?.kind);
    try std.testing.expectEqual(.error_value, r.items.items[1].subject.?.kind);
    try std.testing.expectEqualStrings("out_of_memory", r.items.items[1].subject.?.name);
}

test "inline type-expression alias should be PascalCase" {
    var r = try runCheck("pub const kind_phrase = []const []const u8;", .reachability_traversal);
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 1), r.count());
    try std.testing.expectEqual(.type_alias, r.items.items[0].subject.?.kind);
    try std.testing.expectEqualStrings("should be PascalCase", r.items.items[0].detail.?);
}

test "well-cased inline type alias is clean" {
    var r = try runCheck("pub const KindPhrase = []const u8;", .reachability_traversal);
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 0), r.count());
}

test "idiomatic error set is clean" {
    var r = try runCheck("pub const Error = error{ OutOfMemory, FileNotFound };", .reachability_traversal);
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 0), r.count());
}

test "PascalCase basename on namespace import is flagged" {
    const base = std.testing.allocator;
    var msg_arena = std.heap.ArenaAllocator.init(base);
    defer msg_arena.deinit();

    const source =
        \\const ns = @import("BadNamespace.zig");
    ++ "\x00";
    var tree = try std.zig.Ast.parse(base, source, .zig);
    defer tree.deinit(base);

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(base);

    try check(
        &tree,
        .warn,
        "tests/fixtures/style/import_site.zig",
        .{},
        base,
        std.testing.io,
        msg_arena.allocator(),
        &diagnostics,
    );
    try std.testing.expectEqual(@as(usize, 1), diagnostics.items.len);
    try std.testing.expectEqual(.source_file, diagnostics.items[0].subject.?.kind);
    try std.testing.expectEqualStrings("BadNamespace.zig", diagnostics.items[0].subject.?.name);
    try std.testing.expect(std.mem.indexOf(u8, diagnostics.items[0].detail.?, "snake_case filename") != null);
}

test "snake_case basename on struct-at-file-scope import is not flagged" {
    const base = std.testing.allocator;
    var msg_arena = std.heap.ArenaAllocator.init(base);
    defer msg_arena.deinit();

    const source =
        \\const struct_file = @import("struct_file.zig");
    ++ "\x00";
    var tree = try std.zig.Ast.parse(base, source, .zig);
    defer tree.deinit(base);

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(base);

    try check(
        &tree,
        .warn,
        "tests/fixtures/style/import_site.zig",
        .{},
        base,
        std.testing.io,
        msg_arena.allocator(),
        &diagnostics,
    );
    try std.testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}

test "function alias re-export is skipped" {
    var r = try runCheck(
        \\const helpers = @import("helpers.zig");
        \\pub const parseInt = helpers.parseInt;
    , .reachability_traversal);
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 0), r.count());
}

test "quoted identifiers are exempt" {
    var r = try runCheck("pub const @\"foo bar\" = 1;", .reachability_traversal);
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 0), r.count());
}

test "private declarations skipped under public_api_only" {
    var r = try runCheck("fn DoThing() void {}", .public_api_surface);
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 0), r.count());
}

test "private declarations checked when public_api_only is false" {
    var r = try runCheck("fn DoThing() void {}", .reachability_traversal);
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 1), r.count());
}

test "detail explains expected case" {
    var r = try runCheck("pub fn DoThing() void {}", .reachability_traversal);
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 1), r.count());
    try std.testing.expectEqualStrings("should be camelCase", r.items.items[0].detail.?);
}

test "inactive severity yields no diagnostics" {
    const base = std.testing.allocator;
    var tree = try std.zig.Ast.parse(base, "pub fn DoThing() void {}", .zig);
    defer tree.deinit(base);
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(base);
    try check(&tree, .allow, "<test>", .{}, base, std.testing.io, base, &diagnostics);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}

test "struct_file_case snake_case accepts snake_case implicit struct file stem" {
    const base = std.testing.allocator;
    var msg_arena = std.heap.ArenaAllocator.init(base);
    defer msg_arena.deinit();

    const source =
        \\x: u32 = 0,
    ++ "\x00";
    var tree = try std.zig.Ast.parse(base, source, .zig);
    defer tree.deinit(base);

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(base);

    try check(
        &tree,
        .warn,
        "init_options.zig",
        .{ .struct_file_case = .snake_case },
        base,
        std.testing.io,
        msg_arena.allocator(),
        &diagnostics,
    );
    try std.testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}

test "default struct_file_case flags non-snake_case struct file stem" {
    const base = std.testing.allocator;
    var msg_arena = std.heap.ArenaAllocator.init(base);
    defer msg_arena.deinit();

    const source =
        \\x: u32 = 0,
    ++ "\x00";
    var tree = try std.zig.Ast.parse(base, source, .zig);
    defer tree.deinit(base);

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(base);

    try check(
        &tree,
        .warn,
        "InitOptions.zig",
        .{},
        base,
        std.testing.io,
        msg_arena.allocator(),
        &diagnostics,
    );
    try std.testing.expectEqual(@as(usize, 1), diagnostics.items.len);
}

test "namespace module helper struct does not require matching filename" {
    const base = std.testing.allocator;
    var msg_arena = std.heap.ArenaAllocator.init(base);
    defer msg_arena.deinit();

    const source =
        \\pub const Options = struct {
        \\    threshold: u32 = 0,
        \\};
        \\
        \\pub fn check() void {}
    ++ "\x00";
    var tree = try std.zig.Ast.parse(base, source, .zig);
    defer tree.deinit(base);

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(base);

    try check(
        &tree,
        .warn,
        "max_fun_params.zig",
        .{},
        base,
        std.testing.io,
        msg_arena.allocator(),
        &diagnostics,
    );
    try std.testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}

test "paired PascalCase struct name with snake_case filename stem is accepted" {
    const base = std.testing.allocator;
    var msg_arena = std.heap.ArenaAllocator.init(base);
    defer msg_arena.deinit();

    const source =
        \\pub const InitOptions = struct {
        \\    x: u32,
        \\};
    ++ "\x00";
    var tree = try std.zig.Ast.parse(base, source, .zig);
    defer tree.deinit(base);

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(base);

    try check(
        &tree,
        .warn,
        "init_options.zig",
        .{},
        base,
        std.testing.io,
        msg_arena.allocator(),
        &diagnostics,
    );
    try std.testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}

test "snake_case struct file stem is accepted by default" {
    const base = std.testing.allocator;
    var msg_arena = std.heap.ArenaAllocator.init(base);
    defer msg_arena.deinit();

    const source =
        \\pub const InitOptions = struct {
        \\    x: u32,
        \\};
    ++ "\x00";
    var tree = try std.zig.Ast.parse(base, source, .zig);
    defer tree.deinit(base);

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(base);

    try check(
        &tree,
        .warn,
        "init_options.zig",
        .{},
        base,
        std.testing.io,
        msg_arena.allocator(),
        &diagnostics,
    );
    try std.testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}

test "snake_case binding on struct import is flagged" {
    const base = std.testing.allocator;
    var msg_arena = std.heap.ArenaAllocator.init(base);
    defer msg_arena.deinit();

    const source =
        \\const init_options = @import("init_options.zig");
    ++ "\x00";
    var tree = try std.zig.Ast.parse(base, source, .zig);
    defer tree.deinit(base);

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(base);

    try check(
        &tree,
        .warn,
        "tests/fixtures/style/import_site.zig",
        .{ .struct_file_case = .snake_case },
        base,
        std.testing.io,
        msg_arena.allocator(),
        &diagnostics,
    );

    var found_binding = false;
    for (diagnostics.items) |d| {
        if (d.subject) |s| {
            if (s.kind == .structure and std.mem.eql(u8, s.name, "init_options")) found_binding = true;
        }
    }
    try std.testing.expect(found_binding);
}

test "PascalCase binding on snake_case struct import path is clean under Tiger" {
    const base = std.testing.allocator;
    var msg_arena = std.heap.ArenaAllocator.init(base);
    defer msg_arena.deinit();

    const source =
        \\const InitOptions = @import("init_options.zig");
    ++ "\x00";
    var tree = try std.zig.Ast.parse(base, source, .zig);
    defer tree.deinit(base);

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(base);

    try check(
        &tree,
        .warn,
        "tests/fixtures/style/import_site.zig",
        .{ .struct_file_case = .snake_case },
        base,
        std.testing.io,
        msg_arena.allocator(),
        &diagnostics,
    );
    try std.testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}
