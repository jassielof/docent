//! Module doc comment stays at the top.

const std = @import("std");
const assert = std.debug.assert;
const fs = std.fs;
const mem = std.mem;
const Allocator = std.mem.Allocator;
const process = std.process;

const builtin = @import("builtin");

const root = @import("root");
const version = root.version;

const fangz = @import("fangz");
const App = fangz.App;
const Command = fangz.Command;
const Flag = fangz.Flag;
const vereda = @import("vereda");
const WalkEntry = vereda.WalkEntry;
const Walker = vereda.Walker;

const analysis = @import("analysis.zig");
const check_command = @import("commands/check.zig");
const fmt_command = @import("commands/fmt.zig");
const init_command = @import("commands/init.zig");
const status_command = @import("commands/status.zig");
const suppressions = @import("suppressions.zig");
const string_utils = @import("utils/string.zig");
const platform = if (builtin.os.tag == .windows)
    @import("platform/windows.zig")
else
    @import("platform/posix.zig");

pub const Config = @import("Config.zig");
pub const Diagnostic = @import("Diagnostic.zig");
pub const rule_config = @import("rule_config.zig");
pub const scan = @import("scan.zig");
pub const severity = @import("severity.zig");

pub const registerConfigPathFlag = @import("flags.zig").registerConfigPath;

pub const default_fail_fast = @import("types.zig").default_fail_fast;
pub const FailFast = @import("types.zig").FailFast;
pub const OutputMode = @import("types.zig").OutputMode;

pub const registerStatusSubcommand = status_command.register;
pub const Suppressions = suppressions.Table;
