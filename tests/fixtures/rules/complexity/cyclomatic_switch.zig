pub fn getWords(number: u32) []const u8 {
    switch (number) {
        1 => return "one",
        2 => return "a couple",
        3 => return "a few",
        else => return "lots",
    }
}
