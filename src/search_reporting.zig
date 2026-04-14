const std = @import("std");
const zigrep = struct {
    pub const search = @import("search/root.zig");
};
const regex = @import("regex/root.zig");
const command = @import("command.zig");
const search_output = @import("search_output.zig");

// Reporting and output shaping.
// This module owns line, multiline, context, count, path-only, and match
// reporting over already-selected haystacks.

const OutputOptions = command.OutputOptions;
const OutputFormat = command.OutputFormat;
const ReportMode = command.ReportMode;
const ReplacementSegment = search_output.ReplacementSegment;
const DisplayMode = search_output.DisplayMode;

pub const ReportSummary = struct {
    matched: bool = false,
    matched_lines: usize = 0,
    matches: usize = 0,
};

const ReplacedLine = struct {
    line_number: usize,
    column_number: usize,
    line: []const u8,
    line_span: zigrep.search.report.Span,
    segments: []ReplacementSegment,
};
pub fn writeFileReports(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    searcher: *zigrep.search.grep.Searcher,
    path: []const u8,
    bytes: []const u8,
    encoding: zigrep.search.io.InputEncoding,
    output: OutputOptions,
    output_format: OutputFormat,
    max_count: ?usize,
    display_mode: DisplayMode,
) !ReportSummary {
    if (output.replacement != null and output.only_matching) {
        return writeFileOnlyMatchingReplacement(allocator, writer, searcher, path, bytes, encoding, output, max_count, display_mode);
    }
    if (output.replacement != null and !output.only_matching) {
        return writeFileReportsReplacing(allocator, writer, searcher, path, bytes, encoding, output, max_count, display_mode);
    }
    if (output.only_matching) {
        std.debug.assert(max_count == null or max_count.? > 0);
    }
    const IterationStop = error{MaxCountReached};

    const WriterContext = struct {
        allocator: std.mem.Allocator,
        writer: *std.Io.Writer,
        output: OutputOptions,
        output_format: OutputFormat,
        max_count: ?usize,
        display_mode: DisplayMode,
        matched_lines: usize = 0,
        matches: usize = 0,
        last_line_start: ?usize = null,

        fn emit(self: *@This(), report: zigrep.search.grep.MatchReport) !void {
            if (self.output.only_matching) {
                if (self.last_line_start == null or self.last_line_start.? != report.line_span.start) {
                    if (self.max_count) |limit| {
                        if (self.matched_lines >= limit) return IterationStop.MaxCountReached;
                    }
                    self.matched_lines += 1;
                    self.last_line_start = report.line_span.start;
                }
            } else {
                if (self.max_count) |limit| {
                    if (self.matched_lines >= limit) return IterationStop.MaxCountReached;
                }
                self.matched_lines += 1;
            }
            if (report.owned_line) |line| {
                defer self.allocator.free(line);
            }
            self.matches += 1;
            switch (self.output_format) {
                .text => try search_output.writeReport(self.writer, report, self.output, self.display_mode),
                .json => try search_output.writeJsonMatchEvent(self.writer, report, self.output),
            }
        }
    };

    var context = WriterContext{
        .allocator = allocator,
        .writer = writer,
        .output = .{},
        .output_format = output_format,
        .max_count = max_count,
        .display_mode = display_mode,
    };
    context.output = output;

    if (try zigrep.search.io.decodeToUtf8Alloc(allocator, bytes, encoding)) |decoded| {
        defer allocator.free(decoded);
        if (output.only_matching) {
            _ = searcher.forEachMatchReport(path, decoded, &context, WriterContext.emit) catch |err| switch (err) {
                IterationStop.MaxCountReached => .{
                    .matched = context.matches != 0,
                    .matched_lines = context.matched_lines,
                    .matches = context.matches,
                },
                else => return err,
            };
            return .{
                .matched = context.matches != 0,
                .matched_lines = context.matched_lines,
                .matches = context.matches,
            };
        }
        _ = searcher.forEachLineReport(path, decoded, &context, WriterContext.emit) catch |err| switch (err) {
            IterationStop.MaxCountReached => .{
                .matched = context.matches != 0,
                .matched_lines = context.matched_lines,
                .matches = context.matches,
            },
            else => return err,
        };
        return .{
            .matched = context.matches != 0,
            .matched_lines = context.matched_lines,
            .matches = context.matches,
        };
    }

    if (output.only_matching) {
        _ = searcher.forEachMatchReport(path, bytes, &context, WriterContext.emit) catch |err| switch (err) {
            IterationStop.MaxCountReached => .{
                .matched = context.matches != 0,
                .matched_lines = context.matched_lines,
                .matches = context.matches,
            },
            else => return err,
        };
        return .{
            .matched = context.matches != 0,
            .matched_lines = context.matched_lines,
            .matches = context.matches,
        };
    }

    _ = searcher.forEachLineReport(path, bytes, &context, WriterContext.emit) catch |err| switch (err) {
        IterationStop.MaxCountReached => .{
            .matched = context.matches != 0,
            .matched_lines = context.matched_lines,
            .matches = context.matches,
        },
        else => return err,
    };
    return .{
        .matched = context.matches != 0,
        .matched_lines = context.matched_lines,
        .matches = context.matches,
    };
}

