const std = @import("std");
const zigrep = @import("zigrep");

const CliError = error{
    MissingPattern,
    UnknownFlag,
    MissingFlagValue,
    InvalidFlagValue,
    InvalidFlagCombination,
};

pub const OutputOptions = struct {
    with_filename: bool = true,
    line_number: bool = true,
    column_number: bool = true,
    only_matching: bool = false,
};

const ReportMode = enum {
    lines,
    count,
    files_with_matches,
    files_without_match,
};

pub const CliOptions = struct {
    pattern: []const u8,
    paths: []const []const u8,
    globs: []const []const u8 = &.{},
    ignore_files: []const []const u8 = &.{},
    include_hidden: bool = false,
    follow_symlinks: bool = false,
    no_ignore: bool = false,
    no_ignore_vcs: bool = false,
    no_ignore_parent: bool = false,
    skip_binary: bool = true,
    read_strategy: zigrep.search.io.ReadStrategy = .mmap,
    encoding: zigrep.search.io.InputEncoding = .auto,
    parallel_jobs: ?usize = null,
    max_depth: ?usize = null,
    max_count: ?usize = null,
    context_before: usize = 0,
    context_after: usize = 0,
    output: OutputOptions = .{},
    report_mode: ReportMode = .lines,
    buffer_output: bool = false,
};

const ParseResult = union(enum) {
    help,
    version,
    run: CliOptions,
};

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    // Process-lifetime allocator: owns argv, the collected file list, and other
    // state that lives for the full CLI invocation.
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
        try writeFatalError(stderr, argv[0], err);
        try stderr.flush();
        std.process.exit(2);
    };

    try stdout.flush();
    try stderr.flush();
    if (exit_code != 0) std.process.exit(exit_code);
}

fn writeFatalError(writer: *std.Io.Writer, argv0: []const u8, err: anyerror) !void {
    try writer.print("error: {s}\n", .{@errorName(err)});
    if (isUsageError(err)) {
        try writeUsage(writer, argv0);
    }
}

fn isUsageError(err: anyerror) bool {
    return switch (err) {
        error.MissingPattern,
        error.UnknownFlag,
        error.MissingFlagValue,
        error.InvalidFlagValue,
        error.InvalidFlagCombination,
        => true,
        else => false,
    };
}

fn runCli(
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    argv: []const []const u8,
) !u8 {
    const parsed = try parseArgs(allocator, argv);
    defer switch (parsed) {
        .run => |opts| {
            allocator.free(opts.paths);
            allocator.free(opts.globs);
            allocator.free(opts.ignore_files);
        },
        .help, .version => {},
    };

    switch (parsed) {
        .help => {
            try writeUsage(stdout, argv[0]);
            return 0;
        },
        .version => {
            try stdout.print("zigrep {s}\n", .{zigrep.app_version});
            return 0;
        },
        .run => |opts| {
            return runSearch(allocator, stdout, stderr, opts);
        },
    }
}

fn parseArgs(allocator: std.mem.Allocator, argv: []const []const u8) !ParseResult {
    if (argv.len <= 1) return error.MissingPattern;

    var include_hidden = false;
    var follow_symlinks = false;
    var no_ignore = false;
    var no_ignore_vcs = false;
    var no_ignore_parent = false;
    var skip_binary = true;
    var read_strategy: zigrep.search.io.ReadStrategy = .mmap;
    var encoding: zigrep.search.io.InputEncoding = .auto;
    var parallel_jobs: ?usize = null;
    var max_depth: ?usize = null;
    var max_count: ?usize = null;
    var context_before: usize = 0;
    var context_after: usize = 0;
    var output: OutputOptions = .{};
    var report_mode: ReportMode = .lines;
    var pattern: ?[]const u8 = null;
    var paths = std.ArrayList([]const u8).empty;
    var globs = std.ArrayList([]const u8).empty;
    var ignore_files = std.ArrayList([]const u8).empty;
    defer paths.deinit(allocator);
    defer globs.deinit(allocator);
    defer ignore_files.deinit(allocator);
    var stop_parsing_flags = false;

    var index: usize = 1;
    while (index < argv.len) : (index += 1) {
        const arg = argv[index];
        if (!stop_parsing_flags and pattern == null and std.mem.eql(u8, arg, "--")) {
            stop_parsing_flags = true;
            continue;
        }

        if (!stop_parsing_flags and pattern == null and arg.len > 0 and arg[0] == '-') {
            if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                return .help;
            }
            if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V")) {
                return .version;
            }
            if (std.mem.eql(u8, arg, "--hidden")) {
                include_hidden = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--ignore-file")) {
                index += 1;
                if (index >= argv.len) return error.MissingFlagValue;
                try ignore_files.append(allocator, argv[index]);
                continue;
            }
            if (std.mem.eql(u8, arg, "--no-ignore")) {
                no_ignore = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--no-ignore-vcs")) {
                no_ignore_vcs = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--no-ignore-parent")) {
                no_ignore_parent = true;
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
            if (std.mem.eql(u8, arg, "-g") or std.mem.eql(u8, arg, "--glob")) {
                index += 1;
                if (index >= argv.len) return error.MissingFlagValue;
                try globs.append(allocator, argv[index]);
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
            if (std.mem.eql(u8, arg, "-E") or std.mem.eql(u8, arg, "--encoding")) {
                index += 1;
                if (index >= argv.len) return error.MissingFlagValue;
                encoding = try parseEncoding(argv[index]);
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
            if (std.mem.eql(u8, arg, "-A") or std.mem.eql(u8, arg, "--after-context")) {
                index += 1;
                if (index >= argv.len) return error.MissingFlagValue;
                context_after = try parseNonNegativeUsize(argv[index]);
                continue;
            }
            if (std.mem.eql(u8, arg, "-B") or std.mem.eql(u8, arg, "--before-context")) {
                index += 1;
                if (index >= argv.len) return error.MissingFlagValue;
                context_before = try parseNonNegativeUsize(argv[index]);
                continue;
            }
            if (std.mem.eql(u8, arg, "-C") or std.mem.eql(u8, arg, "--context")) {
                index += 1;
                if (index >= argv.len) return error.MissingFlagValue;
                const context = try parseNonNegativeUsize(argv[index]);
                context_before = context;
                context_after = context;
                continue;
            }
            if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--max-count")) {
                index += 1;
                if (index >= argv.len) return error.MissingFlagValue;
                max_count = try parsePositiveUsize(argv[index]);
                continue;
            }
            if (std.mem.eql(u8, arg, "-H") or std.mem.eql(u8, arg, "--with-filename")) {
                output.with_filename = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--count")) {
                report_mode = .count;
                continue;
            }
            if (std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "--files-with-matches")) {
                report_mode = .files_with_matches;
                continue;
            }
            if (std.mem.eql(u8, arg, "-L") or std.mem.eql(u8, arg, "--files-without-match")) {
                report_mode = .files_without_match;
                continue;
            }
            if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--only-matching")) {
                output.only_matching = true;
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
    if ((context_before != 0 or context_after != 0) and (report_mode != .lines or output.only_matching)) {
        return error.InvalidFlagCombination;
    }

    const owned_paths = try paths.toOwnedSlice(allocator);
    errdefer allocator.free(owned_paths);
    const owned_globs = try globs.toOwnedSlice(allocator);
    errdefer allocator.free(owned_globs);
    const owned_ignore_files = try ignore_files.toOwnedSlice(allocator);
    errdefer allocator.free(owned_ignore_files);

    return .{ .run = .{
        .pattern = pattern.?,
        .paths = owned_paths,
        .globs = owned_globs,
        .ignore_files = owned_ignore_files,
        .include_hidden = include_hidden,
        .follow_symlinks = follow_symlinks,
        .no_ignore = no_ignore,
        .no_ignore_vcs = no_ignore_vcs,
        .no_ignore_parent = no_ignore_parent,
        .skip_binary = skip_binary,
        .read_strategy = read_strategy,
        .encoding = encoding,
        .parallel_jobs = parallel_jobs,
        .max_depth = max_depth,
        .max_count = max_count,
        .context_before = context_before,
        .context_after = context_after,
        .output = output,
        .report_mode = report_mode,
    } };
}

pub fn runSearch(
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    options: CliOptions,
) !u8 {
    var matched = false;
    for (options.paths) |path| {
        if (options.buffer_output) {
            var buffered_output: std.Io.Writer.Allocating = .init(allocator);
            defer buffered_output.deinit();

            if (try searchPath(allocator, &buffered_output.writer, stderr, path, options)) {
                matched = true;
            }
            try stdout.writeAll(buffered_output.written());
            continue;
        }

        if (try searchPath(allocator, stdout, stderr, path, options)) {
            matched = true;
        }
    }
    return if (matched) 0 else 1;
}

fn searchPath(
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    root_path: []const u8,
    options: CliOptions,
) !bool {
    const TraversalWarningHandler = struct {
        writer: *std.Io.Writer,

        pub fn warn(self: @This(), path: []const u8, err: anyerror) void {
            self.writer.print("warning: skipping directory {s}: {s}\n", .{ path, @errorName(err) }) catch {};
        }
    };

    const entries = try zigrep.search.walk.collectFilesWithWarnings(allocator, root_path, .{
        .include_hidden = options.include_hidden,
        .follow_symlinks = options.follow_symlinks,
        .max_depth = options.max_depth,
    }, TraversalWarningHandler{ .writer = stderr });
    defer {
        for (entries) |entry| entry.deinit(allocator);
        allocator.free(entries);
    }

    const loaded_ignores = try loadIgnoreMatchers(allocator, root_path, options);
    defer deinitLoadedIgnores(allocator, loaded_ignores);

    const filtered_entries = try filterEntries(
        allocator,
        root_path,
        entries,
        options.globs,
        loaded_ignores,
    );
    defer allocator.free(filtered_entries);

    const schedule = zigrep.search.schedule.plan(filtered_entries.len, .{
        .requested_jobs = options.parallel_jobs,
    });
    if (schedule.parallel) {
        return searchEntriesParallel(stdout, stderr, filtered_entries, options, schedule);
    }
    return searchEntriesSequential(allocator, stdout, stderr, filtered_entries, options);
}

const LoadedIgnore = struct {
    base_dir: []u8,
    matcher: zigrep.search.ignore.IgnoreMatcher,

    fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        allocator.free(self.base_dir);
        self.matcher.deinit(allocator);
    }
};

