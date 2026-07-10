//! Thematic-break (`---`) block nodes in Zig doc-comment markup.

const Document = @import("Document.zig");

pub const tag = Document.Node.Tag.thematic_break;
