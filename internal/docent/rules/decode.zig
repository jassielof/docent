//! Generic, reflection-driven TOML decoder for lint-rule config structs.
//!
//! A rule's config struct *is* its resolved shape: every field has a real default, so decoding
//! means "start from `.{}` and overwrite only the keys the TOML actually sets". One `decodeInto`
//! walks any struct by field name and dispatches on the field's type, which retires the per-rule
//! `Config`/`Options`/`resolve`/`decodeConfig` boilerplate.
//!
//! Two field-name conventions keep the config surface ergonomic:
//!
//! - A field named `level` maps to the TOML `level` key and honours the forbid lock (a `forbid` value is never weakened). A bare string (`identifier_case = "deny"`) is shorthand for `{ level = "deny" }`.
//! - A field named `options` is *flattened*: its sub-fields are read from the parent table, so granular knobs stay direct keys under the rule's table even though they live in an `options` sub-struct in Zig.
//!
//! Enums decode from their tag name unless they expose `pub fn fromConfigString`, which is then preferred and absorbs odd spellings such as `public`/`all` or `@"kebab-case"`.

const std = @import("std");
const toml = @import("toml");

const severity = @import("../severity.zig");
const scan = @import("../scan.zig");

/// Decode errors surfaced to config loaders and `formatError`.
pub const Error = error{
    ConfigParseFailed,
    InvalidSeverity,
    InvalidScanMode,
    OutOfMemory,
};

/// Overlays `value` (a TOML table, or a bare severity string for a rule) onto the defaulted `out`, writing only the keys present in the TOML.
pub fn decodeInto(
    comptime T: type,
    value: toml.DynamicValue,
    out: *T,
) Error!void {
    if (comptime @hasField(T, "level")) {
        if (value.stringSlice()) |text| {
            setLevel(
                T,
                out,
                try parseSeverity(text),
            );
            return;
        }
    }

    const table = switch (value) {
        .table => |t| t,
        else => return,
    };

    inline for (std.meta.fields(T)) |field| {
        if (comptime std.mem.eql(
            u8,
            field.name,
            "level",
        )) {
            if (table.get("level")) |level_value| {
                const text = level_value.stringSlice() orelse return error.InvalidSeverity;
                setLevel(
                    T,
                    out,
                    try parseSeverity(text),
                );
            }
        } else if (comptime std.mem.eql(
            u8,
            field.name,
            "options",
        )) {
            try decodeInto(
                field.type,
                value,
                &@field(out, field.name),
            );
        } else if (table.get(field.name)) |field_value| {
            try decodeField(
                field.type,
                field_value,
                &@field(out, field.name),
            );
        }
    }
}

/// Writes `new` to `out.level`, preserving a `forbid` already in place since `forbid` cannot be relaxed.
fn setLevel(
    comptime T: type,
    out: *T,
    new: severity.Level,
) void {
    if (out.level == .forbid and new != .forbid) return;
    out.level = new;
}

fn parseSeverity(text: []const u8) Error!severity.Level {
    return std.meta.stringToEnum(severity.Level, text) orelse error.InvalidSeverity;
}

fn decodeField(
    comptime F: type,
    value: toml.DynamicValue,
    out: *F,
) Error!void {
    switch (@typeInfo(F)) {
        .optional => |opt| {
            var child: opt.child = undefined;
            try decodeField(
                opt.child,
                value,
                &child,
            );
            out.* = child;
        },
        .@"struct" => {
            if (comptime @hasDecl(F, "fromConfigString")) {
                const text = value.stringSlice() orelse return error.ConfigParseFailed;
                out.* = F.fromConfigString(text) orelse return error.InvalidScanMode;
            } else {
                try decodeInto(
                    F,
                    value,
                    out,
                );
            }
        },
        .@"enum" => out.* = try decodeEnum(F, value),
        .bool => out.* = switch (value) {
            .boolean => |b| b,
            else => return error.ConfigParseFailed,
        },
        .int => out.* = switch (value) {
            .integer => |i| std.math.cast(F, i) orelse return error.ConfigParseFailed,
            else => return error.ConfigParseFailed,
        },
        else => @compileError("decode: unsupported config field type " ++ @typeName(F)),
    }
}

fn decodeEnum(comptime E: type, value: toml.DynamicValue) Error!E {
    const text = value.stringSlice() orelse return enumError(E);
    const parsed = if (@hasDecl(E, "fromConfigString"))
        E.fromConfigString(text)
    else
        std.meta.stringToEnum(E, text);
    return parsed orelse enumError(E);
}

fn enumError(comptime E: type) Error {
    if (E == severity.Level) return error.InvalidSeverity;
    return error.ConfigParseFailed;
}
