const std = @import("std");
const zigrep = struct {
    pub const search = @import("search/root.zig");
};
const command = @import("command.zig");
const search_reporting = @import("search_reporting.zig");
const search_execution = @import("search_execution.zig");
const search_output = @import("search_output.zig");

// Per-file search execution.
// This module owns file reads, preprocessing/decoding preparation, binary
// behavior, and producing owned output for one entry.

pub const CliOptions = command.CliOptions;

pub const EntryOutput = struct {
    bytes: std.ArrayListUnmanaged(u8) = .empty,
    searched_bytes: usize = 0,
    printed_bytes: usize = 0,
    matched_lines: usize = 0,
    matches: usize = 0,
    elapsed_ns: u64 = 0,
    matched: bool = false,
    match_events: usize = 0,
    skipped_binary: bool = false,
    warning_emitted: bool = false,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.bytes.deinit(allocator);
    }
};

pub fn searchEntryToOwnedOutput(
    file_allocator: std.mem.Allocator,
    output_allocator: std.mem.Allocator,
    stderr: *std.Io.Writer,
    searcher: *zigrep.search.grep.Searcher,
    entry: zigrep.search.walk.Entry,
    options: CliOptions,
) !EntryOutput {
    const suppress_binary_output = if (options.search_compressed)
        null
    else blk: {
        if (options.encoding != .auto) break :blk false;
        switch (options.binary_mode) {
            .text => break :blk false,
            .skip, .suppress => {
                const decision = zigrep.search.io.detectBinaryFile(entry.path, .{}) catch |err| {
                    if (try search_execution.warnAndSkipFileError(stderr, entry.path, err)) {
                        return .{ .warning_emitted = true };
                    }
                    return err;
                };
                if (decision == .binary) {
                    if (options.binary_mode == .skip) {
                        return .{ .skipped_binary = true };
                    }
                    break :blk true;
                }
                break :blk false;
            },
        }
    };

    const buffer = zigrep.search.io.readFile(file_allocator, entry.path, .{
        .strategy = options.read_strategy,
    }) catch |err| {
        if (try search_execution.warnAndSkipFileError(stderr, entry.path, err)) {
            return .{ .warning_emitted = true };
        }
        return err;
    };
    defer buffer.deinit(file_allocator);

    const search_bytes = search_execution.prepareSearchBytes(file_allocator, entry.path, buffer.bytes(), options) catch |err| {
        if (try search_execution.warnAndSkipFileError(stderr, entry.path, err)) {
            return .{ .warning_emitted = true };
        }
        return err;
    };

    const effective_binary_output = if (options.search_compressed or options.preprocessor != null)
        search_execution.decideBinaryBehavior(search_bytes, options.encoding, options.binary_mode) orelse {
            return .{ .skipped_binary = true };
        }
    else
        suppress_binary_output.?;
    const raw_text_output = search_execution.shouldRenderRawBinaryText(search_bytes, options.encoding, options.binary_mode);

    var capture: std.Io.Writer.Allocating = .init(output_allocator);
    defer capture.deinit();
    var timer = try std.time.Timer.start();

    if (options.output_format == .json) {
        try search_output.writeJsonBeginEvent(&capture.writer, entry.path);
    }

    const matched = try search_reporting.writeFileOutput(
        file_allocator,
        &capture.writer,
        searcher,
        entry.path,
        search_bytes,
        options.encoding,
        effective_binary_output,
        options.invert_match,
        options.output,
        options.output_format,
        options.report_mode,
        options.max_count,
        options.context_before,
        options.context_after,
        if (raw_text_output) .raw else .escaped,
    );

    const pre_end_written = capture.written();
    const elapsed_ns = timer.read();
    if (options.output_format == .json) {
        const match_events = countJsonEventType(pre_end_written, "\"type\":\"match\"");
        const matched_lines = countDistinctJsonLineNumbers(pre_end_written);
        try search_output.writeJsonEndEvent(&capture.writer, entry.path, .{
            .bytes_searched = search_bytes.len,
            .bytes_printed = pre_end_written.len,
            .searches = 1,
            .searches_with_match = if (matched) 1 else 0,
            .matched_lines = matched_lines,
            .matches = match_events,
            .elapsed_ns = elapsed_ns,
        });
    }

    const written = capture.written();
    const match_events = if (options.output_format == .json)
        countJsonEventType(pre_end_written, "\"type\":\"match\"")
    else
        0;
    const matched_lines = if (options.output_format == .json)
        countDistinctJsonLineNumbers(pre_end_written)
    else
        match_events;
    return .{
        .bytes = capture.toArrayList(),
        .searched_bytes = search_bytes.len,
        .printed_bytes = if (options.output_format == .json) pre_end_written.len else written.len,
        .matched_lines = matched_lines,
        .matches = match_events,
        .elapsed_ns = elapsed_ns,
        .matched = matched,
        .match_events = match_events,
    };
}

fn countJsonEventType(bytes: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, bytes, start, needle)) |index| {
        count += 1;
        start = index + needle.len;
    }
    return count;
}

fn countDistinctJsonLineNumbers(bytes: []const u8) usize {
    const needle = "\"line_number\":";
    var count: usize = 0;
    var start: usize = 0;
    var last_line_number: ?usize = null;

    while (std.mem.indexOfPos(u8, bytes, start, needle)) |index| {
        var cursor = index + needle.len;
        const number_start = cursor;
        while (cursor < bytes.len and std.ascii.isDigit(bytes[cursor])) : (cursor += 1) {}
        if (cursor == number_start) {
            start = number_start;
            continue;
        }

        const line_number = std.fmt.parseUnsigned(usize, bytes[number_start..cursor], 10) catch {
            start = cursor;
            continue;
        };
        if (last_line_number == null or last_line_number.? != line_number) {
            count += 1;
            last_line_number = line_number;
        }
        start = cursor;
    }

    return count;
}
