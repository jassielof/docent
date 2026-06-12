//! Letter grades for weighted score percentages (Go Report Card style).

const std = @import("std");

pub const Grade = enum {
    a_plus,
    a,
    a_minus,
    b_plus,
    b,
    b_minus,
    c_plus,
    c,
    c_minus,
    d_plus,
    d,
    d_minus,
    f,

    pub fn label(self: Grade) []const u8 {
        return switch (self) {
            .a_plus => "A+",
            .a => "A",
            .a_minus => "A-",
            .b_plus => "B+",
            .b => "B",
            .b_minus => "B-",
            .c_plus => "C+",
            .c => "C",
            .c_minus => "C-",
            .d_plus => "D+",
            .d => "D",
            .d_minus => "D-",
            .f => "F",
        };
    }
};

/// Maps a percentage in `[0, 100]` to a letter grade.
pub fn fromPercentage(percentage: f64) Grade {
    if (percentage >= 97.0) return .a_plus;
    if (percentage >= 93.0) return .a;
    if (percentage >= 90.0) return .a_minus;
    if (percentage >= 87.0) return .b_plus;
    if (percentage >= 83.0) return .b;
    if (percentage >= 80.0) return .b_minus;
    if (percentage >= 77.0) return .c_plus;
    if (percentage >= 73.0) return .c;
    if (percentage >= 70.0) return .c_minus;
    if (percentage >= 67.0) return .d_plus;
    if (percentage >= 63.0) return .d;
    if (percentage >= 60.0) return .d_minus;
    return .f;
}

test "grade thresholds" {
    try std.testing.expectEqual(Grade.a_plus, fromPercentage(99.0));
    try std.testing.expectEqual(Grade.f, fromPercentage(59.9));
}