fn writeFileReportsReplacing(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    searcher: *zigrep.search.grep.Searcher,
    path: []const u8,
    bytes: []const u8,
    encoding: zigrep.search.io.InputEncoding,
    output: OutputOptions,
    max_count: ?usize,
    display_mode: DisplayMode,
 ) !ReportSummary {
    const haystack = if (try zigrep.search.io.decodeToUtf8Alloc(allocator, bytes, encoding)) |decoded|
        decoded
    else
        bytes;
    defer if (haystack.ptr != bytes.ptr) allocator.free(haystack);

    var lines: std.ArrayList(ReplacedLine) = .empty;
    defer {
        for (lines.items) |line| {
            for (line.segments) |segment| allocator.free(segment.replacement);
            allocator.free(line.segments);
        }
        lines.deinit(allocator);
    }

    const Collector = struct {
        allocator: std.mem.Allocator,
        lines: *std.ArrayList(ReplacedLine),
        max_count: ?usize,
        replacement_template: []const u8,
        capture_names: []const ?[]const u8,

        fn emit(self: *@This(), captured: zigrep.search.grep.CapturedMatchReport) !void {
            const report = captured.report;
            const replacement = try expandReplacementAlloc(
                self.allocator,
                self.replacement_template,
                report.match_span,
                captured.groups,
                self.capture_names,
                report.line,
                report.line_span.start,
            );
            if (self.lines.items.len != 0 and self.lines.items[self.lines.items.len - 1].line_span.start == report.line_span.start) {
                var current = &self.lines.items[self.lines.items.len - 1];
                current.segments = try self.allocator.realloc(current.segments, current.segments.len + 1);
                current.segments[current.segments.len - 1] = .{
                    .match_span = report.match_span,
                    .replacement = replacement,
                };
                return;
            }

            if (self.max_count) |limit| {
                if (self.lines.items.len >= limit) {
                    self.allocator.free(replacement);
                    return error.MaxCountReached;
                }
            }

            const segments = try self.allocator.alloc(ReplacementSegment, 1);
            segments[0] = .{
                .match_span = report.match_span,
                .replacement = replacement,
            };
            try self.lines.append(self.allocator, .{
                .line_number = report.line_number,
                .column_number = report.column_number,
                .line = report.line,
                .line_span = report.line_span,
                .segments = segments,
            });
        }
    };

    var collector = Collector{
        .allocator = allocator,
        .lines = &lines,
        .max_count = max_count,
        .replacement_template = output.replacement.?,
        .capture_names = searcher.captureNames(),
    };

    _ = searcher.forEachCapturedMatchReport(path, haystack, &collector, Collector.emit) catch |err| switch (err) {
        error.MaxCountReached => true,
        else => return err,
    };

    if (lines.items.len == 0) return .{};

    for (lines.items) |line| {
        try search_output.writeReplacedLine(
            writer,
            path,
            line.line_number,
            line.column_number,
            line.line,
            line.line_span.start,
            line.segments,
            output,
            display_mode,
        );
    }
    var match_count: usize = 0;
    for (lines.items) |line| match_count += line.segments.len;
    return .{
        .matched = true,
        .matched_lines = lines.items.len,
        .matches = match_count,
    };
}

fn writeFileOnlyMatchingReplacement(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    searcher: *zigrep.search.grep.Searcher,
    path: []const u8,
    bytes: []const u8,
    encoding: zigrep.search.io.InputEncoding,
    output: OutputOptions,
    max_count: ?usize,
    display_mode: DisplayMode,
) !ReportSummary {
    const haystack = if (try zigrep.search.io.decodeToUtf8Alloc(allocator, bytes, encoding)) |decoded|
        decoded
    else
        bytes;
    defer if (haystack.ptr != bytes.ptr) allocator.free(haystack);

    const IterationStop = error{MaxCountReached};

    const WriterContext = struct {
        allocator: std.mem.Allocator,
        writer: *std.Io.Writer,
        output: OutputOptions,
        max_count: ?usize,
        capture_names: []const ?[]const u8,
        display_mode: DisplayMode,
        matched_lines: usize = 0,
        matches: usize = 0,
        last_line_start: ?usize = null,

        fn emit(self: *@This(), captured: zigrep.search.grep.CapturedMatchReport) !void {
            const report = captured.report;
            if (self.last_line_start == null or self.last_line_start.? != report.line_span.start) {
                if (self.max_count) |limit| {
                    if (self.matched_lines >= limit) return IterationStop.MaxCountReached;
                }
                self.matched_lines += 1;
                self.last_line_start = report.line_span.start;
            }

            const replacement = try expandReplacementAlloc(
                self.allocator,
                self.output.replacement.?,
                report.match_span,
                captured.groups,
                self.capture_names,
                report.line,
                report.line_span.start,
            );
            defer self.allocator.free(replacement);
            self.matches += 1;

            var effective_output = self.output;
            effective_output.replacement = null;
            try search_output.writePrefixedDisplayBytes(
                self.writer,
                report.path,
                report.line_number,
                report.column_number,
                replacement,
                effective_output,
                false,
                self.display_mode,
            );
        }
    };

    var context = WriterContext{
        .allocator = allocator,
        .writer = writer,
        .output = output,
        .max_count = max_count,
        .capture_names = searcher.captureNames(),
        .display_mode = display_mode,
    };

    _ = searcher.forEachCapturedMatchReport(path, haystack, &context, WriterContext.emit) catch |err| switch (err) {
        IterationStop.MaxCountReached => return .{
            .matched = context.matches != 0,
            .matched_lines = context.matched_lines,
            .matches = context.matches,
        },
        else => return err,
    };
    return .{
        .matched = context.matches != 0,
        .matched_lines = context.matched_lines,
        .matches = context.matches,
    };
}

