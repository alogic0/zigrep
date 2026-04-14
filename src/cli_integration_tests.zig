const std = @import("std");
const zigrep = @import("zigrep");
const cli_test_support = @import("cli_test_support.zig");

test "runCli reports matches and skips binary files by default" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "match.txt",
        .data = "before\nneedle here\nafter\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "binary.bin",
        .data = "xx\x00needleyy",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "match.txt:2:1:needle here"));
    try testing.expect(!std.mem.containsAtLeast(u8, run.stdout, 1, "binary.bin"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli files mode lists filtered files without compiling a pattern" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = ".gitignore",
        .data = "ignored.txt\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "shown.txt",
        .data = "shown\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "ignored.txt",
        .data = "ignored\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "--files", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "shown.txt\n"));
    try testing.expect(!std.mem.containsAtLeast(u8, run.stdout, 1, "ignored.txt"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli fixed-strings matches literal regex metacharacters" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "sample.zig",
        .data = "const x = @import(\"search/root.zig\");\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{
        "zigrep",
        "-F",
        "-e",
        "@import(\"search/root.zig\")",
        root_path,
    });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "sample.zig:1:11:const x = @import(\"search/root.zig\");"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli repeated explicit patterns match any branch" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "sample.txt",
        .data = "foo here\nbar there\nbaz only\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{
        "zigrep",
        "-e",
        "foo",
        "-e",
        "bar",
        root_path,
    });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "sample.txt:1:1:foo here"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "sample.txt:2:1:bar there"));
    try testing.expect(!std.mem.containsAtLeast(u8, run.stdout, 1, "baz only"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli repeated fixed-string explicit patterns escape each branch independently" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "sample.txt",
        .data = "a.b\n[x]\naxb\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{
        "zigrep",
        "-F",
        "-e",
        "a.b",
        "-e",
        "[x]",
        root_path,
    });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "sample.txt:1:1:a.b"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "sample.txt:2:1:[x]"));
    try testing.expect(!std.mem.containsAtLeast(u8, run.stdout, 1, "sample.txt:3:1:axb"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli treats stats as a no-op in files mode" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "shown.txt",
        .data = "shown\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "--files", "--stats", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "shown.txt\n"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli treats stats as a no-op in files-with-matches mode" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "sample.txt",
        .data = "needle\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "--stats", "-l", "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "sample.txt\n"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli honors root gitignore by default" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = ".gitignore",
        .data = "ignored.txt\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "ignored.txt",
        .data = "needle hidden\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "shown.txt",
        .data = "needle shown\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(!std.mem.containsAtLeast(u8, run.stdout, 1, "ignored.txt"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "shown.txt:1:1:needle shown"));
}

test "runCli no-ignore-vcs bypasses root gitignore" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = ".gitignore",
        .data = "ignored.txt\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "ignored.txt",
        .data = "needle hidden\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "--no-ignore-vcs", "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "ignored.txt:1:1:needle hidden"));
}

test "runCli no-ignore-parent bypasses parent gitignore" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("sub");
    try tmp.dir.writeFile(.{
        .sub_path = ".gitignore",
        .data = "sub/ignored.txt\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "sub/ignored.txt",
        .data = "needle hidden\n",
    });

    const sub_path = try tmp.dir.realpathAlloc(testing.allocator, "sub");
    defer testing.allocator.free(sub_path);

    const default_run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "needle", sub_path });
    defer default_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 1), default_run.exit_code);

    const bypass_run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "--no-ignore-parent", "needle", sub_path });
    defer bypass_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), bypass_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, bypass_run.stdout, 1, "ignored.txt:1:1:needle hidden"));
}

test "runCli ignore-file applies explicit ignore rules" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "custom.ignore",
        .data = "blocked.txt\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "blocked.txt",
        .data = "needle hidden\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "shown.txt",
        .data = "needle shown\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);
    const ignore_path = try tmp.dir.realpathAlloc(testing.allocator, "custom.ignore");
    defer testing.allocator.free(ignore_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "--ignore-file", ignore_path, "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(!std.mem.containsAtLeast(u8, run.stdout, 1, "blocked.txt"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "shown.txt:1:1:needle shown"));
}

