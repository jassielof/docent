const std = @import("std");

fn doSomething() void {}
fn foo() void {}
fn bar() void {}
fn alreadyBraced() void {}

fn process(item: i32) void {
    _ = item;
}

fn example() void {
    const a = 5;
    const b = 10;
    const x = .{ .a = 1 };
    const y = 30;
    const iter: std.ArrayList(i32) = .empty;
    const items = [_]i32{ 1, 2, 3 };

    if (true) return;

    if (a > b) doSomething();

    if (x) foo() else bar();

    while (iter.next()) |item| process(item);

    for (items) |item| process(item);

    if (true) {
        alreadyBraced();
    }

    if (a) {
        x;
    } else if (b) {
        y;
    }

    const conditional_value: usize = if (x > 4)
        "greater"
    else
        "lesser";

    _ = conditional_value;
}
