const std = @import("std");
const command = @import("command.zig");
const zigrep = struct {
    pub const search = @import("search/root.zig");
};

pub const OutputOptions = command.OutputOptions;
pub const DisplayMode = enum {
    escaped,
    raw,
};

pub const ReplacementSegment = struct {
    match_span: zigrep.search.report.Span,
    replacement: []const u8,
};

pub const JsonEventStats = struct {
    bytes_searched: usize,
    bytes_printed: usize,
    searches: usize = 1,
    searches_with_match: usize,
    matched_lines: usize,
    matches: usize,
    elapsed_ns: ?u64 = null,
    elapsed_total_ns: ?u64 = null,
};

pub fn writeHeadingBlock(
    writer: *std.Io.Writer,
    path: []const u8,
    bytes: []const u8,
    wrote_previous_group: *bool,
) !void {
    if (wrote_previous_group.*) try writer.writeByte('\n');
    try writer.print("{s}\n", .{path});
    try writer.writeAll(bytes);
    wrote_previous_group.* = true;
}

pub fn writeBinaryMatchNotice(writer: *std.Io.Writer, binary_offset: usize) !void {
    try writer.print("binary file matches (found \"\\0\" byte around offset {d})\n", .{binary_offset});
}

pub fn writeJsonBeginEvent(writer: *std.Io.Writer, path: []const u8) !void {
    try writer.writeAll("{\"type\":\"begin\",\"data\":{\"path\":");
    try writeJsonTextValue(writer, path);
    try writer.writeAll("}}\n");
}

pub fn writeJsonMatchEvent(
    writer: *std.Io.Writer,
    report: zigrep.search.grep.MatchReport,
    output: OutputOptions,
) !void {
    _ = output;
    const submatch_start = report.match_span.start - report.line_span.start;
    const submatch_end = report.match_span.end - report.line_span.start;

    try writer.writeAll("{\"type\":\"match\",\"data\":{");
    try writer.writeAll("\"path\":");
    try writeJsonTextValue(writer, report.path);
    try writer.writeAll(",\"lines\":");
    try writeJsonTextValueWithTerminator(writer, report.line, report.line_terminated);
    try writer.print(",\"line_number\":{d},\"absolute_offset\":{d}", .{ report.line_number, report.line_span.start });
    try writer.writeAll(",\"submatches\":[{\"match\":");
    try writeJsonTextValue(writer, report.line[report.match_span.start - report.line_span.start .. report.match_span.end - report.line_span.start]);
    try writer.print(",\"start\":{d},\"end\":{d}", .{ submatch_start, submatch_end });
    try writer.writeAll("}]");
    try writer.writeAll("}}\n");
}

pub fn writeJsonCountEvent(writer: *std.Io.Writer, path: []const u8, count: usize) !void {
    try writer.writeAll("{\"type\":\"count\",\"data\":{");
    try writer.writeAll("\"path\":");
    try writeJsonTextValue(writer, path);
    try writer.print(",\"count\":{d}}}\n", .{count});
}

pub fn writeJsonPathEvent(writer: *std.Io.Writer, path: []const u8, matched: bool) !void {
    try writer.writeAll("{\"type\":\"path\",\"data\":{");
    try writer.writeAll("\"path\":");
    try writeJsonTextValue(writer, path);
    try writer.print(",\"matched\":{s}}}\n", .{if (matched) "true" else "false"});
}

pub fn writeJsonEndEvent(
    writer: *std.Io.Writer,
    path: []const u8,
    stats: JsonEventStats,
) !void {
    try writer.writeAll("{\"type\":\"end\",\"data\":{");
    try writer.writeAll("\"path\":");
    try writeJsonTextValue(writer, path);
    try writer.writeAll(",\"binary_offset\":null,\"stats\":{");
    if (stats.elapsed_ns) |elapsed_ns| {
        try writer.writeAll("\"elapsed\":");
        try writeJsonElapsed(writer, elapsed_ns);
        try writer.writeByte(',');
    }
    try writer.print(
        "\"searches\":{d},\"searches_with_match\":{d},\"bytes_searched\":{d},\"bytes_printed\":{d},\"matched_lines\":{d},\"matches\":{d}",
        .{ stats.searches, stats.searches_with_match, stats.bytes_searched, stats.bytes_printed, stats.matched_lines, stats.matches },
    );
    try writer.writeAll("}}}\n");
}

