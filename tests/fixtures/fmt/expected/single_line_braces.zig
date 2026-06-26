fn example() void {
    if (cond) {
        return;
    }

    if (a > b) {
        doSomething();
    }

    if (x) {
        foo()
    } else {
        bar();
    }

    while (iter.next()) |item| {
        process(item);
    }

    for (items) |item| {
        process(item);
    }

    if (cond) {
        alreadyBraced();
    }

    if (a) {
        x;
    } else if (b) {
        y;
    }

    const x = .{ .a = 1 };
}
