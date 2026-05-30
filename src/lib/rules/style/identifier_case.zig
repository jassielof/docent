//! The `identifier_case` namespace checks that identifiers follow the project's naming conventions.
//!
//! By default the conventions mirror the {zig-docs}#Names[Zig documentation style]:
//!
//! * `snake_case` — namespaces (field-less containers), global variables and constants, struct/union
//!   fields, and enumerators.
//! * `camelCase` — concrete functions.
//! * `PascalCase` — structs, unions, enumerations, error sets, generic (type-returning) functions, and
//!   error-set values.
//!
//! Notes:
//!
//! * Error-set values are checked as `PascalCase`, following the standard-library convention
//!   (`error.OutOfMemory`), even though they technically belong to the "value" category.
//! * Declarations whose initializer is an alias/re-export (a plain identifier, field access, call, or
//!   `@import(...)`) are skipped: their real kind lives elsewhere, so checking the local binding would
//!   produce false positives (for instance a `camelCase` constant that just re-exports a function).
//! * For `@import("path.zig")`, when the resolved file is a *namespace* (no structure fields at file
//!   scope — the usual `fn`/`const` module layout), the `.zig` basename must be `snake_case` (e.g.
//!   `reachability.zig`, not `Reachability.zig`). Struct files that declare fields on the file type
//!   itself (e.g. `LintResult.zig`) keep `PascalCase` basenames.
//! * Quoted identifiers (`@"foo bar"`) are exempt from case checks.

const std = @import("std");
const Ast = std.zig.Ast;

const Diagnostic = @import("../../Diagnostic.zig");
const Severity = @import("../../severity.zig");
const utils = @import("../utils.zig");

const rule_name = "identifier_case";

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
    severity: Severity.Level,
    file: []const u8,
    public_api_only: bool,
    allocator: std.mem.Allocator,
    io: std.Io,
    msg_allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) std.mem.Allocator.Error!void {
    if (!severity.isActive()) return;

    var namespace_cache = std.StringHashMap(bool).init(allocator);
    defer {
        var it = namespace_cache.keyIterator();
        while (it.next()) |key| allocator.free(key.*);
        namespace_cache.deinit();
    }

    for (tree.rootDecls()) |decl| {
        try checkNode(tree, decl, severity, file, public_api_only, .field, allocator, io, &namespace_cache, msg_allocator, diagnostics);
    }
}

fn checkNode(
    tree: *const Ast,
    node: Ast.Node.Index,
    severity: Severity.Level,
    file: []const u8,
    public_api_only: bool,
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
                    try checkName(tree, name_tok, expected, .function, severity, file, allocator, msg_allocator, diagnostics);
                }
            }
        }
        return;
    }

    if (tree.fullVarDecl(node)) |var_decl| {
        if (var_decl.ast.init_node.unwrap()) |init_node| {
            try checkImportFilenameExpr(tree, init_node, severity, file, allocator, io, namespace_cache, msg_allocator, diagnostics);
        }
        if (utils.isPubVisibility(tree, var_decl.visib_token) or !public_api_only) {
            const name_tok = var_decl.ast.mut_token + 1;
            if (classifyVarDecl(tree, var_decl)) |c| {
                try checkName(tree, name_tok, c.case, c.kind, severity, file, allocator, msg_allocator, diagnostics);
            }
            if (var_decl.ast.init_node.unwrap()) |init_node| {
                if (tree.nodeTag(init_node) == .error_set_decl) {
                    try checkErrorSetValues(tree, init_node, severity, file, allocator, msg_allocator, diagnostics);
                }
            }
        }
        try checkVarDeclInit(tree, var_decl, severity, file, public_api_only, allocator, io, namespace_cache, msg_allocator, diagnostics);
        return;
    }

    if (utils.isContainerDecl(tag)) {
        var buf: [2]Ast.Node.Index = undefined;
        if (tree.fullContainerDecl(&buf, node)) |container| {
            const child_kind: Diagnostic.SubjectKind = if (utils.isEnumContainer(tree, node)) .enumerator else member_field_kind;
            for (container.ast.members) |member| {
                try checkNode(tree, member, severity, file, public_api_only, child_kind, allocator, io, namespace_cache, msg_allocator, diagnostics);
            }
        }
        return;
    }

    if (tree.fullContainerField(node)) |field| {
        try checkName(tree, field.ast.main_token, .snake, member_field_kind, severity, file, allocator, msg_allocator, diagnostics);
        return;
    }
}

