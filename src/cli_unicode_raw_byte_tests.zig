const std = @import("std");
const cli_test_support = @import("cli_test_support.zig");

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
