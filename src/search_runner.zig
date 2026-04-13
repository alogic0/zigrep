const std = @import("std");
const zigrep = struct {
    pub const search = @import("search/root.zig");
};
const command = @import("command.zig");
const search_entry_runner = @import("search_entry_runner.zig");
const search_execution = @import("search_execution.zig");
const search_filtering = @import("search_filtering.zig");
const search_output = @import("search_output.zig");

pub const OutputOptions = command.OutputOptions;
pub const OutputFormat = command.OutputFormat;
pub const BinaryMode = command.BinaryMode;
pub const ReportMode = command.ReportMode;
pub const CliOptions = command.CliOptions;

pub const SearchStats = struct {
    searched_files: usize = 0,
    matched_files: usize = 0,
    searched_bytes: usize = 0,
    skipped_binary_files: usize = 0,
    warnings_emitted: usize = 0,

    fn add(self: *SearchStats, other: SearchStats) void {
        self.searched_files += other.searched_files;
        self.matched_files += other.matched_files;
        self.searched_bytes += other.searched_bytes;
        self.skipped_binary_files += other.skipped_binary_files;
        self.warnings_emitted += other.warnings_emitted;
    }
};

pub const SearchResult = struct {
    matched: bool,
    stats: SearchStats = .{},
};

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

            const path_result = try searchPath(allocator, &buffered_output.writer, stderr, path, options, type_matcher);
            if (path_result.matched) result.matched = true;
            result.stats.add(path_result.stats);
            try stdout.writeAll(buffered_output.written());
            continue;
        }

        const path_result = try searchPath(allocator, stdout, stderr, path, options, type_matcher);
        if (path_result.matched) result.matched = true;
        result.stats.add(path_result.stats);
    }
    if (options.show_stats) try writeStats(stderr, result.stats);
    return if (result.matched) 0 else 1;
}