fn filterEntries(
    allocator: std.mem.Allocator,
    root_path: []const u8,
    entries: []const zigrep.search.walk.Entry,
    globs: []const []const u8,
    loaded_ignores: []const LoadedIgnore,
) ![]const zigrep.search.walk.Entry {
    var filtered: std.ArrayList(zigrep.search.walk.Entry) = .empty;
    defer filtered.deinit(allocator);

    for (entries) |entry| {
        const relative = relativeGlobPath(root_path, entry.path);
        if (!zigrep.search.glob.allowsPath(globs, relative)) continue;
        if (try pathIsIgnored(allocator, entry.path, loaded_ignores)) continue;
        try filtered.append(allocator, entry);
    }

    return filtered.toOwnedSlice(allocator);
}

fn pathIsIgnored(
    allocator: std.mem.Allocator,
    entry_path: []const u8,
    loaded_ignores: []const LoadedIgnore,
) !bool {
    var ignored = false;

    for (loaded_ignores) |loaded| {
        const relative = try std.fs.path.relative(allocator, loaded.base_dir, entry_path);
        defer allocator.free(relative);
        if (std.mem.startsWith(u8, relative, "..")) continue;
        if (loaded.matcher.matchResult(.{ .path = relative })) |matched_ignore| {
            ignored = matched_ignore;
        }
    }

    return ignored;
}

fn loadIgnoreMatchers(
    allocator: std.mem.Allocator,
    root_path: []const u8,
    options: CliOptions,
) ![]LoadedIgnore {
    var loaded: std.ArrayList(LoadedIgnore) = .empty;
    errdefer {
        for (loaded.items) |item| item.deinit(allocator);
        loaded.deinit(allocator);
    }

    if (!options.no_ignore) {
        if (!options.no_ignore_vcs) {
            try loadVcsIgnoreChain(allocator, &loaded, root_path, options.no_ignore_parent);
        }
        for (options.ignore_files) |ignore_path| {
            try loadExplicitIgnoreFile(allocator, &loaded, ignore_path);
        }
    }

    return loaded.toOwnedSlice(allocator);
}

fn deinitLoadedIgnores(allocator: std.mem.Allocator, loaded: []LoadedIgnore) void {
    for (loaded) |item| item.deinit(allocator);
    allocator.free(loaded);
}

fn loadVcsIgnoreChain(
    allocator: std.mem.Allocator,
    loaded: *std.ArrayList(LoadedIgnore),
    root_path: []const u8,
    no_ignore_parent: bool,
) !void {
    const search_dir = try resolveSearchDir(allocator, root_path);
    defer allocator.free(search_dir);

    var dirs: std.ArrayList([]u8) = .empty;
    defer {
        for (dirs.items) |dir| allocator.free(dir);
        dirs.deinit(allocator);
    }

    var current = try allocator.dupe(u8, search_dir);
    while (true) {
        try dirs.append(allocator, current);
        if (no_ignore_parent) break;

        const parent_opt = std.fs.path.dirname(current);
        if (parent_opt == null) break;
        const parent = parent_opt.?;
        if (parent.len == 0 or std.mem.eql(u8, parent, current)) break;
        current = try allocator.dupe(u8, parent);
    }

    var index = dirs.items.len;
    while (index > 0) {
        index -= 1;
        try loadImplicitIgnoreFileAtDir(allocator, loaded, dirs.items[index]);
    }
}

fn resolveSearchDir(allocator: std.mem.Allocator, root_path: []const u8) ![]u8 {
    const resolved = try std.fs.cwd().realpathAlloc(allocator, root_path);
    errdefer allocator.free(resolved);

    if (std.fs.cwd().openDir(root_path, .{})) |dir_opened| {
        var dir = dir_opened;
        dir.close();
        return resolved;
    } else |err| switch (err) {
        error.NotDir => {
            const dirname = std.fs.path.dirname(resolved) orelse ".";
            const duped = try allocator.dupe(u8, dirname);
            allocator.free(resolved);
            return duped;
        },
        else => return err,
    }
}

