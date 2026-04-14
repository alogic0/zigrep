const std = @import("std");
const command = @import("../command.zig");

pub const GlobSpec = command.GlobSpec;

pub fn allowsPath(globs: []const GlobSpec, path: []const u8) bool {
    if (globs.len == 0) return true;

    var has_positive = false;
    for (globs) |glob| {
        if (glob.pattern.len != 0 and glob.pattern[0] != '!') {
            has_positive = true;
            break;
        }
    }

    var allowed = !has_positive;
    for (globs) |glob| {
        if (glob.pattern.len == 0) continue;

        const excluded = glob.pattern[0] == '!';
        const pattern = if (excluded) glob.pattern[1..] else glob.pattern;
        if (pattern.len == 0) continue;
        if (!matchesPathPattern(pattern, path, glob.case_insensitive)) continue;
        allowed = !excluded;
    }

    return allowed;
}

pub fn allowsPathStrings(globs: []const []const u8, path: []const u8) bool {
    if (globs.len == 0) return true;

    var has_positive = false;
    for (globs) |pattern| {
        if (pattern.len != 0 and pattern[0] != '!') {
            has_positive = true;
            break;
        }
    }

    var allowed = !has_positive;
    for (globs) |pattern| {
        if (pattern.len == 0) continue;

        const excluded = pattern[0] == '!';
        const body = if (excluded) pattern[1..] else pattern;
        if (body.len == 0) continue;
        if (!matchesPathPattern(body, path, false)) continue;
        allowed = !excluded;
    }

    return allowed;
}

pub fn matchesPathPattern(pattern: []const u8, path: []const u8, case_insensitive: bool) bool {
    if (pattern.len == 0) return path.len == 0;

    var body = pattern;
    var anchored = false;
    if (body[0] == '/') {
        anchored = true;
        body = body[1..];
    }
    if (body.len == 0) return false;

    if (anchored) return globMatch(body, path, case_insensitive);
    if (globMatch(body, path, case_insensitive)) return true;

    var iter = std.mem.splitScalar(u8, path, std.fs.path.sep);
    while (iter.next()) |segment| {
        if (globMatch(body, segment, case_insensitive)) return true;
    }
    return false;
}

fn globMatch(pattern: []const u8, text: []const u8, case_insensitive: bool) bool {
    return globMatchFrom(pattern, 0, text, 0, case_insensitive);
}

fn globMatchFrom(pattern: []const u8, pat_index: usize, text: []const u8, text_index: usize, case_insensitive: bool) bool {
    if (pat_index == pattern.len) return text_index == text.len;

    if (pattern[pat_index] == '*') {
        var next_pat = pat_index;
        while (next_pat < pattern.len and pattern[next_pat] == '*') : (next_pat += 1) {}
        if (next_pat == pattern.len) return true;

        var i = text_index;
        while (i <= text.len) : (i += 1) {
            if (globMatchFrom(pattern, next_pat, text, i, case_insensitive)) return true;
        }
        return false;
    }

    if (text_index == text.len) return false;
    if (!bytesEqual(pattern[pat_index], text[text_index], case_insensitive)) return false;
    return globMatchFrom(pattern, pat_index + 1, text, text_index + 1, case_insensitive);
}

fn bytesEqual(a: u8, b: u8, case_insensitive: bool) bool {
    if (!case_insensitive) return a == b;
    return std.ascii.toLower(a) == std.ascii.toLower(b);
}

test "allowsPath defaults to true with no globs" {
    const testing = std.testing;

    try testing.expect(allowsPath(&.{}, "src/main.zig"));
}

test "allowsPathStrings preserves existing case-sensitive behavior" {
    const testing = std.testing;

    try testing.expect(allowsPathStrings(&.{"*.zig"}, "src/main.zig"));
    try testing.expect(!allowsPathStrings(&.{"*.zig"}, "src/Main.ZIG"));
    try testing.expect(!allowsPathStrings(&.{"*.zig", "!main.zig"}, "src/main.zig"));
}

test "allowsPath uses positive globs as an allow-list" {
    const testing = std.testing;

    try testing.expect(allowsPath(&.{.{ .pattern = "*.zig" }}, "src/main.zig"));
    try testing.expect(!allowsPath(&.{.{ .pattern = "*.zig" }}, "README.md"));
}

test "allowsPath supports excluded globs with bang prefix" {
    const testing = std.testing;

    try testing.expect(allowsPath(&.{ .{ .pattern = "*.zig" }, .{ .pattern = "!main.zig" } }, "src/lib.zig"));
    try testing.expect(!allowsPath(&.{ .{ .pattern = "*.zig" }, .{ .pattern = "!main.zig" } }, "src/main.zig"));
}

test "allowsPath supports case-insensitive globs" {
    const testing = std.testing;

    try testing.expect(allowsPath(&.{.{ .pattern = "*.zig", .case_insensitive = true }}, "src/Main.ZIG"));
    try testing.expect(!allowsPath(&.{.{ .pattern = "*.zig" }}, "src/Main.ZIG"));
}

test "allowsPath preserves mixed glob ordering across sensitivity modes" {
    const testing = std.testing;

    try testing.expect(allowsPath(&.{
        .{ .pattern = "*.ZIG", .case_insensitive = true },
        .{ .pattern = "!main.zig" },
    }, "src/Main.ZIG"));
    try testing.expect(!allowsPath(&.{
        .{ .pattern = "*.ZIG", .case_insensitive = true },
        .{ .pattern = "!Main.ZIG", .case_insensitive = true },
    }, "src/Main.ZIG"));
}

test "matchesPathPattern supports anchored full-path globs" {
    const testing = std.testing;

    try testing.expect(matchesPathPattern("/src/*.zig", "src/main.zig", false));
    try testing.expect(!matchesPathPattern("/src/*.zig", "pkg/src/main.zig", false));
}
