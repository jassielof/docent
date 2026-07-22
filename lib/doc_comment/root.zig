//! Parsing and analysis of Zig documentation comments (`///` / `//!`).
//!
//! - `extract` — AST helpers: which declaration a doc comment documents
//! - `comment` — text helpers: line bodies, paragraphs, summaries
//! - `markup` — Zig's Markdown subset parser (Document / Parser / components)

const std = @import("std");

pub const comment = @import("comment.zig");
pub const extract = @import("extract.zig");
pub const containerDocBlockIsFullyBlank = extract.containerDocBlockIsFullyBlank;
pub const exposedSourceFileSubjectKind = extract.exposedSourceFileSubjectKind;
pub const fileIsNamespace = extract.fileIsNamespace;
pub const hasContainerDocComment = extract.hasContainerDocComment;
pub const resolveDocCommentSubject = extract.resolveDocCommentSubject;
pub const shouldCheckDocCommentTarget = extract.shouldCheckDocCommentTarget;
// Convenience re-exports of the most-used extract APIs.
pub const Subject = extract.Subject;
pub const SubjectKind = extract.SubjectKind;
pub const markup = @import("markup.zig");

comptime {
    std.testing.refAllDecls(@This());
}