fn loadImplicitIgnoreFileAtDir(
    allocator: std.mem.Allocator,
    loaded: *std.ArrayList(LoadedIgnore),
    dir_path: []const u8,
) !void {
    const ignore_path = try std.fs.path.join(allocator, &.{ dir_path, ".gitignore" });
    defer allocator.free(ignore_path);

    const buffer = zigrep.search.io.readFileOwned(allocator, ignore_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer buffer.deinit(allocator);

    const matcher = try zigrep.search.ignore.compile(allocator, buffer.bytes);
    try loaded.append(allocator, .{
        .base_dir = try allocator.dupe(u8, dir_path),
        .matcher = matcher,
    });
}

fn loadExplicitIgnoreFile(
    allocator: std.mem.Allocator,
    loaded: *std.ArrayList(LoadedIgnore),
    ignore_path: []const u8,
) !void {
    const resolved = try std.fs.cwd().realpathAlloc(allocator, ignore_path);
    defer allocator.free(resolved);

    const buffer = try zigrep.search.io.readFileOwned(allocator, ignore_path, .{});
    defer buffer.deinit(allocator);

    const matcher = try zigrep.search.ignore.compile(allocator, buffer.bytes);
    const base_dir = std.fs.path.dirname(resolved) orelse ".";
    try loaded.append(allocator, .{
        .base_dir = try allocator.dupe(u8, base_dir),
        .matcher = matcher,
    });
}

fn relativeGlobPath(root_path: []const u8, entry_path: []const u8) []const u8 {
    if (std.mem.eql(u8, root_path, entry_path)) {
        return std.fs.path.basename(entry_path);
    }
    if (entry_path.len > root_path.len and
        std.mem.startsWith(u8, entry_path, root_path) and
        entry_path[root_path.len] == std.fs.path.sep)
    {
        return entry_path[root_path.len + 1 ..];
    }
    return entry_path;
}

fn searchEntriesSequential(
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    entries: []const zigrep.search.walk.Entry,
    options: CliOptions,
) !bool {
    // Search-lifetime allocator: the compiled regex program and VM state are
    // reused across every file in this search invocation.
    var searcher = try zigrep.search.grep.Searcher.init(allocator, options.pattern, .{});
    defer searcher.deinit();

    var matched = false;
    for (entries) |entry| {
        // File-lifetime allocator: buffered reads and temporary per-file
        // matching/reporting allocations,
        // and temporary formatted output for one file are reclaimed together.
        var file_arena_state = std.heap.ArenaAllocator.init(allocator);
        defer file_arena_state.deinit();
        const file_allocator = file_arena_state.allocator();

        if (options.skip_binary and options.encoding == .auto) {
            const decision = zigrep.search.io.detectBinaryFile(entry.path, .{}) catch |err| {
                if (try warnAndSkipFileError(stderr, entry.path, err)) continue;
                return err;
            };
            if (decision == .binary) continue;
        }

        const buffer = zigrep.search.io.readFile(file_allocator, entry.path, .{
            .strategy = options.read_strategy,
        }) catch |err| {
            if (try warnAndSkipFileError(stderr, entry.path, err)) continue;
            return err;
        };
        defer buffer.deinit(file_allocator);

        if (try writeFileOutput(
            file_allocator,
            stdout,
            &searcher,
            entry.path,
            buffer.bytes(),
            options.encoding,
            options.output,
            options.report_mode,
            options.max_count,
            options.context_before,
            options.context_after,
        )) {
            matched = true;
        }
    }

    return matched;
}

fn searchEntriesParallel(
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    entries: []const zigrep.search.walk.Entry,
    options: CliOptions,
    schedule: zigrep.search.schedule.Plan,
) !bool {
    // Worker-lifetime allocator: shared worker state and stored output lines
    // stay on smp_allocator, while each file gets its own short-lived arena.
    const worker_allocator = std.heap.smp_allocator;
    if (schedule.worker_count <= 1) {
        return searchEntriesSequential(worker_allocator, stdout, stderr, entries, options);
    }

    const StoredOutput = struct {
        bytes: std.ArrayListUnmanaged(u8),

        fn deinit(self: @This()) void {
            var bytes = self.bytes;
            bytes.deinit(std.heap.smp_allocator);
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
        error_mutex: std.Thread.Mutex = .{},
        warning_mutex: std.Thread.Mutex = .{},

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
            var file_arena_state = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer file_arena_state.deinit();
            const file_allocator = file_arena_state.allocator();

            if (self.options.skip_binary and self.options.encoding == .auto) {
                const decision = zigrep.search.io.detectBinaryFile(entry.path, .{}) catch |err| {
                    if (try self.warnAndSkip(entry.path, err)) return;
                    return err;
                };
                if (decision == .binary) return;
            }

            const buffer = zigrep.search.io.readFile(file_allocator, entry.path, .{
                .strategy = self.options.read_strategy,
            }) catch |err| {
                if (try self.warnAndSkip(entry.path, err)) return;
                return err;
            };
            defer buffer.deinit(file_allocator);

            var capture: std.Io.Writer.Allocating = .init(std.heap.smp_allocator);
            defer capture.deinit();

            if (try writeFileOutput(
                file_allocator,
                &capture.writer,
                searcher,
                entry.path,
                buffer.bytes(),
                self.options.encoding,
                self.options.output,
                self.options.report_mode,
                self.options.max_count,
                self.options.context_before,
                self.options.context_after,
            )) {
                self.result_reports[index] = .{
                    .bytes = capture.toArrayList(),
                };
            }
        }

        fn warnAndSkip(self: *@This(), path: []const u8, err: anyerror) !bool {
            self.warning_mutex.lock();
            defer self.warning_mutex.unlock();
            return warnAndSkipFileError(self.stderr, path, err);
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

    var matched = false;
    for (result_reports) |maybe_report| {
        if (maybe_report) |report| {
            defer report.deinit();
            try stdout.writeAll(report.bytes.items);
            matched = true;
        }
    }
    return matched;
}

fn printReport(
    stdout: *std.Io.Writer,
    report: zigrep.search.grep.MatchReport,
    output: OutputOptions,
) !void {
    try writeReport(stdout, report, output);
}

fn writeReport(
    writer: *std.Io.Writer,
    report: zigrep.search.grep.MatchReport,
    output: OutputOptions,
) !void {
    var wrote_prefix = false;
    if (output.with_filename) {
        try writer.print("{s}", .{report.path});
        wrote_prefix = true;
    }
    if (output.line_number) {
        if (wrote_prefix) {
            try writer.writeByte(':');
        }
        try writer.print("{d}", .{report.line_number});
        wrote_prefix = true;
    }
    if (output.column_number) {
        if (wrote_prefix) {
            try writer.writeByte(':');
        }
        try writer.print("{d}", .{report.column_number});
        wrote_prefix = true;
    }
    if (wrote_prefix) {
        try writer.writeByte(':');
    }
    const display_slice = if (output.only_matching)
        report.line[report.match_span.start - report.line_span.start .. report.match_span.end - report.line_span.start]
    else
        report.line;
    try writeDisplayLine(writer, display_slice);
    try writer.writeByte('\n');
}

fn warnAndSkipFileError(writer: *std.Io.Writer, path: []const u8, err: anyerror) !bool {
    if (!shouldWarnAndSkipFileError(err)) return false;
    try writer.print("warning: skipping {s}: {s}\n", .{ path, @errorName(err) });
    return true;
}

fn shouldWarnAndSkipFileError(err: anyerror) bool {
    return switch (err) {
        error.FileNotFound,
        error.AccessDenied,
        error.NotDir,
        error.NameTooLong,
        error.SymLinkLoop,
        => true,
        else => false,
    };
}

fn writeFileReports(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    searcher: *zigrep.search.grep.Searcher,
    path: []const u8,
    bytes: []const u8,
    encoding: zigrep.search.io.InputEncoding,
    output: OutputOptions,
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
            try writeReport(self.writer, report, self.output);
        }
    };

    var context = WriterContext{
        .allocator = allocator,
        .writer = writer,
        .output = .{},
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
    try writeDisplayLine(writer, line);
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
            try writeReport(writer, matched_lines.items[match_index].report, output);
        } else {
            try writeContextLine(writer, path, line_index + 1, haystack[line_span.start..line_span.end], output);
        }
    }

    return true;
}

fn writeFileOutput(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    searcher: *zigrep.search.grep.Searcher,
    path: []const u8,
    bytes: []const u8,
    encoding: zigrep.search.io.InputEncoding,
    output: OutputOptions,
    report_mode: ReportMode,
    max_count: ?usize,
    context_before: usize,
    context_after: usize,
) !bool {
    return switch (report_mode) {
        .lines => writeFileLines(
            allocator,
            writer,
            searcher,
            path,
            bytes,
            encoding,
            output,
            max_count,
            context_before,
            context_after,
        ),
        .count => writeFileCount(allocator, writer, searcher, path, bytes, encoding, output, max_count),
        .files_with_matches => writeFilePathOnMatch(allocator, writer, searcher, path, bytes, encoding),
        .files_without_match => writeFilePathWithoutMatch(allocator, writer, searcher, path, bytes, encoding),
    };
}