/// Recurses into a `var`/`const` whose initializer is a container so its members are checked too.
fn checkVarDeclInit(
    tree: *const Ast,
    var_decl: Ast.full.VarDecl,
    severity: Severity.Level,
    file: []const u8,
    public_api_only: bool,
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
            try checkNode(tree, member, severity, file, public_api_only, child_kind, allocator, io, namespace_cache, msg_allocator, diagnostics);
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

fn checkImportFilenameExpr(
    tree: *const Ast,
    node: Ast.Node.Index,
    severity: Severity.Level,
    file: []const u8,
    allocator: std.mem.Allocator,
    io: std.Io,
    namespace_cache: *std.StringHashMap(bool),
    msg_allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) std.mem.Allocator.Error!void {
    const lit = getImportLiteral(tree, node) orelse return;
    try checkImportFilename(tree, lit, severity, file, allocator, io, namespace_cache, msg_allocator, diagnostics);
}

fn checkImportFilename(
    tree: *const Ast,
    lit: ImportLiteral,
    severity: Severity.Level,
    file: []const u8,
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
    if (isSnakeCase(stem)) return;

    const is_namespace = try resolveImportedFileIsNamespace(lit.path, file, allocator, io, namespace_cache);
    if (!is_namespace) return;

    const loc = tree.tokenLocation(0, lit.str_tok);
    const snake_stem = try toSnakeFilenameStem(msg_allocator, stem);
    defer msg_allocator.free(snake_stem);
    const expected = try std.fmt.allocPrint(msg_allocator, "{s}.zig", .{snake_stem});

    try diagnostics.append(allocator, .{
        .rule = rule_name,
        .severity = severity,
        .subject = try utils.ownedSubject(msg_allocator, .source_file, basename),
        .detail = try std.fmt.allocPrint(msg_allocator, "namespace file should use snake_case filename; expected \"{s}\"", .{expected}),
        .file = file,
        .line = loc.line + 1,
        .column = loc.column + 1,
        .source_line = try utils.dupSourceLine(tree, lit.str_tok, msg_allocator),
        .symbol_len = lit.path.len,
    });
}

/// Lowercases ASCII letters in `stem` for a suggested `snake_case` filename stem.
fn toSnakeFilenameStem(allocator: std.mem.Allocator, stem: []const u8) std.mem.Allocator.Error![]u8 {
    const out = try allocator.alloc(u8, stem.len);
    for (stem, 0..) |c, i| {
        out[i] = if (c >= 'A' and c <= 'Z') c + 32 else c;
    }
    return out;
}

/// Returns whether a resolved `.zig` file is a namespace (no structure fields at file scope).
fn resolveImportedFileIsNamespace(
    import_path: []const u8,
    current_file: []const u8,
    allocator: std.mem.Allocator,
    io: std.Io,
    cache: *std.StringHashMap(bool),
) std.mem.Allocator.Error!bool {
    const base_dir = std.fs.path.dirname(current_file) orelse ".";
    const joined = try std.fs.path.join(allocator, &.{ base_dir, import_path });
    defer allocator.free(joined);

    const abs = utils.normalizePathSeparators(allocator, joined) catch return false;
    defer allocator.free(abs);

    if (cache.get(abs)) |cached| return cached;

    const is_namespace = blk: {
        const source = std.Io.Dir.cwd().readFileAllocOptions(
            io,
            abs,
            allocator,
            .limited(std.math.maxInt(u32)),
            .of(u8),
            0,
        ) catch break :blk false;
        defer allocator.free(source);

        var imported = std.zig.Ast.parse(allocator, source, .zig) catch break :blk false;
        defer imported.deinit(allocator);

        break :blk fileIsNamespace(&imported);
    };

    const cache_key = try allocator.dupe(u8, abs);
    try cache.put(cache_key, is_namespace);
    return is_namespace;
}

/// True when the file has no structure fields at file scope (only `fn`, `const`, nested types, etc.).
fn fileIsNamespace(tree: *const Ast) bool {
    for (tree.rootDecls()) |decl| {
        if (tree.fullContainerField(decl) != null) return false;
    }
    return true;
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
    severity: Severity.Level,
    file: []const u8,
    allocator: std.mem.Allocator,
    msg_allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) std.mem.Allocator.Error!void {
    const first = tree.firstToken(node);
    const last = tree.lastToken(node);
    var tok = first;
    while (tok <= last) : (tok += 1) {
        if (tree.tokenTag(tok) == .identifier) {
            try checkName(tree, tok, .pascal, .error_value, severity, file, allocator, msg_allocator, diagnostics);
        }
    }
}

fn checkName(
    tree: *const Ast,
    name_tok: Ast.TokenIndex,
    expected: Case,
    kind: Diagnostic.SubjectKind,
    severity: Severity.Level,
    file: []const u8,
    allocator: std.mem.Allocator,
    msg_allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) std.mem.Allocator.Error!void {
    const name = tree.tokenSlice(name_tok);
    if (isExemptName(name)) return;
    if (expected.matches(name)) return;

    const loc = tree.tokenLocation(0, name_tok);
    try diagnostics.append(allocator, .{
        .rule = rule_name,
        .severity = severity,
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

fn runCheck(source: [:0]const u8, public_api_only: bool) !TestResult {
    const base = std.testing.allocator;
    var msg_arena = std.heap.ArenaAllocator.init(base);
    errdefer msg_arena.deinit();

    var tree = try std.zig.Ast.parse(base, source, .zig);
    defer tree.deinit(base);

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    errdefer diagnostics.deinit(base);

    try check(&tree, .warn, "<test>", public_api_only, base, std.testing.io, msg_arena.allocator(), &diagnostics);
    return .{ .msg_arena = msg_arena, .items = diagnostics };
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
    var r = try runCheck("pub fn DoThing() void {}", false);
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 1), r.count());
    try std.testing.expectEqual(.function, r.items.items[0].subject.?.kind);
    try std.testing.expectEqualStrings("DoThing", r.items.items[0].subject.?.name);
}

test "well-cased concrete function is clean" {
    var r = try runCheck("pub fn doThing() void {}", false);
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 0), r.count());
}

