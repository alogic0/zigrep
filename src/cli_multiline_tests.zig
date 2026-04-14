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
    try testing.expect(std.mem.endsWith(u8, run.stdout, "multi.txt:abc\ndefxxxabc\ndefxxx\n"));
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
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "multi.txt:abc\ndef\n"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 2, "multi.txt:abc\ndef\n"));
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
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "multi.txt-before\n"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "multi.txt:abc\ndef\n"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "multi.txt-after\n"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "--\n"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "multi.txt-gap2\n"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 2, "multi.txt:abc\ndef\n"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "multi.txt-tail\n"));
}

test "runCli multiline json mode emits ripgrep-style block events with submatches" {
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
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "\"path\":{\"text\":"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "\"lines\":{\"text\":\"abc\\ndef\\nabc\\ndef\\n\"}"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "\"line_number\":1,\"absolute_offset\":0"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "\"submatches\":["));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "\"start\":0,\"end\":7"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "\"start\":8,\"end\":15"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "\"matched_lines\":4"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "\"matches\":2"));
}

test "runCli multiline heading on one explicit file follows ripgrep and suppresses the heading" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "multi.txt",
        .data =
            "abc\n" ++
            "def\n",
    });

    const file_path = try tmp.dir.realpathAlloc(testing.allocator, "multi.txt");
    defer testing.allocator.free(file_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "-U", "--heading", "abc\\ndef", file_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expectEqualStrings("abc\ndef\n", run.stdout);
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
    try testing.expect(std.mem.endsWith(u8, run.stdout, "multi.txt:abc\nabc\n"));
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
    try testing.expect(std.mem.endsWith(u8, run.stdout, "multi.txt:abc\nabc\n"));
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
    try testing.expect(std.mem.endsWith(u8, run.stdout, "multi.txt:a\nb\n"));
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
