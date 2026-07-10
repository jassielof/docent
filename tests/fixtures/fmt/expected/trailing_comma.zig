fn foo(
    a: u8,
    b: u8,
    c: u8,
) void {
    _ = a;
    _ = b;
    _ = c;
}

fn bar(x: u8, y: u8) void {
    _ = x;
    _ = y;
}

fn baz(
    one: u8,
    two: u8,
    three: u8,
    four: u8,
) void {
    _ = one;
    _ = two;
    _ = three;
    _ = four;
}

fn quux(
    a: u8,
    b: u8,
    c: u8,
) void {
    _ = a;
    _ = b;
    _ = c;
}

fn example() void {
    const a = 1;
    const b = 2;
    const c = 3;

    foo(
        a,
        b,
        c,
    );

    bar("x", "y");

    baz(
        "one",
        "two",
        "three",
        "four",
    );

    const s = .{
        .a = 1,
        .b = 2,
        .c = 3,
    };
    _ = s;

    const arr = [_]u8{
        1,
        2,
        3,
    };
    _ = arr;

    const nested = foo(
        bar(
            "x",
            "y",
            "z",
        ),
        "d",
        "e",
    );
    _ = nested;

    const two_fields = .{ .x = 1, .y = 2 };
    _ = two_fields;

    const msg = "hello, world, foo";
    _ = msg;

    quux(
        a,
        b,
        c,
    );
}