fn writeContextLine(
    writer: *std.Io.Writer,
    path: []const u8,
    line_number: usize,
    line: []const u8,
    output: OutputOptions,
    display_mode: DisplayMode,
) !void {
    var wrote_prefix = false;
    if (output.with_filename) {
        try writer.print("{s}", .{path});
        wrote_prefix = true;
    }
    if (output.line_number) {
        if (wrote_prefix) try writer.writeByte('-');
        try writer.print("{d}", .{line_number});
        wrote_prefix = true;
    }
    if (wrote_prefix) try writer.writeByte('-');
    try search_output.writeDisplayLine(writer, line, display_mode);
    try writer.writeByte('\n');
}

fn writeFileReportsWithContext(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    searcher: *zigrep.search.grep.Searcher,
    path: []const u8,
    haystack: []const u8,
    output: OutputOptions,
    max_count: ?usize,
    context_before: usize,
    context_after: usize,
    display_mode: DisplayMode,
) !ReportSummary {
    if (output.replacement != null) {
        return writeFileReportsWithContextReplacing(allocator, writer, searcher, path, haystack, output, max_count, context_before, context_after, display_mode);
    }
    const IterationStop = error{MaxCountReached};

    const MatchLine = struct {
        line_index: usize,
        report: zigrep.search.grep.MatchReport,
    };

    const Collector = struct {
        allocator: std.mem.Allocator,
        line_spans: []const zigrep.search.report.Span,
        items: *std.ArrayList(MatchLine),
        max_count: ?usize,
        next_line_index: usize = 0,

        fn emit(self: *@This(), report: zigrep.search.grep.MatchReport) !void {
            while (self.next_line_index < self.line_spans.len and
                self.line_spans[self.next_line_index].start != report.line_span.start)
            {
                self.next_line_index += 1;
            }
            if (self.next_line_index >= self.line_spans.len) return error.InvalidFlagCombination;
            try self.items.append(self.allocator, .{
                .line_index = self.next_line_index,
                .report = report,
            });
            if (self.max_count) |limit| {
                if (self.items.items.len >= limit) return IterationStop.MaxCountReached;
            }
        }
    };

    const line_spans = try zigrep.search.report.collectLineSpansAlloc(allocator, haystack);
    defer allocator.free(line_spans);

    var matched_lines: std.ArrayList(MatchLine) = .empty;
    defer matched_lines.deinit(allocator);

    var collector = Collector{
        .allocator = allocator,
        .line_spans = line_spans,
        .items = &matched_lines,
        .max_count = max_count,
    };

    _ = searcher.forEachLineReport(path, haystack, &collector, Collector.emit) catch |err| switch (err) {
        IterationStop.MaxCountReached => true,
        else => return err,
    };

    if (matched_lines.items.len == 0) return .{};

    const include = try allocator.alloc(bool, line_spans.len);
    defer allocator.free(include);
    @memset(include, false);

    const matched_indexes = try allocator.alloc(?usize, line_spans.len);
    defer allocator.free(matched_indexes);
    @memset(matched_indexes, null);

    for (matched_lines.items, 0..) |match_line, match_index| {
        matched_indexes[match_line.line_index] = match_index;
        const start = match_line.line_index -| context_before;
        const end = @min(match_line.line_index + context_after + 1, line_spans.len);
        for (start..end) |line_index| include[line_index] = true;
    }

    var previous_included: ?usize = null;
    for (line_spans, 0..) |line_span, line_index| {
        if (!include[line_index]) continue;
        if (previous_included) |prev| {
            if (line_index > prev + 1) try writer.writeAll("--\n");
        }
        previous_included = line_index;

        if (matched_indexes[line_index]) |match_index| {
            try search_output.writeReport(writer, matched_lines.items[match_index].report, output, display_mode);
        } else {
            try writeContextLine(writer, path, line_index + 1, haystack[line_span.start..line_span.end], output, display_mode);
        }
    }

    return .{
        .matched = true,
        .matched_lines = matched_lines.items.len,
        .matches = matched_lines.items.len,
    };
}

