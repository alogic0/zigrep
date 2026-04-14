const std = @import("std");
const zigrep = struct {
    pub const search = @import("search/root.zig");
};
const command = @import("command.zig");
const search_output = @import("search_output.zig");
const search_reporting_multiline = @import("search_reporting_multiline.zig");
const search_reporting_types = @import("search_reporting_types.zig");

pub const OutputOptions = command.OutputOptions;
pub const OutputFormat = command.OutputFormat;
pub const ReportSummary = search_reporting_types.ReportSummary;

pub fn writeBinaryFileMatchNotice(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    searcher: *zigrep.search.grep.Searcher,
    path: []const u8,
    bytes: []const u8,
    encoding: zigrep.search.io.InputEncoding,
    invert_match: bool,
) !ReportSummary {
    const has_match = if (invert_match)
        try countInvertedLines(allocator, searcher, path, bytes, encoding, null) != 0
    else
        (try reportFileMatch(allocator, searcher, path, bytes, encoding)) != null;
    if (!has_match) return .{};
    const binary_offset = zigrep.search.io.firstBinaryOffset(bytes, .{}) orelse 0;
    try search_output.writeBinaryMatchNotice(writer, binary_offset);
    return .{ .matched = true };
}

pub fn writeFileCount(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    searcher: *zigrep.search.grep.Searcher,
    path: []const u8,
    bytes: []const u8,
    encoding: zigrep.search.io.InputEncoding,
    invert_match: bool,
    output: OutputOptions,
    output_format: OutputFormat,
    max_count: ?usize,
) !ReportSummary {
    if (max_count != null and searcher.program.can_match_newline) return error.InvalidFlagCombination;

    const IterationStop = error{MaxCountReached};

    const Counter = struct {
        count: usize = 0,
        max_count: ?usize,

        fn emit(self: *@This(), report: zigrep.search.grep.MatchReport) !void {
            _ = report;
            self.count += 1;
            if (self.max_count) |limit| {
                if (self.count >= limit) return IterationStop.MaxCountReached;
            }
        }
    };

    var counter = Counter{ .max_count = max_count };

    if (invert_match) {
        const count = try countInvertedLines(allocator, searcher, path, bytes, encoding, max_count);
        if (count == 0) return .{};
        switch (output_format) {
            .text => if (output.with_filename) {
                try writer.print("{s}:{d}\n", .{ path, count });
            } else {
                try writer.print("{d}\n", .{count});
            },
            .json => try search_output.writeJsonCountEvent(writer, path, count),
        }
        return .{ .matched = true };
    }

    if (try zigrep.search.io.decodeToUtf8Alloc(allocator, bytes, encoding)) |decoded| {
        defer allocator.free(decoded);
        if (searcher.program.can_match_newline) {
            return search_reporting_multiline.writeFileCountMultiline(allocator, writer, searcher, path, decoded, output_format);
        }
        _ = searcher.forEachLineReport(path, decoded, &counter, Counter.emit) catch |err| switch (err) {
            IterationStop.MaxCountReached => true,
            else => return err,
        };
    } else {
        if (searcher.program.can_match_newline) {
            return search_reporting_multiline.writeFileCountMultiline(allocator, writer, searcher, path, bytes, output_format);
        }
        _ = searcher.forEachLineReport(path, bytes, &counter, Counter.emit) catch |err| switch (err) {
            IterationStop.MaxCountReached => true,
            else => return err,
        };
    }

    if (counter.count == 0) return .{};
    switch (output_format) {
        .text => if (output.with_filename) {
            try writer.print("{s}:{d}\n", .{ path, counter.count });
        } else {
            try writer.print("{d}\n", .{counter.count});
        },
        .json => try search_output.writeJsonCountEvent(writer, path, counter.count),
    }
    return .{ .matched = true };
}

pub fn writeFilePathOnMatch(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    searcher: *zigrep.search.grep.Searcher,
    path: []const u8,
    bytes: []const u8,
    encoding: zigrep.search.io.InputEncoding,
    invert_match: bool,
    output: OutputOptions,
    output_format: OutputFormat,
) !ReportSummary {
    if (invert_match) {
        if (try countInvertedLines(allocator, searcher, path, bytes, encoding, null) == 0) return .{};
    } else {
        const report = try reportFileMatch(allocator, searcher, path, bytes, encoding) orelse return .{};
        defer report.deinit(allocator);
    }
    switch (output_format) {
        .text => try search_output.writePathResult(writer, path, output),
        .json => try search_output.writeJsonPathEvent(writer, path, true),
    }
    return .{ .matched = true };
}

pub fn writeFilePathWithoutMatch(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    searcher: *zigrep.search.grep.Searcher,
    path: []const u8,
    bytes: []const u8,
    encoding: zigrep.search.io.InputEncoding,
    invert_match: bool,
    output: OutputOptions,
    output_format: OutputFormat,
) !ReportSummary {
    if (invert_match) {
        if (try countInvertedLines(allocator, searcher, path, bytes, encoding, null) != 0) return .{};
    } else {
        const report = try reportFileMatch(allocator, searcher, path, bytes, encoding);
        if (report) |found| {
            found.deinit(allocator);
            return .{};
        }
    }
    switch (output_format) {
        .text => try search_output.writePathResult(writer, path, output),
        .json => try search_output.writeJsonPathEvent(writer, path, false),
    }
    return .{ .matched = true };
}

pub fn reportFileMatch(
    allocator: std.mem.Allocator,
    searcher: *zigrep.search.grep.Searcher,
    path: []const u8,
    bytes: []const u8,
    encoding: zigrep.search.io.InputEncoding,
) !?zigrep.search.grep.MatchReport {
    if (try zigrep.search.io.decodeToUtf8Alloc(allocator, bytes, encoding)) |decoded| {
        defer allocator.free(decoded);
        if (try searcher.reportFirstMatch(path, decoded)) |report| {
            const owned_line = try allocator.dupe(u8, report.line);
            var stable = report;
            stable.line = owned_line;
            stable.owned_line = owned_line;
            return stable;
        }
        return null;
    }

    return searcher.reportFirstMatch(path, bytes);
}

fn countInvertedLines(
    allocator: std.mem.Allocator,
    searcher: *zigrep.search.grep.Searcher,
    path: []const u8,
    bytes: []const u8,
    encoding: zigrep.search.io.InputEncoding,
    max_count: ?usize,
) !usize {
    const haystack = if (try zigrep.search.io.decodeToUtf8Alloc(allocator, bytes, encoding)) |decoded|
        decoded
    else
        bytes;
    defer if (haystack.ptr != bytes.ptr) allocator.free(haystack);

    const line_spans = try zigrep.search.report.collectLineSpansAlloc(allocator, haystack);
    defer allocator.free(line_spans);

    var count: usize = 0;
    for (line_spans) |line_span| {
        const line = haystack[line_span.start..line_span.end];
        const is_match = (try searcher.reportFirstMatch(path, line)) != null;
        if (is_match) continue;
        count += 1;
        if (max_count) |limit| {
            if (count >= limit) break;
        }
    }
    return count;
}
