const std = @import("std");
const zigrep = struct {
    pub const search = @import("search/root.zig");
};
const command = @import("command.zig");
const search_entry_runner = @import("search_entry_runner.zig");
const search_execution = @import("search_execution.zig");
const search_output = @import("search_output.zig");
const search_parallel = @import("search_parallel.zig");
const search_path_runner = @import("search_path_runner.zig");
const search_reporting = @import("search_reporting.zig");
const search_result = @import("search_result.zig");

// Top-level search coordination.
// This module owns high-level run coordination and the sequential entry loop,
// while delegating path traversal, parallel execution, per-file execution, and
// reporting to narrower modules.

pub const OutputOptions = command.OutputOptions;
pub const OutputFormat = command.OutputFormat;
pub const BinaryMode = command.BinaryMode;
pub const ReportMode = command.ReportMode;
pub const CliOptions = command.CliOptions;

pub const SearchStats = search_result.SearchStats;
pub const SearchResult = search_result.SearchResult;
const stdin_label = "stdin";

fn isPathOnlyReportMode(mode: ReportMode) bool {
    return mode == .files_with_matches or mode == .files_without_match;
}

fn shouldUseExplicitSingleFileDefaults(options: CliOptions) bool {
    if (options.output.heading or isPathOnlyReportMode(options.report_mode) or options.output_format != .text) return false;
    if (options.used_default_path or options.paths.len != 1) return false;

    const stat = std.fs.cwd().statFile(options.paths[0]) catch return false;
    return stat.kind == .file;
}

fn applyExplicitSingleFileOutputDefaults(options: CliOptions) CliOptions {
    var effective = options;
    if (!shouldUseExplicitSingleFileDefaults(options)) return effective;

    if (!options.filename_flag_seen) effective.output.with_filename = false;
    if (!options.line_number_flag_seen) effective.output.line_number = false;
    if (!options.column_number_flag_seen) effective.output.column_number = false;
    return effective;
}

pub fn runSearch(
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    options: CliOptions,
) !u8 {
    var total_timer = try std.time.Timer.start();
    if (options.multiline and
        (options.invert_match or
            options.max_count != null or
            (options.output.heading and options.report_mode != .lines)))
    {
        return error.InvalidFlagCombination;
    }
    if (options.multiline_dotall and !options.multiline) return error.InvalidFlagCombination;

    const type_matcher = try zigrep.search.types.init(allocator, options.type_adds);
    defer type_matcher.deinit(allocator);
    try zigrep.search.types.validateSelectedTypes(type_matcher, options.include_types, options.exclude_types);

    const effective_options = applyExplicitSingleFileOutputDefaults(options);

    var result: SearchResult = .{ .matched = false };
    for (effective_options.paths) |path| {
        if (effective_options.buffer_output or effective_options.output_format == .json) {
            var buffered_output: std.Io.Writer.Allocating = .init(allocator);
            defer buffered_output.deinit();

            const path_result = try search_path_runner.searchPath(
                allocator,
                &buffered_output.writer,
                stderr,
                path,
                effective_options,
                type_matcher,
                searchEntriesSequential,
                searchEntriesParallel,
            );
            if (path_result.matched) result.matched = true;
            result.stats.add(path_result.stats);
            if (effective_options.output_format == .json) {
                result.stats.matched_lines -= path_result.stats.matched_lines;
                result.stats.matches -= path_result.stats.matches;
                result.stats.matched_lines += countDistinctJsonLineNumbers(buffered_output.written());
                result.stats.matches += countJsonEventType(buffered_output.written(), "\"type\":\"match\"");
            }
            try stdout.writeAll(buffered_output.written());
            continue;
        }

        const path_result = try search_path_runner.searchPath(
            allocator,
            stdout,
            stderr,
            path,
            effective_options,
            type_matcher,
            searchEntriesSequential,
            searchEntriesParallel,
        );
        if (path_result.matched) result.matched = true;
        result.stats.add(path_result.stats);
    }
    if (effective_options.output_format == .json) {
        try search_output.writeJsonSummaryEvent(stdout, .{
            .bytes_searched = result.stats.searched_bytes,
            .bytes_printed = result.stats.printed_bytes,
            .searches = result.stats.searched_files,
            .searches_with_match = result.stats.matched_files,
            .matched_lines = result.stats.matched_lines,
            .matches = result.stats.matches,
            .elapsed_ns = result.stats.elapsed_ns,
            .elapsed_total_ns = total_timer.read(),
        });
    }
    if (effective_options.show_stats) try writeStats(stderr, result.stats);
    return if (result.matched) 0 else 1;
}

