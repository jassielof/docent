//! `docs.json` schema — the contract between `json_emit.zig` (the writer)
//! and the Typst template under `typst/docent-docs/` (the reader).
//! `doc`/`doc_summary` fields hold pre-rendered Typst markup, not Markdown —
//! conversion happens in `markdown_typst.zig` at emit time, not at
//! Typst-compile time.
//!
//! Package-level (multiple modules per `docs.json`): a Zig package can
//! define several build targets -- typically one public library module plus
//! one or more (often private) executable/test modules -- so `DocsFile`
//! holds a `modules` array rather than a single `root`, one `DeclNode` per
//! discovered target (see `../../cli/commands/typeset.zig`, which reuses
//! `status_plan.gather` for target discovery, the same machinery
//! `docent status`/`docent check` already use).
//!
//! `appendix`: `.path` build.zig.zon dependencies (`--deps`), bundled into
//! the *same* docs.json/PDF rather than linked externally -- see
//! `../../lib/typeset/path_deps.zig`. Since everything shares one `Walk`
//! process, cross-references between `modules` and `appendix` (or between
//! appendix entries) resolve as ordinary internal links, exactly like
//! same-package modules already do.

const std = @import("std");

/// Top-level `docs.json` document.
pub const DocsFile = struct {
    schema_version: u32 = 2,
    generator: Generator,
    /// One entry per documented build target (library/executable/test
    /// module), in discovery order.
    modules: []const DeclNode,
    /// One entry per bundled `.path` dependency (see `--deps`), rendered
    /// after `modules` under an "Appendix" heading. Empty unless `--deps`.
    appendix: []const DeclNode = &.{},
};

pub const Generator = struct {
    zig_version: []const u8,
    tool_version: []const u8,
    generated_at: []const u8,
};

pub const DeclKind = enum {
    container,
    @"fn",
    @"var",
    @"const",
    type_alias,
    error_set,
    field,
};

pub const ContainerKind = enum {
    @"struct",
    @"enum",
    @"union",
    @"opaque",
    module,
};

pub const Visibility = enum {
    public,
    private,
};

pub const SourceLoc = struct {
    file: []const u8,
    line: u32,
    col: u32,
};

pub const ParamNode = struct {
    name: []const u8,
    type: []const u8,
    doc: ?[]const u8,
};

pub const FieldNode = struct {
    name: []const u8,
    type: ?[]const u8,
    value: ?[]const u8,
    doc: ?[]const u8,
};

pub const DeclNode = struct {
    id: []const u8,
    name: []const u8,
    kind: DeclKind,
    container_kind: ?ContainerKind,
    visibility: Visibility,
    source: SourceLoc,

    signature: ?[]const u8,
    return_type: ?[]const u8,
    params: ?[]const ParamNode,

    fields: ?[]const FieldNode,

    doc: ?[]const u8,
    doc_summary: ?[]const u8,

    link_targets: ?[]const []const u8,

    decls: ?[]const DeclNode,
};
