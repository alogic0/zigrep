const std = @import("std");
const zigrep = @import("zigrep");
const command = zigrep.command;
const runner = zigrep.search_runner;
const cli = zigrep.cli;
const cli_test_support = @import("cli_test_support.zig");

const CliError = cli.CliError;

pub const OutputOptions = command.OutputOptions;
pub const CliOptions = command.CliOptions;
const SearchStats = runner.SearchStats;
const SearchResult = runner.SearchResult;


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

test "runCli prints every matching line from one file" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "many.txt",
        .data =
            "needle one\n" ++
            "skip\n" ++
            "needle two\n" ++
            "needle needle\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "many.txt:1:1:needle one"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "many.txt:3:1:needle two"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "many.txt:4:1:needle needle"));
}




test "runCli only-matching mode prints each match occurrence" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "many.txt",
        .data = "needle one needle two\nneedle\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "--only-matching", "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "many.txt:1:1:needle\n"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "many.txt:1:12:needle\n"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "many.txt:2:1:needle\n"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli only-matching mode honors lazy quantifiers" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "sample.txt",
        .data = "axxbxxb\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "--only-matching", "a.+?b", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "sample.txt:1:1:axxb\n"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli only-matching mode respects max-count by matching line" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "many.txt",
        .data = "needle one needle two\nneedle three\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "--only-matching", "--max-count", "1", "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "many.txt:1:1:needle\n"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "many.txt:1:12:needle\n"));
    try testing.expect(!std.mem.containsAtLeast(u8, run.stdout, 1, "many.txt:2:1:needle\n"));
    try testing.expectEqualStrings("", run.stderr);
}


test "runCli honors max depth in recursive search" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("nested/deeper");
    try tmp.dir.writeFile(.{
        .sub_path = "root.txt",
        .data = "needle root\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "nested/child.txt",
        .data = "needle child\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "nested/deeper/grandchild.txt",
        .data = "needle grandchild\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const shallow = try cli_test_support.runCliCaptured(testing.allocator, &.{
        "zigrep",
        "--max-depth",
        "1",
        "needle",
        root_path,
    });
    defer shallow.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), shallow.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, shallow.stdout, 1, "root.txt:1:1:needle root"));
    try testing.expect(std.mem.containsAtLeast(u8, shallow.stdout, 1, "child.txt:1:1:needle child"));
    try testing.expect(!std.mem.containsAtLeast(u8, shallow.stdout, 1, "grandchild.txt"));
}

test "runCli can search binary files when text mode is enabled" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "payload.bin",
        .data = "aa\x00needle\x00bb",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const skipped = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "needle", root_path });
    defer skipped.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 1), skipped.exit_code);

    const searched = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "--text", "needle", root_path });
    defer searched.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), searched.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, searched.stdout, 1, "payload.bin:1:4:aa"));
}

test "runCli binary mode reports binary matches without line content" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "payload.bin",
        .data = "aa\x00needle\x00bb",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "--binary", "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "payload.bin: binary file matches\n"));
    try testing.expect(!std.mem.containsAtLeast(u8, run.stdout, 1, "\\x00bb"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli binary mode supports files-with-matches" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "payload.bin",
        .data = "aa\x00needle\x00bb",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "--binary", "--files-with-matches", "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "payload.bin\n"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli raw-byte encoding mode searches binary payloads without text mode" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "payload.bin",
        .data = "aa\x00needle\x00bb",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "-E", "none", "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "payload.bin:1:4:aa"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli compressed search mode finds matches in gzip files" {
    const testing = std.testing;

    const gzip_hello = [_]u8{
        0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x03,
        0xf3, 0x48, 0xcd, 0xc9, 0xc9, 0x57, 0x28, 0xcf,
        0x2f, 0xca, 0x49, 0xe1, 0x02, 0x00,
        0xd5, 0xe0, 0x39, 0xb7, 0x0c, 0x00, 0x00, 0x00,
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "sample.txt.gz",
        .data = &gzip_hello,
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const default_run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "Hello", root_path });
    defer default_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 1), default_run.exit_code);
    try testing.expectEqualStrings("", default_run.stdout);

    const zip_run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "-z", "Hello", root_path });
    defer zip_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), zip_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, zip_run.stdout, 1, "sample.txt.gz:1:1:Hello world"));
}

test "runCli preprocessor takes precedence over compressed search" {
    const testing = std.testing;

    const gzip_hello = [_]u8{
        0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x03,
        0xf3, 0x48, 0xcd, 0xc9, 0xc9, 0x57, 0x28, 0xcf,
        0x2f, 0xca, 0x49, 0xe1, 0x02, 0x00,
        0xd5, 0xe0, 0x39, 0xb7, 0x0c, 0x00, 0x00, 0x00,
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "sample.txt.gz",
        .data = &gzip_hello,
    });
    try tmp.dir.writeFile(.{
        .sub_path = "pre.sh",
        .data =
            "#!/bin/sh\n" ++
            "printf 'needle from pre\\n'\n",
    });

    var script = try tmp.dir.openFile("pre.sh", .{ .mode = .read_write });
    defer script.close();
    try script.chmod(0o755);

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);
    const script_path = try std.fs.path.join(testing.allocator, &.{ root_path, "pre.sh" });
    defer testing.allocator.free(script_path);
    const pre_command = try std.fmt.allocPrint(testing.allocator, "/bin/sh {s}", .{script_path});
    defer testing.allocator.free(pre_command);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{
        "zigrep",
        "-j",
        "1",
        "-z",
        "--pre",
        pre_command,
        "--pre-glob",
        "*.gz",
        "needle",
        root_path,
    });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "sample.txt.gz:1:1:needle from pre"));
    try testing.expect(!std.mem.containsAtLeast(u8, run.stdout, 1, "Hello world"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli compressed search warns and skips invalid compressed input" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "bad.txt.gz",
        .data = "\x1f\x8bbad",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "-z", "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 1), run.exit_code);
    try testing.expectEqualStrings("", run.stdout);
    try testing.expect(std.mem.containsAtLeast(u8, run.stderr, 1, "warning: skipping "));
    try testing.expect(std.mem.containsAtLeast(u8, run.stderr, 1, "invalid compressed input\n"));
}

test "runCli preprocessor transforms matching files selected by pre-glob" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "sample.wrapped",
        .data = "original payload\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "plain.txt",
        .data = "plain text\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "pre.sh",
        .data =
            "#!/bin/sh\n" ++
            "case \"$1\" in\n" ++
            "  *.wrapped) printf '\\156\\145\\145\\144\\154\\145 from pre\\n' ;;\n" ++
            "  *) cat \"$1\" ;;\n" ++
            "esac\n",
    });

    var script = try tmp.dir.openFile("pre.sh", .{ .mode = .read_write });
    defer script.close();
    try script.chmod(0o755);

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);
    const script_path = try std.fs.path.join(testing.allocator, &.{ root_path, "pre.sh" });
    defer testing.allocator.free(script_path);

    const default_run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "needle", root_path });
    defer default_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 1), default_run.exit_code);

    const pre_command = try std.fmt.allocPrint(testing.allocator, "/bin/sh {s}", .{script_path});
    defer testing.allocator.free(pre_command);

    const pre_run = try cli_test_support.runCliCaptured(testing.allocator, &.{
        "zigrep",
        "-j",
        "1",
        "--pre",
        pre_command,
        "--pre-glob",
        "*.wrapped",
        "needle",
        root_path,
    });
    defer pre_run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), pre_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, pre_run.stdout, 1, "sample.wrapped:1:1:needle from pre"));
    try testing.expect(!std.mem.containsAtLeast(u8, pre_run.stdout, 1, "plain.txt"));
}

