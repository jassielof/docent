const std = @import("std");
const refAllDecls = std.testing.refAllDecls;

comptime {
    refAllDecls(@import("docs/missing_doc_comment.zig"));
    refAllDecls(@import("docs/missing_doctest.zig"));
    refAllDecls(@import("docs/blank_doc_comment.zig"));
    refAllDecls(@import("docs/missing_container_doc_comment.zig"));
}
