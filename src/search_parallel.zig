const std = @import("std");
const zigrep = struct {
    pub const search = @import("search/root.zig");
};
const command = @import("command.zig");
const search_entry_runner = @import("search_entry_runner.zig");
const search_execution = @import("search_execution.zig");
const search_output = @import("search_output.zig");
const search_result = @import("search_result.zig");

// Parallel search execution.
// This module owns worker-pool execution and aggregation for already-filtered
// entries. It does not own traversal or per-file search policy.

pub const CliOptions = command.CliOptions;
pub const SearchResult = search_result.SearchResult;

pub fn searchEntriesParallel(
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    entries: []const zigrep.search.walk.Entry,
    options: CliOptions,
    schedule: zigrep.search.schedule.Plan,
) !SearchResult {
    const worker_allocator = std.heap.smp_allocator;
    if (schedule.worker_count <= 1) return error.InvalidFlagValue;

    const StoredOutput = struct {
        bytes: std.ArrayListUnmanaged(u8),
        searched_bytes: usize = 0,
        printed_bytes: usize = 0,
        matched_lines: usize = 0,
        matches: usize = 0,
        elapsed_ns: u64 = 0,
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
                    .printed_bytes = 0,
                    .matched_lines = 0,
                    .matches = 0,
                    .elapsed_ns = 0,
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
                .printed_bytes = entry_output.printed_bytes,
                .matched_lines = entry_output.matched_lines,
                .matches = entry_output.matches,
                .elapsed_ns = entry_output.elapsed_ns,
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
            result.stats.printed_bytes += report.printed_bytes;
            result.stats.matched_lines += report.matched_lines;
            result.stats.matches += report.matches;
            result.stats.elapsed_ns += report.elapsed_ns;
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