test "runCli preprocessor failure warns and skips the file" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "sample.txt",
        .data = "needle one\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "fail.sh",
        .data = "#!/bin/sh\nexit 3\n",
    });

    var script = try tmp.dir.openFile("fail.sh", .{ .mode = .read_write });
    defer script.close();
    try script.chmod(0o755);

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);
    const script_path = try std.fs.path.join(testing.allocator, &.{ root_path, "fail.sh" });
    defer testing.allocator.free(script_path);
    const pre_command = try std.fmt.allocPrint(testing.allocator, "/bin/sh {s}", .{script_path});
    defer testing.allocator.free(pre_command);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{
        "zigrep",
        "-j",
        "1",
        "--pre",
        pre_command,
        "needle",
        root_path,
    });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 1), run.exit_code);
    try testing.expectEqualStrings("", run.stdout);
    try testing.expect(std.mem.containsAtLeast(u8, run.stderr, 1, "preprocessor exited with non-zero status\n"));
}

test "runCli skips invalid UTF-8 files instead of aborting the whole search" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "good.txt",
        .data = "needle here\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "bad.bin",
        .data = "xx\xffneedleyy",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "good.txt:1:1:needle here"));
    try testing.expect(!std.mem.containsAtLeast(u8, run.stderr, 1, "InvalidUtf8"));
}

test "runCli text mode searches invalid UTF-8 files through the raw-byte matcher" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "bad.bin",
        .data = "xx\xffneedleyy",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "--text", "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "bad.bin:1:4:xx\\xFFneedleyy"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli text mode lets dot match an invalid byte through the raw-byte matcher" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "dot.bin",
        .data = "a\xffb\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "--text", "a.b", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "dot.bin:1:1:a\\xFFb"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli text mode matches UTF-8 literals through the byte path on invalid UTF-8 files" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "utf8.bin",
        .data = "xx\xffжарyy\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "--text", "жар", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "utf8.bin:1:4:xx\\xFFжарyy"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli default mode uses the raw-byte path for planner-covered invalid UTF-8 files" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "textish.bin",
        .data = "xx\xffneedleyy",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "textish.bin:1:4:xx\\xFFneedleyy"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli default mode uses the raw-byte path for empty capture groups on invalid UTF-8 files" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "textish.bin",
        .data = "xx\xffabyy",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "a()b", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "textish.bin:1:4:xx\\xFFabyy"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli default mode uses the raw-byte path for grouped concatenation inside a larger sequence" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "textish.bin",
        .data = "zzxa\xff7byy",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "x(a.[0-9]b)y", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "textish.bin:1:3:zzxa\\xFF7byy"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli default mode uses the raw-byte path for quantified bare anchors on invalid UTF-8 files" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "textish.bin",
        .data = "\xffabc",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "^+", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "textish.bin:1:1:\\xFFabc"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli default mode uses the general raw-byte VM when no planner path exists" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "textish.bin",
        .data = "aby\xff",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "(^ab)y", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "textish.bin:1:1:aby\\xFF"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli supports mixed shorthand compatibility semantics" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "sample.txt",
        .data =
            "a5b\n" ++
            "a١b\n" ++
            "a²b\n" ++
            "Жβ\n" ++
            "a\xCD\x85\n" ++
            "word_123\n" ++
            " \t\n" ++
            "foo\xC2\xA0bar\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "space.txt",
        .data = " \t\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const digit_run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "a\\db", root_path });
    defer digit_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), digit_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, digit_run.stdout, 1, "sample.txt:1:1:a5b"));
    try testing.expect(std.mem.containsAtLeast(u8, digit_run.stdout, 1, "sample.txt:2:1:a١b"));
    try testing.expect(!std.mem.containsAtLeast(u8, digit_run.stdout, 1, "a²b"));

    const word_run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "\\w+", root_path });
    defer word_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), word_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, word_run.stdout, 1, "sample.txt:1:1:a5b"));
    try testing.expect(std.mem.containsAtLeast(u8, word_run.stdout, 1, "sample.txt:4:1:Жβ"));
    try testing.expect(std.mem.containsAtLeast(u8, word_run.stdout, 1, "sample.txt:5:1:a\xCD\x85"));
    try testing.expect(std.mem.containsAtLeast(u8, word_run.stdout, 1, "sample.txt:6:1:word_123"));

    const space_run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "-U", "\\s+", root_path });
    defer space_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), space_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, space_run.stdout, 1, "sample.txt:1:4:a5b"));
    try testing.expect(std.mem.containsAtLeast(u8, space_run.stdout, 1, "foo\xC2\xA0bar"));
    try testing.expect(std.mem.containsAtLeast(u8, space_run.stdout, 1, "space.txt:1:1: \t"));
}

test "runCli shorthand negation matches invalid UTF-8 bytes on the raw-byte path" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "raw.bin",
        .data = "a\xffb\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "a\\Db", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "raw.bin:1:1:a\\xFFb"));
}

test "runCli uses Unicode word shorthand semantics" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "sample.txt",
        .data =
            "Жβ\n" ++
            "a\xCD\x85\n" ++
            "_\n" ++
            "-\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "raw.bin",
        .data = "\xff\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const word_run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "\\w+", root_path });
    defer word_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), word_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, word_run.stdout, 1, "sample.txt:1:1:Жβ"));
    try testing.expect(std.mem.containsAtLeast(u8, word_run.stdout, 1, "sample.txt:2:1:a\xCD\x85"));
    try testing.expect(std.mem.containsAtLeast(u8, word_run.stdout, 1, "sample.txt:3:1:_"));
    try testing.expect(!std.mem.containsAtLeast(u8, word_run.stdout, 1, "sample.txt:4:1:-"));
    try testing.expect(!std.mem.containsAtLeast(u8, word_run.stdout, 1, "raw.bin"));

    const not_word_run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "\\W+", root_path });
    defer not_word_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), not_word_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, not_word_run.stdout, 1, "sample.txt:4:1:-"));
    try testing.expect(std.mem.containsAtLeast(u8, not_word_run.stdout, 1, "raw.bin:1:1:\\xFF"));
}

