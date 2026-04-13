const std = @import("std");
const zigrep = @import("zigrep");
const cli_entry = zigrep.cli_entry;

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    // Process-lifetime allocator: owns argv, the collected file list, and other
    // state that lives for the full CLI invocation.
    const allocator = gpa.allocator();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stderr = &stderr_writer.interface;

    const exit_code = cli_entry.runCli(allocator, stdout, stderr, argv) catch |err| {
        try cli_entry.writeFatalError(stderr, argv[0], err);
        try stderr.flush();
        std.process.exit(2);
    };

    try stdout.flush();
    try stderr.flush();
    if (exit_code != 0) std.process.exit(exit_code);
}

test {
    _ = @import("cli_tests.zig");
    _ = @import("cli_integration_tests.zig");
    _ = @import("cli_multiline_tests.zig");
    _ = @import("cli_reporting_tests.zig");
    _ = @import("cli_tail_tests.zig");
    _ = @import("cli_unicode_raw_byte_tests.zig");
    _ = @import("search_runner_tests.zig");
}
