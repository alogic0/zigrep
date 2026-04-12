const std = @import("std");

pub fn allowsPath(globs: []const []const u8, path: []const u8) bool {
    if (globs.len == 0) return true;

    var has_positive = false;
    for (globs) |glob| {
        if (glob.len != 0 and glob[0] != '!') {
            has_positive = true;
            break;
        }
    }

    var allowed = !has_positive;
    for (globs) |glob| {
        if (glob.len == 0) continue;

        const excluded = glob[0] == '!';
        const pattern = if (excluded) glob[1..] else glob;
        if (pattern.len == 0) continue;
        if (!matchesPathPattern(pattern, path)) continue;
        allowed = !excluded;
    }

    return allowed;
}

pub fn matchesPathPattern(pattern: []const u8, path: []const u8) bool {
    if (pattern.len == 0) return path.len == 0;

    var body = pattern;
    var anchored = false;
    if (body[0] == '/') {
        anchored = true;
        body = body[1..];
    }
    if (body.len == 0) return false;

    if (anchored) return globMatch(body, path);
    if (globMatch(body, path)) return true;

    var iter = std.mem.splitScalar(u8, path, std.fs.path.sep);
    while (iter.next()) |segment| {
        if (globMatch(body, segment)) return true;
    }
    return false;
}

fn globMatch(pattern: []const u8, text: []const u8) bool {
    return globMatchFrom(pattern, 0, text, 0);
}

fn globMatchFrom(pattern: []const u8, pat_index: usize, text: []const u8, text_index: usize) bool {
    if (pat_index == pattern.len) return text_index == text.len;

    if (pattern[pat_index] == '*') {
        var next_pat = pat_index;
        while (next_pat < pattern.len and pattern[next_pat] == '*') : (next_pat += 1) {}
        if (next_pat == pattern.len) return true;

        var i = text_index;
        while (i <= text.len) : (i += 1) {
            if (globMatchFrom(pattern, next_pat, text, i)) return true;
        }
        return false;
    }

    if (text_index == text.len) return false;
    if (pattern[pat_index] != text[text_index]) return false;
    return globMatchFrom(pattern, pat_index + 1, text, text_index + 1);
}

test "allowsPath defaults to true with no globs" {
    const testing = std.testing;

    try testing.expect(allowsPath(&.{}, "src/main.zig"));
}

test "allowsPath uses positive globs as an allow-list" {
    const testing = std.testing;

    try testing.expect(allowsPath(&.{"*.zig"}, "src/main.zig"));
    try testing.expect(!allowsPath(&.{"*.zig"}, "README.md"));
}

test "allowsPath supports excluded globs with bang prefix" {
    const testing = std.testing;

    try testing.expect(allowsPath(&.{ "*.zig", "!main.zig" }, "src/lib.zig"));
    try testing.expect(!allowsPath(&.{ "*.zig", "!main.zig" }, "src/main.zig"));
}

test "matchesPathPattern supports anchored full-path globs" {
    const testing = std.testing;

    try testing.expect(matchesPathPattern("/src/*.zig", "src/main.zig"));
    try testing.expect(!matchesPathPattern("/src/*.zig", "pkg/src/main.zig"));
}
