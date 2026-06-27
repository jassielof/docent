fn example() void {
    foo(a, b, c,);
    bar(x, y);
    baz(one, two, three, four,);
    const s = .{ .a = 1, .b = 2, .c = 3, };
    const arr = [_]u8{ 1, 2, 3, };
    const nested = foo(bar(a, b, c,), d, e,);
    const two_fields = .{ .x = 1, .y = 2 };
    const msg = "hello, world, foo";
    quux(a, b, c,);
}
