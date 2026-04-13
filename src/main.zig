const std = @import("std");
const zigrep = @import("zigrep");
const command = zigrep.command;
const runner = zigrep.search_runner;
const cli = zigrep.cli;

pub const CliOptions = command.CliOptions;

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

    const exit_code = cli.runCli(allocator, stdout, stderr, argv) catch |err| {
        try cli.writeFatalError(stderr, argv[0], err);
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

test "runSearch reports matches across files on the parallel path" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "one.txt",
        .data = "needle one\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "two.txt",
        .data = "needle two\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "three.txt",
        .data = "no hit here\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    var stdout_capture: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_capture.deinit();

    const exit_code = try runner.runSearch(testing.allocator, &stdout_capture.writer, &stderr_capture.writer, .{
        .pattern = "needle",
        .paths = &.{root_path},
        .parallel_jobs = 2,
    });

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, stdout_capture.written(), 1, "one.txt:1:1:needle one"));
    try testing.expect(std.mem.containsAtLeast(u8, stdout_capture.written(), 1, "two.txt:1:1:needle two"));
    try testing.expectEqualStrings("", stderr_capture.written());
}

test "runSearch buffered output stays identical to the default path" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "one.txt",
        .data = "needle one\nneedle two\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "two.txt",
        .data = "xx\xffneedleyy\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    var default_stdout: std.Io.Writer.Allocating = .init(testing.allocator);
    defer default_stdout.deinit();
    var default_stderr: std.Io.Writer.Allocating = .init(testing.allocator);
    defer default_stderr.deinit();

    const default_exit = try runner.runSearch(testing.allocator, &default_stdout.writer, &default_stderr.writer, .{
        .pattern = "needle",
        .paths = &.{root_path},
        .parallel_jobs = 1,
    });

    var buffered_stdout: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffered_stdout.deinit();
    var buffered_stderr: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffered_stderr.deinit();

    const buffered_exit = try runner.runSearch(testing.allocator, &buffered_stdout.writer, &buffered_stderr.writer, .{
        .pattern = "needle",
        .paths = &.{root_path},
        .parallel_jobs = 1,
        .buffer_output = true,
    });

    try testing.expectEqual(default_exit, buffered_exit);
    try testing.expectEqualStrings(default_stdout.written(), buffered_stdout.written());
    try testing.expectEqualStrings(default_stderr.written(), buffered_stderr.written());
}

test "runSearch output stays identical across allocator and output modes on mixed input" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "plain.txt",
        .data = "needle one\nskip\nneedle two\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "invalid.bin",
        .data = "xx\xffneedleyy\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "utf16le.txt",
        .data =
            "\xff\xfe" ++
            "n\x00e\x00e\x00d\x00l\x00e\x00 \x00u\x00n\x00o\x00\n\x00" ++
            "s\x00k\x00i\x00p\x00\n\x00" ++
            "n\x00e\x00e\x00d\x00l\x00e\x00 \x00d\x00o\x00s\x00\n\x00",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const modes = [_]CliOptions{
        .{
            .pattern = "needle",
            .paths = &.{root_path},
            .parallel_jobs = 1,
            .read_strategy = .buffered,
        },
        .{
            .pattern = "needle",
            .paths = &.{root_path},
            .parallel_jobs = 1,
            .read_strategy = .mmap,
            .buffer_output = true,
        },
        .{
            .pattern = "needle",
            .paths = &.{root_path},
            .parallel_jobs = 4,
            .read_strategy = .mmap,
        },
        .{
            .pattern = "needle",
            .paths = &.{root_path},
            .parallel_jobs = 4,
            .read_strategy = .mmap,
            .buffer_output = true,
        },
    };

    var expected_stdout: ?[]u8 = null;
    defer if (expected_stdout) |bytes| testing.allocator.free(bytes);
    var expected_stderr: ?[]u8 = null;
    defer if (expected_stderr) |bytes| testing.allocator.free(bytes);
    var expected_exit: ?u8 = null;

    for (modes) |mode| {
        var stdout_capture: std.Io.Writer.Allocating = .init(testing.allocator);
        defer stdout_capture.deinit();
        var stderr_capture: std.Io.Writer.Allocating = .init(testing.allocator);
        defer stderr_capture.deinit();

        const exit_code = try runner.runSearch(
            testing.allocator,
            &stdout_capture.writer,
            &stderr_capture.writer,
            mode,
        );

        if (expected_stdout == null) {
            expected_stdout = try testing.allocator.dupe(u8, stdout_capture.written());
            expected_stderr = try testing.allocator.dupe(u8, stderr_capture.written());
            expected_exit = exit_code;
        } else {
            try testing.expectEqual(expected_exit.?, exit_code);
            try testing.expectEqualStrings(expected_stdout.?, stdout_capture.written());
            try testing.expectEqualStrings(expected_stderr.?, stderr_capture.written());
        }
    }
}
