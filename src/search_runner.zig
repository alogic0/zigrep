const std = @import("std");
const zigrep = struct {
    pub const search = @import("search/root.zig");
};
const command = @import("command.zig");
const search_entry_runner = @import("search_entry_runner.zig");
const search_execution = @import("search_execution.zig");
const search_output = @import("search_output.zig");
const search_output_policy = @import("search_output_policy.zig");
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
const stdin_json_label = "<stdin>";

pub fn runSearch(
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    options: CliOptions,
) !u8 {
    var total_timer = try std.time.Timer.start();
    const traversal = options.traversal();
    const matcher = options.matcher();
    const reporting = options.reporting();
    if (matcher.multiline and
        (matcher.invert_match or
            reporting.max_count != null or
            (reporting.output.heading and reporting.report_mode != .lines)))
    {
        return error.InvalidFlagCombination;
    }
    if (matcher.multiline_dotall and !matcher.multiline) return error.InvalidFlagCombination;

    const type_matcher = try zigrep.search.types.init(allocator, traversal.type_adds);
    defer type_matcher.deinit(allocator);
    try zigrep.search.types.validateSelectedTypes(type_matcher, traversal.include_types, traversal.exclude_types);

    const effective_options = search_output_policy.effectivePathSearchOptions(options);
    const effective_traversal = effective_options.traversal();
    const effective_reporting = effective_options.reporting();

    var result: SearchResult = .{ .matched = false };
    for (effective_traversal.paths) |path| {
        if (effective_traversal.buffer_output) {
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
    if (effective_reporting.show_stats) try writeStats(stderr, result.stats, total_timer.read());
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
    const traversal = options.traversal();
    const matcher = options.matcher();
    const reporting = search_output_policy.effectiveStdinReporting(options);
    if (traversal.preprocessor != null or traversal.list_files) return error.InvalidFlagCombination;
    if (matcher.multiline and
        (matcher.invert_match or
            reporting.max_count != null or
            (reporting.output.heading and reporting.report_mode != .lines)))
    {
        return error.InvalidFlagCombination;
    }
    if (matcher.multiline_dotall and !matcher.multiline) return error.InvalidFlagCombination;

    var searcher = try zigrep.search.grep.Searcher.init(allocator, matcher.pattern, .{
        .case_mode = matcher.case_mode,
        .fixed_strings = matcher.fixed_strings,
        .multiline = matcher.multiline,
        .multiline_dotall = matcher.multiline_dotall,
    });
    defer searcher.deinit();

    const search_bytes = try search_execution.prepareSearchBytes(allocator, stdin_label, stdin_bytes, traversal);
    defer if (search_bytes.ptr != stdin_bytes.ptr) allocator.free(search_bytes);

    const effective_binary_output = if (traversal.search_compressed)
        search_execution.decideBinaryBehavior(search_bytes, matcher) orelse {
            const stats: SearchStats = .{ .skipped_binary_files = 1 };
            if (reporting.show_stats) try writeStats(stderr, stats, total_timer.read());
            return 1;
        }
    else
        search_execution.decideBinaryBehavior(stdin_bytes, matcher) orelse {
            const stats: SearchStats = .{ .skipped_binary_files = 1 };
            if (reporting.show_stats) try writeStats(stderr, stats, total_timer.read());
            return 1;
        };
    const raw_text_output = search_execution.shouldRenderRawBinaryText(search_bytes, matcher);

    var json_capture: std.Io.Writer.Allocating = .init(allocator);
    defer json_capture.deinit();
    const output_writer = if (reporting.output_format == .json) &json_capture.writer else stdout;
    var search_timer = try std.time.Timer.start();

    if (reporting.output_format == .json) {
        try search_output.writeJsonBeginEvent(output_writer, stdin_json_label);
    }

    const report = try search_reporting.writeFileOutput(
        allocator,
        output_writer,
        &searcher,
        if (reporting.output_format == .json) stdin_json_label else stdin_label,
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

    if (reporting.output_format == .json) {
        const pre_end_written = json_capture.written();
        const elapsed_ns = search_timer.read();
        try search_output.writeJsonEndEvent(output_writer, stdin_json_label, .{
            .bytes_searched = search_bytes.len,
            .bytes_printed = pre_end_written.len,
            .searches = 1,
            .searches_with_match = if (report.matched) 1 else 0,
            .matched_lines = report.matched_lines,
            .matches = report.matches,
            .elapsed_ns = elapsed_ns,
        });
        try search_output.writeJsonSummaryEvent(output_writer, .{
            .bytes_searched = search_bytes.len,
            .bytes_printed = pre_end_written.len,
            .searches = 1,
            .searches_with_match = if (report.matched) 1 else 0,
            .matched_lines = report.matched_lines,
            .matches = report.matches,
            .elapsed_ns = elapsed_ns,
            .elapsed_total_ns = total_timer.read(),
        });
        try stdout.writeAll(json_capture.written());
    }

    const stats: SearchStats = .{
        .searched_files = 1,
        .matched_files = if (report.matched) 1 else 0,
        .searched_bytes = search_bytes.len,
        .printed_bytes = if (reporting.output_format == .json) json_capture.written().len else 0,
        .matched_lines = report.matched_lines,
        .matches = report.matches,
        .elapsed_ns = if (reporting.output_format == .json) search_timer.read() else 0,
    };
    if (reporting.show_stats) try writeStats(stderr, stats, total_timer.read());
    return if (report.matched) 0 else 1;
}

pub fn searchEntriesSequential(
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    entries: []const zigrep.search.walk.Entry,
    options: CliOptions,
) !SearchResult {
    const matcher = options.matcher();
    const reporting = options.reporting();
    const entry_options: search_entry_runner.EntrySearchOptions = .{
        .traversal = options.traversal(),
        .matcher = matcher,
        .reporting = reporting,
    };
    var searcher = try zigrep.search.grep.Searcher.init(allocator, matcher.pattern, .{
        .case_mode = matcher.case_mode,
        .fixed_strings = matcher.fixed_strings,
        .multiline = matcher.multiline,
        .multiline_dotall = matcher.multiline_dotall,
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
            entry_options,
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
            if (reporting.quiet) {
                result.matched = true;
                result.stats.matched_files += 1;
                return result;
            }
            if (reporting.output.heading) {
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
    const traversal = options.traversal();
    const reporting = options.reporting();
    const type_matcher = try zigrep.search.types.init(allocator, traversal.type_adds);
    defer type_matcher.deinit(allocator);
    try zigrep.search.types.validateSelectedTypes(type_matcher, traversal.include_types, traversal.exclude_types);

    for (traversal.paths) |path| {
        const listed = try search_path_runner.listPathFiles(
            allocator,
            stdout,
            stderr,
            path,
            options,
            type_matcher,
        );
        if (reporting.quiet and listed != 0) return 0;
    }

    return if (reporting.quiet) 1 else 0;
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

fn writeStats(writer: *std.Io.Writer, stats: SearchStats, total_elapsed_ns: u64) !void {
    const search_secs_whole = stats.elapsed_ns / std.time.ns_per_s;
    const search_secs_frac = (stats.elapsed_ns % std.time.ns_per_s) / std.time.ns_per_us;
    const total_secs_whole = total_elapsed_ns / std.time.ns_per_s;
    const total_secs_frac = (total_elapsed_ns % std.time.ns_per_s) / std.time.ns_per_us;

    try writer.print(
        "\n{d} matches\n{d} matched lines\n{d} files contained matches\n{d} files searched\n{d} bytes printed\n{d} bytes searched\n{d}.{d:0>6} seconds spent searching\n{d}.{d:0>6} seconds total\n",
        .{
            stats.matches,
            stats.matched_lines,
            stats.matched_files,
            stats.searched_files,
            stats.printed_bytes,
            stats.searched_bytes,
            search_secs_whole,
            search_secs_frac,
            total_secs_whole,
            total_secs_frac,
        },
    );
    if (stats.skipped_binary_files != 0) {
        try writer.print("{d} {s} skipped as binary\n", .{
            stats.skipped_binary_files,
            if (stats.skipped_binary_files == 1) "file was" else "files were",
        });
    }
    if (stats.warnings_emitted != 0) {
        try writer.print("{d} {s} emitted\n", .{
            stats.warnings_emitted,
            if (stats.warnings_emitted == 1) "warning was" else "warnings were",
        });
    }
}