fn writeFileLines(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    searcher: *zigrep.search.grep.Searcher,
    path: []const u8,
    bytes: []const u8,
    encoding: zigrep.search.io.InputEncoding,
    output: OutputOptions,
    max_count: ?usize,
    context_before: usize,
    context_after: usize,
) !bool {
    if (try zigrep.search.io.decodeToUtf8Alloc(allocator, bytes, encoding)) |decoded| {
        defer allocator.free(decoded);
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
        return writeFileReports(allocator, writer, searcher, path, decoded, .utf8, output, max_count);
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
    return writeFileReports(allocator, writer, searcher, path, bytes, .utf8, output, max_count);
}

fn writeFileCount(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    searcher: *zigrep.search.grep.Searcher,
    path: []const u8,
    bytes: []const u8,
    encoding: zigrep.search.io.InputEncoding,
    output: OutputOptions,
    max_count: ?usize,
) !bool {
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

    if (try zigrep.search.io.decodeToUtf8Alloc(allocator, bytes, encoding)) |decoded| {
        defer allocator.free(decoded);
        _ = searcher.forEachLineReport(path, decoded, &counter, Counter.emit) catch |err| switch (err) {
            IterationStop.MaxCountReached => true,
            else => return err,
        };
    } else {
        _ = searcher.forEachLineReport(path, bytes, &counter, Counter.emit) catch |err| switch (err) {
            IterationStop.MaxCountReached => true,
            else => return err,
        };
    }

    if (counter.count == 0) return false;
    if (output.with_filename) {
        try writer.print("{s}:{d}\n", .{ path, counter.count });
    } else {
        try writer.print("{d}\n", .{counter.count});
    }
    return true;
}

fn writeFilePathOnMatch(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    searcher: *zigrep.search.grep.Searcher,
    path: []const u8,
    bytes: []const u8,
    encoding: zigrep.search.io.InputEncoding,
) !bool {
    const report = try reportFileMatch(allocator, searcher, path, bytes, encoding) orelse return false;
    defer report.deinit(allocator);
    try writer.print("{s}\n", .{path});
    return true;
}

fn writeFilePathWithoutMatch(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    searcher: *zigrep.search.grep.Searcher,
    path: []const u8,
    bytes: []const u8,
    encoding: zigrep.search.io.InputEncoding,
) !bool {
    const report = try reportFileMatch(allocator, searcher, path, bytes, encoding);
    if (report) |found| {
        found.deinit(allocator);
        return false;
    }
    try writer.print("{s}\n", .{path});
    return true;
}

fn reportFileMatch(
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

fn formatReport(
    allocator: std.mem.Allocator,
    report: zigrep.search.grep.MatchReport,
    output: OutputOptions,
) ![]u8 {
    var buffer: std.Io.Writer.Allocating = .init(allocator);
    defer buffer.deinit();
    try writeReport(&buffer.writer, report, output);
    var array_list = buffer.toArrayList();
    return try array_list.toOwnedSlice(allocator);
}

fn writeDisplayLine(writer: *std.Io.Writer, bytes: []const u8) !void {
    var index: usize = 0;
    while (index < bytes.len) {
        const byte = bytes[index];
        if (byte < 0x80) {
            if (isDisplaySafeAscii(byte)) {
                try writer.writeByte(byte);
            } else {
                try writer.print("\\x{X:0>2}", .{byte});
            }
            index += 1;
            continue;
        }

        const sequence_len = std.unicode.utf8ByteSequenceLength(byte) catch {
            try writer.print("\\x{X:0>2}", .{byte});
            index += 1;
            continue;
        };
        if (index + sequence_len > bytes.len) {
            try writer.print("\\x{X:0>2}", .{byte});
            index += 1;
            continue;
        }

        const sequence = bytes[index .. index + sequence_len];
        _ = std.unicode.utf8Decode(sequence) catch {
            try writer.print("\\x{X:0>2}", .{byte});
            index += 1;
            continue;
        };

        try writer.writeAll(sequence);
        index += sequence_len;
    }
}

fn isDisplaySafeAscii(byte: u8) bool {
    return switch (byte) {
        '\t', ' '...'~' => true,
        else => false,
    };
}

fn parseEncoding(arg: []const u8) CliError!zigrep.search.io.InputEncoding {
    if (std.ascii.eqlIgnoreCase(arg, "auto")) return .auto;
    if (std.ascii.eqlIgnoreCase(arg, "utf8")) return .utf8;
    if (std.ascii.eqlIgnoreCase(arg, "utf16le")) return .utf16le;
    if (std.ascii.eqlIgnoreCase(arg, "utf16be")) return .utf16be;
    return error.InvalidFlagValue;
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
        \\  -V, --version         show program version
        \\  --hidden              include hidden files
        \\  --ignore-file PATH    load ignore rules from PATH
        \\  --no-ignore           disable ignore filtering
        \\  --no-ignore-vcs       ignore VCS ignore files like .gitignore
        \\  --no-ignore-parent    ignore parent VCS ignore files
        \\  --follow              follow symlinks
        \\  --text                search binary files too
        \\  -g, --glob GLOB       include or exclude paths by glob
        \\  --buffered            use the simpler file-reading method
        \\  --mmap                use the faster file-reading method when possible
        \\  -E, --encoding ENC    force input encoding: auto, utf8, utf16le, utf16be
        \\  -j, --threads N       use up to N worker threads
        \\  --max-depth N         limit recursive walk depth
        \\  -A, --after-context N
        \\                        print N trailing context lines
        \\  -B, --before-context N
        \\                        print N leading context lines
        \\  -C, --context N       print N leading and trailing context lines
        \\  -m, --max-count N     stop after N matching lines per file
        \\  -c, --count           print matching line counts
        \\  -l, --files-with-matches
        \\                        print only matching file paths
        \\  -L, --files-without-match
        \\                        print only non-matching file paths
        \\  -o, --only-matching   print only the matched text
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
        .run => |opts| {
            testing.allocator.free(opts.paths);
            testing.allocator.free(opts.globs);
            testing.allocator.free(opts.ignore_files);
        },
        .help, .version => {},
    };

    switch (parsed) {
        .run => |opts| {
            try testing.expectEqualStrings("needle", opts.pattern);
            try testing.expectEqual(@as(usize, 1), opts.paths.len);
            try testing.expectEqualStrings(".", opts.paths[0]);
            try testing.expectEqual(@as(usize, 0), opts.globs.len);
            try testing.expectEqual(@as(usize, 0), opts.ignore_files.len);
            try testing.expect(!opts.include_hidden);
            try testing.expect(!opts.follow_symlinks);
            try testing.expect(!opts.no_ignore);
            try testing.expect(!opts.no_ignore_vcs);
            try testing.expect(!opts.no_ignore_parent);
            try testing.expect(opts.skip_binary);
            try testing.expectEqual(zigrep.search.io.ReadStrategy.mmap, opts.read_strategy);
            try testing.expectEqual(zigrep.search.io.InputEncoding.auto, opts.encoding);
            try testing.expectEqual(@as(?usize, null), opts.parallel_jobs);
            try testing.expectEqual(@as(?usize, null), opts.max_depth);
            try testing.expect(opts.output.with_filename);
            try testing.expect(opts.output.line_number);
            try testing.expect(opts.output.column_number);
            try testing.expect(!opts.output.only_matching);
            try testing.expectEqual(ReportMode.lines, opts.report_mode);
        },
        .help => unreachable,
        .version => unreachable,
    }
}

test "parseArgs accepts version flag" {
    const testing = std.testing;

    const parsed = try parseArgs(testing.allocator, &.{ "zigrep", "--version" });
    switch (parsed) {
        .version => {},
        else => return error.TestExpectedEqual,
    }
}

test "writeFatalError includes usage for CLI usage errors" {
    const testing = std.testing;

    var stderr_capture: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_capture.deinit();

    try writeFatalError(&stderr_capture.writer, "zigrep", error.MissingPattern);

    try testing.expect(std.mem.containsAtLeast(u8, stderr_capture.written(), 1, "error: MissingPattern\n"));
    try testing.expect(std.mem.containsAtLeast(u8, stderr_capture.written(), 1, "usage: zigrep [FLAGS] PATTERN [PATH...]\n"));
}

test "writeFatalError omits usage for runtime search errors" {
    const testing = std.testing;

    var stderr_capture: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_capture.deinit();

    try writeFatalError(&stderr_capture.writer, "zigrep", error.FileNotFound);

    try testing.expectEqualStrings("error: FileNotFound\n", stderr_capture.written());
}

test "parseArgs treats version-like args as positional after the pattern starts" {
    const testing = std.testing;

    const parsed = try parseArgs(testing.allocator, &.{ "zigrep", "needle", "--version" });
    defer switch (parsed) {
        .run => |opts| {
            testing.allocator.free(opts.paths);
            testing.allocator.free(opts.globs);
            testing.allocator.free(opts.ignore_files);
        },
        .help, .version => {},
    };

    switch (parsed) {
        .run => |opts| {
            try testing.expectEqualStrings("needle", opts.pattern);
            try testing.expectEqual(@as(usize, 1), opts.paths.len);
            try testing.expectEqualStrings("--version", opts.paths[0]);
        },
        .help, .version => return error.TestExpectedEqual,
    }
}

test "parseArgs treats help-like args as positional after terminator" {
    const testing = std.testing;

    const parsed = try parseArgs(testing.allocator, &.{ "zigrep", "--", "--help" });
    defer switch (parsed) {
        .run => |opts| {
            testing.allocator.free(opts.paths);
            testing.allocator.free(opts.globs);
            testing.allocator.free(opts.ignore_files);
        },
        .help, .version => {},
    };

    switch (parsed) {
        .run => |opts| {
            try testing.expectEqualStrings("--help", opts.pattern);
            try testing.expectEqual(@as(usize, 1), opts.paths.len);
            try testing.expectEqualStrings(".", opts.paths[0]);
        },
        .help, .version => return error.TestExpectedEqual,
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
        "--max-count",
        "3",
        "--count",
        "--only-matching",
        "--encoding",
        "utf16le",
        "--no-filename",
        "--no-column",
        "--",
        "-literal",
        "src",
    });
    defer switch (parsed) {
        .run => |opts| {
            testing.allocator.free(opts.paths);
            testing.allocator.free(opts.globs);
            testing.allocator.free(opts.ignore_files);
        },
        .help, .version => {},
    };

    switch (parsed) {
        .run => |opts| {
            try testing.expectEqualStrings("-literal", opts.pattern);
            try testing.expectEqual(@as(?usize, 4), opts.parallel_jobs);
            try testing.expectEqual(@as(?usize, 2), opts.max_depth);
            try testing.expectEqual(@as(?usize, 3), opts.max_count);
            try testing.expectEqual(zigrep.search.io.InputEncoding.utf16le, opts.encoding);
            try testing.expect(!opts.output.with_filename);
            try testing.expect(opts.output.line_number);
            try testing.expect(!opts.output.column_number);
            try testing.expect(opts.output.only_matching);
            try testing.expectEqual(ReportMode.count, opts.report_mode);
            try testing.expectEqual(@as(usize, 1), opts.paths.len);
            try testing.expectEqualStrings("src", opts.paths[0]);
        },
        .help, .version => unreachable,
    }
}