test "runCli supports word boundaries on UTF-8 and raw-byte inputs" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "sample.txt",
        .data =
            "a cat!\n" ++
            "scatter\n" ++
            "Жβ\n" ++
            "β\xCD\x85\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "raw.bin",
        .data = "\xffcat\xff\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const word_run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "\\bcat\\b", root_path });
    defer word_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), word_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, word_run.stdout, 1, "sample.txt:1:3:a cat!"));
    try testing.expect(std.mem.containsAtLeast(u8, word_run.stdout, 1, "raw.bin:1:2:\\xFFcat\\xFF"));
    try testing.expect(!std.mem.containsAtLeast(u8, word_run.stdout, 1, "scatter"));

    const not_word_run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "\\Bcat\\B", root_path });
    defer not_word_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), not_word_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, not_word_run.stdout, 1, "sample.txt:2:2:scatter"));

    const unicode_word_run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "\\bЖβ\\b", root_path });
    defer unicode_word_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), unicode_word_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, unicode_word_run.stdout, 1, "sample.txt:3:1:Жβ"));

    const combining_word_run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "\\bβ\xCD\x85\\b", root_path });
    defer combining_word_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), combining_word_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, combining_word_run.stdout, 1, "sample.txt:4:1:β\xCD\x85"));
}

test "runCli supports inline Unicode mode toggles" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "sample.txt",
        .data =
            "A\n" ++
            "Ж\n" ++
            "AЖA\n" ++
            "AЖЖ\n" ++
            "foo bar\n" ++
            "foo\xC2\xA0bar\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const ascii_word_run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "(?-u:\\w+)", root_path });
    defer ascii_word_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), ascii_word_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, ascii_word_run.stdout, 1, "sample.txt:1:1:A"));
    try testing.expect(std.mem.containsAtLeast(u8, ascii_word_run.stdout, 1, "sample.txt:3:1:AЖA"));
    try testing.expect(std.mem.containsAtLeast(u8, ascii_word_run.stdout, 1, "sample.txt:4:1:AЖЖ"));
    try testing.expect(!std.mem.containsAtLeast(u8, ascii_word_run.stdout, 1, "sample.txt:2:1:Ж"));

    const ascii_space_run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "foo(?-u:\\s)bar", root_path });
    defer ascii_space_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), ascii_space_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, ascii_space_run.stdout, 1, "sample.txt:5:1:foo bar"));
    try testing.expect(!std.mem.containsAtLeast(u8, ascii_space_run.stdout, 1, "sample.txt:6:1:foo"));

    const nested_run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "(?-u:\\w(?u:\\w)\\w)", root_path });
    defer nested_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), nested_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, nested_run.stdout, 1, "sample.txt:3:1:AЖA"));
    try testing.expect(!std.mem.containsAtLeast(u8, nested_run.stdout, 1, "sample.txt:4:1:AЖЖ"));

    try testing.expectError(error.UnsupportedGroup, cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "(?-u:\\p{Greek})", root_path }));
}

test "runCli supports half-word boundaries" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "sample.txt",
        .data =
            "cat\n" ++
            "!cat\n" ++
            "cat!\n" ++
            "βcat\n" ++
            "catβ\n" ++
            "(-2)\n" ++
            "!A!\n" ++
            "!Ж!\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const half_run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "\\b{start-half}cat\\b{end-half}", root_path });
    defer half_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), half_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, half_run.stdout, 1, "sample.txt:1:1:cat"));
    try testing.expect(std.mem.containsAtLeast(u8, half_run.stdout, 1, "sample.txt:2:2:!cat"));
    try testing.expect(std.mem.containsAtLeast(u8, half_run.stdout, 1, "sample.txt:3:1:cat!"));
    try testing.expect(!std.mem.containsAtLeast(u8, half_run.stdout, 1, "sample.txt:4:1:βcat"));
    try testing.expect(!std.mem.containsAtLeast(u8, half_run.stdout, 1, "sample.txt:5:1:catβ"));

    const minus_run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "\\b{start-half}-2\\b{end-half}", root_path });
    defer minus_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), minus_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, minus_run.stdout, 1, "sample.txt:6:2:(-2)"));

    const ascii_half_run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "(?-u:\\b{start-half}A\\b{end-half})", root_path });
    defer ascii_half_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), ascii_half_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, ascii_half_run.stdout, 1, "sample.txt:7:2:!A!"));
    try testing.expect(!std.mem.containsAtLeast(u8, ascii_half_run.stdout, 1, "sample.txt:8:2:!Ж!"));
}

test "runCli supports basic class-set operators" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "sample.txt",
        .data =
            "A\n" ++
            "Ж\n" ++
            "Ω\n" ++
            "ω\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const subtraction_run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "[\\w--\\p{ASCII}]+", root_path });
    defer subtraction_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), subtraction_run.exit_code);
    try testing.expect(!std.mem.containsAtLeast(u8, subtraction_run.stdout, 1, "sample.txt:1:1:A"));
    try testing.expect(std.mem.containsAtLeast(u8, subtraction_run.stdout, 1, "sample.txt:2:1:Ж"));
    try testing.expect(std.mem.containsAtLeast(u8, subtraction_run.stdout, 1, "sample.txt:3:1:Ω"));
    try testing.expect(std.mem.containsAtLeast(u8, subtraction_run.stdout, 1, "sample.txt:4:1:ω"));

    const intersection_run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "[\\p{Greek}&&\\p{Uppercase}]+", root_path });
    defer intersection_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), intersection_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, intersection_run.stdout, 1, "sample.txt:3:1:Ω"));
    try testing.expect(!std.mem.containsAtLeast(u8, intersection_run.stdout, 1, "sample.txt:4:1:ω"));
}

test "runCli supports nested class-set expressions" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "sample.txt",
        .data =
            "A\n" ++
            "_\n" ++
            "Ж\n" ++
            "Ω\n" ++
            "ω\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "[\\w--[\\p{ASCII}&&[^_]]]+", root_path });
    defer run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(!std.mem.containsAtLeast(u8, run.stdout, 1, "sample.txt:1:1:A"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "sample.txt:2:1:_"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "sample.txt:3:1:Ж"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "sample.txt:4:1:Ω"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "sample.txt:5:1:ω"));
}