fn writeFileReportsWithContextReplacing(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    searcher: *zigrep.search.grep.Searcher,
    path: []const u8,
    haystack: []const u8,
    output: OutputOptions,
    max_count: ?usize,
    context_before: usize,
    context_after: usize,
    display_mode: DisplayMode,
) !ReportSummary {
    var matched_lines: std.ArrayList(ReplacedLine) = .empty;
    defer {
        for (matched_lines.items) |line| {
            for (line.segments) |segment| allocator.free(segment.replacement);
            allocator.free(line.segments);
        }
        matched_lines.deinit(allocator);
    }

    const Collector = struct {
        allocator: std.mem.Allocator,
        items: *std.ArrayList(ReplacedLine),
        max_count: ?usize,
        replacement_template: []const u8,
        capture_names: []const ?[]const u8,

        fn emit(self: *@This(), captured: zigrep.search.grep.CapturedMatchReport) !void {
            const report = captured.report;
            const replacement = try expandReplacementAlloc(
                self.allocator,
                self.replacement_template,
                report.match_span,
                captured.groups,
                self.capture_names,
                report.line,
                report.line_span.start,
            );
            if (self.items.items.len != 0 and self.items.items[self.items.items.len - 1].line_span.start == report.line_span.start) {
                var current = &self.items.items[self.items.items.len - 1];
                current.segments = try self.allocator.realloc(current.segments, current.segments.len + 1);
                current.segments[current.segments.len - 1] = .{
                    .match_span = report.match_span,
                    .replacement = replacement,
                };
                return;
            }

            if (self.max_count) |limit| {
                if (self.items.items.len >= limit) {
                    self.allocator.free(replacement);
                    return error.MaxCountReached;
                }
            }

            const segments = try self.allocator.alloc(ReplacementSegment, 1);
            segments[0] = .{
                .match_span = report.match_span,
                .replacement = replacement,
            };
            try self.items.append(self.allocator, .{
                .line_number = report.line_number,
                .column_number = report.column_number,
                .line = report.line,
                .line_span = report.line_span,
                .segments = segments,
            });
        }
    };

    var collector = Collector{
        .allocator = allocator,
        .items = &matched_lines,
        .max_count = max_count,
        .replacement_template = output.replacement.?,
        .capture_names = searcher.captureNames(),
    };

    _ = searcher.forEachCapturedMatchReport(path, haystack, &collector, Collector.emit) catch |err| switch (err) {
        error.MaxCountReached => true,
        else => return err,
    };

    if (matched_lines.items.len == 0) return .{};

    const line_spans = try zigrep.search.report.collectLineSpansAlloc(allocator, haystack);
    defer allocator.free(line_spans);

    const include = try allocator.alloc(bool, line_spans.len);
    defer allocator.free(include);
    @memset(include, false);

    const matched_indexes = try allocator.alloc(?usize, line_spans.len);
    defer allocator.free(matched_indexes);
    @memset(matched_indexes, null);

    for (matched_lines.items, 0..) |match_line, match_index| {
        const line_index = match_line.line_number - 1;
        matched_indexes[line_index] = match_index;
        const start = line_index -| context_before;
        const end = @min(line_index + context_after + 1, line_spans.len);
        for (start..end) |idx| include[idx] = true;
    }

    var previous_included: ?usize = null;
    for (line_spans, 0..) |line_span, line_index| {
        if (!include[line_index]) continue;
        if (previous_included) |prev| {
            if (line_index > prev + 1) try writer.writeAll("--\n");
        }
        previous_included = line_index;

        if (matched_indexes[line_index]) |match_index| {
            const line = matched_lines.items[match_index];
            try search_output.writeReplacedLine(
                writer,
                path,
                line.line_number,
                line.column_number,
                line.line,
                line.line_span.start,
                line.segments,
                output,
                display_mode,
            );
        } else {
            try writeContextLine(writer, path, line_index + 1, haystack[line_span.start..line_span.end], output, display_mode);
        }
    }

    var match_count: usize = 0;
    for (matched_lines.items) |line| match_count += line.segments.len;
    return .{
        .matched = true,
        .matched_lines = matched_lines.items.len,
        .matches = match_count,
    };
}

fn writeMultilineReportBlock(
    writer: *std.Io.Writer,
    path: []const u8,
    info: zigrep.search.report.DisplayBlockInfo,
    haystack: []const u8,
    output: OutputOptions,
    display_mode: DisplayMode,
) !void {
    try search_output.writePrefixedDisplayBytes(
        writer,
        path,
        info.line_number,
        info.column_number,
        haystack[info.block.block_span.start..info.block.block_span.end],
        output,
        true,
        display_mode,
    );
}