test "parseArgs accepts files-without-match mode" {
    const testing = std.testing;

    const parsed = try parseArgs(testing.allocator, &.{ "zigrep", "--files-without-match", "needle", "src" });
    defer switch (parsed) {
        .run => |opts| {
            testing.allocator.free(opts.paths);
            testing.allocator.free(opts.globs);
            testing.allocator.free(opts.ignore_files);
        },
        .help, .version => {},
    };

    switch (parsed) {
        .run => |opts| {
            try testing.expectEqual(ReportMode.files_without_match, opts.report_mode);
            try testing.expectEqualStrings("needle", opts.pattern);
            try testing.expectEqual(@as(usize, 1), opts.paths.len);
            try testing.expectEqualStrings("src", opts.paths[0]);
        },
        .help, .version => unreachable,
    }
}

test "parseArgs accepts max-count mode" {
    const testing = std.testing;

    const parsed = try parseArgs(testing.allocator, &.{ "zigrep", "-m", "2", "needle", "src" });
    defer switch (parsed) {
        .run => |opts| {
            testing.allocator.free(opts.paths);
            testing.allocator.free(opts.globs);
            testing.allocator.free(opts.ignore_files);
        },
        .help, .version => {},
    };

    switch (parsed) {
        .run => |opts| {
            try testing.expectEqual(@as(?usize, 2), opts.max_count);
            try testing.expectEqualStrings("needle", opts.pattern);
            try testing.expectEqual(@as(usize, 1), opts.paths.len);
            try testing.expectEqualStrings("src", opts.paths[0]);
        },
        .help, .version => unreachable,
    }
}

test "parseArgs accepts before and after context flags" {
    const testing = std.testing;

    const parsed = try parseArgs(testing.allocator, &.{ "zigrep", "-B", "2", "-A", "3", "needle", "src" });
    defer switch (parsed) {
        .run => |opts| {
            testing.allocator.free(opts.paths);
            testing.allocator.free(opts.globs);
            testing.allocator.free(opts.ignore_files);
        },
        .help, .version => {},
    };

    switch (parsed) {
        .run => |opts| {
            try testing.expectEqual(@as(usize, 2), opts.context_before);
            try testing.expectEqual(@as(usize, 3), opts.context_after);
        },
        .help, .version => unreachable,
    }
}

test "parseArgs accepts repeated glob flags" {
    const testing = std.testing;

    const parsed = try parseArgs(testing.allocator, &.{ "zigrep", "-g", "*.zig", "--glob", "!main.zig", "needle", "src" });
    defer switch (parsed) {
        .run => |opts| {
            testing.allocator.free(opts.paths);
            testing.allocator.free(opts.globs);
            testing.allocator.free(opts.ignore_files);
        },
        .help, .version => {},
    };

    switch (parsed) {
        .run => |opts| {
            try testing.expectEqual(@as(usize, 2), opts.globs.len);
            try testing.expectEqualStrings("*.zig", opts.globs[0]);
            try testing.expectEqualStrings("!main.zig", opts.globs[1]);
            try testing.expectEqualStrings("needle", opts.pattern);
        },
        .help, .version => unreachable,
    }
}

test "parseArgs accepts ignore control flags" {
    const testing = std.testing;

    const parsed = try parseArgs(testing.allocator, &.{
        "zigrep",
        "--ignore-file",
        "custom.ignore",
        "--no-ignore-vcs",
        "--no-ignore-parent",
        "needle",
        "src",
    });
    defer switch (parsed) {
        .run => |opts| {
            testing.allocator.free(opts.paths);
            testing.allocator.free(opts.globs);
            testing.allocator.free(opts.ignore_files);
        },
        .help, .version => {},
    };

    switch (parsed) {
        .run => |opts| {
            try testing.expectEqual(@as(usize, 1), opts.ignore_files.len);
            try testing.expectEqualStrings("custom.ignore", opts.ignore_files[0]);
            try testing.expect(!opts.no_ignore);
            try testing.expect(opts.no_ignore_vcs);
            try testing.expect(opts.no_ignore_parent);
        },
        .help, .version => unreachable,
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
    try testing.expectError(error.InvalidFlagValue, parseArgs(testing.allocator, &.{
        "zigrep",
        "--encoding",
        "latin1",
        "needle",
    }));
    try testing.expectError(error.InvalidFlagCombination, parseArgs(testing.allocator, &.{
        "zigrep",
        "--count",
        "-C",
        "1",
        "needle",
    }));
    try testing.expectError(error.InvalidFlagCombination, parseArgs(testing.allocator, &.{
        "zigrep",
        "--only-matching",
        "-A",
        "1",
        "needle",
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

test "runCli honors root gitignore by default" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = ".gitignore",
        .data = "ignored.txt\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "ignored.txt",
        .data = "needle hidden\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "shown.txt",
        .data = "needle shown\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try runCliCaptured(testing.allocator, &.{ "zigrep", "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(!std.mem.containsAtLeast(u8, run.stdout, 1, "ignored.txt"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "shown.txt:1:1:needle shown"));
}

test "runCli no-ignore-vcs bypasses root gitignore" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = ".gitignore",
        .data = "ignored.txt\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "ignored.txt",
        .data = "needle hidden\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try runCliCaptured(testing.allocator, &.{ "zigrep", "--no-ignore-vcs", "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "ignored.txt:1:1:needle hidden"));
}

test "runCli no-ignore-parent bypasses parent gitignore" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("sub");
    try tmp.dir.writeFile(.{
        .sub_path = ".gitignore",
        .data = "sub/ignored.txt\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "sub/ignored.txt",
        .data = "needle hidden\n",
    });

    const sub_path = try tmp.dir.realpathAlloc(testing.allocator, "sub");
    defer testing.allocator.free(sub_path);

    const default_run = try runCliCaptured(testing.allocator, &.{ "zigrep", "needle", sub_path });
    defer default_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 1), default_run.exit_code);

    const bypass_run = try runCliCaptured(testing.allocator, &.{ "zigrep", "--no-ignore-parent", "needle", sub_path });
    defer bypass_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), bypass_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, bypass_run.stdout, 1, "ignored.txt:1:1:needle hidden"));
}

