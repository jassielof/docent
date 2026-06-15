//! The doc namespace helps extract and analyze doc comments from Zig's AST.
const std = @import("std");
const Ast = std.zig.Ast;

pub const comment = @import("doc/comment.zig");

// TODO: Here should be moved all utilities and helper functions that are related to extract and for analyzing doc comments strictly from the AST, this is to be aligned with the Go standard library convention, which has `go/doc`. This should be consumed as an absolute import in the respective rules like `const doc = @import("root").doc;`. For anything related to parsing the doc comments itself (like parsing the first paragraph, or parsing the summary), those should go in the subnamespace `doc.comment` and also imported as `const comment = @import("root").doc.comment;` or `doc_comment`.
