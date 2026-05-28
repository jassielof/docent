const std = @import("std");


const carnaval = @import("carnaval");
const docent = @import("docent");
const fangz = @import("fangz");

pub const flag_examples: []const fangz.Command.CliExample = &.{
    .{
        .description = "Treat missing public docs as errors",
        .command = "docent --rule missing_doc_comment=deny src",
    },
    .{
        .description = "Override two rules in one invocation",
        .command = "docent --rule missing_doc_comment=deny --rule private_doctest=allow src",
    },
    .{
        .description = "Deny all rules except one",
        .command = "docent --all deny --rule missing_doctest=allow src",
    },
};

pub fn register(root: *fangz.Command) !void {
    const rules_cmd = try root.addSubcommand(.{
        .name = "rules",
        .brief = "List lint rules, defaults, and severity levels",
    });
    rules_cmd.setHooks(.{ .run = &run });
}

fn run(ctx: *fangz.ParseContext) !void {
    try printRulesReference(ctx.io);
}

pub fn printRulesReference(io: std.Io) !void {
    const profile = carnaval.colorProfileForHandle(std.Io.File.stdout().handle);
    var buf: [16384]u8 = undefined;
    var out = std.Io.File.stdout().writer(io, &buf);
    const w = &out.interface;

    try carnaval.Style.init().bolded().renderWithProfile("Docent lint rules\n\n", w, profile);
    try carnaval.Style.init().bolded().renderWithProfile("Rule overrides:\n", w, profile);
    try w.print("  -r, --rule <RULE=LEVEL>...\n\n", .{});
    try w.print("  Override one rule's severity. Repeat the flag to override multiple rules.\n\n", .{});

    try carnaval.Style.init().bolded().renderWithProfile("Examples:\n", w, profile);
    for (flag_examples) |ex| {
        if (ex.description.len > 0) try w.print("  {s}\n", .{ex.description});
        try w.print("    {s}\n", .{ex.command});
    }
    try w.print("\n", .{});

    try carnaval.Style.init().bolded().renderWithProfile("Severity levels:\n", w, profile);
    for (docent.rule_metadata.levels) |row| {
        try w.print("  {s}", .{row.name});
        var pad: usize = 0;
        while (pad < 8 -| row.name.len) : (pad += 1) try w.print(" ", .{});
        try w.print(" {s}\n", .{row.summary});
    }
    try w.print("\n", .{});

    try carnaval.Style.init().bolded().renderWithProfile("Rules:\n", w, profile);
    for (docent.rule_metadata.rules) |row| {
        try w.print("  {s}", .{row.name});
        var k: usize = 0;
        while (k < 32 -| row.name.len) : (k += 1) try w.print(" ", .{});
        try w.print("{s}\n", .{row.default_level});
        try w.print("    {s}\n\n", .{row.summary});
    }

    try carnaval.Style.init().bolded().renderWithProfile("Override order:\n", w, profile);
    var lines = std.mem.splitScalar(u8, docent.rule_metadata.override_behavior_note, '\n');
    while (lines.next()) |line| try w.print("  {s}\n", .{line});

    try w.flush();
}
