pub fn k() void {
    foo() catch {
        bar();
    };
}
fn foo() !void {}
fn bar() void {}