fn searchPath(
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    root_path: []const u8,
    options: CliOptions,
    type_matcher: zigrep.search.types.Matcher,
) !SearchResult {
    var traversal_warning_count: usize = 0;
    const TraversalWarningHandler = struct {
        writer: *std.Io.Writer,
        count: *usize,

        pub fn warn(self: @This(), path: []const u8, err: anyerror) void {
            self.writer.print("warning: skipping directory {s}: {s}\n", .{ path, search_execution.warningMessage(err) }) catch {};
            self.count.* += 1;
        }
    };

    const entries = try zigrep.search.walk.collectFilesWithWarnings(allocator, root_path, .{
        .include_hidden = options.include_hidden,
        .follow_symlinks = options.follow_symlinks,
        .max_depth = options.max_depth,
    }, TraversalWarningHandler{ .writer = stderr, .count = &traversal_warning_count });
    defer {
        for (entries) |entry| entry.deinit(allocator);
        allocator.free(entries);
    }

    const loaded_ignores = try search_filtering.loadIgnoreMatchers(allocator, root_path, options);
    defer search_filtering.deinitLoadedIgnores(allocator, loaded_ignores);

    const filtered_entries = try search_filtering.filterEntries(
        allocator,
        root_path,
        entries,
        options.globs,
        loaded_ignores,
        type_matcher,
        options.include_types,
        options.exclude_types,
    );
    defer allocator.free(filtered_entries);

    const schedule = zigrep.search.schedule.plan(filtered_entries.len, .{
        .requested_jobs = options.parallel_jobs,
    });
    var result = if (schedule.parallel)
        try searchEntriesParallel(stdout, stderr, filtered_entries, options, schedule)
    else
        try searchEntriesSequential(allocator, stdout, stderr, filtered_entries, options);
    result.stats.warnings_emitted += traversal_warning_count;
    return result;
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

    const StoredOutput = struct {
        bytes: std.ArrayListUnmanaged(u8),
        searched_bytes: usize = 0,
        matched: bool = false,
        skipped_binary: bool = false,
        path: ?[]u8 = null,

        fn deinit(self: @This()) void {
            var bytes = self.bytes;
            bytes.deinit(std.heap.smp_allocator);
            if (self.path) |path| std.heap.smp_allocator.free(path);
        }
    };

    const Context = struct {
        stderr: *std.Io.Writer,
        entries: []const zigrep.search.walk.Entry,
        options: CliOptions,
        schedule: zigrep.search.schedule.Plan,
        next_index: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
        result_reports: []?StoredOutput,
        first_error: ?anyerror = null,
        warning_count: usize = 0,
        error_mutex: std.Thread.Mutex = .{},
        warning_mutex: std.Thread.Mutex = .{},

        fn setError(self: *@This(), err: anyerror) void {
            self.error_mutex.lock();
            defer self.error_mutex.unlock();
            if (self.first_error == null) self.first_error = err;
        }

        fn runWorker(self: *@This()) void {
            var searcher = zigrep.search.grep.Searcher.init(std.heap.smp_allocator, self.options.pattern, .{
                .case_mode = self.options.case_mode,
                .multiline = self.options.multiline,
                .multiline_dotall = self.options.multiline_dotall,
            }) catch |err| {
                self.setError(err);
                return;
            };
            defer searcher.deinit();

            while (true) {
                if (self.first_error != null) return;

                const start = self.next_index.fetchAdd(self.schedule.chunk_size, .monotonic);
                if (start >= self.entries.len) return;

                const end = @min(start + self.schedule.chunk_size, self.entries.len);
                for (start..end) |index| {
                    const entry = self.entries[index];
                    self.processEntry(&searcher, index, entry) catch |err| {
                        self.setError(err);
                        return;
                    };
                }
            }
        }

        fn processEntry(
            self: *@This(),
            searcher: *zigrep.search.grep.Searcher,
            index: usize,
            entry: zigrep.search.walk.Entry,
        ) !void {
            var file_arena_state = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer file_arena_state.deinit();
            const file_allocator = file_arena_state.allocator();
            var entry_output = search_entry_runner.searchEntryToOwnedOutput(
                file_allocator,
                std.heap.smp_allocator,
                self.stderr,
                searcher,
                entry,
                self.options,
            ) catch |err| {
                if (try self.warnAndSkip(entry.path, err)) return;
                return err;
            };
            errdefer entry_output.deinit(std.heap.smp_allocator);
            if (entry_output.warning_emitted) {
                self.warning_mutex.lock();
                self.warning_count += 1;
                self.warning_mutex.unlock();
                return;
            }
            if (entry_output.skipped_binary) {
                self.result_reports[index] = .{
                    .bytes = .empty,
                    .searched_bytes = 0,
                    .matched = false,
                    .skipped_binary = true,
                    .path = null,
                };
                entry_output.deinit(std.heap.smp_allocator);
                return;
            }
            self.result_reports[index] = .{
                .bytes = entry_output.bytes,
                .searched_bytes = entry_output.searched_bytes,
                .matched = entry_output.matched,
                .skipped_binary = false,
                .path = if (self.options.output.heading) try std.heap.smp_allocator.dupe(u8, entry.path) else null,
            };
        }

        fn warnAndSkip(self: *@This(), path: []const u8, err: anyerror) !bool {
            self.warning_mutex.lock();
            defer self.warning_mutex.unlock();
            const skipped = try search_execution.warnAndSkipFileError(self.stderr, path, err);
            if (skipped) self.warning_count += 1;
            return skipped;
        }
    };

    const result_reports = try worker_allocator.alloc(?StoredOutput, entries.len);
    defer worker_allocator.free(result_reports);
    @memset(result_reports, null);

    var pool: std.Thread.Pool = undefined;
    try pool.init(.{
        .allocator = worker_allocator,
        .n_jobs = schedule.worker_count,
    });
    defer pool.deinit();

    var wait_group: std.Thread.WaitGroup = .{};
    var context = Context{
        .stderr = stderr,
        .entries = entries,
        .options = options,
        .schedule = schedule,
        .result_reports = result_reports,
    };

    for (0..schedule.worker_count) |_| {
        pool.spawnWg(&wait_group, Context.runWorker, .{&context});
    }
    wait_group.wait();

    if (context.first_error) |err| {
        for (result_reports) |maybe_report| {
            if (maybe_report) |report| report.deinit();
        }
        return err;
    }

    var result: SearchResult = .{ .matched = false };
    result.stats.warnings_emitted += context.warning_count;
    var wrote_heading_group = false;
    for (result_reports) |maybe_report| {
        if (maybe_report) |report| {
            defer report.deinit();
            if (report.skipped_binary) {
                result.stats.skipped_binary_files += 1;
                continue;
            }
            result.stats.searched_files += 1;
            result.stats.searched_bytes += report.searched_bytes;
            if (report.matched) {
                if (options.output.heading) {
                    try search_output.writeHeadingBlock(stdout, report.path.?, report.bytes.items, &wrote_heading_group);
                } else {
                    try stdout.writeAll(report.bytes.items);
                }
                result.matched = true;
                result.stats.matched_files += 1;
            }
        }
    }
    return result;
}

