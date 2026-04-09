const std = @import("std");
const zigrep = @import("zigrep");

const CliError = error{
    MissingPattern,
    UnknownFlag,
    MissingFlagValue,
    InvalidFlagValue,
};

const OutputOptions = struct {
    with_filename: bool = true,
    line_number: bool = true,
    column_number: bool = true,
};

const CliOptions = struct {
    pattern: []const u8,
    paths: []const []const u8,
    include_hidden: bool = false,
    follow_symlinks: bool = false,
    skip_binary: bool = true,
    read_strategy: zigrep.search.io.ReadStrategy = .mmap,
    parallel_jobs: ?usize = null,
    max_depth: ?usize = null,
    output: OutputOptions = .{},
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
    var parallel_jobs: ?usize = null;
    var max_depth: ?usize = null;
    var output: OutputOptions = .{};
    var pattern: ?[]const u8 = null;
    var paths = std.ArrayList([]const u8).empty;
    defer paths.deinit(allocator);
    var stop_parsing_flags = false;

    var index: usize = 1;
    while (index < argv.len) : (index += 1) {
        const arg = argv[index];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return .help;
        }

        if (!stop_parsing_flags and pattern == null and std.mem.eql(u8, arg, "--")) {
            stop_parsing_flags = true;
            continue;
        }

        if (!stop_parsing_flags and pattern == null and arg.len > 0 and arg[0] == '-') {
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
            if (std.mem.eql(u8, arg, "-j") or std.mem.eql(u8, arg, "--threads")) {
                index += 1;
                if (index >= argv.len) return error.MissingFlagValue;
                parallel_jobs = try parsePositiveUsize(argv[index]);
                continue;
            }
            if (std.mem.eql(u8, arg, "--max-depth")) {
                index += 1;
                if (index >= argv.len) return error.MissingFlagValue;
                max_depth = try parseNonNegativeUsize(argv[index]);
                continue;
            }
            if (std.mem.eql(u8, arg, "-H") or std.mem.eql(u8, arg, "--with-filename")) {
                output.with_filename = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--no-filename")) {
                output.with_filename = false;
                continue;
            }
            if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--line-number")) {
                output.line_number = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--no-line-number")) {
                output.line_number = false;
                continue;
            }
            if (std.mem.eql(u8, arg, "--column")) {
                output.column_number = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--no-column")) {
                output.column_number = false;
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
        .parallel_jobs = parallel_jobs,
        .max_depth = max_depth,
        .output = output,
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
        .max_depth = options.max_depth,
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
            try printReport(stdout, report, options.output);
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
                self.result_lines[index] = try formatReport(std.heap.smp_allocator, report, self.options.output);
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

fn printReport(stdout: *std.Io.Writer, report: zigrep.search.grep.MatchReport, output: OutputOptions) !void {
    const line = try formatReport(std.heap.smp_allocator, report, output);
    defer std.heap.smp_allocator.free(line);
    try stdout.writeAll(line);
}

fn formatReport(
    allocator: std.mem.Allocator,
    report: zigrep.search.grep.MatchReport,
    output: OutputOptions,
) ![]u8 {
    var buffer: std.Io.Writer.Allocating = .init(allocator);
    defer buffer.deinit();

    var wrote_prefix = false;
    if (output.with_filename) {
        try buffer.writer.print("{s}", .{report.path});
        wrote_prefix = true;
    }
    if (output.line_number) {
        if (wrote_prefix) {
            try buffer.writer.writeByte(':');
        }
        try buffer.writer.print("{d}", .{report.line_number});
        wrote_prefix = true;
    }
    if (output.column_number) {
        if (wrote_prefix) {
            try buffer.writer.writeByte(':');
        }
        try buffer.writer.print("{d}", .{report.column_number});
        wrote_prefix = true;
    }
    if (wrote_prefix) {
        try buffer.writer.writeByte(':');
    }
    try buffer.writer.print("{s}\n", .{report.line});
    return try allocator.dupe(u8, buffer.written());
}

fn parsePositiveUsize(arg: []const u8) CliError!usize {
    const value = parseNonNegativeUsize(arg) catch return error.InvalidFlagValue;
    if (value == 0) return error.InvalidFlagValue;
    return value;
}

fn parseNonNegativeUsize(arg: []const u8) CliError!usize {
    return std.fmt.parseUnsigned(usize, arg, 10) catch error.InvalidFlagValue;
}

fn writeUsage(writer: *std.Io.Writer, argv0: []const u8) !void {
    try writer.print(
        \\usage: {s} [FLAGS] PATTERN [PATH...]
        \\search recursively for PATTERN starting at each PATH, or "." when omitted
        \\  -h, --help            show this help
        \\  --hidden              include hidden files
        \\  --follow              follow symlinks
        \\  --text                search binary files too
        \\  --buffered            force buffered file reads
        \\  --mmap                prefer mmap-backed file reads
        \\  -j, --threads N       use up to N worker threads
        \\  --max-depth N         limit recursive walk depth
        \\  -H, --with-filename   always print the file path
        \\  --no-filename         suppress the file path prefix
        \\  -n, --line-number     print line numbers
        \\  --no-line-number      suppress line numbers
        \\  --column              print match columns
        \\  --no-column           suppress match columns
        \\  --                    stop parsing flags
        \\
    , .{argv0});
}

const CapturedCliRun = struct {
    exit_code: u8,
    stdout: []u8,
    stderr: []u8,

    fn deinit(self: CapturedCliRun, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

fn runCliCaptured(allocator: std.mem.Allocator, argv: []const []const u8) !CapturedCliRun {
    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    const exit_code = try runCli(
        allocator,
        &stdout_capture.writer,
        &stderr_capture.writer,
        argv,
    );

    return .{
        .exit_code = exit_code,
        .stdout = try allocator.dupe(u8, stdout_capture.written()),
        .stderr = try allocator.dupe(u8, stderr_capture.written()),
    };
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
            try testing.expectEqual(@as(?usize, null), opts.parallel_jobs);
            try testing.expectEqual(@as(?usize, null), opts.max_depth);
            try testing.expect(opts.output.with_filename);
            try testing.expect(opts.output.line_number);
            try testing.expect(opts.output.column_number);
        },
        .help => unreachable,
    }
}

test "parseArgs accepts numeric and formatting flags" {
    const testing = std.testing;

    const parsed = try parseArgs(testing.allocator, &.{
        "zigrep",
        "-j",
        "4",
        "--max-depth",
        "2",
        "--no-filename",
        "--no-column",
        "--",
        "-literal",
        "src",
    });
    defer switch (parsed) {
        .run => |opts| testing.allocator.free(opts.paths),
        .help => {},
    };

    switch (parsed) {
        .run => |opts| {
            try testing.expectEqualStrings("-literal", opts.pattern);
            try testing.expectEqual(@as(?usize, 4), opts.parallel_jobs);
            try testing.expectEqual(@as(?usize, 2), opts.max_depth);
            try testing.expect(!opts.output.with_filename);
            try testing.expect(opts.output.line_number);
            try testing.expect(!opts.output.column_number);
            try testing.expectEqual(@as(usize, 1), opts.paths.len);
            try testing.expectEqualStrings("src", opts.paths[0]);
        },
        .help => unreachable,
    }
}

test "parseArgs rejects invalid numeric flags" {
    const testing = std.testing;

    try testing.expectError(error.InvalidFlagValue, parseArgs(testing.allocator, &.{
        "zigrep",
        "-j",
        "0",
        "needle",
    }));
    try testing.expectError(error.MissingFlagValue, parseArgs(testing.allocator, &.{
        "zigrep",
        "--max-depth",
    }));
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

    const run = try runCliCaptured(testing.allocator, &.{ "zigrep", "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "match.txt:2:1:needle here"));
    try testing.expect(!std.mem.containsAtLeast(u8, run.stdout, 1, "binary.bin"));
    try testing.expectEqualStrings("", run.stderr);
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

    const run = try runCliCaptured(testing.allocator, &.{ "zigrep", "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 1), run.exit_code);
    try testing.expectEqualStrings("", run.stdout);
    try testing.expectEqualStrings("", run.stderr);
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

test "formatReport obeys output toggles" {
    const testing = std.testing;

    const report: zigrep.search.grep.MatchReport = .{
        .path = "sample.txt",
        .line_number = 3,
        .column_number = 7,
        .line = "matched line",
        .line_span = .{ .start = 0, .end = 12 },
        .match_span = .{ .start = 0, .end = 6 },
    };

    const line = try formatReport(testing.allocator, report, .{
        .with_filename = false,
        .line_number = true,
        .column_number = false,
    });
    defer testing.allocator.free(line);

    try testing.expectEqualStrings("3:matched line\n", line);
}

test "runCli honors max depth in recursive search" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("nested/deeper");
    try tmp.dir.writeFile(.{
        .sub_path = "root.txt",
        .data = "needle root\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "nested/child.txt",
        .data = "needle child\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "nested/deeper/grandchild.txt",
        .data = "needle grandchild\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const shallow = try runCliCaptured(testing.allocator, &.{
        "zigrep",
        "--max-depth",
        "1",
        "needle",
        root_path,
    });
    defer shallow.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), shallow.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, shallow.stdout, 1, "root.txt:1:1:needle root"));
    try testing.expect(std.mem.containsAtLeast(u8, shallow.stdout, 1, "child.txt:1:1:needle child"));
    try testing.expect(!std.mem.containsAtLeast(u8, shallow.stdout, 1, "grandchild.txt"));
}

test "runCli can search binary files when text mode is enabled" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "payload.bin",
        .data = "aa\x00needle\x00bb",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const skipped = try runCliCaptured(testing.allocator, &.{ "zigrep", "needle", root_path });
    defer skipped.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 1), skipped.exit_code);

    const searched = try runCliCaptured(testing.allocator, &.{ "zigrep", "--text", "needle", root_path });
    defer searched.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), searched.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, searched.stdout, 1, "payload.bin:1:4:aa"));
}

test "runCli output toggles apply across the end-to-end path" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "sample.txt",
        .data = "prefix needle suffix\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try runCliCaptured(testing.allocator, &.{
        "zigrep",
        "--no-filename",
        "--no-column",
        "needle",
        root_path,
    });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expectEqualStrings("1:prefix needle suffix\n", run.stdout);
}

test "runCli parallel and sequential modes produce the same output set" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "a.txt", .data = "needle a\n" });
    try tmp.dir.writeFile(.{ .sub_path = "b.txt", .data = "needle b\n" });
    try tmp.dir.writeFile(.{ .sub_path = "c.txt", .data = "needle c\n" });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const sequential = try runCliCaptured(testing.allocator, &.{
        "zigrep",
        "-j",
        "1",
        "needle",
        root_path,
    });
    defer sequential.deinit(testing.allocator);

    const parallel = try runCliCaptured(testing.allocator, &.{
        "zigrep",
        "-j",
        "4",
        "needle",
        root_path,
    });
    defer parallel.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), sequential.exit_code);
    try testing.expectEqual(@as(u8, 0), parallel.exit_code);
    try testing.expectEqualStrings(sequential.stdout, parallel.stdout);
}
