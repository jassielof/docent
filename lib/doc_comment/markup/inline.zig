//! Inline nodes: link, autolink, image, strong, emphasis, code span, text, line break.

const Document = @import("Document.zig");

pub const autolink = Document.Node.Tag.autolink;
pub const code_span = Document.Node.Tag.code_span;
pub const emphasis = Document.Node.Tag.emphasis;
pub const image = Document.Node.Tag.image;
pub const line_break = Document.Node.Tag.line_break;
pub const link = Document.Node.Tag.link;
pub const strong = Document.Node.Tag.strong;
pub const text = Document.Node.Tag.text;
