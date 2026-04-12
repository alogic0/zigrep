const std = @import("std");

pub const Span = struct {
    start: usize,
    end: usize,
};

pub const LineInfo = struct {
    line_number: usize,
    column_number: usize,
    line_span: Span,
};

pub fn collectLineSpansAlloc(allocator: std.mem.Allocator, haystack: []const u8) ![]Span {
    var spans: std.ArrayList(Span) = .empty;
    defer spans.deinit(allocator);

    var line_start: usize = 0;
    var index: usize = 0;
    while (index < haystack.len) : (index += 1) {
        if (haystack[index] == '\n') {
            try spans.append(allocator, .{
                .start = line_start,
                .end = index,
            });
            line_start = index + 1;
        }
    }

    if (line_start < haystack.len or haystack.len == 0 or (haystack.len > 0 and haystack[haystack.len - 1] != '\n')) {
        try spans.append(allocator, .{
            .start = line_start,
            .end = haystack.len,
        });
    }

    return spans.toOwnedSlice(allocator);
}

pub fn deriveLineInfo(haystack: []const u8, offset: usize) LineInfo {
    const clamped = @min(offset, haystack.len);
    const line_start = findLineStart(haystack, clamped);
    const line_end = findLineEnd(haystack, clamped);

    // The CLI reports matching lines by rescanning from each emitted line, so a
    // full line index is still not worth the extra complexity yet.
    return .{
        .line_number = countLines(haystack[0..line_start]) + 1,
        .column_number = (clamped - line_start) + 1,
        .line_span = .{
            .start = line_start,
            .end = line_end,
        },
    };
}

fn findLineStart(haystack: []const u8, offset: usize) usize {
    var index = @min(offset, haystack.len);
    while (index > 0) {
        if (haystack[index - 1] == '\n') break;
        index -= 1;
    }
    return index;
}

fn findLineEnd(haystack: []const u8, offset: usize) usize {
    var index = @min(offset, haystack.len);
    while (index < haystack.len) : (index += 1) {
        if (haystack[index] == '\n') break;
    }
    return index;
}

fn countLines(bytes: []const u8) usize {
    return std.mem.count(u8, bytes, "\n");
}

test "deriveLineInfo handles empty haystack" {
    const testing = std.testing;

    const info = deriveLineInfo("", 0);
    try testing.expectEqual(@as(usize, 1), info.line_number);
    try testing.expectEqual(@as(usize, 1), info.column_number);
    try testing.expectEqual(Span{ .start = 0, .end = 0 }, info.line_span);
}

test "deriveLineInfo handles missing trailing newline" {
    const testing = std.testing;

    const haystack = "first line\nsecond line";
    const offset = std.mem.indexOf(u8, haystack, "second").?;
    const info = deriveLineInfo(haystack, offset);

    try testing.expectEqual(@as(usize, 2), info.line_number);
    try testing.expectEqual(@as(usize, 1), info.column_number);
    try testing.expectEqualStrings("second line", haystack[info.line_span.start..info.line_span.end]);
}

test "deriveLineInfo handles very long lines" {
    const testing = std.testing;

    var haystack: [4102]u8 = undefined;
    @memset(haystack[0..4096], 'a');
    @memcpy(haystack[4096..], "needle");
    const offset = haystack.len - "needle".len;
    const info = deriveLineInfo(haystack[0..], offset);

    try testing.expectEqual(@as(usize, 1), info.line_number);
    try testing.expectEqual(@as(usize, 4097), info.column_number);
    try testing.expectEqual(@as(usize, 0), info.line_span.start);
    try testing.expectEqual(haystack.len, info.line_span.end);
}

test "deriveLineInfo handles matches late in large files" {
    const testing = std.testing;

    const haystack =
        "line1\n" ++
        "line2\n" ++
        "line3\n" ++
        "line4\n" ++
        "line5\n" ++
        "late needle here\n";
    const offset = std.mem.indexOf(u8, haystack, "needle").?;
    const info = deriveLineInfo(haystack, offset);

    try testing.expectEqual(@as(usize, 6), info.line_number);
    try testing.expectEqual(@as(usize, 6), info.column_number);
    try testing.expectEqualStrings("late needle here", haystack[info.line_span.start..info.line_span.end]);
}

test "collectLineSpansAlloc handles empty haystack" {
    const testing = std.testing;

    const spans = try collectLineSpansAlloc(testing.allocator, "");
    defer testing.allocator.free(spans);

    try testing.expectEqual(@as(usize, 1), spans.len);
    try testing.expectEqual(Span{ .start = 0, .end = 0 }, spans[0]);
}

test "collectLineSpansAlloc handles trailing newline" {
    const testing = std.testing;

    const spans = try collectLineSpansAlloc(testing.allocator, "one\ntwo\n");
    defer testing.allocator.free(spans);

    try testing.expectEqual(@as(usize, 2), spans.len);
    try testing.expectEqual(Span{ .start = 0, .end = 3 }, spans[0]);
    try testing.expectEqual(Span{ .start = 4, .end = 7 }, spans[1]);
}

test "collectLineSpansAlloc handles missing trailing newline" {
    const testing = std.testing;

    const spans = try collectLineSpansAlloc(testing.allocator, "one\ntwo");
    defer testing.allocator.free(spans);

    try testing.expectEqual(@as(usize, 2), spans.len);
    try testing.expectEqual(Span{ .start = 0, .end = 3 }, spans[0]);
    try testing.expectEqual(Span{ .start = 4, .end = 7 }, spans[1]);
}
