const std = @import("std");
const refAllDecls = std.testing.refAllDecls;

comptime {
    refAllDecls(@import("docs/missing_doc_comment.zig"));
    refAllDecls(@import("docs/missing_doctest.zig"));
    refAllDecls(@import("docs/blank_doc_comment.zig"));
    refAllDecls(@import("docs/trailing_blank_doc_comment.zig"));
    refAllDecls(@import("docs/missing_summary_terminal_punctuation.zig"));
    refAllDecls(@import("docs/invalid_leading_phrase.zig"));
}
