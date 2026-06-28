//! Module doc comment stays at the top.

const std = @import("std");
const builtin = @import("builtin");
const vereda = @import("vereda");
const Walker = vereda.Walker;
const WalkEntry = vereda.WalkEntry;
const fangz = @import("fangz");
const App = fangz.App;
const Flag = fangz.Flag;
const Command = fangz.Command;
const Allocator = std.mem.Allocator;
const fs = std.fs;
const mem = std.mem;
const process = std.process;
const assert = std.debug.assert;
const root = @import("root");
const version = root.version;
const suppressions = @import("suppressions.zig");
const check_command = @import("commands/check.zig");
const fmt_command = @import("commands/fmt.zig");
const init_command = @import("commands/init.zig");
const status_command = @import("commands/status.zig");
const analysis = @import("analysis.zig");
const string_utils = @import("utils/string.zig");

const platform = if (builtin.os.tag == .windows)
    @import("platform/windows.zig")
else
    @import("platform/posix.zig");

pub const Diagnostic = @import("Diagnostic.zig");
pub const Config = @import("Config.zig");
pub const severity = @import("severity.zig");
pub const scan = @import("scan.zig");
pub const rule_config = @import("rule_config.zig");

pub const OutputMode = @import("types.zig").OutputMode;
pub const default_fail_fast = @import("types.zig").default_fail_fast;
pub const FailFast = @import("types.zig").FailFast;

pub const registerConfigPathFlag = @import("flags.zig").registerConfigPath;

pub const Suppressions = suppressions.Table;
pub const registerStatusSubcommand = status_command.register;