test "runCli supports inline case-fold groups" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "sample.txt",
        .data =
            "A\n" ++
            "a\n" ++
            "aA\n" ++
            "Aa\n" ++
            "Ω\n" ++
            "ω\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const local_on_run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "(?i:a)", root_path });
    defer local_on_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), local_on_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, local_on_run.stdout, 1, "sample.txt:1:1:A"));
    try testing.expect(std.mem.containsAtLeast(u8, local_on_run.stdout, 1, "sample.txt:2:1:a"));

    const local_off_run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "(?i:a)(?-i:A)", root_path });
    defer local_off_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), local_off_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, local_off_run.stdout, 1, "sample.txt:3:1:aA"));
    try testing.expect(!std.mem.containsAtLeast(u8, local_off_run.stdout, 1, "sample.txt:4:1:Aa"));

    const unicode_local_run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "(?i:ω)", root_path });
    defer unicode_local_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), unicode_local_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, unicode_local_run.stdout, 1, "sample.txt:5:1:Ω"));
    try testing.expect(std.mem.containsAtLeast(u8, unicode_local_run.stdout, 1, "sample.txt:6:1:ω"));

    const override_global_run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "--ignore-case", "(?-i:A)", root_path });
    defer override_global_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), override_global_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, override_global_run.stdout, 1, "sample.txt:1:1:A"));
    try testing.expect(!std.mem.containsAtLeast(u8, override_global_run.stdout, 1, "sample.txt:2:1:a"));
}

test "runCli supports inline multiline and dotall groups" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "sample.txt",
        .data =
            "a\n" ++
            "b\n" ++
            "a\n" ++
            "b\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const multiline_anchor = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "(?m:^b$)", root_path });
    defer multiline_anchor.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), multiline_anchor.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, multiline_anchor.stdout, 1, "sample.txt:2:1:b"));
    try testing.expect(std.mem.containsAtLeast(u8, multiline_anchor.stdout, 1, "sample.txt:4:1:b"));

    const absolute_anchor = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "(?-m:^b$)", root_path });
    defer absolute_anchor.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 1), absolute_anchor.exit_code);

    try testing.expectError(error.MultilineRequired, cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "(?s:a.b)", root_path }));

    const scoped_dotall = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "-U", "(?s:a.b)", root_path });
    defer scoped_dotall.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), scoped_dotall.exit_code);

    const scoped_no_dotall = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "-U", "--multiline-dotall", "(?-s:a.b)", root_path });
    defer scoped_no_dotall.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 1), scoped_no_dotall.exit_code);
}

test "runCli supports unscoped inline flag toggles" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "sample.txt",
        .data =
            "A\n" ++
            "a\n" ++
            "aA\n" ++
            "AA\n" ++
            "Aa\n" ++
            "Ж\n" ++
            "a\n" ++
            "b\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const local_case = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "(?i)a(?-i)A", root_path });
    defer local_case.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), local_case.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, local_case.stdout, 1, "sample.txt:3:1:aA"));
    try testing.expect(std.mem.containsAtLeast(u8, local_case.stdout, 1, "sample.txt:4:1:AA"));
    try testing.expect(!std.mem.containsAtLeast(u8, local_case.stdout, 1, "sample.txt:5:1:Aa"));

    const ascii_word = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "(?-u)\\w+", root_path });
    defer ascii_word.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), ascii_word.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, ascii_word.stdout, 1, "sample.txt:1:1:A"));
    try testing.expect(!std.mem.containsAtLeast(u8, ascii_word.stdout, 1, "sample.txt:6:1:Ж"));

    const multiline_anchor = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "(?m)^b$", root_path });
    defer multiline_anchor.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), multiline_anchor.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, multiline_anchor.stdout, 1, "sample.txt:8:1:b"));

    try testing.expectError(error.MultilineRequired, cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "(?s)a.b", root_path }));

    const local_dotall = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "-U", "(?s)a.b", root_path });
    defer local_dotall.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), local_dotall.exit_code);
}

test "runCli supports grouped inline flag bundles" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "sample.txt",
        .data =
            "x\n" ++
            "A\n" ++
            "A\n" ++
            "b\n" ++
            "Ж\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const multiline_case = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "(?im:^a$)", root_path });
    defer multiline_case.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), multiline_case.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, multiline_case.stdout, 1, "sample.txt:2:1:A"));

    const no_multiline = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "(?i-m:^a$)", root_path });
    defer no_multiline.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 1), no_multiline.exit_code);

    const dotall = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "-U", "(?is:a.b)", root_path });
    defer dotall.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), dotall.exit_code);

    const ascii_word = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "(?i-u:\\w+)", root_path });
    defer ascii_word.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), ascii_word.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, ascii_word.stdout, 1, "sample.txt:2:1:A"));
    try testing.expect(!std.mem.containsAtLeast(u8, ascii_word.stdout, 1, "sample.txt:5:1:Ж"));
}

test "runCli supports non-capturing groups" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "sample.txt",
        .data =
            "ababx\n" ++
            "abx\n" ++
            "ax\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "(?:ab)+x", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "sample.txt:1:1:ababx"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "sample.txt:2:1:abx"));
    try testing.expect(!std.mem.containsAtLeast(u8, run.stdout, 1, "sample.txt:3:1:ax"));
}

test "runCli supports named capture groups" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "sample.txt",
        .data =
            "abcc\n" ++
            "zz\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "(?P<head>ab)(c+)", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "sample.txt:1:1:abcc"));
    try testing.expect(!std.mem.containsAtLeast(u8, run.stdout, 1, "sample.txt:2:1:zz"));
}

test "runCli supports Unicode literal escapes" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "sample.txt",
        .data =
            "жар\n" ++
            "日本\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const cyrillic_run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "\\u{0436}ар", root_path });
    defer cyrillic_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), cyrillic_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, cyrillic_run.stdout, 1, "sample.txt:1:1:жар"));

    const kanji_run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "\\u{65E5}\\u{672C}", root_path });
    defer kanji_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), kanji_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, kanji_run.stdout, 1, "sample.txt:2:1:日本"));
}

test "runCli supports Unicode property escapes on UTF-8 and raw-byte inputs" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "sample.txt",
        .data =
            "ж7\n" ++
            "7ж\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "raw.bin",
        .data = "\xffж7\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const utf8_run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "\\p{Letter}+\\p{Number}+", root_path });
    defer utf8_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), utf8_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, utf8_run.stdout, 1, "sample.txt:1:1:ж7"));

    const raw_run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "\\P{Letter}+", root_path });
    defer raw_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), raw_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, raw_run.stdout, 1, "raw.bin:1:1:"));
}

