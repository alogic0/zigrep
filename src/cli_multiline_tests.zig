const std = @import("std");
const cli_test_support = @import("cli_test_support.zig");

test "runCli multiline mode prints merged multiline blocks in normal text output" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "multi.txt",
        .data =
            "zero\n" ++
            "abc\n" ++
            "defxxxabc\n" ++
            "defxxx\n" ++
            "tail\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "-U", "abc\\ndef", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.endsWith(u8, run.stdout, "multi.txt:2:1:abc\ndefxxxabc\ndefxxx\n"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli multiline only-matching mode prints each exact multiline match" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "multi.txt",
        .data =
            "zero\n" ++
            "abc\n" ++
            "def\n" ++
            "abc\n" ++
            "def\n" ++
            "tail\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "-U", "--only-matching", "abc\\ndef", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "multi.txt:2:1:abc\ndef\n"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "multi.txt:4:1:abc\ndef\n"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli multiline count mode counts multiline matches" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "multi.txt",
        .data =
            "abc\n" ++
            "def\n" ++
            "gap\n" ++
            "abc\n" ++
            "def\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "-U", "--count", "abc\\ndef", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.endsWith(u8, run.stdout, "multi.txt:2\n"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli multiline context mode expands around merged blocks" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "multi.txt",
        .data =
            "before\n" ++
            "abc\n" ++
            "def\n" ++
            "after\n" ++
            "gap1\n" ++
            "gap2\n" ++
            "abc\n" ++
            "def\n" ++
            "tail\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "-U", "-C", "1", "abc\\ndef", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "multi.txt-1-before\n"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "multi.txt:2:1:abc\ndef\n"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "multi.txt-4-after\n"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "--\n"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "multi.txt-6-gap2\n"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "multi.txt:7:1:abc\ndef\n"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "multi.txt-9-tail\n"));
}

test "runCli multiline json mode emits per-match events with raw spans" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "multi.txt",
        .data =
            "abc\n" ++
            "def\n" ++
            "abc\n" ++
            "def\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "-U", "--json", "abc\\ndef", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "\"type\":\"match\""));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "\"line_number\":1,\"column_number\":1"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "\"line\":\"abc\\ndef\""));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "\"line_span\":{\"start\":0,\"end\":7}"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "\"match_span\":{\"start\":0,\"end\":7}"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "\"line_number\":3,\"column_number\":1"));
}

test "runCli multiline heading mode groups blocks by file" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "multi.txt",
        .data =
            "abc\n" ++
            "def\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "-U", "--heading", "abc\\ndef", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "multi.txt\n1:1:abc\ndef\n"));
}

test "runCli multiline mode keeps leftmost non-overlapping behavior for overlapping exact matches" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "multi.txt",
        .data =
            "pre\n" ++
            "abc\n" ++
            "abc\n" ++
            "abc\n" ++
            "post\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "-U", "abc\\nabc", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.endsWith(u8, run.stdout, "multi.txt:2:1:abc\nabc\n"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli multiline mode merges adjacent match groups without duplicating lines" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "multi.txt",
        .data =
            "abc\n" ++
            "abc\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "-U", "abc\\n", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.endsWith(u8, run.stdout, "multi.txt:1:1:abc\nabc\n"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli multiline mode keeps dot from matching newline without dotall" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "multi.txt",
        .data =
            "a\n" ++
            "b\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "-U", "a.b", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 1), run.exit_code);
    try testing.expectEqualStrings("", run.stdout);
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli multiline dotall makes dot match newline" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "multi.txt",
        .data =
            "a\n" ++
            "b\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "-U", "--multiline-dotall", "a.b", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.endsWith(u8, run.stdout, "multi.txt:1:1:a\nb\n"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli multiline buffered mode matches normal full-buffer output" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "multi.txt",
        .data =
            "zero\n" ++
            "abc\n" ++
            "def\n" ++
            "tail\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const default_run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "-U", "abc\\ndef", root_path });
    defer default_run.deinit(testing.allocator);

    const buffered_run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "-U", "--buffered", "abc\\ndef", root_path });
    defer buffered_run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), default_run.exit_code);
    try testing.expectEqual(@as(u8, 0), buffered_run.exit_code);
    try testing.expectEqualStrings(default_run.stdout, buffered_run.stdout);
    try testing.expectEqualStrings(default_run.stderr, buffered_run.stderr);
}

test "runCli multiline output stays consistent across sequential and parallel search" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "utf8.txt",
        .data =
            "lead\n" ++
            "abc\n" ++
            "def\n" ++
            "tail\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "invalid.bin",
        .data =
            "xx\xff\n" ++
            "abc\n" ++
            "def\n" ++
            "yy\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "utf16le.txt",
        .data =
            "\xff\xfe" ++
            "l\x00e\x00a\x00d\x00\n\x00" ++
            "a\x00b\x00c\x00\n\x00" ++
            "d\x00e\x00f\x00\n\x00" ++
            "t\x00a\x00i\x00l\x00\n\x00",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const sequential = try cli_test_support.runCliCaptured(testing.allocator, &.{
        "zigrep",
        "-U",
        "--text",
        "-j",
        "1",
        "abc\\ndef",
        root_path,
    });
    defer sequential.deinit(testing.allocator);

    const parallel = try cli_test_support.runCliCaptured(testing.allocator, &.{
        "zigrep",
        "-U",
        "--text",
        "-j",
        "4",
        "abc\\ndef",
        root_path,
    });
    defer parallel.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), sequential.exit_code);
    try testing.expectEqual(@as(u8, 0), parallel.exit_code);
    try testing.expectEqualStrings(sequential.stdout, parallel.stdout);
    try testing.expectEqualStrings(sequential.stderr, parallel.stderr);
}

test "runCli multiline output stays consistent across buffered and mmap reads" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "utf8.txt",
        .data =
            "lead\n" ++
            "abc\n" ++
            "def\n" ++
            "tail\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "invalid.bin",
        .data =
            "xx\xff\n" ++
            "abc\n" ++
            "def\n" ++
            "yy\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "utf16le.txt",
        .data =
            "\xff\xfe" ++
            "l\x00e\x00a\x00d\x00\n\x00" ++
            "a\x00b\x00c\x00\n\x00" ++
            "d\x00e\x00f\x00\n\x00" ++
            "t\x00a\x00i\x00l\x00\n\x00",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const buffered = try cli_test_support.runCliCaptured(testing.allocator, &.{
        "zigrep",
        "-U",
        "--text",
        "--buffered",
        "-j",
        "1",
        "abc\\ndef",
        root_path,
    });
    defer buffered.deinit(testing.allocator);

    const mmap = try cli_test_support.runCliCaptured(testing.allocator, &.{
        "zigrep",
        "-U",
        "--text",
        "--mmap",
        "-j",
        "1",
        "abc\\ndef",
        root_path,
    });
    defer mmap.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), buffered.exit_code);
    try testing.expectEqual(@as(u8, 0), mmap.exit_code);
    try testing.expectEqualStrings(buffered.stdout, mmap.stdout);
    try testing.expectEqualStrings(buffered.stderr, mmap.stderr);
}
