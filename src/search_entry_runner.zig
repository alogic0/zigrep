const std = @import("std");
const zigrep = struct {
    pub const search = @import("search/root.zig");
};
const command = @import("command.zig");
const search_reporting = @import("search_reporting.zig");
const search_execution = @import("search_execution.zig");
const search_output = @import("search_output.zig");
const search_output_policy = @import("search_output_policy.zig");

// Per-file search execution.
// This module owns file reads, preprocessing/decoding preparation, binary
// behavior, and producing owned output for one entry.

pub const CliOptions = command.CliOptions;
pub const EntrySearchOptions = struct {
    traversal: command.TraversalOptions,
    matcher: command.MatchOptions,
    reporting: command.ReportExecutionOptions,
};

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
    options: EntrySearchOptions,
) !EntryOutput {
    const traversal = options.traversal;
    const matcher = options.matcher;
    const reporting = options.reporting;

    const suppress_binary_output = if (traversal.search_compressed)
        null
    else blk: {
        if (matcher.encoding != .auto) break :blk false;
        switch (matcher.binary_mode) {
            .text => break :blk false,
            .skip, .suppress => {
                const decision = zigrep.search.io.detectBinaryFile(entry.path, .{}) catch |err| {
                    if (try search_execution.warnAndSkipFileError(stderr, entry.path, err)) {
                        return .{ .warning_emitted = true };
                    }
                    return err;
                };
                if (decision == .binary) {
                    if (matcher.binary_mode == .skip) {
                        return .{ .skipped_binary = true };
                    }
                    break :blk true;
                }
                break :blk false;
            },
        }
    };

    const buffer = zigrep.search.io.readFile(file_allocator, entry.path, .{
        .strategy = traversal.read_strategy,
    }) catch |err| {
        if (try search_execution.warnAndSkipFileError(stderr, entry.path, err)) {
            return .{ .warning_emitted = true };
        }
        return err;
    };
    defer buffer.deinit(file_allocator);

    const search_bytes = search_execution.prepareSearchBytes(file_allocator, entry.path, buffer.bytes(), traversal) catch |err| {
        if (try search_execution.warnAndSkipFileError(stderr, entry.path, err)) {
            return .{ .warning_emitted = true };
        }
        return err;
    };

    const effective_binary_output = if (traversal.search_compressed or traversal.preprocessor != null)
        search_execution.decideBinaryBehavior(search_bytes, matcher) orelse {
            return .{ .skipped_binary = true };
        }
    else
        suppress_binary_output.?;
    const raw_text_output = search_execution.shouldRenderRawBinaryText(search_bytes, matcher);

    var capture: std.Io.Writer.Allocating = .init(output_allocator);
    defer capture.deinit();
    var timer = try std.time.Timer.start();

    if (reporting.output_format == .json) {
        try search_output.writeJsonBeginEvent(&capture.writer, entry.path);
    }

    const matched = try search_reporting.writeFileOutput(
        file_allocator,
        &capture.writer,
        searcher,
        entry.path,
        search_bytes,
        matcher.encoding,
        effective_binary_output,
        matcher.invert_match,
        reporting.output,
        reporting.output_format,
        reporting.report_mode,
        reporting.max_count,
        reporting.context_before,
        reporting.context_after,
        search_output_policy.displayMode(raw_text_output),
    );
    const report = matched;

    const pre_end_written = capture.written();
    const elapsed_ns = timer.read();
    if (reporting.output_format == .json) {
        try search_output.writeJsonEndEvent(&capture.writer, entry.path, .{
            .bytes_searched = search_bytes.len,
            .bytes_printed = pre_end_written.len,
            .searches = 1,
            .searches_with_match = if (report.matched) 1 else 0,
            .matched_lines = report.matched_lines,
            .matches = report.matches,
            .elapsed_ns = elapsed_ns,
        });
    }

    const written = capture.written();
    return .{
        .bytes = capture.toArrayList(),
        .searched_bytes = search_bytes.len,
        .printed_bytes = if (reporting.output_format == .json) pre_end_written.len else written.len,
        .matched_lines = report.matched_lines,
        .matches = report.matches,
        .elapsed_ns = elapsed_ns,
        .matched = report.matched,
        .match_events = report.matches,
    };
}