test "runCli supports the Alphabetic Unicode property" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "sample.txt",
        .data = "\xCD\x85\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "\\p{Alphabetic}+", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "sample.txt:1:1:"));
}

test "runCli supports Cased and Case_Ignorable Unicode properties" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "sample.txt",
        .data =
            "Σ\n" ++
            "\xCD\x85\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const cased_run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "\\p{Cased}+", root_path });
    defer cased_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), cased_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, cased_run.stdout, 1, "sample.txt:1:1:Σ"));

    const case_ignorable_run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "\\p{Case_Ignorable}+", root_path });
    defer case_ignorable_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), case_ignorable_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, case_ignorable_run.stdout, 1, "sample.txt:2:1:"));
}

test "runCli supports Any and ASCII Unicode properties" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "sample.txt",
        .data =
            "ж\n" ++
            "Az09\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "raw.bin",
        .data = "\xffA\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const any_run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "\\p{Any}+", root_path });
    defer any_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), any_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, any_run.stdout, 1, "sample.txt:1:1:ж"));

    const ascii_run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "\\p{ASCII}+", root_path });
    defer ascii_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), ascii_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, ascii_run.stdout, 1, "sample.txt:2:1:Az09"));

    const not_any_run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "\\P{Any}+", root_path });
    defer not_any_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), not_any_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, not_any_run.stdout, 1, "raw.bin:1:1:"));
}

test "runCli supports initial Script Unicode properties" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "sample.txt",
        .data =
            "A\n" ++
            "Ω\n" ++
            "\xCD\xB5\n" ++
            "Ж\n" ++
            "א\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const greek_run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "\\p{Greek}+", root_path });
    defer greek_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), greek_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, greek_run.stdout, 1, "sample.txt:2:1:Ω"));

    const greek_scx_run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "\\p{scx=Greek}+", root_path });
    defer greek_scx_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), greek_scx_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, greek_scx_run.stdout, 1, "sample.txt:2:1:Ω"));
    try testing.expect(std.mem.containsAtLeast(u8, greek_scx_run.stdout, 1, "sample.txt:3:1:͵"));

    const greek_scx_long_run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "\\p{Script_Extensions=Greek}+", root_path });
    defer greek_scx_long_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), greek_scx_long_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, greek_scx_long_run.stdout, 1, "sample.txt:3:1:͵"));

    const latin_run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "\\p{Script=Latin}+", root_path });
    defer latin_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), latin_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, latin_run.stdout, 1, "sample.txt:1:1:A"));

    const cyrillic_run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "\\p{sc=Cyrl}+", root_path });
    defer cyrillic_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), cyrillic_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, cyrillic_run.stdout, 1, "sample.txt:4:1:Ж"));

    const hebrew_run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "\\p{Hebrew}+", root_path });
    defer hebrew_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), hebrew_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, hebrew_run.stdout, 1, "sample.txt:5:1:א"));
}

test "runCli supports identifier-style derived Unicode properties" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "sample.txt",
        .data =
            "A\n" ++
            "0\n" ++
            "\xC2\xAD\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const id_start_run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "\\p{ID_Start}+", root_path });
    defer id_start_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), id_start_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, id_start_run.stdout, 1, "sample.txt:1:1:A"));

    const id_continue_run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "\\p{ID_Continue}+", root_path });
    defer id_continue_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), id_continue_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, id_continue_run.stdout, 1, "sample.txt:2:1:0"));

    const xid_start_run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "\\p{XID_Start}+", root_path });
    defer xid_start_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), xid_start_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, xid_start_run.stdout, 1, "sample.txt:1:1:A"));

    const xid_continue_run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "\\p{XID_Continue}+", root_path });
    defer xid_continue_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), xid_continue_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, xid_continue_run.stdout, 1, "sample.txt:2:1:0"));

    const default_ignorable_run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "\\p{Default_Ignorable_Code_Point}+", root_path });
    defer default_ignorable_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), default_ignorable_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, default_ignorable_run.stdout, 1, "sample.txt:3:1:"));
}

test "runCli supports Lowercase and Uppercase Unicode properties" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "sample.txt",
        .data =
            "ß\n" ++
            "Σ\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const lower_run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "\\p{Lowercase}+", root_path });
    defer lower_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), lower_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, lower_run.stdout, 1, "sample.txt:1:1:ß"));

    const upper_run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "\\p{Uppercase}+", root_path });
    defer upper_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), upper_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, upper_run.stdout, 1, "sample.txt:2:1:Σ"));
}

test "runCli supports Mark, Punctuation, Separator, and Symbol Unicode properties" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "sample.txt",
        .data =
            "\xCD\x85\n" ++
            "!\n" ++
            " \n" ++
            "+\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const mark_run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "\\p{Mark}+", root_path });
    defer mark_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), mark_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, mark_run.stdout, 1, "sample.txt:1:1:"));

    const punctuation_run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "\\p{Punctuation}+", root_path });
    defer punctuation_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), punctuation_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, punctuation_run.stdout, 1, "sample.txt:2:1:!"));

    const separator_run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "\\p{Separator}+", root_path });
    defer separator_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), separator_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, separator_run.stdout, 1, "sample.txt:3:1: "));

    const symbol_run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "\\p{Symbol}+", root_path });
    defer symbol_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), symbol_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, symbol_run.stdout, 1, "sample.txt:4:1:+"));

    const not_punctuation_run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "\\P{Punctuation}+", root_path });
    defer not_punctuation_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), not_punctuation_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, not_punctuation_run.stdout, 1, "sample.txt:1:1:"));
}

test "runCli supports Unicode general-category subgroup properties" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "sample.txt",
        .data =
            "ǅ\n" ++
            "Ⅰ\n" ++
            "_\n" ++
            "\xEE\x80\x80\n" ++
            "\xCD\xB8\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const titlecase_run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "\\p{Lt}+", root_path });
    defer titlecase_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), titlecase_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, titlecase_run.stdout, 1, "sample.txt:1:1:ǅ"));

    const letter_number_run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "\\p{Nl}+", root_path });
    defer letter_number_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), letter_number_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, letter_number_run.stdout, 1, "sample.txt:2:1:Ⅰ"));

    const connector_run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "\\p{Pc}+", root_path });
    defer connector_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), connector_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, connector_run.stdout, 1, "sample.txt:3:1:_"));

    const other_run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "\\p{Other}+", root_path });
    defer other_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), other_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, other_run.stdout, 1, "sample.txt:4:1:"));

    const unassigned_run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "\\p{Cn}+", root_path });
    defer unassigned_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), unassigned_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, unassigned_run.stdout, 1, "sample.txt:5:1:"));
}

