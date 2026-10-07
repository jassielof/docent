//! Build-system integration: a `build.zig` helper that runs the Docent CLI during `zig build`.
//!
//! Zig 0.17 split the build into a configure phase and a separate maker process, so build
//! scripts can no longer register steps that run arbitrary code in-process. The helper
//! therefore wires the CLI executable into a `Run` step instead.

const std = @import("std");

const docent = @import("root.zig");

/// Options for `addLintStep`.
pub const Options = struct {
    /// The Docent CLI to run, for example `docent_dep.artifact("docent")`.
    docent: *std.Build.Step.Compile,
    /// Lint roots; when null, the CLI uses `.paths` from the nearest `build.zig.zon`.
    sources: ?[]const []const u8 = null,
    /// Also lint files under path dependencies from `build.zig.zon`.
    deps: bool = false,
    /// Overrides the `.config/docent.toml` lookup.
    config_path: ?std.Build.LazyPath = null,
    /// Diagnostic output options.
    output: OutputOptions = .{},
};

/// Output formatting options for diagnostics printed during the build step.
pub const OutputOptions = struct {
    /// Text layout for each diagnostic.
    format: docent.output.TextFormat = .pretty,
    /// When the run stops early on a finding.
    fail_fast: FailFast = .none,
};

/// The severities at which the CLI stops after the first finding.
pub const FailFast = enum { none, @"error", warn, any };

/// Registers a Docent lint run on `b` and returns its step for `dependOn` / `enableIf`.
///
/// The step fails the build when a denied rule reports a finding.
pub fn addLintStep(b: *std.Build, options: Options) *std.Build.Step.Run {
    const run = b.addRunArtifact(options.docent);

    run.addArgs(&.{
        "check",
        "all",
        "--format",
        @tagName(options.output.format),
        "--fail-fast",
        @tagName(options.output.fail_fast),
    });

    if (options.deps) {
        run.addArg("--deps");
    }

    if (options.config_path) |config_path| {
        run.addPrefixedFileArg("--config-path", config_path);
    }

    for (options.sources orelse &.{}) |source| {
        run.addArg(source);
    }

    return run;
}