fn writeFileReportsMultiline(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    searcher: *zigrep.search.grep.Searcher,
    path: []const u8,
    haystack: []const u8,
    output: OutputOptions,
    display_mode: DisplayMode,
) !ReportSummary {
    const matches = try collectMultilineMatchesAlloc(allocator, searcher, path, haystack);
    defer allocator.free(matches);
    if (matches.len == 0) return .{};

    const merged = try mergeMultilineMatchesAlloc(allocator, matches);
    defer allocator.free(merged);

    for (merged) |info| {
        try writeMultilineReportBlock(writer, path, info, haystack, output, display_mode);
    }

    return .{
        .matched = true,
        .matched_lines = merged.len,
        .matches = matches.len,
    };
}

fn writeFileOnlyMatchingMultiline(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    searcher: *zigrep.search.grep.Searcher,
    path: []const u8,
    haystack: []const u8,
    output: OutputOptions,
    display_mode: DisplayMode,
) !ReportSummary {
    const line_spans = try zigrep.search.report.collectLineSpansAlloc(allocator, haystack);
    defer allocator.free(line_spans);

    const Context = struct {
        writer: *std.Io.Writer,
        haystack: []const u8,
        line_spans: []const zigrep.search.report.Span,
        output: OutputOptions,
        display_mode: DisplayMode,
        matches: usize = 0,

        fn emit(self: *@This(), report: zigrep.search.grep.MatchReport) !void {
            const info = zigrep.search.report.deriveDisplayBlockInfo(self.haystack, self.line_spans, report.match_span);
            try search_output.writePrefixedDisplayBytes(
                self.writer,
                report.path,
                info.line_number,
                info.column_number,
                self.haystack[report.match_span.start..report.match_span.end],
                self.output,
                true,
                self.display_mode,
            );
            self.matches += 1;
        }
    };

    var context = Context{
        .writer = writer,
        .haystack = haystack,
        .line_spans = line_spans,
        .output = output,
        .display_mode = display_mode,
    };

    _ = try searcher.forEachMatchReport(path, haystack, &context, Context.emit);
    return .{
        .matched = context.matches != 0,
        .matched_lines = context.matches,
        .matches = context.matches,
    };
}

fn writeMultilineJsonMatchEvent(
    writer: *std.Io.Writer,
    path: []const u8,
    haystack: []const u8,
    match_info: MultilineMatchInfo,
    output: OutputOptions,
) !void {
    const display_slice = if (output.only_matching)
        haystack[match_info.match_span.start..match_info.match_span.end]
    else
        haystack[match_info.display.block.block_span.start..match_info.display.block.block_span.end];
    const line_span = if (output.only_matching)
        match_info.match_span
    else
        match_info.display.block.block_span;

    try writer.writeAll("{\"type\":\"match\",\"data\":{");
    try writer.writeAll("\"path\":");
    try search_output.writeJsonString(writer, path);
    try writer.print(",\"line_number\":{d},\"column_number\":{d}", .{ match_info.display.line_number, match_info.display.column_number });
    try writer.writeAll(",\"line\":");
    try search_output.writeJsonString(writer, display_slice);
    try writer.print(",\"line_span\":{{\"start\":{d},\"end\":{d}}}", .{ line_span.start, line_span.end });
    try writer.print(",\"match_span\":{{\"start\":{d},\"end\":{d}}}", .{ match_info.match_span.start, match_info.match_span.end });
    try writer.writeAll("}}\n");
}

fn writeFileCountMultiline(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    searcher: *zigrep.search.grep.Searcher,
    path: []const u8,
    haystack: []const u8,
    output_format: OutputFormat,
) !ReportSummary {
    const matches = try collectMultilineMatchesAlloc(allocator, searcher, path, haystack);
    defer allocator.free(matches);
    if (matches.len == 0) return .{};

    switch (output_format) {
        .text => try writer.print("{s}:{d}\n", .{ path, matches.len }),
        .json => try search_output.writeJsonCountEvent(writer, path, matches.len),
    }
    return .{ .matched = true };
}

fn writeFileReportsWithContextMultiline(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    searcher: *zigrep.search.grep.Searcher,
    path: []const u8,
    haystack: []const u8,
    output: OutputOptions,
    context_before: usize,
    context_after: usize,
    display_mode: DisplayMode,
) !ReportSummary {
    const matches = try collectMultilineMatchesAlloc(allocator, searcher, path, haystack);
    defer allocator.free(matches);
    if (matches.len == 0) return .{};

    const merged = try mergeMultilineMatchesAlloc(allocator, matches);
    defer allocator.free(merged);

    const line_spans = try zigrep.search.report.collectLineSpansAlloc(allocator, haystack);
    defer allocator.free(line_spans);

    const include = try allocator.alloc(bool, line_spans.len);
    defer allocator.free(include);
    @memset(include, false);

    const block_starts = try allocator.alloc(?usize, line_spans.len);
    defer allocator.free(block_starts);
    @memset(block_starts, null);

    for (merged, 0..) |info, block_index| {
        block_starts[info.block.start_line_index] = block_index;
        const start = info.block.start_line_index -| context_before;
        const end = @min(info.block.end_line_index + context_after + 1, line_spans.len);
        for (start..end) |line_index| include[line_index] = true;
    }

    var previous_included: ?usize = null;
    var line_index: usize = 0;
    while (line_index < line_spans.len) {
        if (!include[line_index]) {
            line_index += 1;
            continue;
        }
        if (previous_included) |prev| {
            if (line_index > prev + 1) try writer.writeAll("--\n");
        }

        if (block_starts[line_index]) |block_index| {
            const info = merged[block_index];
            try writeMultilineReportBlock(writer, path, info, haystack, output, display_mode);
            previous_included = info.block.end_line_index;
            line_index = info.block.end_line_index + 1;
            continue;
        }

        previous_included = line_index;
        const line_span = line_spans[line_index];
        try writeContextLine(writer, path, line_index + 1, haystack[line_span.start..line_span.end], output, display_mode);
        line_index += 1;
    }

    return .{
        .matched = true,
        .matched_lines = merged.len,
        .matches = matches.len,
    };
}

