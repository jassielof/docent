//! `docs.json` schema v1 — locked, do not redesign without re-opening the
//! planning discussion. Mirrors the TS interfaces in Appendix A exactly.
//!
//! These types are the contract between `json_emit.zig` (the writer) and the
//! Typst template under `typst/docent-docs/` (the reader). `doc`/`doc_summary`
//! fields hold pre-rendered Typst markup, not Markdown — conversion happens
//! in `markdown_typst.zig` at emit time, not at Typst-compile time.

const std = @import("std");

/// Top-level `docs.json` document.
pub const DocsFile = struct {
    schema_version: u32 = 1,
    generator: Generator,
    root: DeclNode,
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
