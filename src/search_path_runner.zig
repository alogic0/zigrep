const std = @import("std");
const zigrep = struct {
    pub const search = @import("search/root.zig");
};
const command = @import("command.zig");
const search_execution = @import("search_execution.zig");
const search_filtering = @import("search_filtering.zig");
const search_result = @import("search_result.zig");

// Path-level search orchestration.
// This module owns directory traversal, ignore loading, entry filtering, and
// schedule selection for one root path.

pub const CliOptions = command.CliOptions;
pub const SearchResult = search_result.SearchResult;

pub fn searchPath(
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    root_path: []const u8,
    options: CliOptions,
    type_matcher: zigrep.search.types.Matcher,
    sequentialFn: *const fn (std.mem.Allocator, *std.Io.Writer, *std.Io.Writer, []const zigrep.search.walk.Entry, CliOptions) anyerror!SearchResult,
    parallelFn: *const fn (*std.Io.Writer, *std.Io.Writer, []const zigrep.search.walk.Entry, CliOptions, zigrep.search.schedule.Plan) anyerror!SearchResult,
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
        try parallelFn(stdout, stderr, filtered_entries, options, schedule)
    else
        try sequentialFn(allocator, stdout, stderr, filtered_entries, options);
    result.stats.warnings_emitted += traversal_warning_count;
    return result;
}