const MultilineMatchInfo = struct {
    display: zigrep.search.report.DisplayBlockInfo,
    match_span: zigrep.search.report.Span,
};

fn collectMultilineMatchesAlloc(
    allocator: std.mem.Allocator,
    searcher: *zigrep.search.grep.Searcher,
    path: []const u8,
    haystack: []const u8,
) ![]MultilineMatchInfo {
    const line_spans = try zigrep.search.report.collectLineSpansAlloc(allocator, haystack);
    defer allocator.free(line_spans);

    const Context = struct {
        allocator: std.mem.Allocator,
        haystack: []const u8,
        line_spans: []const zigrep.search.report.Span,
        items: *std.ArrayList(MultilineMatchInfo),

        fn emit(self: *@This(), report: zigrep.search.grep.MatchReport) !void {
            try self.items.append(self.allocator, .{
                .display = zigrep.search.report.deriveDisplayBlockInfo(self.haystack, self.line_spans, report.match_span),
                .match_span = report.match_span,
            });
        }
    };

    var items: std.ArrayList(MultilineMatchInfo) = .empty;
    errdefer items.deinit(allocator);

    var context = Context{
        .allocator = allocator,
        .haystack = haystack,
        .line_spans = line_spans,
        .items = &items,
    };

    const matched = try searcher.forEachMatchReport(path, haystack, &context, Context.emit);
    if (!matched) return allocator.alloc(MultilineMatchInfo, 0);
    return items.toOwnedSlice(allocator);
}

fn mergeMultilineMatchesAlloc(
    allocator: std.mem.Allocator,
    matches: []const MultilineMatchInfo,
) ![]zigrep.search.report.DisplayBlockInfo {
    if (matches.len == 0) return allocator.alloc(zigrep.search.report.DisplayBlockInfo, 0);

    const projected = try allocator.alloc(zigrep.search.report.DisplayBlock, matches.len);
    defer allocator.free(projected);
    for (matches, 0..) |match_info, index| projected[index] = match_info.display.block;

    const merged_blocks = try zigrep.search.report.mergeDisplayBlocksAlloc(allocator, projected);
    defer allocator.free(merged_blocks);

    var merged_infos: std.ArrayList(zigrep.search.report.DisplayBlockInfo) = .empty;
    defer merged_infos.deinit(allocator);

    var match_index: usize = 0;
    for (merged_blocks) |block| {
        while (match_index < matches.len and matches[match_index].display.block.start_line_index < block.start_line_index) {
            match_index += 1;
        }
        if (match_index >= matches.len) return error.InvalidFlagCombination;

        try merged_infos.append(allocator, .{
            .line_number = matches[match_index].display.line_number,
            .column_number = matches[match_index].display.column_number,
            .block = block,
        });
    }

    return merged_infos.toOwnedSlice(allocator);
}

pub fn writeFileOutput(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    searcher: *zigrep.search.grep.Searcher,
    path: []const u8,
    bytes: []const u8,
    encoding: zigrep.search.io.InputEncoding,
    suppress_binary_output: bool,
    invert_match: bool,
    output: OutputOptions,
    output_format: OutputFormat,
    report_mode: ReportMode,
    max_count: ?usize,
    context_before: usize,
    context_after: usize,
    display_mode: DisplayMode,
) !ReportSummary {
    if (suppress_binary_output) {
        return switch (report_mode) {
            .lines => writeBinaryFileMatchNotice(allocator, writer, searcher, path, bytes, encoding, invert_match),
            .files_with_matches => writeFilePathOnMatch(allocator, writer, searcher, path, bytes, encoding, invert_match, output, output_format),
            .files_without_match => writeFilePathWithoutMatch(allocator, writer, searcher, path, bytes, encoding, invert_match, output, output_format),
            .count => unreachable,
        };
    }
    return switch (report_mode) {
        .lines => writeFileLines(
            allocator,
            writer,
            searcher,
            path,
            bytes,
            encoding,
            invert_match,
            output,
            output_format,
            max_count,
            context_before,
            context_after,
            display_mode,
        ),
        .count => writeFileCount(allocator, writer, searcher, path, bytes, encoding, invert_match, output, output_format, max_count),
        .files_with_matches => writeFilePathOnMatch(allocator, writer, searcher, path, bytes, encoding, invert_match, output, output_format),
        .files_without_match => writeFilePathWithoutMatch(allocator, writer, searcher, path, bytes, encoding, invert_match, output, output_format),
    };
}