test "runCli supports Unicode property items inside character classes" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "sample.txt",
        .data =
            "ж7\n" ++
            "ΩΣ\n" ++
            " \n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "[\\p{Letter}\\P{Whitespace}]+", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "sample.txt:1:1:ж7"));

    const script_run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "[\\p{Greek}\\p{Uppercase}]+", root_path });
    defer script_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), script_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, script_run.stdout, 1, "sample.txt:2:1:ΩΣ"));
}

test "runCli rejects unsupported Unicode properties" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "sample.txt",
        .data = "needle\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    try testing.expectError(error.UnsupportedProperty, cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "\\p{NotARealProperty}", root_path }));
}

test "runCli supports Emoji Unicode properties" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "sample.txt",
        .data =
            "😀\n" ++
            "A\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "\\p{Emoji}+", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "sample.txt:1:1:😀"));
}

test "runCli uses Unicode digit and whitespace shorthand semantics" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "sample.txt",
        .data =
            "a١b\n" ++
            "a²b\n" ++
            "foo\xC2\xA0bar\n" ++
            "foo\nbar\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const digit_run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "a\\db", root_path });
    defer digit_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), digit_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, digit_run.stdout, 1, "sample.txt:1:1:a١b"));
    try testing.expect(!std.mem.containsAtLeast(u8, digit_run.stdout, 1, "sample.txt:2:1:a²b"));

    const whitespace_run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "foo\\sbar", root_path });
    defer whitespace_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), whitespace_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, whitespace_run.stdout, 1, "sample.txt:3:1:foo\xC2\xA0bar"));
    try testing.expect(!std.mem.containsAtLeast(u8, whitespace_run.stdout, 1, "sample.txt:4:1:foo"));
}

test "runCli rejects invalid Unicode escapes" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "sample.txt",
        .data = "needle\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    try testing.expectError(error.InvalidUnicodeEscape, cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "\\u{}", root_path }));
    try testing.expectError(error.InvalidUnicodeEscape, cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "\\u{110000}", root_path }));
}

test "runCli default mode matches literal-only UTF-8 classes through the byte path" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "utf8-class.bin",
        .data = "xx\xffжyy\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "[ж]", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "utf8-class.bin:1:4:xx\\xFFжyy"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli default mode matches small UTF-8 range classes through the byte path" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "utf8-range.bin",
        .data = "xx\xffжyy\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "[а-я]", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "utf8-range.bin:1:4:xx\\xFFжyy"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli default mode matches negated literal-only UTF-8 classes through the byte path" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "utf8-negated.bin",
        .data = "\xffaяb\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "a[^ж]b", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "utf8-negated.bin:1:2:\\xFFaяb"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli default mode matches negated small UTF-8 ranges through the byte path" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "utf8-negated-range.bin",
        .data = "\xffaѣb\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "a[^а-я]b", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "utf8-negated-range.bin:1:2:\\xFFaѣb"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli default mode matches larger UTF-8 ranges through the byte path" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "utf8-large-range.bin",
        .data = "xx\xffжyy\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "[Ā-ӿ]", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "utf8-large-range.bin:1:4:xx\\xFFжyy"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli default mode matches negated larger UTF-8 ranges through the byte path" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "utf8-large-negated.bin",
        .data = "\xffa字b\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "a[^Ā-ӿ]b", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "utf8-large-negated.bin:1:2:\\xFFa字b"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli default mode matches quantified larger UTF-8 ranges through the byte path" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "utf8-large-quant.bin",
        .data = "x\xffжѣz\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "[Ā-ӿ]+", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "utf8-large-quant.bin:1:3:x\\xFFжѣz"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli default mode matches bare start anchors through the byte path" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "anchor-start.bin",
        .data = "\xffabc\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "^", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "anchor-start.bin:1:1:\\xFFabc"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli default mode matches bare end anchors through the byte path" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "anchor-end.bin",
        .data = "abc\xff",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "$", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "anchor-end.bin:1:5:abc\\xFF"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli default mode matches grouped alternation with anchored branches through the byte path" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "anchored-alt.bin",
        .data = "\xffcde\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "(^ab|cd)e", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "anchored-alt.bin:1:2:\\xFFcde"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli default mode matches anchored grouped repetition through the byte path" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "anchored-group.bin",
        .data = "abc",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "(^ab)+c", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "anchored-group.bin:1:1:abc"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli skips control-heavy binary payloads by default but searches them with text mode" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const payload = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 'n', 'e', 'e', 'd', 'l', 'e', '\n' };
    try tmp.dir.writeFile(.{
        .sub_path = "control-heavy.bin",
        .data = &payload,
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const default_run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "needle", root_path });
    defer default_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 1), default_run.exit_code);
    try testing.expectEqualStrings("", default_run.stdout);

    const text_run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "--text", "needle", root_path });
    defer text_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), text_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, text_run.stdout, 1, "control-heavy.bin:1:9:\\x01\\x02\\x03\\x04\\x05\\x06\\x07\\x08needle"));
}

test "runCli can search UTF-16LE BOM files in default mode" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "utf16le.txt",
        .data = "\xff\xfen\x00e\x00e\x00d\x00l\x00e\x00\n\x00",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "utf16le.txt:1:1:needle"));
}

test "runCli can search UTF-16BE BOM files in default mode" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "utf16be.txt",
        .data = "\xfe\xff\x00n\x00e\x00e\x00d\x00l\x00e\x00\x0a",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "utf16be.txt:1:1:needle"));
}

test "runCli can force UTF-16LE decoding without a BOM" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "utf16le-no-bom.txt",
        .data = "n\x00e\x00e\x00d\x00l\x00e\x00\n\x00",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const default_run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "needle", root_path });
    defer default_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 1), default_run.exit_code);

    const forced_run = try cli_test_support.runCliCaptured(testing.allocator, &.{
        "zigrep",
        "--encoding",
        "utf16le",
        "needle",
        root_path,
    });
    defer forced_run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), forced_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, forced_run.stdout, 1, "utf16le-no-bom.txt:1:1:needle"));
}

test "runCli can force UTF-16BE decoding without a BOM" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "utf16be-no-bom.txt",
        .data = "\x00n\x00e\x00e\x00d\x00l\x00e\x00\x0a",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const forced_run = try cli_test_support.runCliCaptured(testing.allocator, &.{
        "zigrep",
        "-E",
        "utf16be",
        "needle",
        root_path,
    });
    defer forced_run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), forced_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, forced_run.stdout, 1, "utf16be-no-bom.txt:1:1:needle"));
}

