const std = @import("std");

pub fn example(
    a: i32,
    b: i32,
    c: i32,
    d: i32,
    e: i32,
    f: i32,
    g: i32,
    h: i32,
) i32 {
    return a + b + c + d + e + f + g + h;
}

pub fn short(x: i32) i32 {
    return x;
}
