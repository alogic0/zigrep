const std = @import("std");
const zigrep = @import("zigrep");

const CliError = error{
    MissingPattern,
    UnknownFlag,
};

const CliOptions = struct {
    pattern: []const u8,
    paths: []const []const u8,
    include_hidden: bool = false,
    follow_symlinks: bool = false,
    skip_binary: bool = true,
    read_strategy: zigrep.search.io.ReadStrategy = .mmap,
    parallel_jobs: ?usize = null,
};

const ParseResult = union(enum) {
    help,
    run: CliOptions,
};

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stderr = &stderr_writer.interface;

    const exit_code = runCli(allocator, stdout, stderr, argv) catch |err| {
        try stderr.print("error: {s}\n", .{@errorName(err)});
        try writeUsage(stderr, argv[0]);
        try stderr.flush();
        std.process.exit(2);
    };

    try stdout.flush();
    try stderr.flush();
    if (exit_code != 0) std.process.exit(exit_code);
}

fn runCli(
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    argv: []const []const u8,
) !u8 {
    const parsed = try parseArgs(allocator, argv);
    defer switch (parsed) {
        .run => |opts| allocator.free(opts.paths),
        .help => {},
    };

    switch (parsed) {
        .help => {
            try writeUsage(stdout, argv[0]);
            return 0;
        },
        .run => |opts| {
            _ = stderr;
            return runSearch(allocator, stdout, opts);
        },
    }
}

fn parseArgs(allocator: std.mem.Allocator, argv: []const []const u8) !ParseResult {
    if (argv.len <= 1) return error.MissingPattern;

    var include_hidden = false;
    var follow_symlinks = false;
    var skip_binary = true;
    var read_strategy: zigrep.search.io.ReadStrategy = .mmap;
    var pattern: ?[]const u8 = null;
    var paths = std.ArrayList([]const u8).empty;
    defer paths.deinit(allocator);

    for (argv[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return .help;
        }

        if (pattern == null and arg.len > 0 and arg[0] == '-') {
            if (std.mem.eql(u8, arg, "--hidden")) {
                include_hidden = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--follow")) {
                follow_symlinks = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--text")) {
                skip_binary = false;
                continue;
            }
            if (std.mem.eql(u8, arg, "--buffered")) {
                read_strategy = .buffered;
                continue;
            }
            if (std.mem.eql(u8, arg, "--mmap")) {
                read_strategy = .mmap;
                continue;
            }
            return error.UnknownFlag;
        }

        if (pattern == null) {
            pattern = arg;
        } else {
            try paths.append(allocator, arg);
        }
    }

    if (pattern == null) return error.MissingPattern;
    if (paths.items.len == 0) try paths.append(allocator, ".");

    return .{ .run = .{
        .pattern = pattern.?,
        .paths = try paths.toOwnedSlice(allocator),
        .include_hidden = include_hidden,
        .follow_symlinks = follow_symlinks,
        .skip_binary = skip_binary,
        .read_strategy = read_strategy,
    } };
}

fn runSearch(
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    options: CliOptions,
) !u8 {
    var matched = false;
    for (options.paths) |path| {
        if (try searchPath(allocator, stdout, path, options)) {
            matched = true;
        }
    }
    return if (matched) 0 else 1;
}

fn searchPath(
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    root_path: []const u8,
    options: CliOptions,
) !bool {
    const entries = try zigrep.search.walk.collectFiles(allocator, root_path, .{
        .include_hidden = options.include_hidden,
        .follow_symlinks = options.follow_symlinks,
    });
    defer {
        for (entries) |entry| entry.deinit(allocator);
        allocator.free(entries);
    }

    const schedule = zigrep.search.schedule.plan(entries.len, .{
        .requested_jobs = options.parallel_jobs,
    });
    if (schedule.parallel) {
        return searchEntriesParallel(stdout, entries, options, schedule);
    }
    return searchEntriesSequential(allocator, stdout, entries, options);
}

fn searchEntriesSequential(
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    entries: []const zigrep.search.walk.Entry,
    options: CliOptions,
) !bool {
    var searcher = try zigrep.search.grep.Searcher.init(allocator, options.pattern, .{});
    defer searcher.deinit();

    var matched = false;
    for (entries) |entry| {
        if (options.skip_binary) {
            if (try zigrep.search.io.detectBinaryFile(entry.path, .{}) == .binary) continue;
        }

        const buffer = try zigrep.search.io.readFile(allocator, entry.path, .{
            .strategy = options.read_strategy,
        });
        defer buffer.deinit(allocator);

        if (try searcher.reportFirstMatch(entry.path, buffer.bytes())) |report| {
            try printReport(stdout, report);
            matched = true;
        }
    }

    return matched;
}