test "runCli ignore-file applies explicit ignore rules" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "custom.ignore",
        .data = "blocked.txt\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "blocked.txt",
        .data = "needle hidden\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "shown.txt",
        .data = "needle shown\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);
    const ignore_path = try tmp.dir.realpathAlloc(testing.allocator, "custom.ignore");
    defer testing.allocator.free(ignore_path);

    const run = try runCliCaptured(testing.allocator, &.{ "zigrep", "--ignore-file", ignore_path, "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(!std.mem.containsAtLeast(u8, run.stdout, 1, "blocked.txt"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "shown.txt:1:1:needle shown"));
}

test "runCli no-ignore bypasses all ignore filtering" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = ".gitignore",
        .data = "ignored.txt\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "custom.ignore",
        .data = "blocked.txt\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "ignored.txt",
        .data = "needle ignored\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "blocked.txt",
        .data = "needle blocked\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);
    const ignore_path = try tmp.dir.realpathAlloc(testing.allocator, "custom.ignore");
    defer testing.allocator.free(ignore_path);

    const run = try runCliCaptured(testing.allocator, &.{ "zigrep", "--no-ignore", "--ignore-file", ignore_path, "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "ignored.txt:1:1:needle ignored"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "blocked.txt:1:1:needle blocked"));
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

test "runCli prints version and exits successfully" {
    const testing = std.testing;

    const run = try runCliCaptured(testing.allocator, &.{ "zigrep", "--version" });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expectEqualStrings("zigrep " ++ zigrep.app_version ++ "\n", run.stdout);
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
    var stderr_capture: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_capture.deinit();

    const exit_code = try runSearch(testing.allocator, &stdout_capture.writer, &stderr_capture.writer, .{
        .pattern = "needle",
        .paths = &.{root_path},
        .parallel_jobs = 2,
    });

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, stdout_capture.written(), 1, "one.txt:1:1:needle one"));
    try testing.expect(std.mem.containsAtLeast(u8, stdout_capture.written(), 1, "two.txt:1:1:needle two"));
    try testing.expectEqualStrings("", stderr_capture.written());
}

test "runSearch buffered output stays identical to the default path" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "one.txt",
        .data = "needle one\nneedle two\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "two.txt",
        .data = "xx\xffneedleyy\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    var default_stdout: std.Io.Writer.Allocating = .init(testing.allocator);
    defer default_stdout.deinit();
    var default_stderr: std.Io.Writer.Allocating = .init(testing.allocator);
    defer default_stderr.deinit();

    const default_exit = try runSearch(testing.allocator, &default_stdout.writer, &default_stderr.writer, .{
        .pattern = "needle",
        .paths = &.{root_path},
        .parallel_jobs = 1,
    });

    var buffered_stdout: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffered_stdout.deinit();
    var buffered_stderr: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffered_stderr.deinit();

    const buffered_exit = try runSearch(testing.allocator, &buffered_stdout.writer, &buffered_stderr.writer, .{
        .pattern = "needle",
        .paths = &.{root_path},
        .parallel_jobs = 1,
        .buffer_output = true,
    });

    try testing.expectEqual(default_exit, buffered_exit);
    try testing.expectEqualStrings(default_stdout.written(), buffered_stdout.written());
    try testing.expectEqualStrings(default_stderr.written(), buffered_stderr.written());
}

test "runSearch output stays identical across allocator and output modes on mixed input" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "plain.txt",
        .data = "needle one\nskip\nneedle two\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "invalid.bin",
        .data = "xx\xffneedleyy\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "utf16le.txt",
        .data =
            "\xff\xfe" ++
            "n\x00e\x00e\x00d\x00l\x00e\x00 \x00u\x00n\x00o\x00\n\x00" ++
            "s\x00k\x00i\x00p\x00\n\x00" ++
            "n\x00e\x00e\x00d\x00l\x00e\x00 \x00d\x00o\x00s\x00\n\x00",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const modes = [_]CliOptions{
        .{
            .pattern = "needle",
            .paths = &.{root_path},
            .parallel_jobs = 1,
            .read_strategy = .buffered,
        },
        .{
            .pattern = "needle",
            .paths = &.{root_path},
            .parallel_jobs = 1,
            .read_strategy = .mmap,
            .buffer_output = true,
        },
        .{
            .pattern = "needle",
            .paths = &.{root_path},
            .parallel_jobs = 4,
            .read_strategy = .mmap,
        },
        .{
            .pattern = "needle",
            .paths = &.{root_path},
            .parallel_jobs = 4,
            .read_strategy = .mmap,
            .buffer_output = true,
        },
    };

    var expected_stdout: ?[]u8 = null;
    defer if (expected_stdout) |bytes| testing.allocator.free(bytes);
    var expected_stderr: ?[]u8 = null;
    defer if (expected_stderr) |bytes| testing.allocator.free(bytes);
    var expected_exit: ?u8 = null;

    for (modes) |mode| {
        var stdout_capture: std.Io.Writer.Allocating = .init(testing.allocator);
        defer stdout_capture.deinit();
        var stderr_capture: std.Io.Writer.Allocating = .init(testing.allocator);
        defer stderr_capture.deinit();

        const exit_code = try runSearch(
            testing.allocator,
            &stdout_capture.writer,
            &stderr_capture.writer,
            mode,
        );

        if (expected_stdout == null) {
            expected_stdout = try testing.allocator.dupe(u8, stdout_capture.written());
            expected_stderr = try testing.allocator.dupe(u8, stderr_capture.written());
            expected_exit = exit_code;
        } else {
            try testing.expectEqual(expected_exit.?, exit_code);
            try testing.expectEqualStrings(expected_stdout.?, stdout_capture.written());
            try testing.expectEqualStrings(expected_stderr.?, stderr_capture.written());
        }
    }
}

test "runCli prints every matching line from one file" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "many.txt",
        .data =
            "needle one\n" ++
            "skip\n" ++
            "needle two\n" ++
            "needle needle\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try runCliCaptured(testing.allocator, &.{ "zigrep", "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "many.txt:1:1:needle one"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "many.txt:3:1:needle two"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "many.txt:4:1:needle needle"));
}

