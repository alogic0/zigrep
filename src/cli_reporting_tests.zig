const std = @import("std");
const cli_test_support = @import("cli_test_support.zig");

test "runCli count mode prints per-file matching line counts" {
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

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "--count", "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "many.txt:3\n"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli max-count limits matching lines per file" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "many.txt",
        .data =
            "needle one\n" ++
            "skip\n" ++
            "needle two\n" ++
            "needle three\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "--max-count", "2", "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "many.txt:1:1:needle one"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "many.txt:3:1:needle two"));
    try testing.expect(!std.mem.containsAtLeast(u8, run.stdout, 1, "many.txt:4:1:needle three"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli context mode prints surrounding lines and separators" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "ctx.txt",
        .data =
            "alpha\n" ++
            "before\n" ++
            "needle one\n" ++
            "after\n" ++
            "gap1\n" ++
            "gap2\n" ++
            "needle two\n" ++
            "tail\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "-C", "1", "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "ctx.txt-2-before\n"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "ctx.txt:3:1:needle one\n"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "ctx.txt-4-after\n"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "--\n"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "ctx.txt-6-gap2\n"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "ctx.txt:7:1:needle two\n"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "ctx.txt-8-tail\n"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli context mode respects max-count" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "ctx.txt",
        .data =
            "before\n" ++
            "needle one\n" ++
            "after\n" ++
            "gap1\n" ++
            "needle two\n" ++
            "tail\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "-C", "1", "--max-count", "1", "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "ctx.txt-1-before\n"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "ctx.txt:2:1:needle one\n"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "ctx.txt-3-after\n"));
    try testing.expect(!std.mem.containsAtLeast(u8, run.stdout, 1, "needle two"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli replace rewrites every match occurrence in a matching line" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "many.txt",
        .data = "needle one needle two\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "-r", "HIT", "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "many.txt:1:1:HIT one HIT two\n"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli replace works with context mode and leaves context lines untouched" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "ctx.txt",
        .data =
            "before\n" ++
            "needle one needle two\n" ++
            "after\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "-C", "1", "-r", "HIT", "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "ctx.txt-1-before\n"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "ctx.txt:2:1:HIT one HIT two\n"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "ctx.txt-3-after\n"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli replace expands numbered captures in matching lines" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "caps.txt",
        .data = "foo bar\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{
        "zigrep",
        "-r",
        "X$2-$1-$0",
        "(foo) (bar)",
        root_path,
    });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "caps.txt:1:1:Xbar-foo-foo bar\n"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli glob mode filters files by positive glob" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "keep.txt",
        .data = "needle one\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "skip.md",
        .data = "needle two\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "-g", "*.txt", "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "keep.txt:1:1:needle one"));
    try testing.expect(!std.mem.containsAtLeast(u8, run.stdout, 1, "skip.md"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli glob mode supports negative globs" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "one.txt",
        .data = "needle one\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "main.txt",
        .data = "needle two\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "-g", "*.txt", "-g", "!main.txt", "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "one.txt:1:1:needle one"));
    try testing.expect(!std.mem.containsAtLeast(u8, run.stdout, 1, "main.txt:1:1:needle two"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli glob mode supports case-insensitive globs" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "Keep.ZIG",
        .data = "needle one\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "skip.md",
        .data = "needle two\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "--iglob", "*.zig", "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "Keep.ZIG:1:1:needle one"));
    try testing.expect(!std.mem.containsAtLeast(u8, run.stdout, 1, "skip.md"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli sort path orders matching files ascending" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "b.txt",
        .data = "needle two\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "a.txt",
        .data = "needle one\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "--sort", "path", "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    const a_index = std.mem.indexOf(u8, run.stdout, "a.txt:1:1:needle one").?;
    const b_index = std.mem.indexOf(u8, run.stdout, "b.txt:1:1:needle two").?;
    try testing.expect(a_index < b_index);
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli type include filter limits matches" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "main.zig",
        .data = "needle one\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "README.md",
        .data = "needle two\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "-t", "zig", "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "main.zig:1:1:needle one"));
    try testing.expect(!std.mem.containsAtLeast(u8, run.stdout, 1, "README.md"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli type exclude filter skips matching type" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "main.zig",
        .data = "needle one\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "README.md",
        .data = "needle two\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "-T", "markdown", "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "main.zig:1:1:needle one"));
    try testing.expect(!std.mem.containsAtLeast(u8, run.stdout, 1, "README.md"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli type-add defines custom type" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "home.web",
        .data = "needle one\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "main.zig",
        .data = "needle two\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{
        "zigrep",
        "--type-add",
        "web:*.web",
        "-t",
        "web",
        "needle",
        root_path,
    });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "home.web:1:1:needle one"));
    try testing.expect(!std.mem.containsAtLeast(u8, run.stdout, 1, "main.zig"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli type-list prints known types" {
    const testing = std.testing;

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{
        "zigrep",
        "--type-add",
        "web:*.web,*.page",
        "--type-list",
    });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "zig: *.zig\n"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "web: *.web, *.page\n"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli unknown type fails cleanly" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "main.zig",
        .data = "needle one\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    try testing.expectError(error.UnknownType, cli_test_support.runCliCaptured(testing.allocator, &.{
        "zigrep",
        "-t",
        "missing",
        "needle",
        root_path,
    }));
}

