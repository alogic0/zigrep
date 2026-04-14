const std = @import("std");
const zigrep = @import("zigrep");
const cli = zigrep.cli;
const config = zigrep.config;
const sort_capability = zigrep.internal.sort_capability;

// Top-level CLI entry orchestration.
// This module resolves config, handles help/version, and bridges parsed CLI
// results into the dispatch layer.

pub const app_version = zigrep.app_version;
const stdin_max_bytes = std.math.maxInt(usize);

pub fn writeFatalError(writer: *std.Io.Writer, argv0: []const u8, err: anyerror) !void {
    if (err == error.CreationTimeUnavailable) {
        try writer.print("{s}\n", .{sort_capability.createdSortUnavailableMessage()});
        return;
    }

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
    const stdin_file = std.fs.File.stdin();
    const stdin_bytes = if (stdin_file.isTty()) null else try stdin_file.readToEndAlloc(allocator, stdin_max_bytes);
    defer if (stdin_bytes) |bytes| allocator.free(bytes);

    return runCliWithInput(allocator, stdout, stderr, argv, stdin_bytes);
}

pub fn runCliWithInput(
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    argv: []const []const u8,
    stdin_bytes: ?[]const u8,
) !u8 {
    const resolved = try config.resolveArgs(allocator, argv);
    defer resolved.deinit(allocator);

    const parsed = try cli.parseArgs(allocator, resolved.argv);
    defer cli.deinitParseResult(parsed, allocator);

    switch (parsed) {
        .help => {
            try cli.writeUsage(stdout, resolved.argv[0]);
            return 0;
        },
        .version => {
            try stdout.print("zigrep {s}\n", .{app_version});
            return 0;
        },
        .type_list, .run => return cli.executeParsedCommand(allocator, stdout, stderr, parsed, stdin_bytes),
    }
}
