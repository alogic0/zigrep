const std = @import("std");
const zigrep = @import("zigrep");

const runner = zigrep.search_runner;
const search_reporting = zigrep.search_reporting;
const CliOptions = zigrep.command.CliOptions;

test "runSearch parallel path preserves heading groups" {
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

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    var stdout_capture: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_capture.deinit();

    const exit_code = try runner.runSearch(testing.allocator, &stdout_capture.writer, &stderr_capture.writer, .{
        .pattern = "needle",
        .paths = &.{root_path},
        .parallel_jobs = 4,
        .output = .{ .heading = true, .with_filename = false },
    });

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, stdout_capture.written(), 1, "one.txt\n1:1:needle one"));
    try testing.expect(std.mem.containsAtLeast(u8, stdout_capture.written(), 1, "two.txt\n1:1:needle two"));
    try testing.expectEqualStrings("", stderr_capture.written());
}

test "runSearch parallel path prints every matching line from one file" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "one.txt",
        .data = "needle one\nneedle again\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "two.txt",
        .data = "needle two\n",
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
    try testing.expect(std.mem.containsAtLeast(u8, stdout_capture.written(), 1, "one.txt:2:1:needle again"));
    try testing.expect(std.mem.containsAtLeast(u8, stdout_capture.written(), 1, "two.txt:1:1:needle two"));
    try testing.expectEqualStrings("", stderr_capture.written());
}

test "searchEntriesSequential warns and skips unreadable files" {
    const testing = std.testing;

    var stdout_capture: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_capture.deinit();

    const missing_path = try testing.allocator.dupe(u8, "missing-file-for-zigrep-test");
    defer testing.allocator.free(missing_path);

    const entries = [_]zigrep.search.walk.Entry{
        .{
            .path = missing_path,
            .kind = .file,
            .depth = 0,
            .accessed_ns = 0,
            .modified_ns = 0,
            .changed_ns = 0,
        },
    };

    const result = try runner.searchEntriesSequential(testing.allocator, &stdout_capture.writer, &stderr_capture.writer, &entries, .{
        .pattern = "needle",
        .paths = &.{"."},
    });

    try testing.expect(!result.matched);
    try testing.expectEqual(@as(usize, 0), result.stats.searched_files);
    try testing.expectEqual(@as(usize, 1), result.stats.warnings_emitted);
    try testing.expectEqualStrings("", stdout_capture.written());
    try testing.expect(std.mem.containsAtLeast(u8, stderr_capture.written(), 1, "warning: skipping missing-file-for-zigrep-test: file not found\n"));
}

test "search scheduler keeps tiny workloads on the sequential path" {
    const testing = std.testing;

    const schedule = zigrep.search.schedule.plan(1, .{
        .requested_jobs = 8,
    });

    try testing.expect(!schedule.parallel);
    try testing.expectEqual(@as(usize, 1), schedule.worker_count);
    try testing.expectEqual(@as(usize, 1), schedule.chunk_size);
}

test "formatReport obeys output toggles" {
    const testing = std.testing;

    const report: zigrep.search.grep.MatchReport = .{
        .path = "sample.txt",
        .line_number = 3,
        .column_number = 7,
        .line = "matched line",
        .line_span = .{ .start = 0, .end = 12 },
        .match_span = .{ .start = 0, .end = 6 },
    };

    const line = try search_reporting.formatReport(testing.allocator, report, .{
        .with_filename = false,
        .line_number = true,
        .column_number = false,
    });
    defer testing.allocator.free(line);

    try testing.expectEqualStrings("3:matched line\n", line);
}

test "formatReport escapes unsafe bytes in displayed lines" {
    const testing = std.testing;

    const report: zigrep.search.grep.MatchReport = .{
        .path = "sample.bin",
        .line_number = 1,
        .column_number = 4,
        .line = "aa\x00\xffneedle\x1b",
        .line_span = .{ .start = 0, .end = 11 },
        .match_span = .{ .start = 4, .end = 10 },
    };

    const line = try search_reporting.formatReport(testing.allocator, report, .{});
    defer testing.allocator.free(line);

    try testing.expectEqualStrings("sample.bin:1:4:aa\\x00\\xFFneedle\\x1B\n", line);
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

test "runSearch sort path disables parallel reordering and sorts descending" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "a.txt",
        .data = "needle one\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "b.txt",
        .data = "needle two\n",
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
        .parallel_jobs = 4,
        .sort_mode = .path,
        .sort_reverse = true,
    });

    try testing.expectEqual(@as(u8, 0), exit_code);
    const a_index = std.mem.indexOf(u8, stdout_capture.written(), "a.txt:1:1:needle one").?;
    const b_index = std.mem.indexOf(u8, stdout_capture.written(), "b.txt:1:1:needle two").?;
    try testing.expect(b_index < a_index);
    try testing.expectEqualStrings("", stderr_capture.written());
}

test "runSearch reports creation-time-unavailable sort" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "a.txt",
        .data = "needle one\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    var stdout_capture: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_capture.deinit();

    try testing.expectError(error.CreationTimeUnavailable, runner.runSearch(
        testing.allocator,
        &stdout_capture.writer,
        &stderr_capture.writer,
        .{
            .pattern = "needle",
            .paths = &.{root_path},
            .sort_mode = .created,
        },
    ));
}
