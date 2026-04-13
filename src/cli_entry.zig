const std = @import("std");
const build_options = @import("build_options");
const cli = @import("cli.zig");
const cli_dispatch = @import("cli_dispatch.zig");
const config = @import("config.zig");

// Top-level CLI entry orchestration.
// This module resolves config, handles help/version, and bridges parsed CLI
// results into the dispatch layer.

pub const app_version = build_options.app_version;

pub fn writeFatalError(writer: *std.Io.Writer, argv0: []const u8, err: anyerror) !void {
    try writer.print("error: {s}\n", .{@errorName(err)});
    if (cli.isUsageError(err)) {
        try cli.writeUsage(writer, argv0);
    }
}

pub fn runCli(
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    argv: []const []const u8,
) !u8 {
    const resolved = try config.resolveArgs(allocator, argv);
    defer resolved.deinit(allocator);

    const parsed = try cli.parseArgs(allocator, resolved.argv);
    defer cli_dispatch.deinitParseResult(parsed, allocator);

    switch (parsed) {
        .help => {
            try cli.writeUsage(stdout, resolved.argv[0]);
            return 0;
        },
        .version => {
            try stdout.print("zigrep {s}\n", .{app_version});
            return 0;
        },
        .type_list, .run => return cli_dispatch.executeParsedCommand(allocator, stdout, stderr, parsed),
    }
}
