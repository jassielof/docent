const std = @import("std");

const Target = struct {
    id: u32,
    active: bool,
    weight: ?i32,
};

pub fn processData(matrix: [][]const ?Target, threshold: i32, max_cycles: u32) !u32 {
    if (matrix.len == 0) {
        return error.EmptyMatrix;
    }

    var score: u32 = 0;
    var cycle: u32 = 0;

    while (cycle < max_cycles) : (cycle += 1) {
        for (matrix) |row| {
            for (row) |maybe_target| {
                // 1. Optional unwrapping payload check
                if (maybe_target) |target| {

                    // 2. Complex short-circuiting condition
                    if (target.active and target.id % 2 == 0 or cycle > 5) {

                        // 3. Nested optional unwrapping
                        if (target.weight) |w| {
                            if (w > threshold) {
                                score += 10;
                            } else {
                                score += 2;
                            }
                        } else {
                            score += 1;
                        }
                    } else {
                        continue;
                    }
                } else {
                    // 4. Early return error path
                    return error.NullElementFound;
                }
            }
        }
    }

    return score;
}
