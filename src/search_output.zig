const std = @import("std");
const command = @import("command.zig");
const zigrep = struct {
    pub const search = @import("search/root.zig");
};

pub const OutputOptions = command.OutputOptions;

pub const ReplacementSegment = struct {
    match_span: zigrep.search.report.Span,
    replacement: []const u8,
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

pub fn writeBinaryMatchNotice(writer: *std.Io.Writer, path: []const u8) !void {
    try writer.print("{s}: binary file matches\n", .{path});
}

pub fn writeJsonMatchEvent(
    writer: *std.Io.Writer,
    report: zigrep.search.grep.MatchReport,
    output: OutputOptions,
) !void {
    const display_slice = if (output.only_matching)
        report.line[report.match_span.start - report.line_span.start .. report.match_span.end - report.line_span.start]
    else
        report.line;

    try writer.writeAll("{\"type\":\"match\",\"data\":{");
    try writer.writeAll("\"path\":");
    try writeJsonString(writer, report.path);
    try writer.print(",\"line_number\":{d},\"column_number\":{d}", .{ report.line_number, report.column_number });
    try writer.writeAll(",\"line\":");
    try writeJsonString(writer, display_slice);
    try writer.print(",\"line_span\":{{\"start\":{d},\"end\":{d}}}", .{ report.line_span.start, report.line_span.end });
    try writer.print(",\"match_span\":{{\"start\":{d},\"end\":{d}}}", .{ report.match_span.start, report.match_span.end });
    try writer.writeAll("}}\n");
}

pub fn writeJsonCountEvent(writer: *std.Io.Writer, path: []const u8, count: usize) !void {
    try writer.writeAll("{\"type\":\"count\",\"data\":{");
    try writer.writeAll("\"path\":");
    try writeJsonString(writer, path);
    try writer.print(",\"count\":{d}}}\n", .{count});
}

pub fn writeJsonPathEvent(writer: *std.Io.Writer, path: []const u8, matched: bool) !void {
    try writer.writeAll("{\"type\":\"path\",\"data\":{");
    try writer.writeAll("\"path\":");
    try writeJsonString(writer, path);
    try writer.print(",\"matched\":{s}}}\n", .{if (matched) "true" else "false"});
}

pub fn writePathResult(writer: *std.Io.Writer, path: []const u8, output: OutputOptions) !void {
    try writer.writeAll(path);
    try writer.writeByte(if (output.null_path_terminator) 0 else '\n');
}

pub fn writeReport(
    writer: *std.Io.Writer,
    report: zigrep.search.grep.MatchReport,
    output: OutputOptions,
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
    try writeDisplayLine(writer, display_slice);
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
        try writeDisplayLine(writer, line[cursor..relative_start]);
        try writeDisplayLine(writer, segment.replacement);
        cursor = relative_end;
    }
    try writeDisplayLine(writer, line[cursor..]);
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
    try writeDisplayBytes(writer, bytes, allow_newlines);
    try writer.writeByte('\n');
}

pub fn writeDisplayBytes(writer: *std.Io.Writer, bytes: []const u8, allow_newlines: bool) !void {
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

pub fn writeDisplayLine(writer: *std.Io.Writer, bytes: []const u8) !void {
    try writeDisplayBytes(writer, bytes, false);
}

pub fn formatReport(
    allocator: std.mem.Allocator,
    report: zigrep.search.grep.MatchReport,
    output: OutputOptions,
) ![]u8 {
    var buffer: std.Io.Writer.Allocating = .init(allocator);
    defer buffer.deinit();
    try writeReport(&buffer.writer, report, output);
    var array_list = buffer.toArrayList();
    return try array_list.toOwnedSlice(allocator);
}

pub fn writeJsonString(writer: *std.Io.Writer, bytes: []const u8) !void {
    try writer.writeByte('"');

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

    try writer.writeByte('"');
}

fn isDisplaySafeAscii(byte: u8, allow_newlines: bool) bool {
    return switch (byte) {
        '\n' => allow_newlines,
        '\t', ' '...'~' => true,
        else => false,
    };
}
