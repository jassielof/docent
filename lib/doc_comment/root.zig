//! Parsing and analysis of Zig documentation comments (`///` / `//!`).
//!
//! - `extract` — AST helpers: which declaration a doc comment documents
//! - `comment` — text helpers: line bodies, paragraphs, summaries
//! - `markup` — Zig's Markdown subset parser (Document / Parser / components)

pub const extract = @import("extract.zig");
pub const comment = @import("comment.zig");
pub const markup = @import("markup.zig");
const std = @import("std");
// Convenience re-exports of the most-used extract APIs.
pub const Subject = extract.Subject;
pub const SubjectKind = extract.SubjectKind;
pub const shouldCheckDocCommentTarget = extract.shouldCheckDocCommentTarget;
pub const resolveDocCommentSubject = extract.resolveDocCommentSubject;
pub const fileIsNamespace = extract.fileIsNamespace;
pub const exposedSourceFileSubjectKind = extract.exposedSourceFileSubjectKind;
pub const hasContainerDocComment = extract.hasContainerDocComment;
pub const containerDocBlockIsFullyBlank = extract.containerDocBlockIsFullyBlank;

comptime {
    std.testing.refAllDecls(@This());
}
