//! Builds Fangz `KeyValueHelp` for `--rule` from `docent.rule_metadata`.
const fangz = @import("fangz");
const rm = @import("docent").rule_metadata;

fn keyMeta(comptime i: usize) fangz.Command.KeyValueKeyMeta {
    const row = rm.rules[i];
    return .{
        .name = row.name,
        .default_value = row.default_level,
        .summary = row.summary,
        .long_description = row.long,
    };
}

fn valueMeta(comptime i: usize) fangz.Command.KeyValueValueMeta {
    const row = rm.levels[i];
    return .{ .name = row.name, .summary = row.summary };
}

const keys_storage: [rm.rules.len]fangz.Command.KeyValueKeyMeta = blk: {
    var a: [rm.rules.len]fangz.Command.KeyValueKeyMeta = undefined;
    for (0..rm.rules.len) |i| {
        a[i] = keyMeta(i);
    }
    break :blk a;
};

const values_storage: [rm.levels.len]fangz.Command.KeyValueValueMeta = blk: {
    var a: [rm.levels.len]fangz.Command.KeyValueValueMeta = undefined;
    for (0..rm.levels.len) |i| {
        a[i] = valueMeta(i);
    }
    break :blk a;
};

pub const keys: []const fangz.Command.KeyValueKeyMeta = &keys_storage;

pub const values: []const fangz.Command.KeyValueValueMeta = &values_storage;

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

pub const app_examples: []const fangz.Command.CliExample = &.{
    .{ .description = "", .command = "docent src" },
    .{ .description = "", .command = "docent --rule missing_doc_comment=deny src" },
    .{ .description = "", .command = "docent --all deny --rule missing_doctest=allow src" },
    .{ .description = "", .command = "docent docs --output-dir docs" },
    .{ .description = "", .command = "docent completion nu" },
};

pub const key_value_help: fangz.Command.KeyValueHelp = .{
    .keys = keys,
    .values = values,
    .override_behavior_note = rm.override_behavior_note,
    .examples = flag_examples,
};
