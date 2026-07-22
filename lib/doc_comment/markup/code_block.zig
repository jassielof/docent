//! Fenced code-block nodes in Zig doc-comment markup.

const Document = @import("Document.zig");
pub const tag = Document.Node.Tag.code_block;