test "runCli can force latin1 decoding" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "latin1.txt",
        .data = "caf\xe9 needle\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const default_run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "café", root_path });
    defer default_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 1), default_run.exit_code);

    const forced_run = try cli_test_support.runCliCaptured(testing.allocator, &.{
        "zigrep",
        "-E",
        "latin1",
        "café",
        root_path,
    });
    defer forced_run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), forced_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, forced_run.stdout, 1, "latin1.txt:1:1:café needle"));
}

test "reportFileMatch only owns line bytes for transformed haystacks" {
    const testing = std.testing;

    var searcher = try zigrep.search.grep.Searcher.init(testing.allocator, "needle", .{});
    defer searcher.deinit();

    const normal = (try runner.reportFileMatch(testing.allocator, &searcher, "normal.txt", "xxneedleyy", .auto)).?;
    defer normal.deinit(testing.allocator);
    try testing.expect(normal.owned_line == null);

    const decoded = (try runner.reportFileMatch(testing.allocator, &searcher, "utf16.txt", "\xff\xfen\x00e\x00e\x00d\x00l\x00e\x00", .auto)).?;
    defer decoded.deinit(testing.allocator);
    try testing.expect(decoded.owned_line != null);
    try testing.expectEqualStrings("needle", decoded.line);

    const invalid = (try runner.reportFileMatch(testing.allocator, &searcher, "invalid.bin", "xx\xffneedleyy", .auto)).?;
    defer invalid.deinit(testing.allocator);
    try testing.expect(invalid.owned_line == null);
    try testing.expectEqualStrings("xx\xffneedleyy", invalid.line);
}

test "writeFileReports does not require owned line bytes for decoded multi-line input" {
    const testing = std.testing;

    var searcher = try zigrep.search.grep.Searcher.init(testing.allocator, "needle", .{});
    defer searcher.deinit();

    const utf16le =
        "\xff\xfe" ++
        "n\x00e\x00e\x00d\x00l\x00e\x00 \x00o\x00n\x00e\x00\n\x00" ++
        "s\x00k\x00i\x00p\x00\n\x00" ++
        "n\x00e\x00e\x00d\x00l\x00e\x00 \x00t\x00w\x00o\x00\n\x00";

    var capture: std.Io.Writer.Allocating = .init(testing.allocator);
    defer capture.deinit();

    const matched = try runner.writeFileReports(
        testing.allocator,
        &capture.writer,
        &searcher,
        "utf16.txt",
        utf16le,
        .auto,
        .{},
        .text,
        null,
    );

    try testing.expect(matched);
    try testing.expectEqualStrings(
        "utf16.txt:1:1:needle one\n" ++
            "utf16.txt:3:1:needle two\n",
        capture.written(),
    );
}

test "reportFileMatch uses byte matching for planner-covered invalid UTF-8 input" {
    const testing = std.testing;

    var searcher = try zigrep.search.grep.Searcher.init(testing.allocator, "needle", .{});
    defer searcher.deinit();

    const report = (try runner.reportFileMatch(testing.allocator, &searcher, "plain.bin", "xx\xffneedleyy", .auto)).?;
    defer report.deinit(testing.allocator);
    try testing.expect(report.owned_line == null);
    try testing.expectEqualStrings("xx\xffneedleyy", report.line);
}

test "reportFileMatch uses the raw-byte matcher when the planner does not cover the pattern" {
    const testing = std.testing;

    var searcher = try zigrep.search.grep.Searcher.init(testing.allocator, "(^ab)y", .{});
    defer searcher.deinit();

    const report = (try runner.reportFileMatch(testing.allocator, &searcher, "raw-vm.bin", "aby\xff", .auto)).?;
    defer report.deinit(testing.allocator);
    try testing.expect(report.owned_line == null);
    try testing.expectEqualStrings("aby\xff", report.line);
}

test "reportFileMatch supports Unicode digit shorthand on full file contents" {
    const testing = std.testing;

    var searcher = try zigrep.search.grep.Searcher.init(testing.allocator, "a\\db", .{});
    defer searcher.deinit();

    const report = (try runner.reportFileMatch(
        testing.allocator,
        &searcher,
        "sample.txt",
        "a5b\na١b\na²b\n",
        .auto,
    )).?;
    defer report.deinit(testing.allocator);

    try testing.expectEqualStrings("a5b", report.line);
    try testing.expectEqual(@as(usize, 1), report.line_number);
}

test "writeFileReports supports Unicode digit shorthand on full file contents" {
    const testing = std.testing;

    var searcher = try zigrep.search.grep.Searcher.init(testing.allocator, "a\\db", .{});
    defer searcher.deinit();

    var capture: std.Io.Writer.Allocating = .init(testing.allocator);
    defer capture.deinit();

    const matched = try runner.writeFileReports(
        testing.allocator,
        &capture.writer,
        &searcher,
        "sample.txt",
        "a5b\na١b\na²b\n",
        .auto,
        .{},
        .text,
        null,
    );

    try testing.expect(matched);
    try testing.expectEqualStrings(
        "sample.txt:1:1:a5b\n" ++
            "sample.txt:2:1:a١b\n",
        capture.written(),
    );
}

test "reportFileMatch supports Unicode decimal property inside concatenation" {
    const testing = std.testing;

    var searcher = try zigrep.search.grep.Searcher.init(testing.allocator, "a\\p{Decimal_Number}b", .{});
    defer searcher.deinit();

    const report = (try runner.reportFileMatch(
        testing.allocator,
        &searcher,
        "sample.txt",
        "a5b\na١b\na²b\n",
        .auto,
    )).?;
    defer report.deinit(testing.allocator);

    try testing.expectEqualStrings("a5b", report.line);
    try testing.expectEqual(@as(usize, 1), report.line_number);
}

test "reportFileMatch supports ignore-case literals on full file contents" {
    const testing = std.testing;

    var searcher = try zigrep.search.grep.Searcher.init(testing.allocator, "needle", .{
        .case_mode = .insensitive,
    });
    defer searcher.deinit();

    const maybe_report = try runner.reportFileMatch(
        testing.allocator,
        &searcher,
        "sample.txt",
        "Needle one\n",
        .auto,
    );
    try testing.expect(maybe_report != null);
    const report = maybe_report.?;
    defer report.deinit(testing.allocator);

    try testing.expectEqualStrings("Needle one", report.line);
    try testing.expectEqual(@as(usize, 1), report.line_number);
    try testing.expectEqual(zigrep.search.grep.Span{ .start = 0, .end = 6 }, report.match_span);
}