pub fn writeJsonSummaryEvent(writer: *std.Io.Writer, stats: JsonEventStats) !void {
    try writer.writeAll("{\"type\":\"summary\",\"data\":{");
    if (stats.elapsed_total_ns) |elapsed_total_ns| {
        try writer.writeAll("\"elapsed_total\":");
        try writeJsonElapsed(writer, elapsed_total_ns);
        try writer.writeByte(',');
    }
    try writer.writeAll("\"stats\":{");
    if (stats.elapsed_ns) |elapsed_ns| {
        try writer.writeAll("\"elapsed\":");
        try writeJsonElapsed(writer, elapsed_ns);
        try writer.writeByte(',');
    }
    try writer.print(
        "\"searches\":{d},\"searches_with_match\":{d},\"bytes_searched\":{d},\"bytes_printed\":{d},\"matched_lines\":{d},\"matches\":{d}",
        .{ stats.searches, stats.searches_with_match, stats.bytes_searched, stats.bytes_printed, stats.matched_lines, stats.matches },
    );
    try writer.writeAll("}}}\n");
}

fn writeJsonElapsed(writer: *std.Io.Writer, elapsed_ns: u64) !void {
    const secs = elapsed_ns / std.time.ns_per_s;
    const nanos = elapsed_ns % std.time.ns_per_s;
    const rounded_us = (elapsed_ns + 500) / 1000;
    const human_secs = rounded_us / std.time.us_per_s;
    const human_fraction = rounded_us % std.time.us_per_s;

    try writer.print(
        "{{\"secs\":{d},\"nanos\":{d},\"human\":\"{d}.{d:0>6}s\"}}",
        .{ secs, nanos, human_secs, human_fraction },
    );
}

pub fn writePathResult(writer: *std.Io.Writer, path: []const u8, output: OutputOptions) !void {
    try writer.writeAll(path);
    try writer.writeByte(if (output.null_path_terminator) 0 else '\n');
}

pub fn writeReport(
    writer: *std.Io.Writer,
    report: zigrep.search.grep.MatchReport,
    output: OutputOptions,
    display_mode: DisplayMode,
) !void {
    var wrote_prefix = false;
    if (output.with_filename) {
        try writer.print("{s}", .{report.path});
        wrote_prefix = true;
    }
    if (output.line_number) {
        if (wrote_prefix) try writer.writeByte(':');
        try writer.print("{d}", .{report.line_number});
        wrote_prefix = true;
    }
    if (output.column_number) {
        if (wrote_prefix) try writer.writeByte(':');
        try writer.print("{d}", .{report.column_number});
        wrote_prefix = true;
    }
    if (wrote_prefix) try writer.writeByte(':');
    const display_slice = if (output.only_matching)
        report.line[report.match_span.start - report.line_span.start .. report.match_span.end - report.line_span.start]
    else
        report.line;
    try writeDisplayLine(writer, display_slice, display_mode);
    try writer.writeByte('\n');
}

pub fn writeReplacedLine(
    writer: *std.Io.Writer,
    path: []const u8,
    line_number: usize,
    column_number: usize,
    line: []const u8,
    line_span_start: usize,
    segments: []const ReplacementSegment,
    output: OutputOptions,
    display_mode: DisplayMode,
) !void {
    var wrote_prefix = false;
    if (output.with_filename) {
        try writer.print("{s}", .{path});
        wrote_prefix = true;
    }
    if (output.line_number) {
        if (wrote_prefix) try writer.writeByte(':');
        try writer.print("{d}", .{line_number});
        wrote_prefix = true;
    }
    if (output.column_number) {
        if (wrote_prefix) try writer.writeByte(':');
        try writer.print("{d}", .{column_number});
        wrote_prefix = true;
    }
    if (wrote_prefix) try writer.writeByte(':');

    var cursor: usize = 0;
    for (segments) |segment| {
        const relative_start = segment.match_span.start - line_span_start;
        const relative_end = segment.match_span.end - line_span_start;
        try writeDisplayLine(writer, line[cursor..relative_start], display_mode);
        try writeDisplayLine(writer, segment.replacement, display_mode);
        cursor = relative_end;
    }
    try writeDisplayLine(writer, line[cursor..], display_mode);
    try writer.writeByte('\n');
}

pub fn writePrefixedDisplayBytes(
    writer: *std.Io.Writer,
    path: []const u8,
    line_number: usize,
    column_number: usize,
    bytes: []const u8,
    output: OutputOptions,
    allow_newlines: bool,
    display_mode: DisplayMode,
) !void {
    var wrote_prefix = false;
    if (output.with_filename) {
        try writer.print("{s}", .{path});
        wrote_prefix = true;
    }
    if (output.line_number) {
        if (wrote_prefix) try writer.writeByte(':');
        try writer.print("{d}", .{line_number});
        wrote_prefix = true;
    }
    if (output.column_number) {
        if (wrote_prefix) try writer.writeByte(':');
        try writer.print("{d}", .{column_number});
        wrote_prefix = true;
    }
    if (wrote_prefix) try writer.writeByte(':');
    try writeDisplayBytes(writer, bytes, allow_newlines, display_mode);
    try writer.writeByte('\n');
}