fn searchEntriesParallel(
    stdout: *std.Io.Writer,
    entries: []const zigrep.search.walk.Entry,
    options: CliOptions,
    schedule: zigrep.search.schedule.Plan,
) !bool {
    const worker_allocator = std.heap.smp_allocator;
    if (schedule.worker_count <= 1) {
        return searchEntriesSequential(worker_allocator, stdout, entries, options);
    }

    const Context = struct {
        entries: []const zigrep.search.walk.Entry,
        options: CliOptions,
        schedule: zigrep.search.schedule.Plan,
        next_index: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
        result_lines: []?[]u8,
        first_error: ?anyerror = null,
        error_mutex: std.Thread.Mutex = .{},

        fn setError(self: *@This(), err: anyerror) void {
            self.error_mutex.lock();
            defer self.error_mutex.unlock();
            if (self.first_error == null) self.first_error = err;
        }

        fn runWorker(self: *@This()) void {
            var searcher = zigrep.search.grep.Searcher.init(std.heap.smp_allocator, self.options.pattern, .{}) catch |err| {
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
            if (self.options.skip_binary) {
                if (try zigrep.search.io.detectBinaryFile(entry.path, .{}) == .binary) return;
            }

            const buffer = try zigrep.search.io.readFile(std.heap.smp_allocator, entry.path, .{
                .strategy = self.options.read_strategy,
            });
            defer buffer.deinit(std.heap.smp_allocator);

            if (try searcher.reportFirstMatch(entry.path, buffer.bytes())) |report| {
                self.result_lines[index] = try std.fmt.allocPrint(std.heap.smp_allocator, "{s}:{d}:{d}:{s}\n", .{
                    report.path,
                    report.line_number,
                    report.column_number,
                    report.line,
                });
            }
        }
    };

    const result_lines = try worker_allocator.alloc(?[]u8, entries.len);
    defer worker_allocator.free(result_lines);
    @memset(result_lines, null);

    var pool: std.Thread.Pool = undefined;
    try pool.init(.{
        .allocator = worker_allocator,
        .n_jobs = schedule.worker_count,
    });
    defer pool.deinit();

    var wait_group: std.Thread.WaitGroup = .{};
    var context = Context{
        .entries = entries,
        .options = options,
        .schedule = schedule,
        .result_lines = result_lines,
    };

    for (0..schedule.worker_count) |_| {
        pool.spawnWg(&wait_group, Context.runWorker, .{&context});
    }
    wait_group.wait();

    if (context.first_error) |err| {
        for (result_lines) |maybe_line| {
            if (maybe_line) |line| std.heap.smp_allocator.free(line);
        }
        return err;
    }

    var matched = false;
    for (result_lines) |maybe_line| {
        if (maybe_line) |line| {
            defer std.heap.smp_allocator.free(line);
            try stdout.writeAll(line);
            matched = true;
        }
    }
    return matched;
}

fn printReport(stdout: *std.Io.Writer, report: zigrep.search.grep.MatchReport) !void {
    try stdout.print("{s}:{d}:{d}:{s}\n", .{
        report.path,
        report.line_number,
        report.column_number,
        report.line,
    });
}

fn writeUsage(writer: *std.Io.Writer, argv0: []const u8) !void {
    try writer.print(
        \\usage: {s} [--hidden] [--follow] [--text] [--buffered|--mmap] PATTERN [PATH...]
        \\search recursively for PATTERN starting at each PATH, or "." when omitted
        \\
    , .{argv0});
}

test "parseArgs defaults to current directory search" {
    const testing = std.testing;

    const parsed = try parseArgs(testing.allocator, &.{ "zigrep", "needle" });
    defer switch (parsed) {
        .run => |opts| testing.allocator.free(opts.paths),
        .help => {},
    };

    switch (parsed) {
        .run => |opts| {
            try testing.expectEqualStrings("needle", opts.pattern);
            try testing.expectEqual(@as(usize, 1), opts.paths.len);
            try testing.expectEqualStrings(".", opts.paths[0]);
            try testing.expect(!opts.include_hidden);
            try testing.expect(!opts.follow_symlinks);
            try testing.expect(opts.skip_binary);
            try testing.expectEqual(zigrep.search.io.ReadStrategy.mmap, opts.read_strategy);
        },
        .help => unreachable,
    }
}

test "runCli reports matches and skips binary files by default" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "match.txt",
        .data = "before\nneedle here\nafter\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "binary.bin",
        .data = "xx\x00needleyy",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    var stdout_capture: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_capture.deinit();

    const exit_code = try runCli(
        testing.allocator,
        &stdout_capture.writer,
        &stderr_capture.writer,
        &.{ "zigrep", "needle", root_path },
    );

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, stdout_capture.written(), 1, "match.txt:2:1:needle here"));
    try testing.expect(!std.mem.containsAtLeast(u8, stdout_capture.written(), 1, "binary.bin"));
    try testing.expectEqualStrings("", stderr_capture.written());
}

test "runCli returns 1 when nothing matches" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "sample.txt",
        .data = "hello world\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    var stdout_capture: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_capture.deinit();

    const exit_code = try runCli(
        testing.allocator,
        &stdout_capture.writer,
        &stderr_capture.writer,
        &.{ "zigrep", "needle", root_path },
    );

    try testing.expectEqual(@as(u8, 1), exit_code);
    try testing.expectEqualStrings("", stdout_capture.written());
    try testing.expectEqualStrings("", stderr_capture.written());
}

test "runSearch reports matches across files on the parallel path" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "one.txt",
        .data = "needle one\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "two.txt",
        .data = "needle two\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "three.txt",
        .data = "no hit here\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    var stdout_capture: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_capture.deinit();

    const exit_code = try runSearch(testing.allocator, &stdout_capture.writer, .{
        .pattern = "needle",
        .paths = &.{root_path},
        .parallel_jobs = 2,
    });

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, stdout_capture.written(), 1, "one.txt:1:1:needle one"));
    try testing.expect(std.mem.containsAtLeast(u8, stdout_capture.written(), 1, "two.txt:1:1:needle two"));
}

test "search scheduler keeps tiny workloads on the sequential path" {
    const testing = std.testing;

    const schedule = zigrep.search.schedule.plan(1, .{
        .requested_jobs = 8,
    });

    try testing.expect(!schedule.parallel);
    try testing.expectEqual(@as(usize, 1), schedule.worker_count);
    try testing.expectEqual(@as(usize, 1), schedule.chunk_size);
}
