const std = @import("std");

fn example(gpa: std.mem.Allocator) void {
    const source_code = "test";
    var tree = std.zig.Ast.parse(gpa, source_code, .zig) catch return;
    defer tree.deinit(gpa);
    if (tree.errors.len != 0) {
        std.debug.print("errors", .{});
        return;
    }
    const rendered = tree.renderAlloc(gpa) catch return;
    defer gpa.free(rendered);

    if (rendered.len == 0) {
        return;
    }
    std.debug.print("{s}", .{rendered});
}

fn dense(x: i32) void {
    if (x > 0) {
        doSomething();
    }
    const y = 2;
    _ = y;
    return;
}

fn already_spaced() void {
    const a = 1;

    const b = 2;
    _ = a;
    _ = b;
}

fn double_blanks() void {
    const a = 1;


    const b = 2;
    _ = a;
    _ = b;
}

fn nested(cond: bool) void {
    if (cond) {

        doSomething();

    }
    doB();
}

fn doSomething() void {}
fn doB() void {}
