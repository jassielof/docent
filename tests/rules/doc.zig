//! Test suite aggregator for documentation rules.
const std = @import("std");
const refAllDecls = std.testing.refAllDecls;

comptime {
    refAllDecls(@import("doc/missing_doc_comment.zig"));
    refAllDecls(@import("doc/missing_doctest.zig"));
    refAllDecls(@import("doc/private_doctest.zig"));
    refAllDecls(@import("doc/doctest_naming_mismatch.zig"));
    refAllDecls(@import("doc/blank_doc_comment.zig"));
    refAllDecls(@import("doc/trailing_blank_doc_comment.zig"));
    refAllDecls(@import("doc/missing_summary_terminal_punctuation.zig"));
    refAllDecls(@import("doc/invalid_leading_phrase.zig"));
    refAllDecls(@import("doc/redundant_doc_comment.zig"));
}
