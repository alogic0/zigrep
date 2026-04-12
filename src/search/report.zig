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

pub const DisplayBlock = struct {
    start_line_index: usize,
    end_line_index: usize,
    line_start: usize,
    line_end: usize,
    block_span: Span,
    match_span: Span,
};

pub const DisplayBlockInfo = struct {
    line_number: usize,
    // Multiline columns stay byte-oriented and are anchored to the first
    // matched line. This matches the current single-line column convention and
    // gives later output modes a stable default.
    column_number: usize,
    block: DisplayBlock,
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

pub fn projectMatchToDisplayBlock(haystack: []const u8, line_spans: []const Span, match_span: Span) DisplayBlock {
    std.debug.assert(line_spans.len != 0);

    const start_line_index = findLineIndexForOffset(line_spans, @min(match_span.start, haystack.len));
    const end_offset = if (match_span.end > match_span.start)
        match_span.end - 1
    else
        @min(match_span.end, haystack.len);
    const end_line_index = findLineIndexForOffset(line_spans, end_offset);

    return .{
        .start_line_index = start_line_index,
        .end_line_index = end_line_index,
        .line_start = line_spans[start_line_index].start,
        .line_end = line_spans[end_line_index].end,
        .block_span = .{
            .start = line_spans[start_line_index].start,
            .end = line_spans[end_line_index].end,
        },
        .match_span = match_span,
    };
}

pub fn deriveDisplayBlockInfo(haystack: []const u8, line_spans: []const Span, match_span: Span) DisplayBlockInfo {
    const block = projectMatchToDisplayBlock(haystack, line_spans, match_span);
    const first_line = line_spans[block.start_line_index];

    return .{
        .line_number = block.start_line_index + 1,
        .column_number = (match_span.start - first_line.start) + 1,
        .block = block,
    };
}

pub fn mergeDisplayBlocksAlloc(
    allocator: std.mem.Allocator,
    blocks: []const DisplayBlock,
) ![]DisplayBlock {
    if (blocks.len == 0) return allocator.alloc(DisplayBlock, 0);

    var merged: std.ArrayList(DisplayBlock) = .empty;
    defer merged.deinit(allocator);

    try merged.append(allocator, blocks[0]);
    for (blocks[1..]) |block| {
        const last = &merged.items[merged.items.len - 1];
        if (block.start_line_index <= last.end_line_index + 1) {
            last.end_line_index = @max(last.end_line_index, block.end_line_index);
            last.line_end = @max(last.line_end, block.line_end);
            last.block_span.end = @max(last.block_span.end, block.block_span.end);
            continue;
        }
        try merged.append(allocator, block);
    }

    return merged.toOwnedSlice(allocator);
}

fn findLineIndexForOffset(line_spans: []const Span, offset: usize) usize {
    for (line_spans, 0..) |line_span, index| {
        if (offset <= line_span.end) return index;
    }
    return line_spans.len - 1;
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

test "projectMatchToDisplayBlock expands a multiline match to covered lines" {
    const testing = std.testing;

    const haystack = "aaa\nabc\ndef\nzzz";
    const line_spans = try collectLineSpansAlloc(testing.allocator, haystack);
    defer testing.allocator.free(line_spans);

    const start = std.mem.indexOf(u8, haystack, "abc").?;
    const block = projectMatchToDisplayBlock(haystack, line_spans, .{
        .start = start,
        .end = start + "abc\ndef".len,
    });

    try testing.expectEqual(@as(usize, 1), block.start_line_index);
    try testing.expectEqual(@as(usize, 2), block.end_line_index);
    try testing.expectEqualStrings("abc\ndef", haystack[block.block_span.start..block.block_span.end]);
}

test "projectMatchToDisplayBlock keeps zero-width matches on one line" {
    const testing = std.testing;

    const haystack = "one\ntwo";
    const line_spans = try collectLineSpansAlloc(testing.allocator, haystack);
    defer testing.allocator.free(line_spans);

    const block = projectMatchToDisplayBlock(haystack, line_spans, .{
        .start = 3,
        .end = 3,
    });

    try testing.expectEqual(@as(usize, 0), block.start_line_index);
    try testing.expectEqual(@as(usize, 0), block.end_line_index);
    try testing.expectEqualStrings("one", haystack[block.block_span.start..block.block_span.end]);
}

test "mergeDisplayBlocksAlloc merges overlapping and adjacent blocks" {
    const testing = std.testing;

    const input = [_]DisplayBlock{
        .{
            .start_line_index = 1,
            .end_line_index = 2,
            .line_start = 4,
            .line_end = 11,
            .block_span = .{ .start = 4, .end = 11 },
            .match_span = .{ .start = 4, .end = 10 },
        },
        .{
            .start_line_index = 2,
            .end_line_index = 3,
            .line_start = 8,
            .line_end = 15,
            .block_span = .{ .start = 8, .end = 15 },
            .match_span = .{ .start = 8, .end = 14 },
        },
        .{
            .start_line_index = 4,
            .end_line_index = 4,
            .line_start = 16,
            .line_end = 19,
            .block_span = .{ .start = 16, .end = 19 },
            .match_span = .{ .start = 16, .end = 19 },
        },
    };

    const merged = try mergeDisplayBlocksAlloc(testing.allocator, &input);
    defer testing.allocator.free(merged);

    try testing.expectEqual(@as(usize, 1), merged.len);
    try testing.expectEqual(@as(usize, 1), merged[0].start_line_index);
    try testing.expectEqual(@as(usize, 4), merged[0].end_line_index);
    try testing.expectEqual(Span{ .start = 4, .end = 19 }, merged[0].block_span);
}

test "mergeDisplayBlocksAlloc keeps disjoint blocks separate" {
    const testing = std.testing;

    const input = [_]DisplayBlock{
        .{
            .start_line_index = 0,
            .end_line_index = 0,
            .line_start = 0,
            .line_end = 3,
            .block_span = .{ .start = 0, .end = 3 },
            .match_span = .{ .start = 0, .end = 3 },
        },
        .{
            .start_line_index = 2,
            .end_line_index = 2,
            .line_start = 8,
            .line_end = 11,
            .block_span = .{ .start = 8, .end = 11 },
            .match_span = .{ .start = 8, .end = 11 },
        },
    };

    const merged = try mergeDisplayBlocksAlloc(testing.allocator, &input);
    defer testing.allocator.free(merged);

    try testing.expectEqual(@as(usize, 2), merged.len);
    try testing.expectEqual(Span{ .start = 0, .end = 3 }, merged[0].block_span);
    try testing.expectEqual(Span{ .start = 8, .end = 11 }, merged[1].block_span);
}

test "deriveDisplayBlockInfo anchors multiline columns to the first matched line" {
    const testing = std.testing;

    const haystack = "aaa\nxxabc\ndef\nzzz";
    const line_spans = try collectLineSpansAlloc(testing.allocator, haystack);
    defer testing.allocator.free(line_spans);

    const start = std.mem.indexOf(u8, haystack, "abc\ndef").?;
    const info = deriveDisplayBlockInfo(haystack, line_spans, .{
        .start = start,
        .end = start + "abc\ndef".len,
    });

    try testing.expectEqual(@as(usize, 2), info.line_number);
    try testing.expectEqual(@as(usize, 3), info.column_number);
    try testing.expectEqualStrings("xxabc\ndef", haystack[info.block.block_span.start..info.block.block_span.end]);
}

test "multiline block grouping merges overlapping projected matches" {
    const testing = std.testing;

    const haystack = "zero\nabc\ndefxxxabc\ndefxxx\nlast";
    const line_spans = try collectLineSpansAlloc(testing.allocator, haystack);
    defer testing.allocator.free(line_spans);

    const first_start = std.mem.indexOf(u8, haystack, "abc\ndef").?;
    const second_start = std.mem.indexOfPos(u8, haystack, first_start + 1, "abc\ndef").?;

    const projected = [_]DisplayBlock{
        projectMatchToDisplayBlock(haystack, line_spans, .{
            .start = first_start,
            .end = first_start + "abc\ndef".len,
        }),
        projectMatchToDisplayBlock(haystack, line_spans, .{
            .start = second_start,
            .end = second_start + "abc\ndef".len,
        }),
    };

    const merged = try mergeDisplayBlocksAlloc(testing.allocator, &projected);
    defer testing.allocator.free(merged);

    try testing.expectEqual(@as(usize, 1), merged.len);
    try testing.expectEqual(@as(usize, 1), merged[0].start_line_index);
    try testing.expectEqual(@as(usize, 3), merged[0].end_line_index);
    try testing.expectEqualStrings("abc\ndefxxxabc\ndefxxx", haystack[merged[0].block_span.start..merged[0].block_span.end]);
}

test "multiline block grouping merges adjacent projected matches without duplicated lines" {
    const testing = std.testing;

    const haystack = "one\nabc\ndef\nabc\ndef\ntail";
    const line_spans = try collectLineSpansAlloc(testing.allocator, haystack);
    defer testing.allocator.free(line_spans);

    const first_start = std.mem.indexOf(u8, haystack, "abc\ndef").?;
    const second_start = std.mem.indexOfPos(u8, haystack, first_start + 1, "abc\ndef").?;

    const projected = [_]DisplayBlock{
        projectMatchToDisplayBlock(haystack, line_spans, .{
            .start = first_start,
            .end = first_start + "abc\ndef".len,
        }),
        projectMatchToDisplayBlock(haystack, line_spans, .{
            .start = second_start,
            .end = second_start + "abc\ndef".len,
        }),
    };

    const merged = try mergeDisplayBlocksAlloc(testing.allocator, &projected);
    defer testing.allocator.free(merged);

    try testing.expectEqual(@as(usize, 1), merged.len);
    try testing.expectEqual(@as(usize, 1), merged[0].start_line_index);
    try testing.expectEqual(@as(usize, 4), merged[0].end_line_index);
    try testing.expectEqualStrings("abc\ndef\nabc\ndef", haystack[merged[0].block_span.start..merged[0].block_span.end]);
}
