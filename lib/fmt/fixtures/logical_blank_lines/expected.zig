const std = @import("std");
const mem = std.mem;

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

fn only_return() void {
    return;
}

fn blank_before_return(x: i32) i32 {
    const doubled = x * 2;

    return doubled;
}

fn glued_defer(gpa: std.mem.Allocator) !void {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);

    try list.append(gpa, 1);
}

fn defer_group(gpa: std.mem.Allocator) !void {
    var a: std.ArrayList(u8) = .empty;
    defer a.deinit(gpa);

    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(gpa);
    errdefer b.deinit(gpa);

    try a.append(gpa, 1);
    _ = mem;
}

fn doSomething() void {}
fn doB() void {}