fn printReport(
    stdout: *std.Io.Writer,
    report: zigrep.search.grep.MatchReport,
    output: OutputOptions,
) !void {
    try search_output.writeReport(stdout, report, output);
}

fn writeStats(writer: *std.Io.Writer, stats: SearchStats) !void {
    try writer.print(
        "stats: searched_files={d} matched_files={d} searched_bytes={d} skipped_binary_files={d} warnings_emitted={d}\n",
        .{ stats.searched_files, stats.matched_files, stats.searched_bytes, stats.skipped_binary_files, stats.warnings_emitted },
    );
}

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
) !bool {
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
        matched_lines: usize = 0,
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
            switch (self.output_format) {
                .text => try search_output.writeReport(self.writer, report, self.output),
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
    };
    context.output = output;

    if (try zigrep.search.io.decodeToUtf8Alloc(allocator, bytes, encoding)) |decoded| {
        defer allocator.free(decoded);
        if (output.only_matching) {
            return searcher.forEachMatchReport(path, decoded, &context, WriterContext.emit) catch |err| switch (err) {
                IterationStop.MaxCountReached => context.matched_lines != 0,
                else => return err,
            };
        }
        return searcher.forEachLineReport(path, decoded, &context, WriterContext.emit) catch |err| switch (err) {
            IterationStop.MaxCountReached => context.matched_lines != 0,
            else => return err,
        };
    }

    if (output.only_matching) {
        return searcher.forEachMatchReport(path, bytes, &context, WriterContext.emit) catch |err| switch (err) {
            IterationStop.MaxCountReached => context.matched_lines != 0,
            else => return err,
        };
    }

    return searcher.forEachLineReport(path, bytes, &context, WriterContext.emit) catch |err| switch (err) {
        IterationStop.MaxCountReached => context.matched_lines != 0,
        else => return err,
    };
}

fn writeContextLine(
    writer: *std.Io.Writer,
    path: []const u8,
    line_number: usize,
    line: []const u8,
    output: OutputOptions,
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
    try search_output.writeDisplayLine(writer, line);
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
) !bool {
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

    if (matched_lines.items.len == 0) return false;

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
            try search_output.writeReport(writer, matched_lines.items[match_index].report, output);
        } else {
            try writeContextLine(writer, path, line_index + 1, haystack[line_span.start..line_span.end], output);
        }
    }

    return true;
}

fn writeMultilineReportBlock(
    writer: *std.Io.Writer,
    path: []const u8,
    info: zigrep.search.report.DisplayBlockInfo,
    haystack: []const u8,
    output: OutputOptions,
) !void {
    try search_output.writePrefixedDisplayBytes(
        writer,
        path,
        info.line_number,
        info.column_number,
        haystack[info.block.block_span.start..info.block.block_span.end],
        output,
        true,
    );
}

fn writeFileReportsMultiline(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    searcher: *zigrep.search.grep.Searcher,
    path: []const u8,
    haystack: []const u8,
    output: OutputOptions,
) !bool {
    const matches = try collectMultilineMatchesAlloc(allocator, searcher, path, haystack);
    defer allocator.free(matches);
    if (matches.len == 0) return false;

    const merged = try mergeMultilineMatchesAlloc(allocator, matches);
    defer allocator.free(merged);

    for (merged) |info| {
        try writeMultilineReportBlock(writer, path, info, haystack, output);
    }

    return true;
}

fn writeFileOnlyMatchingMultiline(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    searcher: *zigrep.search.grep.Searcher,
    path: []const u8,
    haystack: []const u8,
    output: OutputOptions,
) !bool {
    const line_spans = try zigrep.search.report.collectLineSpansAlloc(allocator, haystack);
    defer allocator.free(line_spans);

    const Context = struct {
        writer: *std.Io.Writer,
        haystack: []const u8,
        line_spans: []const zigrep.search.report.Span,
        output: OutputOptions,
        matched: bool = false,

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
            );
            self.matched = true;
        }
    };

    var context = Context{
        .writer = writer,
        .haystack = haystack,
        .line_spans = line_spans,
        .output = output,
    };

    _ = try searcher.forEachMatchReport(path, haystack, &context, Context.emit);
    return context.matched;
}

