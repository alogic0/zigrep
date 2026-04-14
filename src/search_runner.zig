const std = @import("std");
const zigrep = struct {
    pub const search = @import("search/root.zig");
};
const command = @import("command.zig");
const search_entry_runner = @import("search_entry_runner.zig");
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

pub fn runSearch(
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    options: CliOptions,
) !u8 {
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

    var result: SearchResult = .{ .matched = false };
    for (options.paths) |path| {
        if (options.buffer_output) {
            var buffered_output: std.Io.Writer.Allocating = .init(allocator);
            defer buffered_output.deinit();

            const path_result = try search_path_runner.searchPath(
                allocator,
                &buffered_output.writer,
                stderr,
                path,
                options,
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
            options,
            type_matcher,
            searchEntriesSequential,
            searchEntriesParallel,
        );
        if (path_result.matched) result.matched = true;
        result.stats.add(path_result.stats);
    }
    if (options.show_stats) try writeStats(stderr, result.stats);
    return if (result.matched) 0 else 1;
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
        if (entry_output.matched) {
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
        _ = try search_path_runner.listPathFiles(
            allocator,
            stdout,
            stderr,
            path,
            options,
            type_matcher,
        );
    }

    return 0;
}

fn searchEntriesParallel(
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    entries: []const zigrep.search.walk.Entry,
    options: CliOptions,
    schedule: zigrep.search.schedule.Plan,
) !SearchResult {
    const worker_allocator = std.heap.smp_allocator;
    if (schedule.worker_count <= 1) {
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
