fn main() void
{
    return;
}

fn example() void
{
    if (cond)
    {
        body;
    }
    else
    {
        other;
    }

    if (a)
    {
        x;
    }
    else if (b)
    {
        y;
    }
    else
    {
        z;
    }

    const val = doSomething() catch |err|
    {
        handleError(err);
    };

    const x = .{ .a = 1 };
    if (cond) {}
}
