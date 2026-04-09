const std = @import("std");
const regex = @import("../regex/root.zig");

pub const SearchError = regex.ParseError || regex.Nfa.CompileError || regex.Vm.MatchError || error{
    UnsupportedCaseInsensitive,
};

pub const SearchOptions = struct {
    case_insensitive: bool = false,
};

pub const Span = struct {
    start: usize,
    end: usize,
};

pub const MatchReport = struct {
    path: []const u8,
    line_number: usize,
    // Columns stay byte-oriented to match the rest of the current search layer.
    column_number: usize,
    line: []const u8,
    line_span: Span,
    match_span: Span,
};

pub fn reportFirstMatch(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    path: []const u8,
    haystack: []const u8,
    options: SearchOptions,
) SearchError!?MatchReport {
    if (options.case_insensitive) return error.UnsupportedCaseInsensitive;

    var hir = try regex.compile(allocator, pattern, .{});
    defer hir.deinit(allocator);

    const program = try regex.Nfa.compile(allocator, hir);
    defer program.deinit(allocator);

    var engine = regex.Vm.MatchEngine.init(allocator);
    const found = try engine.firstMatch(program, haystack);
    if (found) |match| {
        defer match.deinit(allocator);
        return buildReport(path, haystack, match.span);
    }

    return null;
}

fn buildReport(path: []const u8, haystack: []const u8, span: regex.Vm.Capture) MatchReport {
    std.debug.assert(span.start != null);
    std.debug.assert(span.end != null);

    const match_start = span.start.?;
    const match_end = span.end.?;
    const line_start = findLineStart(haystack, match_start);
    const line_end = findLineEnd(haystack, match_start);

    return .{
        .path = path,
        .line_number = countLines(haystack[0..line_start]) + 1,
        .column_number = (match_start - line_start) + 1,
        .line = haystack[line_start..line_end],
        .line_span = .{
            .start = line_start,
            .end = line_end,
        },
        .match_span = .{
            .start = match_start,
            .end = match_end,
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

test "reportFirstMatch returns line-oriented match data" {
    const testing = std.testing;

    const haystack = "first line\nzzzabcqq\nthird line\n";
    const report = (try reportFirstMatch(testing.allocator, "abc", "sample.txt", haystack, .{})).?;

    try testing.expectEqualStrings("sample.txt", report.path);
    try testing.expectEqual(@as(usize, 2), report.line_number);
    try testing.expectEqual(@as(usize, 4), report.column_number);
    try testing.expectEqualStrings("zzzabcqq", report.line);
    try testing.expectEqual(Span{ .start = 11, .end = 19 }, report.line_span);
    try testing.expectEqual(Span{ .start = 14, .end = 17 }, report.match_span);
}

test "reportFirstMatch handles matches on the first line" {
    const testing = std.testing;

    const haystack = "abc on line one\nsecond line\n";
    const report = (try reportFirstMatch(testing.allocator, "abc", "first.txt", haystack, .{})).?;

    try testing.expectEqual(@as(usize, 1), report.line_number);
    try testing.expectEqual(@as(usize, 1), report.column_number);
    try testing.expectEqualStrings("abc on line one", report.line);
    try testing.expectEqual(Span{ .start = 0, .end = 15 }, report.line_span);
    try testing.expectEqual(Span{ .start = 0, .end = 3 }, report.match_span);
}

test "reportFirstMatch returns null when no match exists" {
    const testing = std.testing;

    try testing.expect((try reportFirstMatch(testing.allocator, "needle", "missing.txt", "haystack", .{})) == null);
}

test "reportFirstMatch rejects unsupported case-insensitive search for now" {
    const testing = std.testing;

    try testing.expectError(error.UnsupportedCaseInsensitive, reportFirstMatch(
        testing.allocator,
        "abc",
        "sample.txt",
        "ABC",
        .{ .case_insensitive = true },
    ));
}