test "runCli count mode respects max-count" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "many.txt",
        .data =
            "needle one\n" ++
            "skip\n" ++
            "needle two\n" ++
            "needle three\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "--count", "--max-count", "2", "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "many.txt:2\n"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli invert-match prints non-matching lines" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "many.txt",
        .data = "needle one\nskip this\nneedle two\nkeep this\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "-v", "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "many.txt:2:1:skip this"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "many.txt:4:1:keep this"));
    try testing.expect(!std.mem.containsAtLeast(u8, run.stdout, 1, "needle one"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli invert-match count mode counts non-matching lines" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "many.txt",
        .data = "needle one\nskip this\nneedle two\nkeep this\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "-v", "--count", "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "many.txt:2\n"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli invert-match files-without-match mode prints fully matching files" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "all-match.txt",
        .data = "needle one\nneedle two\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "mixed.txt",
        .data = "needle one\nskip this\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "-v", "--files-without-match", "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "all-match.txt\n"));
    try testing.expect(!std.mem.containsAtLeast(u8, run.stdout, 1, "mixed.txt\n"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli files-with-matches mode prints matching file paths once" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "one.txt",
        .data = "needle one\nneedle two\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "two.txt",
        .data = "skip\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "--files-with-matches", "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "one.txt\n"));
    try testing.expect(!std.mem.containsAtLeast(u8, run.stdout, 1, "two.txt\n"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli files-without-match mode prints only non-matching file paths" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "one.txt",
        .data = "needle one\nneedle two\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "two.txt",
        .data = "skip\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "--files-without-match", "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(!std.mem.containsAtLeast(u8, run.stdout, 1, "one.txt\n"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "two.txt\n"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli null mode emits NUL-delimited matching paths" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "one.txt",
        .data = "needle one\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "two.txt",
        .data = "skip\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "--null", "--files-with-matches", "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "one.txt"));
    try testing.expect(std.mem.indexOfScalar(u8, run.stdout, 0) != null);
    try testing.expect(!std.mem.containsAtLeast(u8, run.stdout, 1, "\n"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli null mode emits NUL-delimited non-matching paths" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "one.txt",
        .data = "needle one\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "two.txt",
        .data = "skip\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "--null", "--files-without-match", "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "two.txt"));
    try testing.expect(std.mem.indexOfScalar(u8, run.stdout, 0) != null);
    try testing.expect(!std.mem.containsAtLeast(u8, run.stdout, 1, "\n"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli json mode emits match events" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "many.txt",
        .data = "needle one\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "--json", "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "\"type\":\"begin\""));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "\"type\":\"match\""));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "\"type\":\"end\""));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "\"type\":\"summary\""));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "\"path\":{\"text\":"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "many.txt"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "\"line_number\":1"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "\"lines\":{\"text\":\"needle one\\n\"}"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "\"submatches\":["));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "\"matched_lines\":1"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "\"matches\":1"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "\"bytes_printed\":"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli json only-matching mode keeps full line payload and submatch offsets" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "many.txt",
        .data = "xxneedle yy\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "--json", "--only-matching", "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "\"lines\":{\"text\":\"xxneedle yy\\n\"}"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "\"absolute_offset\":0"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "\"start\":2,\"end\":8"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "\"match\":{\"text\":\"needle\"}"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "\"matched_lines\":1"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "\"matches\":1"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli json count mode emits count events" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "many.txt",
        .data = "needle one\nneedle two\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "--json", "--count", "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "\"type\":\"begin\""));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "\"type\":\"count\""));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "\"type\":\"end\""));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "\"type\":\"summary\""));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "\"path\":{\"text\":"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "many.txt"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "\"count\":2"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli stats mode prints search summary to stderr" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "one.txt",
        .data = "needle one\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "two.txt",
        .data = "skip\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "binary.bin",
        .data = "xx\x00needleyy",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "--stats", "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "one.txt:1:1:needle one"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stderr, 1, "stats: searched_files=2"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stderr, 1, "matched_files=1"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stderr, 1, "skipped_binary_files=1"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stderr, 1, "warnings_emitted=0"));
}

