const std = @import("std");
const zigrep = struct {
    pub const search = @import("search/root.zig");
};
const regex = @import("regex/root.zig");
const command = @import("command.zig");
const search_output = @import("search_output.zig");
const search_reporting_match_modes = @import("search_reporting_match_modes.zig");
const search_reporting_multiline = @import("search_reporting_multiline.zig");
const search_reporting_types = @import("search_reporting_types.zig");

// Reporting and output shaping.
// This module owns line, multiline, context, count, path-only, and match
// reporting over already-selected haystacks.

const OutputOptions = command.OutputOptions;
const OutputFormat = command.OutputFormat;
const ReportMode = command.ReportMode;
const ReplacementSegment = search_output.ReplacementSegment;
const DisplayMode = search_output.DisplayMode;

pub const ReportSummary = search_reporting_types.ReportSummary;

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
            .lines => search_reporting_match_modes.writeBinaryFileMatchNotice(allocator, writer, searcher, path, bytes, encoding, invert_match),
            .files_with_matches => search_reporting_match_modes.writeFilePathOnMatch(allocator, writer, searcher, path, bytes, encoding, invert_match, output, output_format),
            .files_without_match => search_reporting_match_modes.writeFilePathWithoutMatch(allocator, writer, searcher, path, bytes, encoding, invert_match, output, output_format),
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
        .count => search_reporting_match_modes.writeFileCount(allocator, writer, searcher, path, bytes, encoding, invert_match, output, output_format, max_count),
        .files_with_matches => search_reporting_match_modes.writeFilePathOnMatch(allocator, writer, searcher, path, bytes, encoding, invert_match, output, output_format),
        .files_without_match => search_reporting_match_modes.writeFilePathWithoutMatch(allocator, writer, searcher, path, bytes, encoding, invert_match, output, output_format),
    };
}

pub fn reportFileMatch(
    allocator: std.mem.Allocator,
    searcher: *zigrep.search.grep.Searcher,
    path: []const u8,
    bytes: []const u8,
    encoding: zigrep.search.io.InputEncoding,
) !?zigrep.search.grep.MatchReport {
    return search_reporting_match_modes.reportFileMatch(allocator, searcher, path, bytes, encoding);
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
                return search_reporting_multiline.writeFileOnlyMatchingMultiline(allocator, writer, searcher, path, decoded, output, display_mode);
            }
            if (context_before != 0 or context_after != 0) {
                if (output_format != .text) return error.InvalidFlagCombination;
                return search_reporting_multiline.writeFileReportsWithContextMultiline(
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
                const matches = try search_reporting_multiline.collectMultilineMatchesAlloc(allocator, searcher, path, decoded);
                defer allocator.free(matches);
                if (matches.len == 0) return .{};
                for (matches) |match_info| try search_reporting_multiline.writeMultilineJsonMatchEvent(writer, path, decoded, match_info, output);
                return .{
                    .matched = true,
                    .matched_lines = matches.len,
                    .matches = matches.len,
                };
            }
            return search_reporting_multiline.writeFileReportsMultiline(allocator, writer, searcher, path, decoded, output, display_mode);
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
            return search_reporting_multiline.writeFileOnlyMatchingMultiline(allocator, writer, searcher, path, bytes, output, display_mode);
        }
        if (context_before != 0 or context_after != 0) {
            if (output_format != .text) return error.InvalidFlagCombination;
            return search_reporting_multiline.writeFileReportsWithContextMultiline(
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
            const matches = try search_reporting_multiline.collectMultilineMatchesAlloc(allocator, searcher, path, bytes);
            defer allocator.free(matches);
            if (matches.len == 0) return .{};
            for (matches) |match_info| try search_reporting_multiline.writeMultilineJsonMatchEvent(writer, path, bytes, match_info, output);
            return .{
                .matched = true,
                .matched_lines = matches.len,
                .matches = matches.len,
            };
        }
        return search_reporting_multiline.writeFileReportsMultiline(allocator, writer, searcher, path, bytes, output, display_mode);
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
