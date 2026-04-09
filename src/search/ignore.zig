const std = @import("std");

pub const Rule = struct {
    pattern: []const u8,
    negated: bool = false,
    directory_only: bool = false,
    anchored: bool = false,

    pub fn deinit(self: Rule, allocator: std.mem.Allocator) void {
        allocator.free(self.pattern);
    }
};

pub const MatchInput = struct {
    path: []const u8,
    is_directory: bool = false,
};

pub const IgnoreMatcher = struct {
    rules: []Rule,

    pub fn deinit(self: IgnoreMatcher, allocator: std.mem.Allocator) void {
        for (self.rules) |rule| rule.deinit(allocator);
        allocator.free(self.rules);
    }

    pub fn matches(self: IgnoreMatcher, input: MatchInput) bool {
        var ignored = false;
        for (self.rules) |rule| {
            if (rule.directory_only and !input.is_directory) continue;
            if (!matchesRule(rule, input.path)) continue;
            ignored = !rule.negated;
        }
        return ignored;
    }
};

pub fn compile(allocator: std.mem.Allocator, contents: []const u8) !IgnoreMatcher {
    var rules: std.ArrayList(Rule) = .empty;
    errdefer {
        for (rules.items) |rule| rule.deinit(allocator);
        rules.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        var body = line;
        var negated = false;
        if (body[0] == '!') {
            negated = true;
            body = body[1..];
            if (body.len == 0) continue;
        }

        var anchored = false;
        if (body[0] == '/') {
            anchored = true;
            body = body[1..];
        }

        var directory_only = false;
        if (body.len > 0 and body[body.len - 1] == '/') {
            directory_only = true;
            body = body[0 .. body.len - 1];
        }

        if (body.len == 0) continue;

        try rules.append(allocator, .{
            .pattern = try allocator.dupe(u8, body),
            .negated = negated,
            .directory_only = directory_only,
            .anchored = anchored,
        });
    }

    return .{ .rules = try rules.toOwnedSlice(allocator) };
}

fn matchesRule(rule: Rule, path: []const u8) bool {
    if (rule.anchored) return globMatch(rule.pattern, path);

    if (globMatch(rule.pattern, path)) return true;

    var iter = std.mem.splitScalar(u8, path, std.fs.path.sep);
    while (iter.next()) |segment| {
        if (globMatch(rule.pattern, segment)) return true;
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

test "ignore matcher parses comments, negation, and directory-only rules" {
    const testing = std.testing;

    const matcher = try compile(testing.allocator,
        \\# comment
        \\target/
        \\*.log
        \\!keep.log
    );
    defer matcher.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), matcher.rules.len);
    try testing.expect(matcher.rules[0].directory_only);
    try testing.expect(!matcher.rules[1].negated);
    try testing.expect(matcher.rules[2].negated);
}

test "ignore matcher applies last-match semantics" {
    const testing = std.testing;

    const matcher = try compile(testing.allocator,
        \\*.log
        \\!keep.log
    );
    defer matcher.deinit(testing.allocator);

    try testing.expect(matcher.matches(.{ .path = "debug.log" }));
    try testing.expect(!matcher.matches(.{ .path = "keep.log" }));
}

test "ignore matcher supports anchored and segment rules" {
    const testing = std.testing;

    const matcher = try compile(testing.allocator,
        \\/build/*
        \\node_modules
    );
    defer matcher.deinit(testing.allocator);

    try testing.expect(matcher.matches(.{ .path = "build/out.txt" }));
    try testing.expect(!matcher.matches(.{ .path = "src/build/out.txt" }));
    try testing.expect(matcher.matches(.{ .path = "web/node_modules/package.json" }));
}