pub fn writeDisplayBytes(
    writer: *std.Io.Writer,
    bytes: []const u8,
    allow_newlines: bool,
    display_mode: DisplayMode,
) !void {
    if (display_mode == .raw) {
        try writer.writeAll(bytes);
        return;
    }

    var index: usize = 0;
    while (index < bytes.len) {
        const byte = bytes[index];
        if (byte < 0x80) {
            if (isDisplaySafeAscii(byte, allow_newlines)) {
                try writer.writeByte(byte);
            } else {
                try writer.print("\\x{X:0>2}", .{byte});
            }
            index += 1;
            continue;
        }

        const sequence_len = std.unicode.utf8ByteSequenceLength(byte) catch {
            try writer.print("\\x{X:0>2}", .{byte});
            index += 1;
            continue;
        };
        if (index + sequence_len > bytes.len) {
            try writer.print("\\x{X:0>2}", .{byte});
            index += 1;
            continue;
        }

        const sequence = bytes[index .. index + sequence_len];
        _ = std.unicode.utf8Decode(sequence) catch {
            try writer.print("\\x{X:0>2}", .{byte});
            index += 1;
            continue;
        };

        try writer.writeAll(sequence);
        index += sequence_len;
    }
}

pub fn writeDisplayLine(writer: *std.Io.Writer, bytes: []const u8, display_mode: DisplayMode) !void {
    try writeDisplayBytes(writer, bytes, false, display_mode);
}

pub fn formatReport(
    allocator: std.mem.Allocator,
    report: zigrep.search.grep.MatchReport,
    output: OutputOptions,
) ![]u8 {
    var buffer: std.Io.Writer.Allocating = .init(allocator);
    defer buffer.deinit();
    try writeReport(&buffer.writer, report, output, .escaped);
    var array_list = buffer.toArrayList();
    return try array_list.toOwnedSlice(allocator);
}

pub fn writeJsonString(writer: *std.Io.Writer, bytes: []const u8) !void {
    try writer.writeByte('"');
    try writeJsonStringContents(writer, bytes);
    try writer.writeByte('"');
}

fn writeJsonStringContents(writer: *std.Io.Writer, bytes: []const u8) !void {
    var index: usize = 0;
    while (index < bytes.len) {
        const byte = bytes[index];
        if (byte < 0x80) {
            switch (byte) {
                '"' => try writer.writeAll("\\\""),
                '\\' => try writer.writeAll("\\\\"),
                '\n' => try writer.writeAll("\\n"),
                '\r' => try writer.writeAll("\\r"),
                '\t' => try writer.writeAll("\\t"),
                else => {
                    if (isDisplaySafeAscii(byte, false)) {
                        try writer.writeByte(byte);
                    } else {
                        try writer.print("\\\\x{X:0>2}", .{byte});
                    }
                },
            }
            index += 1;
            continue;
        }

        const sequence_len = std.unicode.utf8ByteSequenceLength(byte) catch {
            try writer.print("\\\\x{X:0>2}", .{byte});
            index += 1;
            continue;
        };
        if (index + sequence_len > bytes.len) {
            try writer.print("\\\\x{X:0>2}", .{byte});
            index += 1;
            continue;
        }

        const sequence = bytes[index .. index + sequence_len];
        _ = std.unicode.utf8Decode(sequence) catch {
            try writer.print("\\\\x{X:0>2}", .{byte});
            index += 1;
            continue;
        };
        try writer.writeAll(sequence);
        index += sequence_len;
    }
}

pub fn writeJsonTextValue(writer: *std.Io.Writer, bytes: []const u8) !void {
    try writer.writeAll("{\"text\":");
    try writeJsonString(writer, bytes);
    try writer.writeByte('}');
}

pub fn writeJsonTextValueWithTerminator(
    writer: *std.Io.Writer,
    bytes: []const u8,
    line_terminated: bool,
) !void {
    try writer.writeAll("{\"text\":");
    if (!line_terminated) {
        try writeJsonString(writer, bytes);
    } else {
        try writer.writeByte('"');
        try writeJsonStringContents(writer, bytes);
        try writer.writeAll("\\n\"");
    }
    try writer.writeByte('}');
}

fn isDisplaySafeAscii(byte: u8, allow_newlines: bool) bool {
    return switch (byte) {
        '\n' => allow_newlines,
        '\t', ' '...'~' => true,
        else => false,
    };
}
