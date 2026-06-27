fn example() void {
    const mode: std.zig.Ast.Mode = .zig;
    var tree = try std.zig.Ast.parse(gpa, source_code, mode);
    defer tree.deinit(gpa);
    if (tree.errors.len != 0) {
        try printErrors(tree);
        return;
    }

    const rendered = try tree.renderAlloc(gpa);
    defer gpa.free(rendered);

    if (check_mode) {
        return;
    }

    try writeFile(rendered);
}

fn dense() void {
    const x = 1;
    if (x > 0) {
        doSomething();
    }

    const y = 2;
    return;

    unreachable;
}

fn already_spaced() void {
    const a = 1;

    const b = 2;
}

fn double_blanks() void {
    const a = 1;

    const b = 2;
}

fn nested() void {
    if (cond) {
        doA();
    }

    doB();
}