test "Searcher.reportFirstMatch supports ignore-case literals on full file contents" {
    const testing = std.testing;

    var searcher = try zigrep.search.grep.Searcher.init(testing.allocator, "needle", .{
        .case_mode = .insensitive,
    });
    defer searcher.deinit();

    const maybe_report = try searcher.reportFirstMatch("sample.txt", "Needle one\n");
    try testing.expect(maybe_report != null);
    const report = maybe_report.?;
    defer report.deinit(testing.allocator);

    try testing.expectEqualStrings("Needle one", report.line);
    try testing.expectEqual(@as(usize, 1), report.line_number);
    try testing.expectEqual(zigrep.search.grep.Span{ .start = 0, .end = 6 }, report.match_span);
}

test "runCli output toggles apply across the end-to-end path" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "sample.txt",
        .data = "prefix needle suffix\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{
        "zigrep",
        "--no-filename",
        "--no-column",
        "needle",
        root_path,
    });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expectEqualStrings("1:prefix needle suffix\n", run.stdout);
}

test "runCli parallel and sequential modes produce the same output set" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "a.txt", .data = "needle a\n" });
    try tmp.dir.writeFile(.{ .sub_path = "b.txt", .data = "needle b\n" });
    try tmp.dir.writeFile(.{ .sub_path = "c.txt", .data = "needle c\n" });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const sequential = try cli_test_support.runCliCaptured(testing.allocator, &.{
        "zigrep",
        "-j",
        "1",
        "needle",
        root_path,
    });
    defer sequential.deinit(testing.allocator);

    const parallel = try cli_test_support.runCliCaptured(testing.allocator, &.{
        "zigrep",
        "-j",
        "4",
        "needle",
        root_path,
    });
    defer parallel.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), sequential.exit_code);
    try testing.expectEqual(@as(u8, 0), parallel.exit_code);
    try testing.expectEqualStrings(sequential.stdout, parallel.stdout);
}

test "runCli search output stays equivalent across allocator and read strategy paths" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "ascii.txt",
        .data = "prefix needle suffix\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "invalid.bin",
        .data = "xx\xffneedleyy\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "utf16le.txt",
        .data = "\xff\xfen\x00e\x00e\x00d\x00l\x00e\x00\n\x00",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const sequential_buffered = try cli_test_support.runCliCaptured(testing.allocator, &.{
        "zigrep",
        "--text",
        "--buffered",
        "-j",
        "1",
        "needle",
        root_path,
    });
    defer sequential_buffered.deinit(testing.allocator);

    const sequential_mmap = try cli_test_support.runCliCaptured(testing.allocator, &.{
        "zigrep",
        "--text",
        "--mmap",
        "-j",
        "1",
        "needle",
        root_path,
    });
    defer sequential_mmap.deinit(testing.allocator);

    const parallel_mmap = try cli_test_support.runCliCaptured(testing.allocator, &.{
        "zigrep",
        "--text",
        "--mmap",
        "-j",
        "4",
        "needle",
        root_path,
    });
    defer parallel_mmap.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), sequential_buffered.exit_code);
    try testing.expectEqual(@as(u8, 0), sequential_mmap.exit_code);
    try testing.expectEqual(@as(u8, 0), parallel_mmap.exit_code);
    try testing.expectEqualStrings(sequential_buffered.stdout, sequential_mmap.stdout);
    try testing.expectEqualStrings(sequential_buffered.stdout, parallel_mmap.stdout);
    try testing.expectEqualStrings(sequential_buffered.stderr, sequential_mmap.stderr);
    try testing.expectEqualStrings(sequential_buffered.stderr, parallel_mmap.stderr);
}

test "runCli binary detection stays consistent across buffered and mmap reads" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "binary.bin",
        .data = "xx\x00needleyy",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const buffered_default = try cli_test_support.runCliCaptured(testing.allocator, &.{
        "zigrep",
        "--buffered",
        "needle",
        root_path,
    });
    defer buffered_default.deinit(testing.allocator);

    const mmap_default = try cli_test_support.runCliCaptured(testing.allocator, &.{
        "zigrep",
        "--mmap",
        "needle",
        root_path,
    });
    defer mmap_default.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 1), buffered_default.exit_code);
    try testing.expectEqual(@as(u8, 1), mmap_default.exit_code);
    try testing.expectEqualStrings(buffered_default.stdout, mmap_default.stdout);
    try testing.expectEqualStrings(buffered_default.stderr, mmap_default.stderr);

    const buffered_binary = try cli_test_support.runCliCaptured(testing.allocator, &.{
        "zigrep",
        "--buffered",
        "--binary",
        "needle",
        root_path,
    });
    defer buffered_binary.deinit(testing.allocator);

    const mmap_binary = try cli_test_support.runCliCaptured(testing.allocator, &.{
        "zigrep",
        "--mmap",
        "--binary",
        "needle",
        root_path,
    });
    defer mmap_binary.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), buffered_binary.exit_code);
    try testing.expectEqual(@as(u8, 0), mmap_binary.exit_code);
    try testing.expectEqualStrings(buffered_binary.stdout, mmap_binary.stdout);
    try testing.expectEqualStrings(buffered_binary.stderr, mmap_binary.stderr);
}

test "runCli type, glob, and ignore controls compose on the end-to-end path" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = ".gitignore",
        .data = "ignored.zig\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "shown.zig",
        .data = "needle shown\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "ignored.zig",
        .data = "needle hidden\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "other.txt",
        .data = "needle text\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const default_run = try cli_test_support.runCliCaptured(testing.allocator, &.{
        "zigrep",
        "-t",
        "zig",
        "-g",
        "*.zig",
        "needle",
        root_path,
    });
    defer default_run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), default_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, default_run.stdout, 1, "shown.zig:1:1:needle shown"));
    try testing.expect(!std.mem.containsAtLeast(u8, default_run.stdout, 1, "ignored.zig"));
    try testing.expect(!std.mem.containsAtLeast(u8, default_run.stdout, 1, "other.txt"));

    const unrestricted_run = try cli_test_support.runCliCaptured(testing.allocator, &.{
        "zigrep",
        "-u",
        "-t",
        "zig",
        "-g",
        "*.zig",
        "needle",
        root_path,
    });
    defer unrestricted_run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), unrestricted_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, unrestricted_run.stdout, 1, "shown.zig:1:1:needle shown"));
    try testing.expect(std.mem.containsAtLeast(u8, unrestricted_run.stdout, 1, "ignored.zig:1:1:needle hidden"));
    try testing.expect(!std.mem.containsAtLeast(u8, unrestricted_run.stdout, 1, "other.txt"));
}