pub fn runStdinSearch(
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    options: CliOptions,
    stdin_bytes: []const u8,
) !u8 {
    var total_timer = try std.time.Timer.start();
    if (options.preprocessor != null or options.list_files) return error.InvalidFlagCombination;
    if (options.multiline and
        (options.invert_match or
            options.max_count != null or
            (options.output.heading and options.report_mode != .lines)))
    {
        return error.InvalidFlagCombination;
    }
    if (options.multiline_dotall and !options.multiline) return error.InvalidFlagCombination;

    var searcher = try zigrep.search.grep.Searcher.init(allocator, options.pattern, .{
        .case_mode = options.case_mode,
        .fixed_strings = options.fixed_strings,
        .multiline = options.multiline,
        .multiline_dotall = options.multiline_dotall,
    });
    defer searcher.deinit();

    const search_bytes = try search_execution.prepareSearchBytes(allocator, stdin_label, stdin_bytes, options);
    defer if (search_bytes.ptr != stdin_bytes.ptr) allocator.free(search_bytes);

    const effective_binary_output = if (options.search_compressed)
        search_execution.decideBinaryBehavior(search_bytes, options.encoding, options.binary_mode) orelse {
            const stats: SearchStats = .{ .skipped_binary_files = 1 };
            if (options.show_stats) try writeStats(stderr, stats);
            return 1;
        }
    else
        search_execution.decideBinaryBehavior(stdin_bytes, options.encoding, options.binary_mode) orelse {
            const stats: SearchStats = .{ .skipped_binary_files = 1 };
            if (options.show_stats) try writeStats(stderr, stats);
            return 1;
        };
    const raw_text_output = search_execution.shouldRenderRawBinaryText(search_bytes, options.encoding, options.binary_mode);

    var effective_output = options.output;
    if (!options.filename_flag_seen and options.report_mode != .files_with_matches and options.report_mode != .files_without_match) {
        effective_output.with_filename = false;
    }

    var json_capture: std.Io.Writer.Allocating = .init(allocator);
    defer json_capture.deinit();
    const output_writer = if (options.output_format == .json) &json_capture.writer else stdout;
    var search_timer = try std.time.Timer.start();

    if (options.output_format == .json) {
        try search_output.writeJsonBeginEvent(output_writer, stdin_label);
    }

    const matched = try search_reporting.writeFileOutput(
        allocator,
        output_writer,
        &searcher,
        stdin_label,
        search_bytes,
        options.encoding,
        effective_binary_output,
        options.invert_match,
        effective_output,
        options.output_format,
        options.report_mode,
        options.max_count,
        options.context_before,
        options.context_after,
        if (raw_text_output) .raw else .escaped,
    );

    if (options.output_format == .json) {
        const pre_end_written = json_capture.written();
        const match_events = countJsonEventType(pre_end_written, "\"type\":\"match\"");
        const matched_lines = countDistinctJsonLineNumbers(pre_end_written);
        const elapsed_ns = search_timer.read();
        try search_output.writeJsonEndEvent(output_writer, stdin_label, .{
            .bytes_searched = search_bytes.len,
            .bytes_printed = pre_end_written.len,
            .searches = 1,
            .searches_with_match = if (matched) 1 else 0,
            .matched_lines = matched_lines,
            .matches = match_events,
            .elapsed_ns = elapsed_ns,
        });
        try search_output.writeJsonSummaryEvent(output_writer, .{
            .bytes_searched = search_bytes.len,
            .bytes_printed = pre_end_written.len,
            .searches = 1,
            .searches_with_match = if (matched) 1 else 0,
            .matched_lines = matched_lines,
            .matches = match_events,
            .elapsed_ns = elapsed_ns,
            .elapsed_total_ns = total_timer.read(),
        });
        try stdout.writeAll(json_capture.written());
    }

    const stats: SearchStats = .{
        .searched_files = 1,
        .matched_files = if (matched) 1 else 0,
        .searched_bytes = search_bytes.len,
        .printed_bytes = if (options.output_format == .json) json_capture.written().len else 0,
        .elapsed_ns = if (options.output_format == .json) search_timer.read() else 0,
    };
    if (options.show_stats) try writeStats(stderr, stats);
    return if (matched) 0 else 1;
}

