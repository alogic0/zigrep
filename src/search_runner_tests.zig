const std = @import("std");
const zigrep = @import("zigrep");

const runner = zigrep.search_runner;

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
        .{ .path = missing_path, .kind = .file, .depth = 0 },
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

    const line = try runner.formatReport(testing.allocator, report, .{
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

    const line = try runner.formatReport(testing.allocator, report, .{});
    defer testing.allocator.free(line);

    try testing.expectEqualStrings("sample.bin:1:4:aa\\x00\\xFFneedle\\x1B\n", line);
}
