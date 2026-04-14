const std = @import("std");
const zigrep = struct {
    pub const search = @import("search/root.zig");
};
const command = @import("command.zig");
const sort_capability = @import("sort_capability.zig");
const search_execution = @import("search_execution.zig");
const search_filtering = @import("search_filtering.zig");
const search_output = @import("search_output.zig");
const search_result = @import("search_result.zig");

// Path-level search orchestration.
// This module owns directory traversal, ignore loading, entry filtering, and
// schedule selection for one root path.

pub const CliOptions = command.CliOptions;
pub const SearchResult = search_result.SearchResult;

fn validateSortMode(options: CliOptions) !void {
    const traversal = options.traversal();
    if (traversal.sort_mode != .created) return;

    return switch (sort_capability.createdSortCapability()) {
        .available => {},
        .unavailable_platform, .unavailable_runtime => error.CreationTimeUnavailable,
    };
}

fn sortEntries(entries: []zigrep.search.walk.Entry, options: CliOptions) void {
    const traversal = options.traversal();
    if (traversal.sort_mode == .none or entries.len <= 1) return;

    const Context = struct {
        mode: command.SortMode,
        reverse: bool,
    };
    const lessThan = struct {
        fn compare(context: Context, lhs: zigrep.search.walk.Entry, rhs: zigrep.search.walk.Entry) bool {
            const ascending = switch (context.mode) {
                .none => false,
                .path => comparePath(lhs, rhs),
                .modified => compareTimestamp(lhs.modified_ns, rhs.modified_ns, lhs.path, rhs.path),
                .accessed => compareTimestamp(lhs.accessed_ns, rhs.accessed_ns, lhs.path, rhs.path),
                .created => compareTimestamp(lhs.changed_ns, rhs.changed_ns, lhs.path, rhs.path),
            };
            if (!context.reverse) return ascending;
            return compareReversed(context.mode, lhs, rhs);
        }

        fn comparePath(lhs: zigrep.search.walk.Entry, rhs: zigrep.search.walk.Entry) bool {
            return std.mem.lessThan(u8, lhs.path, rhs.path);
        }

        fn compareTimestamp(lhs_time: i128, rhs_time: i128, lhs_path: []const u8, rhs_path: []const u8) bool {
            if (lhs_time < rhs_time) return true;
            if (lhs_time > rhs_time) return false;
            return std.mem.lessThan(u8, lhs_path, rhs_path);
        }

        fn compareReversed(mode: command.SortMode, lhs: zigrep.search.walk.Entry, rhs: zigrep.search.walk.Entry) bool {
            return switch (mode) {
                .none => false,
                .path => comparePath(rhs, lhs),
                .modified => compareTimestamp(rhs.modified_ns, lhs.modified_ns, rhs.path, lhs.path),
                .accessed => compareTimestamp(rhs.accessed_ns, lhs.accessed_ns, rhs.path, lhs.path),
                .created => compareTimestamp(rhs.changed_ns, lhs.changed_ns, rhs.path, lhs.path),
            };
        }
    }.compare;

    std.sort.heap(zigrep.search.walk.Entry, entries, Context{
        .mode = traversal.sort_mode,
        .reverse = traversal.sort_reverse,
    }, lessThan);
}

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
    try validateSortMode(options);
    const traversal = options.traversal();
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
        .include_hidden = traversal.include_hidden,
        .follow_symlinks = traversal.follow_symlinks,
        .max_depth = traversal.max_depth,
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
        traversal.globs,
        loaded_ignores,
        type_matcher,
        traversal.include_types,
        traversal.exclude_types,
    );
    defer allocator.free(filtered_entries);
    sortEntries(@constCast(filtered_entries), options);

    const schedule = zigrep.search.schedule.plan(filtered_entries.len, .{
        .requested_jobs = if (traversal.sort_mode == .none) traversal.parallel_jobs else 1,
    });
    var result = if (schedule.parallel)
        try parallelFn(stdout, stderr, filtered_entries, options, schedule)
    else
        try sequentialFn(allocator, stdout, stderr, filtered_entries, options);
    result.stats.warnings_emitted += traversal_warning_count;
    return result;
}

pub fn listPathFiles(
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    root_path: []const u8,
    options: CliOptions,
    type_matcher: zigrep.search.types.Matcher,
) !usize {
    try validateSortMode(options);
    const traversal = options.traversal();
    const reporting = options.reporting();
    var traversal_warning_count: usize = 0;
    const TraversalWarningHandler = struct {
        writer: *std.Io.Writer,
        count: *usize,

        pub fn warn(self: @This(), path: []const u8, err: anyerror) void {
            self.writer.print("warning: skipping directory {s}: {s}\n", .{ path, search_execution.warningMessage(err) }) catch {};
            self.count.* += 1;
        }
    };

    const loaded_ignores = try search_filtering.loadIgnoreMatchers(allocator, root_path, options);
    defer search_filtering.deinitLoadedIgnores(allocator, loaded_ignores);

    if (reporting.quiet and traversal.sort_mode == .none) {
        const QuietVisitor = struct {
            allocator: std.mem.Allocator,
            root_path: []const u8,
            traversal: command.TraversalOptions,
            loaded_ignores: []const search_filtering.LoadedIgnore,
            type_matcher: zigrep.search.types.Matcher,
            listed: *usize,

            pub fn visit(self: @This(), entry: zigrep.search.walk.Entry) !void {
                defer entry.deinit(self.allocator);
                if (!try search_filtering.entryAllowed(
                    self.allocator,
                    self.root_path,
                    entry,
                    self.traversal.globs,
                    self.loaded_ignores,
                    self.type_matcher,
                    self.traversal.include_types,
                    self.traversal.exclude_types,
                )) return;
                self.listed.* += 1;
                return error.StopWalk;
            }
        };

        var listed: usize = 0;
        zigrep.search.walk.walk(allocator, root_path, .{
            .include_hidden = traversal.include_hidden,
            .follow_symlinks = traversal.follow_symlinks,
            .max_depth = traversal.max_depth,
        }, QuietVisitor{
            .allocator = allocator,
            .root_path = root_path,
            .traversal = traversal,
            .loaded_ignores = loaded_ignores,
            .type_matcher = type_matcher,
            .listed = &listed,
        }, TraversalWarningHandler{ .writer = stderr, .count = &traversal_warning_count }) catch |err| switch (err) {
            error.StopWalk => {},
            else => return err,
        };
        return listed;
    }

    const entries = try zigrep.search.walk.collectFilesWithWarnings(allocator, root_path, .{
        .include_hidden = traversal.include_hidden,
        .follow_symlinks = traversal.follow_symlinks,
        .max_depth = traversal.max_depth,
    }, TraversalWarningHandler{ .writer = stderr, .count = &traversal_warning_count });
    defer {
        for (entries) |entry| entry.deinit(allocator);
        allocator.free(entries);
    }

    const filtered_entries = try search_filtering.filterEntries(
        allocator,
        root_path,
        entries,
        traversal.globs,
        loaded_ignores,
        type_matcher,
        traversal.include_types,
        traversal.exclude_types,
    );
    defer allocator.free(filtered_entries);
    sortEntries(@constCast(filtered_entries), options);

    if (reporting.quiet) {
        return if (filtered_entries.len != 0) 1 else 0;
    }

    var listed: usize = 0;
    for (filtered_entries) |entry| {
        try search_output.writePathResult(stdout, entry.path, reporting.output);
        listed += 1;
    }

    return listed;
}