fn writeMultilineJsonMatchEvent(
    writer: *std.Io.Writer,
    path: []const u8,
    haystack: []const u8,
    match_info: MultilineMatchInfo,
    output: OutputOptions,
) !void {
    const display_slice = if (output.only_matching)
        haystack[match_info.match_span.start..match_info.match_span.end]
    else
        haystack[match_info.display.block.block_span.start..match_info.display.block.block_span.end];
    const line_span = if (output.only_matching)
        match_info.match_span
    else
        match_info.display.block.block_span;

    try writer.writeAll("{\"type\":\"match\",\"data\":{");
    try writer.writeAll("\"path\":");
    try search_output.writeJsonString(writer, path);
    try writer.print(",\"line_number\":{d},\"column_number\":{d}", .{ match_info.display.line_number, match_info.display.column_number });
    try writer.writeAll(",\"line\":");
    try search_output.writeJsonString(writer, display_slice);
    try writer.print(",\"line_span\":{{\"start\":{d},\"end\":{d}}}", .{ line_span.start, line_span.end });
    try writer.print(",\"match_span\":{{\"start\":{d},\"end\":{d}}}", .{ match_info.match_span.start, match_info.match_span.end });
    try writer.writeAll("}}\n");
}

fn writeFileCountMultiline(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    searcher: *zigrep.search.grep.Searcher,
    path: []const u8,
    haystack: []const u8,
    output_format: OutputFormat,
) !bool {
    const matches = try collectMultilineMatchesAlloc(allocator, searcher, path, haystack);
    defer allocator.free(matches);
    if (matches.len == 0) return false;

    switch (output_format) {
        .text => try writer.print("{s}:{d}\n", .{ path, matches.len }),
        .json => try search_output.writeJsonCountEvent(writer, path, matches.len),
    }
    return true;
}

fn writeFileReportsWithContextMultiline(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    searcher: *zigrep.search.grep.Searcher,
    path: []const u8,
    haystack: []const u8,
    output: OutputOptions,
    context_before: usize,
    context_after: usize,
) !bool {
    const matches = try collectMultilineMatchesAlloc(allocator, searcher, path, haystack);
    defer allocator.free(matches);
    if (matches.len == 0) return false;

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
            try writeMultilineReportBlock(writer, path, info, haystack, output);
            previous_included = info.block.end_line_index;
            line_index = info.block.end_line_index + 1;
            continue;
        }

        previous_included = line_index;
        const line_span = line_spans[line_index];
        try writeContextLine(writer, path, line_index + 1, haystack[line_span.start..line_span.end], output);
        line_index += 1;
    }

    return true;
}

const MultilineMatchInfo = struct {
    display: zigrep.search.report.DisplayBlockInfo,
    match_span: zigrep.search.report.Span,
};

