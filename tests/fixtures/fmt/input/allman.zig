const std = @import("std");

fn main() void {
    return;
}

fn example(cond: bool, a: bool, b: bool) void {
    if (cond) {
        std.debug.print("body", .{});
    } else {
        std.debug.print("other", .{});
    }

    if (a) {
        std.debug.print("x", .{});
    } else if (b) {
        std.debug.print("y", .{});
    } else {
        std.debug.print("z", .{});
    }

    const val = doSomething() catch |err| {
        _ = err;
    };
    _ = val;

    const x = .{ .a = 1 };
    _ = x;
    if (cond) {}
}

fn doSomething() !void {}