pub fn searchEntriesSequential(
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    entries: []const zigrep.search.walk.Entry,
    options: CliOptions,
) !SearchResult {
    var searcher = try zigrep.search.grep.Searcher.init(allocator, options.pattern, .{
        .case_mode = options.case_mode,
        .fixed_strings = options.fixed_strings,
        .multiline = options.multiline,
        .multiline_dotall = options.multiline_dotall,
    });
    defer searcher.deinit();

    var result: SearchResult = .{ .matched = false };
    var wrote_heading_group = false;
    for (entries) |entry| {
        var file_arena_state = std.heap.ArenaAllocator.init(allocator);
        defer file_arena_state.deinit();
        const file_allocator = file_arena_state.allocator();
        var entry_output = try search_entry_runner.searchEntryToOwnedOutput(
            file_allocator,
            file_allocator,
            stderr,
            &searcher,
            entry,
            options,
        );
        defer entry_output.deinit(file_allocator);

        if (entry_output.warning_emitted) {
            result.stats.warnings_emitted += 1;
            continue;
        }
        if (entry_output.skipped_binary) {
            result.stats.skipped_binary_files += 1;
            continue;
        }

        result.stats.searched_files += 1;
        result.stats.searched_bytes += entry_output.searched_bytes;
        result.stats.printed_bytes += entry_output.printed_bytes;
        result.stats.matched_lines += entry_output.matched_lines;
        result.stats.matches += entry_output.matches;
        result.stats.elapsed_ns += entry_output.elapsed_ns;
        if (entry_output.matched) {
            if (options.quiet) {
                result.matched = true;
                result.stats.matched_files += 1;
                return result;
            }
            if (options.output.heading) {
                try search_output.writeHeadingBlock(stdout, entry.path, entry_output.bytes.items, &wrote_heading_group);
            } else {
                try stdout.writeAll(entry_output.bytes.items);
            }
            result.matched = true;
            result.stats.matched_files += 1;
        }
    }

    return result;
}

pub fn runFileList(
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    options: CliOptions,
) !u8 {
    const type_matcher = try zigrep.search.types.init(allocator, options.type_adds);
    defer type_matcher.deinit(allocator);
    try zigrep.search.types.validateSelectedTypes(type_matcher, options.include_types, options.exclude_types);

    for (options.paths) |path| {
        const listed = try search_path_runner.listPathFiles(
            allocator,
            stdout,
            stderr,
            path,
            options,
            type_matcher,
        );
        if (options.quiet and listed != 0) return 0;
    }

    return if (options.quiet) 1 else 0;
}

fn searchEntriesParallel(
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    entries: []const zigrep.search.walk.Entry,
    options: CliOptions,
    schedule: zigrep.search.schedule.Plan,
) !SearchResult {
    const worker_allocator = std.heap.smp_allocator;
    if (options.quiet or schedule.worker_count <= 1) {
        return searchEntriesSequential(worker_allocator, stdout, stderr, entries, options);
    }
    return search_parallel.searchEntriesParallel(stdout, stderr, entries, options, schedule);
}

fn writeStats(writer: *std.Io.Writer, stats: SearchStats) !void {
    try writer.print(
        "stats: searched_files={d} matched_files={d} searched_bytes={d} skipped_binary_files={d} warnings_emitted={d}\n",
        .{ stats.searched_files, stats.matched_files, stats.searched_bytes, stats.skipped_binary_files, stats.warnings_emitted },
    );
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