test "runCli no-ignore bypasses all ignore filtering" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = ".gitignore",
        .data = "ignored.txt\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "custom.ignore",
        .data = "blocked.txt\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "ignored.txt",
        .data = "needle ignored\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "blocked.txt",
        .data = "needle blocked\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);
    const ignore_path = try tmp.dir.realpathAlloc(testing.allocator, "custom.ignore");
    defer testing.allocator.free(ignore_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "--no-ignore", "--ignore-file", ignore_path, "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "ignored.txt:1:1:needle ignored"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "blocked.txt:1:1:needle blocked"));
}

test "runCli unrestricted mode widens filtering progressively" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = ".gitignore",
        .data = "ignored.txt\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "ignored.txt",
        .data = "needle ignored\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = ".hidden.txt",
        .data = "needle hidden\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "binary.bin",
        .data = "xx\x00needleyy",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const one_u = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "-u", "needle", root_path });
    defer one_u.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), one_u.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, one_u.stdout, 1, "ignored.txt:1:1:needle ignored"));
    try testing.expect(!std.mem.containsAtLeast(u8, one_u.stdout, 1, ".hidden.txt"));
    try testing.expect(!std.mem.containsAtLeast(u8, one_u.stdout, 1, "binary.bin"));

    const two_u = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "-uu", "needle", root_path });
    defer two_u.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), two_u.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, two_u.stdout, 1, "ignored.txt:1:1:needle ignored"));
    try testing.expect(std.mem.containsAtLeast(u8, two_u.stdout, 1, ".hidden.txt:1:1:needle hidden"));
    try testing.expect(!std.mem.containsAtLeast(u8, two_u.stdout, 1, "binary.bin"));

    const three_u = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "-uuu", "needle", root_path });
    defer three_u.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), three_u.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, three_u.stdout, 1, "ignored.txt:1:1:needle ignored"));
    try testing.expect(std.mem.containsAtLeast(u8, three_u.stdout, 1, ".hidden.txt:1:1:needle hidden"));
    try testing.expect(std.mem.containsAtLeast(u8, three_u.stdout, 1, "binary.bin"));
}

test "runCli ignore-case matches differing literal case" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "sample.txt",
        .data = "Needle one\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "--ignore-case", "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "sample.txt:1:1:Needle one"));
}

test "runCli ignore-case matches Unicode literal folding cases" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "sample.txt",
        .data =
            "ς\n" ++
            "ÉCLAIR\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const sigma_run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "--ignore-case", "Σ", root_path });
    defer sigma_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), sigma_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, sigma_run.stdout, 1, "sample.txt:1:1:ς"));

    const accented_run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "--ignore-case", "éclair", root_path });
    defer accented_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), accented_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, accented_run.stdout, 1, "sample.txt:2:1:ÉCLAIR"));
}

test "runCli ignore-case matches Unicode class folding cases" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "sample.txt",
        .data =
            "ςσσ\n" ++
            "Éé\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const sigma_run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "--ignore-case", "[Σ]+", root_path });
    defer sigma_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), sigma_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, sigma_run.stdout, 1, "sample.txt:1:1:ςσσ"));

    const accented_run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "--ignore-case", "[é]+", root_path });
    defer accented_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), accented_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, accented_run.stdout, 1, "sample.txt:2:1:Éé"));
}

test "runCli ignore-case folds case-related Unicode properties" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "sample.txt",
        .data =
            "É\n" ++
            "ς\n" ++
            "中\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "other.txt",
        .data = "中\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const lower_run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "--ignore-case", "\\p{Lowercase}+", root_path });
    defer lower_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), lower_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, lower_run.stdout, 1, "sample.txt:1:1:É"));
    try testing.expect(std.mem.containsAtLeast(u8, lower_run.stdout, 1, "sample.txt:2:1:ς"));

    const class_run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "--ignore-case", "[\\p{Uppercase}]+", root_path });
    defer class_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), class_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, class_run.stdout, 1, "sample.txt:1:1:É"));
    try testing.expect(std.mem.containsAtLeast(u8, class_run.stdout, 1, "sample.txt:2:1:ς"));

    const other_path = try tmp.dir.realpathAlloc(testing.allocator, "other.txt");
    defer testing.allocator.free(other_path);

    const negated_run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "--ignore-case", "\\P{Lowercase}+", other_path });
    defer negated_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), negated_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, negated_run.stdout, 1, "other.txt:1:1:中"));
}