fn collectMultilineMatchesAlloc(
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

fn mergeMultilineMatchesAlloc(
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
) !bool {
    if (suppress_binary_output) {
        return switch (report_mode) {
            .lines => writeBinaryFileMatchNotice(allocator, writer, searcher, path, bytes, encoding, invert_match),
            .files_with_matches => writeFilePathOnMatch(allocator, writer, searcher, path, bytes, encoding, invert_match, output, output_format),
            .files_without_match => writeFilePathWithoutMatch(allocator, writer, searcher, path, bytes, encoding, invert_match, output, output_format),
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
        ),
        .count => writeFileCount(allocator, writer, searcher, path, bytes, encoding, invert_match, output, output_format, max_count),
        .files_with_matches => writeFilePathOnMatch(allocator, writer, searcher, path, bytes, encoding, invert_match, output, output_format),
        .files_without_match => writeFilePathWithoutMatch(allocator, writer, searcher, path, bytes, encoding, invert_match, output, output_format),
    };
}

fn writeBinaryFileMatchNotice(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    searcher: *zigrep.search.grep.Searcher,
    path: []const u8,
    bytes: []const u8,
    encoding: zigrep.search.io.InputEncoding,
    invert_match: bool,
) !bool {
    const has_match = if (invert_match)
        try countInvertedLines(allocator, searcher, path, bytes, encoding, null) != 0
    else
        (try reportFileMatch(allocator, searcher, path, bytes, encoding)) != null;
    if (!has_match) return false;
    try search_output.writeBinaryMatchNotice(writer, path);
    return true;
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
) !bool {
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
                return writeFileOnlyMatchingMultiline(allocator, writer, searcher, path, decoded, output);
            }
            if (context_before != 0 or context_after != 0) {
                if (output_format != .text) return error.InvalidFlagCombination;
                return writeFileReportsWithContextMultiline(
                    allocator,
                    writer,
                    searcher,
                    path,
                    decoded,
                    output,
                    context_before,
                    context_after,
                );
            }
            if (output_format == .json) {
                const matches = try collectMultilineMatchesAlloc(allocator, searcher, path, decoded);
                defer allocator.free(matches);
                if (matches.len == 0) return false;
                for (matches) |match_info| try writeMultilineJsonMatchEvent(writer, path, decoded, match_info, output);
                return true;
            }
            return writeFileReportsMultiline(allocator, writer, searcher, path, decoded, output);
        }
        if (invert_match) {
            return writeInvertedFileReports(allocator, writer, searcher, path, decoded, output, output_format, max_count);
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
            );
        }
        return writeFileReports(allocator, writer, searcher, path, decoded, .utf8, output, output_format, max_count);
    }

    if (searcher.program.can_match_newline) {
        if (invert_match or max_count != null) {
            return error.InvalidFlagCombination;
        }
        if (output.only_matching) {
            if (context_before != 0 or context_after != 0 or output_format == .json) {
                return error.InvalidFlagCombination;
            }
            return writeFileOnlyMatchingMultiline(allocator, writer, searcher, path, bytes, output);
        }
        if (context_before != 0 or context_after != 0) {
            if (output_format != .text) return error.InvalidFlagCombination;
            return writeFileReportsWithContextMultiline(
                allocator,
                writer,
                searcher,
                path,
                bytes,
                output,
                context_before,
                context_after,
            );
        }
        if (output_format == .json) {
            const matches = try collectMultilineMatchesAlloc(allocator, searcher, path, bytes);
            defer allocator.free(matches);
            if (matches.len == 0) return false;
            for (matches) |match_info| try writeMultilineJsonMatchEvent(writer, path, bytes, match_info, output);
            return true;
        }
        return writeFileReportsMultiline(allocator, writer, searcher, path, bytes, output);
    }

    if (invert_match) {
        return writeInvertedFileReports(allocator, writer, searcher, path, bytes, output, output_format, max_count);
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
        );
    }
    return writeFileReports(allocator, writer, searcher, path, bytes, .utf8, output, output_format, max_count);
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
) !bool {
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
            .owned_line = null,
            .line_span = line_span,
            .match_span = line_span,
        };
        switch (output_format) {
            .text => try search_output.writeReport(writer, report, output),
            .json => try search_output.writeJsonMatchEvent(writer, report, output),
        }
    }
    return selected_count != 0;
}

fn writeFileCount(
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
) !bool {
    if (max_count != null and searcher.program.can_match_newline) return error.InvalidFlagCombination;

    const IterationStop = error{MaxCountReached};

    const Counter = struct {
        count: usize = 0,
        max_count: ?usize,

        fn emit(self: *@This(), report: zigrep.search.grep.MatchReport) !void {
            _ = report;
            self.count += 1;
            if (self.max_count) |limit| {
                if (self.count >= limit) return IterationStop.MaxCountReached;
            }
        }
    };

    var counter = Counter{ .max_count = max_count };

    if (invert_match) {
        const count = try countInvertedLines(allocator, searcher, path, bytes, encoding, max_count);
        if (count == 0) return false;
        switch (output_format) {
            .text => if (output.with_filename) {
                try writer.print("{s}:{d}\n", .{ path, count });
            } else {
                try writer.print("{d}\n", .{count});
            },
            .json => try search_output.writeJsonCountEvent(writer, path, count),
        }
        return true;
    }

    if (try zigrep.search.io.decodeToUtf8Alloc(allocator, bytes, encoding)) |decoded| {
        defer allocator.free(decoded);
        if (searcher.program.can_match_newline) {
            return writeFileCountMultiline(allocator, writer, searcher, path, decoded, output_format);
        }
        _ = searcher.forEachLineReport(path, decoded, &counter, Counter.emit) catch |err| switch (err) {
            IterationStop.MaxCountReached => true,
            else => return err,
        };
    } else {
        if (searcher.program.can_match_newline) {
            return writeFileCountMultiline(allocator, writer, searcher, path, bytes, output_format);
        }
        _ = searcher.forEachLineReport(path, bytes, &counter, Counter.emit) catch |err| switch (err) {
            IterationStop.MaxCountReached => true,
            else => return err,
        };
    }

    if (counter.count == 0) return false;
    switch (output_format) {
        .text => if (output.with_filename) {
            try writer.print("{s}:{d}\n", .{ path, counter.count });
        } else {
            try writer.print("{d}\n", .{counter.count});
        },
        .json => try search_output.writeJsonCountEvent(writer, path, counter.count),
    }
    return true;
}