test "runCli count mode prints per-file matching line counts" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "many.txt",
        .data =
            "needle one\n" ++
            "skip\n" ++
            "needle two\n" ++
            "needle needle\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try runCliCaptured(testing.allocator, &.{ "zigrep", "--count", "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "many.txt:3\n"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli max-count limits matching lines per file" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "many.txt",
        .data =
            "needle one\n" ++
            "skip\n" ++
            "needle two\n" ++
            "needle three\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try runCliCaptured(testing.allocator, &.{ "zigrep", "--max-count", "2", "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "many.txt:1:1:needle one"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "many.txt:3:1:needle two"));
    try testing.expect(!std.mem.containsAtLeast(u8, run.stdout, 1, "many.txt:4:1:needle three"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli context mode prints surrounding lines and separators" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "ctx.txt",
        .data =
            "alpha\n" ++
            "before\n" ++
            "needle one\n" ++
            "after\n" ++
            "gap1\n" ++
            "gap2\n" ++
            "needle two\n" ++
            "tail\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try runCliCaptured(testing.allocator, &.{ "zigrep", "-C", "1", "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "ctx.txt-2-before\n"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "ctx.txt:3:1:needle one\n"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "ctx.txt-4-after\n"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "--\n"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "ctx.txt-6-gap2\n"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "ctx.txt:7:1:needle two\n"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "ctx.txt-8-tail\n"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli context mode respects max-count" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "ctx.txt",
        .data =
            "before\n" ++
            "needle one\n" ++
            "after\n" ++
            "gap1\n" ++
            "needle two\n" ++
            "tail\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try runCliCaptured(testing.allocator, &.{ "zigrep", "-C", "1", "--max-count", "1", "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "ctx.txt-1-before\n"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "ctx.txt:2:1:needle one\n"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "ctx.txt-3-after\n"));
    try testing.expect(!std.mem.containsAtLeast(u8, run.stdout, 1, "needle two"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli glob mode filters files by positive glob" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "keep.txt",
        .data = "needle one\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "skip.md",
        .data = "needle two\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try runCliCaptured(testing.allocator, &.{ "zigrep", "-g", "*.txt", "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "keep.txt:1:1:needle one"));
    try testing.expect(!std.mem.containsAtLeast(u8, run.stdout, 1, "skip.md"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli glob mode supports negative globs" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "one.txt",
        .data = "needle one\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "main.txt",
        .data = "needle two\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try runCliCaptured(testing.allocator, &.{ "zigrep", "-g", "*.txt", "-g", "!main.txt", "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "one.txt:1:1:needle one"));
    try testing.expect(!std.mem.containsAtLeast(u8, run.stdout, 1, "main.txt:1:1:needle two"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli count mode respects max-count" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "many.txt",
        .data =
            "needle one\n" ++
            "skip\n" ++
            "needle two\n" ++
            "needle three\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try runCliCaptured(testing.allocator, &.{ "zigrep", "--count", "--max-count", "2", "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "many.txt:2\n"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli files-with-matches mode prints matching file paths once" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "one.txt",
        .data = "needle one\nneedle two\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "two.txt",
        .data = "skip\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try runCliCaptured(testing.allocator, &.{ "zigrep", "--files-with-matches", "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "one.txt\n"));
    try testing.expect(!std.mem.containsAtLeast(u8, run.stdout, 1, "two.txt\n"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli files-without-match mode prints only non-matching file paths" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "one.txt",
        .data = "needle one\nneedle two\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "two.txt",
        .data = "skip\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try runCliCaptured(testing.allocator, &.{ "zigrep", "--files-without-match", "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(!std.mem.containsAtLeast(u8, run.stdout, 1, "one.txt\n"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "two.txt\n"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli only-matching mode prints each match occurrence" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "many.txt",
        .data = "needle one needle two\nneedle\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try runCliCaptured(testing.allocator, &.{ "zigrep", "--only-matching", "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "many.txt:1:1:needle\n"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "many.txt:1:12:needle\n"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "many.txt:2:1:needle\n"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli only-matching mode respects max-count by matching line" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "many.txt",
        .data = "needle one needle two\nneedle three\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try runCliCaptured(testing.allocator, &.{ "zigrep", "--only-matching", "--max-count", "1", "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "many.txt:1:1:needle\n"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "many.txt:1:12:needle\n"));
    try testing.expect(!std.mem.containsAtLeast(u8, run.stdout, 1, "many.txt:2:1:needle\n"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runSearch parallel path prints every matching line from one file" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "one.txt",
        .data = "needle one\nneedle again\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "two.txt",
        .data = "needle two\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    var stdout_capture: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_capture.deinit();

    const exit_code = try runSearch(testing.allocator, &stdout_capture.writer, &stderr_capture.writer, .{
        .pattern = "needle",
        .paths = &.{root_path},
        .parallel_jobs = 2,
    });

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, stdout_capture.written(), 1, "one.txt:1:1:needle one"));
    try testing.expect(std.mem.containsAtLeast(u8, stdout_capture.written(), 1, "one.txt:2:1:needle again"));
    try testing.expect(std.mem.containsAtLeast(u8, stdout_capture.written(), 1, "two.txt:1:1:needle two"));
    try testing.expectEqualStrings("", stderr_capture.written());
}

test "searchEntriesSequential warns and skips unreadable files" {
    const testing = std.testing;

    var stdout_capture: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_capture.deinit();

    const missing_path = try testing.allocator.dupe(u8, "missing-file-for-zigrep-test");
    defer testing.allocator.free(missing_path);

    const entries = [_]zigrep.search.walk.Entry{
        .{ .path = missing_path, .kind = .file, .depth = 0 },
    };

    const matched = try searchEntriesSequential(testing.allocator, &stdout_capture.writer, &stderr_capture.writer, &entries, .{
        .pattern = "needle",
        .paths = &.{"."},
    });

    try testing.expect(!matched);
    try testing.expectEqualStrings("", stdout_capture.written());
    try testing.expect(std.mem.containsAtLeast(u8, stderr_capture.written(), 1, "warning: skipping missing-file-for-zigrep-test: FileNotFound\n"));
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

test "formatReport escapes unsafe bytes in displayed lines" {
    const testing = std.testing;

    const report: zigrep.search.grep.MatchReport = .{
        .path = "sample.bin",
        .line_number = 1,
        .column_number = 4,
        .line = "aa\x00\xffneedle\x1b",
        .line_span = .{ .start = 0, .end = 11 },
        .match_span = .{ .start = 4, .end = 10 },
    };

    const line = try formatReport(testing.allocator, report, .{});
    defer testing.allocator.free(line);

    try testing.expectEqualStrings("sample.bin:1:4:aa\\x00\\xFFneedle\\x1B\n", line);
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

test "runCli skips invalid UTF-8 files instead of aborting the whole search" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "good.txt",
        .data = "needle here\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "bad.bin",
        .data = "xx\xffneedleyy",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try runCliCaptured(testing.allocator, &.{ "zigrep", "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "good.txt:1:1:needle here"));
    try testing.expect(!std.mem.containsAtLeast(u8, run.stderr, 1, "InvalidUtf8"));
}

test "runCli text mode searches invalid UTF-8 files through the raw-byte matcher" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "bad.bin",
        .data = "xx\xffneedleyy",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try runCliCaptured(testing.allocator, &.{ "zigrep", "--text", "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "bad.bin:1:4:xx\\xFFneedleyy"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli text mode lets dot match an invalid byte through the raw-byte matcher" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "dot.bin",
        .data = "a\xffb\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try runCliCaptured(testing.allocator, &.{ "zigrep", "--text", "a.b", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "dot.bin:1:1:a\\xFFb"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli text mode matches UTF-8 literals through the byte path on invalid UTF-8 files" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "utf8.bin",
        .data = "xx\xffжарyy\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try runCliCaptured(testing.allocator, &.{ "zigrep", "--text", "жар", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "utf8.bin:1:4:xx\\xFFжарyy"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli default mode uses the raw-byte path for planner-covered invalid UTF-8 files" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "textish.bin",
        .data = "xx\xffneedleyy",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try runCliCaptured(testing.allocator, &.{ "zigrep", "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "textish.bin:1:4:xx\\xFFneedleyy"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli default mode uses the raw-byte path for empty capture groups on invalid UTF-8 files" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "textish.bin",
        .data = "xx\xffabyy",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try runCliCaptured(testing.allocator, &.{ "zigrep", "a()b", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "textish.bin:1:4:xx\\xFFabyy"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli default mode uses the raw-byte path for grouped concatenation inside a larger sequence" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "textish.bin",
        .data = "zzxa\xff7byy",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try runCliCaptured(testing.allocator, &.{ "zigrep", "x(a.[0-9]b)y", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "textish.bin:1:3:zzxa\\xFF7byy"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli default mode uses the raw-byte path for quantified bare anchors on invalid UTF-8 files" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "textish.bin",
        .data = "\xffabc",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try runCliCaptured(testing.allocator, &.{ "zigrep", "^+", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "textish.bin:1:1:\\xFFabc"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli default mode uses the general raw-byte VM when no planner path exists" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "textish.bin",
        .data = "aby\xff",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try runCliCaptured(testing.allocator, &.{ "zigrep", "(^ab)y", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "textish.bin:1:1:aby\\xFF"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli default mode still returns no match for invalid UTF-8 patterns outside the byte planner" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "dot.bin",
        .data = "\xffa字b\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try runCliCaptured(testing.allocator, &.{ "zigrep", "a\\db", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 1), run.exit_code);
    try testing.expectEqualStrings("", run.stdout);
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli default mode matches literal-only UTF-8 classes through the byte path" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "utf8-class.bin",
        .data = "xx\xffжyy\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try runCliCaptured(testing.allocator, &.{ "zigrep", "[ж]", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "utf8-class.bin:1:4:xx\\xFFжyy"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli default mode matches small UTF-8 range classes through the byte path" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "utf8-range.bin",
        .data = "xx\xffжyy\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try runCliCaptured(testing.allocator, &.{ "zigrep", "[а-я]", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "utf8-range.bin:1:4:xx\\xFFжyy"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli default mode matches negated literal-only UTF-8 classes through the byte path" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "utf8-negated.bin",
        .data = "\xffaяb\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try runCliCaptured(testing.allocator, &.{ "zigrep", "a[^ж]b", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "utf8-negated.bin:1:2:\\xFFaяb"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli default mode matches negated small UTF-8 ranges through the byte path" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "utf8-negated-range.bin",
        .data = "\xffaѣb\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try runCliCaptured(testing.allocator, &.{ "zigrep", "a[^а-я]b", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "utf8-negated-range.bin:1:2:\\xFFaѣb"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli default mode matches larger UTF-8 ranges through the byte path" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "utf8-large-range.bin",
        .data = "xx\xffжyy\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try runCliCaptured(testing.allocator, &.{ "zigrep", "[Ā-ӿ]", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "utf8-large-range.bin:1:4:xx\\xFFжyy"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli default mode matches negated larger UTF-8 ranges through the byte path" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "utf8-large-negated.bin",
        .data = "\xffa字b\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try runCliCaptured(testing.allocator, &.{ "zigrep", "a[^Ā-ӿ]b", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "utf8-large-negated.bin:1:2:\\xFFa字b"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli default mode matches quantified larger UTF-8 ranges through the byte path" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "utf8-large-quant.bin",
        .data = "x\xffжѣz\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try runCliCaptured(testing.allocator, &.{ "zigrep", "[Ā-ӿ]+", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "utf8-large-quant.bin:1:3:x\\xFFжѣz"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli default mode matches bare start anchors through the byte path" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "anchor-start.bin",
        .data = "\xffabc\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try runCliCaptured(testing.allocator, &.{ "zigrep", "^", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "anchor-start.bin:1:1:\\xFFabc"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli default mode matches bare end anchors through the byte path" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "anchor-end.bin",
        .data = "abc\xff",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try runCliCaptured(testing.allocator, &.{ "zigrep", "$", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "anchor-end.bin:1:5:abc\\xFF"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli default mode matches grouped alternation with anchored branches through the byte path" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "anchored-alt.bin",
        .data = "\xffcde\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try runCliCaptured(testing.allocator, &.{ "zigrep", "(^ab|cd)e", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "anchored-alt.bin:1:2:\\xFFcde"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli default mode matches anchored grouped repetition through the byte path" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "anchored-group.bin",
        .data = "abc",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try runCliCaptured(testing.allocator, &.{ "zigrep", "(^ab)+c", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "anchored-group.bin:1:1:abc"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli skips control-heavy binary payloads by default but searches them with text mode" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const payload = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 'n', 'e', 'e', 'd', 'l', 'e', '\n' };
    try tmp.dir.writeFile(.{
        .sub_path = "control-heavy.bin",
        .data = &payload,
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const default_run = try runCliCaptured(testing.allocator, &.{ "zigrep", "needle", root_path });
    defer default_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 1), default_run.exit_code);
    try testing.expectEqualStrings("", default_run.stdout);

    const text_run = try runCliCaptured(testing.allocator, &.{ "zigrep", "--text", "needle", root_path });
    defer text_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), text_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, text_run.stdout, 1, "control-heavy.bin:1:9:\\x01\\x02\\x03\\x04\\x05\\x06\\x07\\x08needle"));
}

test "runCli can search UTF-16LE BOM files in default mode" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "utf16le.txt",
        .data = "\xff\xfen\x00e\x00e\x00d\x00l\x00e\x00\n\x00",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try runCliCaptured(testing.allocator, &.{ "zigrep", "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "utf16le.txt:1:1:needle"));
}

test "runCli can search UTF-16BE BOM files in default mode" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "utf16be.txt",
        .data = "\xfe\xff\x00n\x00e\x00e\x00d\x00l\x00e\x00\x0a",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try runCliCaptured(testing.allocator, &.{ "zigrep", "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "utf16be.txt:1:1:needle"));
}

test "runCli can force UTF-16LE decoding without a BOM" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "utf16le-no-bom.txt",
        .data = "n\x00e\x00e\x00d\x00l\x00e\x00\n\x00",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const default_run = try runCliCaptured(testing.allocator, &.{ "zigrep", "needle", root_path });
    defer default_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 1), default_run.exit_code);

    const forced_run = try runCliCaptured(testing.allocator, &.{
        "zigrep",
        "--encoding",
        "utf16le",
        "needle",
        root_path,
    });
    defer forced_run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), forced_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, forced_run.stdout, 1, "utf16le-no-bom.txt:1:1:needle"));
}

test "runCli can force UTF-16BE decoding without a BOM" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "utf16be-no-bom.txt",
        .data = "\x00n\x00e\x00e\x00d\x00l\x00e\x00\x0a",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const forced_run = try runCliCaptured(testing.allocator, &.{
        "zigrep",
        "-E",
        "utf16be",
        "needle",
        root_path,
    });
    defer forced_run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), forced_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, forced_run.stdout, 1, "utf16be-no-bom.txt:1:1:needle"));
}

test "reportFileMatch only owns line bytes for transformed haystacks" {
    const testing = std.testing;

    var searcher = try zigrep.search.grep.Searcher.init(testing.allocator, "needle", .{});
    defer searcher.deinit();

    const normal = (try reportFileMatch(testing.allocator, &searcher, "normal.txt", "xxneedleyy", .auto)).?;
    defer normal.deinit(testing.allocator);
    try testing.expect(normal.owned_line == null);

    const decoded = (try reportFileMatch(testing.allocator, &searcher, "utf16.txt", "\xff\xfen\x00e\x00e\x00d\x00l\x00e\x00", .auto)).?;
    defer decoded.deinit(testing.allocator);
    try testing.expect(decoded.owned_line != null);
    try testing.expectEqualStrings("needle", decoded.line);

    const invalid = (try reportFileMatch(testing.allocator, &searcher, "invalid.bin", "xx\xffneedleyy", .auto)).?;
    defer invalid.deinit(testing.allocator);
    try testing.expect(invalid.owned_line == null);
    try testing.expectEqualStrings("xx\xffneedleyy", invalid.line);
}

test "writeFileReports does not require owned line bytes for decoded multi-line input" {
    const testing = std.testing;

    var searcher = try zigrep.search.grep.Searcher.init(testing.allocator, "needle", .{});
    defer searcher.deinit();

    const utf16le =
        "\xff\xfe" ++
        "n\x00e\x00e\x00d\x00l\x00e\x00 \x00o\x00n\x00e\x00\n\x00" ++
        "s\x00k\x00i\x00p\x00\n\x00" ++
        "n\x00e\x00e\x00d\x00l\x00e\x00 \x00t\x00w\x00o\x00\n\x00";

    var capture: std.Io.Writer.Allocating = .init(testing.allocator);
    defer capture.deinit();

    const matched = try writeFileReports(
        testing.allocator,
        &capture.writer,
        &searcher,
        "utf16.txt",
        utf16le,
        .auto,
        .{},
        null,
    );

    try testing.expect(matched);
    try testing.expectEqualStrings(
        "utf16.txt:1:1:needle one\n" ++
            "utf16.txt:3:1:needle two\n",
        capture.written(),
    );
}

test "reportFileMatch uses byte matching for planner-covered invalid UTF-8 input" {
    const testing = std.testing;

    var searcher = try zigrep.search.grep.Searcher.init(testing.allocator, "needle", .{});
    defer searcher.deinit();

    const report = (try reportFileMatch(testing.allocator, &searcher, "plain.bin", "xx\xffneedleyy", .auto)).?;
    defer report.deinit(testing.allocator);
    try testing.expect(report.owned_line == null);
    try testing.expectEqualStrings("xx\xffneedleyy", report.line);
}

test "reportFileMatch uses the raw-byte matcher when the planner does not cover the pattern" {
    const testing = std.testing;

    var searcher = try zigrep.search.grep.Searcher.init(testing.allocator, "(^ab)y", .{});
    defer searcher.deinit();

    const report = (try reportFileMatch(testing.allocator, &searcher, "raw-vm.bin", "aby\xff", .auto)).?;
    defer report.deinit(testing.allocator);
    try testing.expect(report.owned_line == null);
    try testing.expectEqualStrings("aby\xff", report.line);
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

test "runCli search output stays equivalent across allocator and read strategy paths" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "ascii.txt",
        .data = "prefix needle suffix\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "invalid.bin",
        .data = "xx\xffneedleyy\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "utf16le.txt",
        .data = "\xff\xfen\x00e\x00e\x00d\x00l\x00e\x00\n\x00",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const sequential_buffered = try runCliCaptured(testing.allocator, &.{
        "zigrep",
        "--text",
        "--buffered",
        "-j",
        "1",
        "needle",
        root_path,
    });
    defer sequential_buffered.deinit(testing.allocator);

    const sequential_mmap = try runCliCaptured(testing.allocator, &.{
        "zigrep",
        "--text",
        "--mmap",
        "-j",
        "1",
        "needle",
        root_path,
    });
    defer sequential_mmap.deinit(testing.allocator);

    const parallel_mmap = try runCliCaptured(testing.allocator, &.{
        "zigrep",
        "--text",
        "--mmap",
        "-j",
        "4",
        "needle",
        root_path,
    });
    defer parallel_mmap.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), sequential_buffered.exit_code);
    try testing.expectEqual(@as(u8, 0), sequential_mmap.exit_code);
    try testing.expectEqual(@as(u8, 0), parallel_mmap.exit_code);
    try testing.expectEqualStrings(sequential_buffered.stdout, sequential_mmap.stdout);
    try testing.expectEqualStrings(sequential_buffered.stdout, parallel_mmap.stdout);
    try testing.expectEqualStrings(sequential_buffered.stderr, sequential_mmap.stderr);
    try testing.expectEqualStrings(sequential_buffered.stderr, parallel_mmap.stderr);
}
