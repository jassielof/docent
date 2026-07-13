fn example(cond: bool) void {
	if (cond) {
		const x = 1;
		_ = x;
		if (!cond) {
			doSomething();
		}
	}
}

fn doSomething() void {}