fn countInvertedLines(
    allocator: std.mem.Allocator,
    searcher: *zigrep.search.grep.Searcher,
    path: []const u8,
    bytes: []const u8,
    encoding: zigrep.search.io.InputEncoding,
    max_count: ?usize,
) !usize {
    const haystack = if (try zigrep.search.io.decodeToUtf8Alloc(allocator, bytes, encoding)) |decoded|
        decoded
    else
        bytes;
    defer if (haystack.ptr != bytes.ptr) allocator.free(haystack);

    const line_spans = try zigrep.search.report.collectLineSpansAlloc(allocator, haystack);
    defer allocator.free(line_spans);

    var count: usize = 0;
    for (line_spans) |line_span| {
        const line = haystack[line_span.start..line_span.end];
        const is_match = (try searcher.reportFirstMatch(path, line)) != null;
        if (is_match) continue;
        count += 1;
        if (max_count) |limit| {
            if (count >= limit) break;
        }
    }
    return count;
}

fn writeFilePathOnMatch(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    searcher: *zigrep.search.grep.Searcher,
    path: []const u8,
    bytes: []const u8,
    encoding: zigrep.search.io.InputEncoding,
    invert_match: bool,
    output: OutputOptions,
    output_format: OutputFormat,
) !bool {
    if (invert_match) {
        if (try countInvertedLines(allocator, searcher, path, bytes, encoding, null) == 0) return false;
    } else {
        const report = try reportFileMatch(allocator, searcher, path, bytes, encoding) orelse return false;
        defer report.deinit(allocator);
    }
    switch (output_format) {
        .text => try search_output.writePathResult(writer, path, output),
        .json => try search_output.writeJsonPathEvent(writer, path, true),
    }
    return true;
}

fn writeFilePathWithoutMatch(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    searcher: *zigrep.search.grep.Searcher,
    path: []const u8,
    bytes: []const u8,
    encoding: zigrep.search.io.InputEncoding,
    invert_match: bool,
    output: OutputOptions,
    output_format: OutputFormat,
) !bool {
    if (invert_match) {
        if (try countInvertedLines(allocator, searcher, path, bytes, encoding, null) != 0) return false;
    } else {
        const report = try reportFileMatch(allocator, searcher, path, bytes, encoding);
        if (report) |found| {
            found.deinit(allocator);
            return false;
        }
    }
    switch (output_format) {
        .text => try search_output.writePathResult(writer, path, output),
        .json => try search_output.writeJsonPathEvent(writer, path, false),
    }
    return true;
}

pub fn reportFileMatch(
    allocator: std.mem.Allocator,
    searcher: *zigrep.search.grep.Searcher,
    path: []const u8,
    bytes: []const u8,
    encoding: zigrep.search.io.InputEncoding,
) !?zigrep.search.grep.MatchReport {
    if (try zigrep.search.io.decodeToUtf8Alloc(allocator, bytes, encoding)) |decoded| {
        defer allocator.free(decoded);
        if (try searcher.reportFirstMatch(path, decoded)) |report| {
            const owned_line = try allocator.dupe(u8, report.line);
            var stable = report;
            stable.line = owned_line;
            stable.owned_line = owned_line;
            return stable;
        }
        return null;
    }

    return searcher.reportFirstMatch(path, bytes);
}

pub fn formatReport(
    allocator: std.mem.Allocator,
    report: zigrep.search.grep.MatchReport,
    output: OutputOptions,
) ![]u8 {
    return search_output.formatReport(allocator, report, output);
}