fn writeBinaryFileMatchNotice(
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

fn writeFileLines(
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
    context_before: usize,
    context_after: usize,
    display_mode: DisplayMode,
) !ReportSummary {
    if (try zigrep.search.io.decodeToUtf8Alloc(allocator, bytes, encoding)) |decoded| {
        defer allocator.free(decoded);
        if (searcher.program.can_match_newline) {
            if (invert_match or max_count != null) {
                return error.InvalidFlagCombination;
            }
            if (output.only_matching) {
                if (context_before != 0 or context_after != 0 or output_format == .json) {
                    return error.InvalidFlagCombination;
                }
                return writeFileOnlyMatchingMultiline(allocator, writer, searcher, path, decoded, output, display_mode);
            }
            if (context_before != 0 or context_after != 0) {
                if (output_format != .text) return error.InvalidFlagCombination;
                return writeFileReportsWithContextMultiline(
                    allocator,
                    writer,
                    searcher,
                    path,
                    decoded,
                    output,
                    context_before,
                    context_after,
                    display_mode,
                );
            }
            if (output_format == .json) {
                const matches = try collectMultilineMatchesAlloc(allocator, searcher, path, decoded);
                defer allocator.free(matches);
                if (matches.len == 0) return .{};
                for (matches) |match_info| try writeMultilineJsonMatchEvent(writer, path, decoded, match_info, output);
                return .{
                    .matched = true,
                    .matched_lines = matches.len,
                    .matches = matches.len,
                };
            }
            return writeFileReportsMultiline(allocator, writer, searcher, path, decoded, output, display_mode);
        }
        if (invert_match) {
            return writeInvertedFileReports(allocator, writer, searcher, path, decoded, output, output_format, max_count, display_mode);
        }
        if (context_before != 0 or context_after != 0) {
            return writeFileReportsWithContext(
                allocator,
                writer,
                searcher,
                path,
                decoded,
                output,
                max_count,
                context_before,
                context_after,
                display_mode,
            );
        }
        return writeFileReports(allocator, writer, searcher, path, decoded, .utf8, output, output_format, max_count, display_mode);
    }

    if (searcher.program.can_match_newline) {
        if (invert_match or max_count != null) {
            return error.InvalidFlagCombination;
        }
        if (output.only_matching) {
            if (context_before != 0 or context_after != 0 or output_format == .json) {
                return error.InvalidFlagCombination;
            }
            return writeFileOnlyMatchingMultiline(allocator, writer, searcher, path, bytes, output, display_mode);
        }
        if (context_before != 0 or context_after != 0) {
            if (output_format != .text) return error.InvalidFlagCombination;
            return writeFileReportsWithContextMultiline(
                allocator,
                writer,
                searcher,
                path,
                bytes,
                output,
                context_before,
                context_after,
                display_mode,
            );
        }
        if (output_format == .json) {
            const matches = try collectMultilineMatchesAlloc(allocator, searcher, path, bytes);
            defer allocator.free(matches);
            if (matches.len == 0) return .{};
            for (matches) |match_info| try writeMultilineJsonMatchEvent(writer, path, bytes, match_info, output);
            return .{
                .matched = true,
                .matched_lines = matches.len,
                .matches = matches.len,
            };
        }
        return writeFileReportsMultiline(allocator, writer, searcher, path, bytes, output, display_mode);
    }

    if (invert_match) {
        return writeInvertedFileReports(allocator, writer, searcher, path, bytes, output, output_format, max_count, display_mode);
    }
    if (context_before != 0 or context_after != 0) {
        return writeFileReportsWithContext(
            allocator,
            writer,
            searcher,
            path,
            bytes,
            output,
            max_count,
            context_before,
            context_after,
            display_mode,
        );
    }
    return writeFileReports(allocator, writer, searcher, path, bytes, .utf8, output, output_format, max_count, display_mode);
}

fn writeInvertedFileReports(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    searcher: *zigrep.search.grep.Searcher,
    path: []const u8,
    haystack: []const u8,
    output: OutputOptions,
    output_format: OutputFormat,
    max_count: ?usize,
    display_mode: DisplayMode,
) !ReportSummary {
    const line_spans = try zigrep.search.report.collectLineSpansAlloc(allocator, haystack);
    defer allocator.free(line_spans);

    var selected_count: usize = 0;
    for (line_spans, 0..) |line_span, index| {
        const line = haystack[line_span.start..line_span.end];
        const is_match = (try searcher.reportFirstMatch(path, line)) != null;
        if (is_match) continue;
        if (max_count) |limit| {
            if (selected_count >= limit) break;
        }
        selected_count += 1;
        const report: zigrep.search.grep.MatchReport = .{
            .path = path,
            .line_number = index + 1,
            .column_number = 1,
            .line = line,
            .line_terminated = line_span.end < haystack.len and haystack[line_span.end] == '\n',
            .owned_line = null,
            .line_span = line_span,
            .match_span = line_span,
        };
        switch (output_format) {
            .text => try search_output.writeReport(writer, report, output, display_mode),
            .json => try search_output.writeJsonMatchEvent(writer, report, output),
        }
    }
    return .{
        .matched = selected_count != 0,
        .matched_lines = selected_count,
        .matches = selected_count,
    };
}

fn writeFileCount(
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
            return writeFileCountMultiline(allocator, writer, searcher, path, decoded, output_format);
        }
        _ = searcher.forEachLineReport(path, decoded, &counter, Counter.emit) catch |err| switch (err) {
            IterationStop.MaxCountReached => true,
            else => return err,
        };
    } else {
        if (searcher.program.can_match_newline) {
            return writeFileCountMultiline(allocator, writer, searcher, path, bytes, output_format);
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

fn writeFilePathOnMatch(
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

fn writeFilePathWithoutMatch(
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

fn expandReplacementAlloc(
    allocator: std.mem.Allocator,
    template: []const u8,
    match_span: zigrep.search.report.Span,
    groups: []const regex.Vm.Capture,
    capture_names: []const ?[]const u8,
    line: []const u8,
    line_span_start: usize,
) ![]u8 {
    var expanded: std.ArrayList(u8) = .empty;
    defer expanded.deinit(allocator);

    var index: usize = 0;
    while (index < template.len) {
        if (template[index] != '$') {
            try expanded.append(allocator, template[index]);
            index += 1;
            continue;
        }
        if (index + 1 >= template.len) {
            try expanded.append(allocator, '$');
            break;
        }

        const next = template[index + 1];
        if (next == '$') {
            try expanded.append(allocator, '$');
            index += 2;
            continue;
        }

        if (next == '{') {
            const close = std.mem.indexOfScalarPos(u8, template, index + 2, '}') orelse {
                try expanded.append(allocator, '$');
                index += 1;
                continue;
            };
            try appendCaptureExpansion(
                allocator,
                &expanded,
                template[index + 2 .. close],
                match_span,
                groups,
                capture_names,
                line,
                line_span_start,
            );
            index = close + 1;
            continue;
        }

        if (std.ascii.isDigit(next)) {
            var end = index + 2;
            while (end < template.len and std.ascii.isDigit(template[end])) end += 1;
            try appendCaptureExpansion(
                allocator,
                &expanded,
                template[index + 1 .. end],
                match_span,
                groups,
                capture_names,
                line,
                line_span_start,
            );
            index = end;
            continue;
        }

        if (isCaptureNameByte(next)) {
            var end = index + 2;
            while (end < template.len and isCaptureNameByte(template[end])) end += 1;
            try appendCaptureExpansion(
                allocator,
                &expanded,
                template[index + 1 .. end],
                match_span,
                groups,
                capture_names,
                line,
                line_span_start,
            );
            index = end;
            continue;
        }

        try expanded.append(allocator, '$');
        index += 1;
    }

    return expanded.toOwnedSlice(allocator);
}

fn appendCaptureExpansion(
    allocator: std.mem.Allocator,
    expanded: *std.ArrayList(u8),
    token: []const u8,
    match_span: zigrep.search.report.Span,
    groups: []const regex.Vm.Capture,
    capture_names: []const ?[]const u8,
    line: []const u8,
    line_span_start: usize,
) !void {
    if (token.len == 0) return;

    var capture: ?regex.Vm.Capture = null;

    if (std.ascii.isDigit(token[0])) {
        const index = std.fmt.parseUnsigned(usize, token, 10) catch return;
        if (index == 0) {
            capture = .{ .start = match_span.start, .end = match_span.end };
        } else if (index <= groups.len) {
            capture = groups[index - 1];
        } else {
            return;
        }
    } else {
        for (capture_names, 0..) |name, index| {
            if (name) |capture_name| {
                if (std.mem.eql(u8, capture_name, token)) {
                    capture = groups[index];
                    break;
                }
            }
        }
        if (capture == null) return;
    }

    const found = capture.?;
    const start = found.start orelse return;
    const end = found.end orelse return;
    if (end < start or start < line_span_start) return;

    const relative_start = start - line_span_start;
    const relative_end = end - line_span_start;
    if (relative_end > line.len) return;

    try expanded.appendSlice(allocator, line[relative_start..relative_end]);
}

fn isCaptureNameByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

pub fn formatReport(
    allocator: std.mem.Allocator,
    report: zigrep.search.grep.MatchReport,
    output: OutputOptions,
) ![]u8 {
    return search_output.formatReport(allocator, report, output);
}