test "runCli accepts universal Unicode case-insensitive range" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "sample.txt",
        .data = "A\nΣ\n😀\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(
        testing.allocator,
        &.{ "zigrep", "--ignore-case", "[\u{0000}-\u{10FFFF}]", root_path },
    );
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "sample.txt:1:1:A"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "sample.txt:2:1:Σ"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "sample.txt:3:1:😀"));
}

test "runCli accepts broad folded BMP case-insensitive range" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "sample.txt",
        .data = "A\nΣ\n😀\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(
        testing.allocator,
        &.{ "zigrep", "--ignore-case", "[\u{0000}-\u{FFFF}]", root_path },
    );
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "sample.txt:1:1:A"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "sample.txt:2:1:Σ"));
    try testing.expect(!std.mem.containsAtLeast(u8, run.stdout, 1, "sample.txt:3:1:😀"));
}

test "runCli smart-case keeps uppercase patterns case-sensitive" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "sample.txt",
        .data = "needle lower\nNeedle upper\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "--smart-case", "Needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(!std.mem.containsAtLeast(u8, run.stdout, 1, "sample.txt:1:1:needle lower"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "sample.txt:2:1:Needle upper"));
}

test "runCli smart-case uses ignore-case for lowercase patterns" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "sample.txt",
        .data = "Needle one\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "--smart-case", "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "sample.txt:1:1:Needle one"));
}

test "runCli smart-case keeps uppercase Unicode patterns case-sensitive" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "sample.txt",
        .data = "жар lower\nЖар upper\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "--smart-case", "Жар", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(!std.mem.containsAtLeast(u8, run.stdout, 1, "sample.txt:1:1:жар lower"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "sample.txt:2:1:Жар upper"));
}

test "runCli smart-case uses ignore-case for titlecase Unicode patterns" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "sample.txt",
        .data = "ǆar lower\nǅar title\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "--smart-case", "ǅar", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "sample.txt:1:1:ǆar lower"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "sample.txt:2:1:ǅar title"));
}

test "runCli returns 1 when nothing matches" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "sample.txt",
        .data = "hello world\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 1), run.exit_code);
    try testing.expectEqualStrings("", run.stdout);
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli prints version and exits successfully" {
    const testing = std.testing;

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{ "zigrep", "--version" });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expectEqualStrings("zigrep " ++ zigrep.app_version ++ "\n", run.stdout);
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli config file prepends default flags" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "zigrep.conf",
        .data =
            "--count\n" ++
            "--ignore-case\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "sample.txt",
        .data =
            "Needle one\n" ++
            "needle two\n" ++
            "miss\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);
    const config_path = try std.fs.path.join(testing.allocator, &.{ root_path, "zigrep.conf" });
    defer testing.allocator.free(config_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{
        "zigrep",
        "--config-path",
        config_path,
        "needle",
        root_path,
    });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "sample.txt:2\n"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli command-line flags override config defaults" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "zigrep.conf",
        .data = "--count\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "sample.txt",
        .data = "needle one\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);
    const config_path = try std.fs.path.join(testing.allocator, &.{ root_path, "zigrep.conf" });
    defer testing.allocator.free(config_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{
        "zigrep",
        "--config-path",
        config_path,
        "--files-with-matches",
        "needle",
        root_path,
    });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "sample.txt\n"));
    try testing.expect(!std.mem.containsAtLeast(u8, run.stdout, 1, "sample.txt:1\n"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli no-config disables config file defaults" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "zigrep.conf",
        .data = "--count\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "sample.txt",
        .data = "needle one\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);
    const config_path = try std.fs.path.join(testing.allocator, &.{ root_path, "zigrep.conf" });
    defer testing.allocator.free(config_path);

    const run = try cli_test_support.runCliCaptured(testing.allocator, &.{
        "zigrep",
        "--config-path",
        config_path,
        "--no-config",
        "needle",
        root_path,
    });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "sample.txt:1:1:needle one"));
    try testing.expect(!std.mem.containsAtLeast(u8, run.stdout, 1, "sample.txt:1\n"));
    try testing.expectEqualStrings("", run.stderr);
}