test "runCli json count mode can emit stats on stderr" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "many.txt",
        .data = "needle one\nneedle two\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{
        "zigrep",
        "--json",
        "--count",
        "--stats",
        "needle",
        root_path,
    });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "\"type\":\"count\""));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "\"count\":2"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stderr, 1, "stats: searched_files=1"));
}

test "runCli heading mode groups matches by file" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "one.txt",
        .data = "needle one\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "two.txt",
        .data = "skip\nneedle two\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "--heading", "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "one.txt\n1:1:needle one\n"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "two.txt\n2:1:needle two\n"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "\n\n"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli suppresses filename by default for one explicit file" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "single.txt",
        .data = "needle one\n",
    });

    const file_path = try tmp.dir.realpathAlloc(testing.allocator, "single.txt");
    defer testing.allocator.free(file_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "needle", file_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expectEqualStrings("needle one\n", run.stdout);
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli count suppresses filename by default for one explicit file" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "single.txt",
        .data = "needle one\nneedle two\n",
    });

    const file_path = try tmp.dir.realpathAlloc(testing.allocator, "single.txt");
    defer testing.allocator.free(file_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "--count", "needle", file_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expectEqualStrings("2\n", run.stdout);
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli with-filename preserves filename for one explicit file" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "single.txt",
        .data = "needle one\n",
    });

    const file_path = try tmp.dir.realpathAlloc(testing.allocator, "single.txt");
    defer testing.allocator.free(file_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "-H", "needle", file_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "single.txt:needle one\n"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli only-matching suppresses all prefixes by default for one explicit file" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "single.txt",
        .data = "needle one\nneedle two\n",
    });

    const file_path = try tmp.dir.realpathAlloc(testing.allocator, "single.txt");
    defer testing.allocator.free(file_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "--only-matching", "needle", file_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expectEqualStrings("needle\nneedle\n", run.stdout);
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli line-number remains when explicitly requested for one explicit file" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "single.txt",
        .data = "needle one\nneedle two\n",
    });

    const file_path = try tmp.dir.realpathAlloc(testing.allocator, "single.txt");
    defer testing.allocator.free(file_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "-n", "needle", file_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expectEqualStrings("1:needle one\n2:needle two\n", run.stdout);
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli column remains when explicitly requested for one explicit file" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "single.txt",
        .data = "needle one\nneedle two\n",
    });

    const file_path = try tmp.dir.realpathAlloc(testing.allocator, "single.txt");
    defer testing.allocator.free(file_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "--column", "needle", file_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expectEqualStrings("1:1:needle one\n2:1:needle two\n", run.stdout);
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli heading preserves explicit heading behavior for one explicit file" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "single.txt",
        .data = "needle one\n",
    });

    const file_path = try tmp.dir.realpathAlloc(testing.allocator, "single.txt");
    defer testing.allocator.free(file_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "--heading", "needle", file_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "single.txt\n1:1:needle one\n"));
    try testing.expectEqualStrings("", run.stderr);
}
