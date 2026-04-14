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

    var capture: std.Io.Writer.Allocating = .init(output_allocator);
    defer capture.deinit();

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
    );

    if (options.output_format == .json) {
        const written = capture.written();
        const match_events = countJsonEventType(written, "\"type\":\"match\"");
        try search_output.writeJsonEndEvent(&capture.writer, entry.path, .{
            .bytes_searched = search_bytes.len,
            .bytes_printed = written.len,
            .searches = 1,
            .searches_with_match = if (matched) 1 else 0,
            .matched_lines = match_events,
            .matches = match_events,
        });
    }

    const written = capture.written();
    return .{
        .bytes = capture.toArrayList(),
        .searched_bytes = search_bytes.len,
        .printed_bytes = written.len,
        .matched = matched,
        .match_events = countJsonEventType(written, "\"type\":\"match\""),
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