test "type-returning function should be PascalCase" {
    var r = try runCheck("pub fn list() type { return struct {}; }", false);
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 1), r.count());
    try std.testing.expectEqualStrings("list", r.items.items[0].subject.?.name);
}

test "well-cased generic function is clean" {
    var r = try runCheck("pub fn List() type { return struct {}; }", false);
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 0), r.count());
}

test "global constant should be snake_case" {
    var r = try runCheck("pub const MaxSize = 10;", false);
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 1), r.count());
    try std.testing.expectEqual(.constant, r.items.items[0].subject.?.kind);
}

test "struct with fields should be PascalCase" {
    var r = try runCheck(
        \\pub const my_struct = struct {
        \\    x: u32,
        \\};
    , false);
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
    , false);
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
    , false);
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 1), r.count());
    try std.testing.expectEqual(.field, r.items.items[0].subject.?.kind);
    try std.testing.expectEqualStrings("X", r.items.items[0].subject.?.name);
}

test "enum should be PascalCase and enumerators snake_case" {
    var r = try runCheck(
        \\pub const color = enum {
        \\    Red,
        \\    green,
        \\};
    , false);
    defer r.deinit();
    // `color` (should be PascalCase) and `Red` (should be snake_case).
    try std.testing.expectEqual(@as(usize, 2), r.count());
    try std.testing.expectEqual(.enumeration, r.items.items[0].subject.?.kind);
    try std.testing.expectEqual(.enumerator, r.items.items[1].subject.?.kind);
    try std.testing.expectEqualStrings("Red", r.items.items[1].subject.?.name);
}

test "error set should be PascalCase and error values too" {
    var r = try runCheck("pub const my_error = error{ out_of_memory };", false);
    defer r.deinit();
    // `my_error` (should be PascalCase) and `out_of_memory` (should be PascalCase).
    try std.testing.expectEqual(@as(usize, 2), r.count());
    try std.testing.expectEqual(.error_set, r.items.items[0].subject.?.kind);
    try std.testing.expectEqual(.error_value, r.items.items[1].subject.?.kind);
    try std.testing.expectEqualStrings("out_of_memory", r.items.items[1].subject.?.name);
}

test "inline type-expression alias should be PascalCase" {
    var r = try runCheck("pub const kind_phrase = []const []const u8;", false);
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 1), r.count());
    try std.testing.expectEqual(.type_alias, r.items.items[0].subject.?.kind);
    try std.testing.expectEqualStrings("should be PascalCase", r.items.items[0].detail.?);
}

test "well-cased inline type alias is clean" {
    var r = try runCheck("pub const KindPhrase = []const u8;", false);
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 0), r.count());
}

test "idiomatic error set is clean" {
    var r = try runCheck("pub const Error = error{ OutOfMemory, FileNotFound };", false);
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
        false,
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

test "PascalCase basename on struct-at-file-scope import is not flagged" {
    const base = std.testing.allocator;
    var msg_arena = std.heap.ArenaAllocator.init(base);
    defer msg_arena.deinit();

    const source =
        \\const opts = @import("StructFile.zig");
    ++ "\x00";
    var tree = try std.zig.Ast.parse(base, source, .zig);
    defer tree.deinit(base);

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(base);

    try check(
        &tree,
        .warn,
        "tests/fixtures/style/import_site.zig",
        false,
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
    , false);
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 0), r.count());
}

test "quoted identifiers are exempt" {
    var r = try runCheck("pub const @\"foo bar\" = 1;", false);
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 0), r.count());
}

test "private declarations skipped under public_api_only" {
    var r = try runCheck("fn DoThing() void {}", true);
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 0), r.count());
}

test "private declarations checked when public_api_only is false" {
    var r = try runCheck("fn DoThing() void {}", false);
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 1), r.count());
}

test "detail explains expected case" {
    var r = try runCheck("pub fn DoThing() void {}", false);
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
    try check(&tree, .allow, "<test>", false, base, std.testing.io, base, &diagnostics);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}
