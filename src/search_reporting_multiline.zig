const std = @import("std");
const zigrep = struct {
    pub const search = @import("search/root.zig");
};
const command = @import("command.zig");
const search_output = @import("search_output.zig");
const search_reporting_types = @import("search_reporting_types.zig");

pub const OutputOptions = command.OutputOptions;
pub const OutputFormat = command.OutputFormat;
pub const DisplayMode = search_output.DisplayMode;
pub const ReportSummary = search_reporting_types.ReportSummary;

pub const MultilineMatchInfo = struct {
    display: zigrep.search.report.DisplayBlockInfo,
    match_span: zigrep.search.report.Span,
};

pub fn writeFileReportsMultiline(
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

pub fn writeFileOnlyMatchingMultiline(
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

pub fn writeMultilineJsonMatchEvent(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    searcher: *zigrep.search.grep.Searcher,
    path: []const u8,
    haystack: []const u8,
    output: OutputOptions,
) !ReportSummary {
    _ = output;
    const matches = try collectMultilineMatchesAlloc(allocator, searcher, path, haystack);
    defer allocator.free(matches);
    if (matches.len == 0) return .{};

    const merged = try mergeMultilineMatchesAlloc(allocator, matches);
    defer allocator.free(merged);

    const line_spans = try zigrep.search.report.collectLineSpansAlloc(allocator, haystack);
    defer allocator.free(line_spans);

    var match_index: usize = 0;
    var matched_lines: usize = 0;
    for (merged) |info| {
        while (match_index < matches.len and matches[match_index].display.block.start_line_index < info.block.start_line_index) {
            match_index += 1;
        }

        var block_match_end = match_index;
        while (block_match_end < matches.len and matches[block_match_end].display.block.end_line_index <= info.block.end_line_index) {
            block_match_end += 1;
        }

        try writeMultilineJsonBlockEvent(writer, path, haystack, line_spans, info, matches[match_index..block_match_end]);
        matched_lines += info.block.end_line_index - info.block.start_line_index + 1;
        match_index = block_match_end;
    }

    return .{
        .matched = true,
        .matched_lines = matched_lines,
        .matches = matches.len,
    };
}

pub fn writeFileCountMultiline(
    _: std.mem.Allocator,
    writer: *std.Io.Writer,
    searcher: *zigrep.search.grep.Searcher,
    path: []const u8,
    haystack: []const u8,
    output_format: OutputFormat,
) !ReportSummary {
    const Context = struct {
        count: usize = 0,

        fn emit(self: *@This(), report: zigrep.search.grep.MatchReport) !void {
            _ = report;
            self.count += 1;
        }
    };

    var context = Context{};
    _ = try searcher.forEachMatchReport(path, haystack, &context, Context.emit);
    if (context.count == 0) return .{};

    switch (output_format) {
        .text => try writer.print("{s}:{d}\n", .{ path, context.count }),
        .json => try search_output.writeJsonCountEvent(writer, path, context.count),
    }
    return .{ .matched = true };
}

pub fn writeFileReportsWithContextMultiline(
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

pub fn collectMultilineMatchesAlloc(
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

pub fn mergeMultilineMatchesAlloc(
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

fn writeMultilineJsonBlockEvent(
    writer: *std.Io.Writer,
    path: []const u8,
    haystack: []const u8,
    line_spans: []const zigrep.search.report.Span,
    info: zigrep.search.report.DisplayBlockInfo,
    block_matches: []const MultilineMatchInfo,
) !void {
    const block_start = line_spans[info.block.start_line_index].start;
    const block_end = if (info.block.end_line_index + 1 < line_spans.len)
        line_spans[info.block.end_line_index + 1].start
    else
        haystack.len;
    const block_bytes = haystack[block_start..block_end];
    const line_terminated = block_end > block_start and haystack[block_end - 1] == '\n';
    const display_bytes = if (line_terminated) block_bytes[0 .. block_bytes.len - 1] else block_bytes;

    try writer.writeAll("{\"type\":\"match\",\"data\":{");
    try writer.writeAll("\"path\":");
    try search_output.writeJsonTextValue(writer, path);
    try writer.writeAll(",\"lines\":");
    try search_output.writeJsonTextValueWithTerminator(writer, display_bytes, line_terminated);
    try writer.print(",\"line_number\":{d},\"absolute_offset\":{d}", .{ info.line_number, block_start });
    try writer.writeAll(",\"submatches\":[");
    for (block_matches, 0..) |match_info, index| {
        if (index != 0) try writer.writeByte(',');
        const relative_start = match_info.match_span.start - block_start;
        const relative_end = match_info.match_span.end - block_start;
        try writer.writeAll("{\"match\":");
        try search_output.writeJsonTextValue(writer, haystack[match_info.match_span.start..match_info.match_span.end]);
        try writer.print(",\"start\":{d},\"end\":{d}", .{ relative_start, relative_end });
        try writer.writeByte('}');
    }
    try writer.writeAll("]}}\n");
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
