const std = @import("std");
const zigrep = @import("zigrep");

const CliError = error{
    MissingPattern,
    UnknownFlag,
    UnknownType,
    MissingFlagValue,
    InvalidFlagValue,
    InvalidFlagCombination,
    InvalidTypeAddSpec,
};

pub const OutputOptions = struct {
    with_filename: bool = true,
    line_number: bool = true,
    column_number: bool = true,
    only_matching: bool = false,
    null_path_terminator: bool = false,
    heading: bool = false,
};

const OutputFormat = enum {
    text,
    json,
};

const BinaryMode = enum {
    skip,
    text,
    suppress,
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
    pre_globs: []const []const u8 = &.{},
    ignore_files: []const []const u8 = &.{},
    include_types: []const []const u8 = &.{},
    exclude_types: []const []const u8 = &.{},
    type_adds: []const []const u8 = &.{},
    include_hidden: bool = false,
    follow_symlinks: bool = false,
    invert_match: bool = false,
    no_ignore: bool = false,
    no_ignore_vcs: bool = false,
    no_ignore_parent: bool = false,
    binary_mode: BinaryMode = .skip,
    search_compressed: bool = false,
    preprocessor: ?[]const u8 = null,
    case_mode: zigrep.search.grep.CaseMode = .sensitive,
    read_strategy: zigrep.search.io.ReadStrategy = .mmap,
    encoding: zigrep.search.io.InputEncoding = .auto,
    multiline: bool = false,
    multiline_dotall: bool = false,
    parallel_jobs: ?usize = null,
    max_depth: ?usize = null,
    max_count: ?usize = null,
    context_before: usize = 0,
    context_after: usize = 0,
    show_stats: bool = false,
    output: OutputOptions = .{},
    output_format: OutputFormat = .text,
    report_mode: ReportMode = .lines,
    buffer_output: bool = false,

    fn deinit(self: CliOptions, allocator: std.mem.Allocator) void {
        allocator.free(self.paths);
        allocator.free(self.globs);
        allocator.free(self.pre_globs);
        allocator.free(self.ignore_files);
        allocator.free(self.include_types);
        allocator.free(self.exclude_types);
        allocator.free(self.type_adds);
    }
};

const ParseResult = union(enum) {
    help,
    version,
    type_list: struct {
        type_adds: []const []const u8,

        fn deinit(self: @This(), allocator: std.mem.Allocator) void {
            allocator.free(self.type_adds);
        }
    },
    run: CliOptions,
};

const SearchStats = struct {
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

const SearchResult = struct {
    matched: bool,
    stats: SearchStats = .{},
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
        error.UnknownType,
        error.MissingFlagValue,
        error.InvalidFlagValue,
        error.InvalidFlagCombination,
        error.InvalidTypeAddSpec,
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
    const resolved = try zigrep.config.resolveArgs(allocator, argv);
    defer resolved.deinit(allocator);

    const parsed = try parseArgs(allocator, resolved.argv);
    defer switch (parsed) {
        .run => |opts| opts.deinit(allocator),
        .type_list => |opts| opts.deinit(allocator),
        .help, .version => {},
    };

    switch (parsed) {
        .help => {
            try writeUsage(stdout, resolved.argv[0]);
            return 0;
        },
        .version => {
            try stdout.print("zigrep {s}\n", .{zigrep.app_version});
            return 0;
        },
        .type_list => |opts| {
            const matcher = try zigrep.search.types.init(allocator, opts.type_adds);
            defer matcher.deinit(allocator);
            try zigrep.search.types.writeTypeList(stdout, matcher);
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
    var invert_match = false;
    var no_ignore = false;
    var no_ignore_vcs = false;
    var no_ignore_parent = false;
    var binary_mode: BinaryMode = .skip;
    var search_compressed = false;
    var preprocessor: ?[]const u8 = null;
    var unrestricted_level: u8 = 0;
    var case_mode: zigrep.search.grep.CaseMode = .sensitive;
    var read_strategy: zigrep.search.io.ReadStrategy = .mmap;
    var encoding: zigrep.search.io.InputEncoding = .auto;
    var multiline = false;
    var multiline_dotall = false;
    var parallel_jobs: ?usize = null;
    var max_depth: ?usize = null;
    var max_count: ?usize = null;
    var context_before: usize = 0;
    var context_after: usize = 0;
    var show_stats = false;
    var output: OutputOptions = .{};
    var output_format: OutputFormat = .text;
    var report_mode: ReportMode = .lines;
    var pattern: ?[]const u8 = null;
    var show_type_list = false;
    var paths = std.ArrayList([]const u8).empty;
    var globs = std.ArrayList([]const u8).empty;
    var pre_globs = std.ArrayList([]const u8).empty;
    var ignore_files = std.ArrayList([]const u8).empty;
    var include_types = std.ArrayList([]const u8).empty;
    var exclude_types = std.ArrayList([]const u8).empty;
    var type_adds = std.ArrayList([]const u8).empty;
    defer paths.deinit(allocator);
    defer globs.deinit(allocator);
    defer pre_globs.deinit(allocator);
    defer ignore_files.deinit(allocator);
    defer include_types.deinit(allocator);
    defer exclude_types.deinit(allocator);
    defer type_adds.deinit(allocator);
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
            if (std.mem.eql(u8, arg, "--unrestricted")) {
                unrestricted_level = @min(unrestricted_level + 1, 3);
                continue;
            }
            if (shortUnrestrictedCount(arg)) |count| {
                unrestricted_level = @min(unrestricted_level + count, 3);
                continue;
            }
            if (std.mem.eql(u8, arg, "--hidden")) {
                include_hidden = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--invert-match")) {
                invert_match = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--ignore-file")) {
                index += 1;
                if (index >= argv.len) return error.MissingFlagValue;
                try ignore_files.append(allocator, argv[index]);
                continue;
            }
            if (std.mem.eql(u8, arg, "--type-list")) {
                show_type_list = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--json")) {
                output_format = .json;
                continue;
            }
            if (std.mem.eql(u8, arg, "--stats")) {
                show_stats = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--null")) {
                output.null_path_terminator = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--heading")) {
                output.heading = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--type-add")) {
                index += 1;
                if (index >= argv.len) return error.MissingFlagValue;
                try type_adds.append(allocator, argv[index]);
                continue;
            }
            if (std.mem.eql(u8, arg, "-t")) {
                index += 1;
                if (index >= argv.len) return error.MissingFlagValue;
                try include_types.append(allocator, argv[index]);
                continue;
            }
            if (std.mem.eql(u8, arg, "-T")) {
                index += 1;
                if (index >= argv.len) return error.MissingFlagValue;
                try exclude_types.append(allocator, argv[index]);
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
            if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--ignore-case")) {
                case_mode = .insensitive;
                continue;
            }
            if (std.mem.eql(u8, arg, "-S") or std.mem.eql(u8, arg, "--smart-case")) {
                case_mode = .smart;
                continue;
            }
            if (std.mem.eql(u8, arg, "--text")) {
                binary_mode = .text;
                continue;
            }
            if (std.mem.eql(u8, arg, "--binary")) {
                binary_mode = .suppress;
                continue;
            }
            if (std.mem.eql(u8, arg, "-z") or std.mem.eql(u8, arg, "--search-zip")) {
                search_compressed = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--pre")) {
                index += 1;
                if (index >= argv.len) return error.MissingFlagValue;
                preprocessor = argv[index];
                continue;
            }
            if (std.mem.eql(u8, arg, "--pre-glob")) {
                index += 1;
                if (index >= argv.len) return error.MissingFlagValue;
                try pre_globs.append(allocator, argv[index]);
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
            if (std.mem.eql(u8, arg, "-U") or std.mem.eql(u8, arg, "--multiline")) {
                multiline = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--multiline-dotall")) {
                multiline_dotall = true;
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

    const owned_type_adds = try type_adds.toOwnedSlice(allocator);
    errdefer allocator.free(owned_type_adds);

    if (show_type_list) {
        return .{ .type_list = .{ .type_adds = owned_type_adds } };
    }

    if (pattern == null) return error.MissingPattern;
    if (preprocessor == null and pre_globs.items.len != 0) return error.InvalidFlagCombination;
    if (multiline_dotall and !multiline) return error.InvalidFlagCombination;
    if (unrestricted_level >= 1) no_ignore = true;
    if (unrestricted_level >= 2) include_hidden = true;
    if (unrestricted_level >= 3) binary_mode = .text;
    if (paths.items.len == 0) try paths.append(allocator, ".");
    if ((context_before != 0 or context_after != 0) and (report_mode != .lines or output.only_matching or invert_match)) {
        return error.InvalidFlagCombination;
    }
    if (invert_match and output.only_matching) return error.InvalidFlagCombination;
    if (output_format == .json and (context_before != 0 or context_after != 0)) {
        return error.InvalidFlagCombination;
    }
    if (output.null_path_terminator and (output_format == .json or
        (report_mode != .files_with_matches and report_mode != .files_without_match)))
    {
        return error.InvalidFlagCombination;
    }
    if (output.heading and (output_format != .text or report_mode != .lines)) {
        return error.InvalidFlagCombination;
    }
    if (binary_mode == .suppress and (output_format != .text or output.only_matching or
        report_mode == .count or output.heading))
    {
        return error.InvalidFlagCombination;
    }
    if (output.heading) {
        output.with_filename = false;
    }

    const owned_paths = try paths.toOwnedSlice(allocator);
    errdefer allocator.free(owned_paths);
    const owned_globs = try globs.toOwnedSlice(allocator);
    errdefer allocator.free(owned_globs);
    const owned_pre_globs = try pre_globs.toOwnedSlice(allocator);
    errdefer allocator.free(owned_pre_globs);
    const owned_ignore_files = try ignore_files.toOwnedSlice(allocator);
    errdefer allocator.free(owned_ignore_files);
    const owned_include_types = try include_types.toOwnedSlice(allocator);
    errdefer allocator.free(owned_include_types);
    const owned_exclude_types = try exclude_types.toOwnedSlice(allocator);
    errdefer allocator.free(owned_exclude_types);

    return .{ .run = .{
        .pattern = pattern.?,
        .paths = owned_paths,
        .globs = owned_globs,
        .pre_globs = owned_pre_globs,
        .ignore_files = owned_ignore_files,
        .include_types = owned_include_types,
        .exclude_types = owned_exclude_types,
        .type_adds = owned_type_adds,
        .include_hidden = include_hidden,
        .follow_symlinks = follow_symlinks,
        .invert_match = invert_match,
        .no_ignore = no_ignore,
        .no_ignore_vcs = no_ignore_vcs,
        .no_ignore_parent = no_ignore_parent,
        .binary_mode = binary_mode,
        .search_compressed = search_compressed,
        .preprocessor = preprocessor,
        .case_mode = case_mode,
        .read_strategy = read_strategy,
        .encoding = encoding,
        .multiline = multiline,
        .multiline_dotall = multiline_dotall,
        .parallel_jobs = parallel_jobs,
        .max_depth = max_depth,
        .max_count = max_count,
        .context_before = context_before,
        .context_after = context_after,
        .show_stats = show_stats,
        .output = output,
        .output_format = output_format,
        .report_mode = report_mode,
    } };
}

fn shortUnrestrictedCount(arg: []const u8) ?u8 {
    if (arg.len < 2 or arg[0] != '-') return null;
    for (arg[1..]) |byte| {
        if (byte != 'u') return null;
    }
    return @intCast(arg.len - 1);
}

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
            self.writer.print("warning: skipping directory {s}: {s}\n", .{ path, warningMessage(err) }) catch {};
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

    const loaded_ignores = try loadIgnoreMatchers(allocator, root_path, options);
    defer deinitLoadedIgnores(allocator, loaded_ignores);

    const filtered_entries = try filterEntries(
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
    type_matcher: zigrep.search.types.Matcher,
    include_types: []const []const u8,
    exclude_types: []const []const u8,
) ![]const zigrep.search.walk.Entry {
    var filtered: std.ArrayList(zigrep.search.walk.Entry) = .empty;
    defer filtered.deinit(allocator);

    for (entries) |entry| {
        const relative = relativeGlobPath(root_path, entry.path);
        if (!zigrep.search.glob.allowsPath(globs, relative)) continue;
        if (!type_matcher.fileAllowed(include_types, exclude_types, relative)) continue;
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
) !SearchResult {
    // Search-lifetime allocator: the compiled regex program and VM state are
    // reused across every file in this search invocation.
    var searcher = try zigrep.search.grep.Searcher.init(allocator, options.pattern, .{
        .case_mode = options.case_mode,
        .multiline = options.multiline,
        .multiline_dotall = options.multiline_dotall,
    });
    defer searcher.deinit();

    var result: SearchResult = .{ .matched = false };
    var wrote_heading_group = false;
    for (entries) |entry| {
        // File-lifetime allocator: buffered reads and temporary per-file
        // matching/reporting allocations,
        // and temporary formatted output for one file are reclaimed together.
        var file_arena_state = std.heap.ArenaAllocator.init(allocator);
        defer file_arena_state.deinit();
        const file_allocator = file_arena_state.allocator();

        const suppress_binary_output = if (options.search_compressed)
            null
        else blk: {
            if (options.encoding != .auto) break :blk false;
            switch (options.binary_mode) {
                .text => break :blk false,
                .skip, .suppress => {
                    const decision = zigrep.search.io.detectBinaryFile(entry.path, .{}) catch |err| {
                        if (try warnAndSkipFileError(stderr, entry.path, err)) {
                            result.stats.warnings_emitted += 1;
                            continue;
                        }
                        return err;
                    };
                    if (decision == .binary) {
                        if (options.binary_mode == .skip) {
                            result.stats.skipped_binary_files += 1;
                            continue;
                        }
                        break :blk true;
                    }
                    break :blk false;
                },
            }
        };

        const buffer = zigrep.search.io.readFile(file_allocator, entry.path, .{
            .strategy = options.read_strategy,
        }) catch |err| {
            if (try warnAndSkipFileError(stderr, entry.path, err)) {
                result.stats.warnings_emitted += 1;
                continue;
            }
            return err;
        };
        defer buffer.deinit(file_allocator);
        const search_bytes = prepareSearchBytes(file_allocator, entry.path, buffer.bytes(), options) catch |err| {
                if (try warnAndSkipFileError(stderr, entry.path, err)) {
                    result.stats.warnings_emitted += 1;
                    continue;
                }
                return err;
            };
        const effective_binary_output = if (options.search_compressed or options.preprocessor != null)
            decideBinaryBehavior(search_bytes, options.encoding, options.binary_mode) orelse {
                result.stats.skipped_binary_files += 1;
                continue;
            }
        else
            suppress_binary_output.?;
        result.stats.searched_files += 1;
        result.stats.searched_bytes += search_bytes.len;

        var capture: std.Io.Writer.Allocating = .init(file_allocator);
        defer capture.deinit();
        const writer = if (options.output.heading) &capture.writer else stdout;

        if (try writeFileOutput(
            file_allocator,
            writer,
            &searcher,
            entry.path,
            search_bytes,
            options.encoding,
            effective_binary_output,
            options.invert_match,
            options.output,
            options.output_format,
            options.report_mode,
            options.max_count,
            options.context_before,
            options.context_after,
        )) {
            if (options.output.heading) {
                try writeHeadingBlock(stdout, entry.path, capture.written(), &wrote_heading_group);
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
    // Worker-lifetime allocator: shared worker state and stored output lines
    // stay on smp_allocator, while each file gets its own short-lived arena.
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

            const suppress_binary_output = if (self.options.search_compressed)
                null
            else blk: {
                if (self.options.encoding != .auto) break :blk false;
                switch (self.options.binary_mode) {
                    .text => break :blk false,
                    .skip, .suppress => {
                        const decision = zigrep.search.io.detectBinaryFile(entry.path, .{}) catch |err| {
                            if (try self.warnAndSkip(entry.path, err)) return;
                            return err;
                        };
                        if (decision == .binary) {
                            if (self.options.binary_mode == .skip) {
                                self.result_reports[index] = .{
                                    .bytes = .empty,
                                    .searched_bytes = 0,
                                    .matched = false,
                                    .skipped_binary = true,
                                    .path = null,
                                };
                                return;
                            }
                            break :blk true;
                        }
                        break :blk false;
                    },
                }
            };

            const buffer = zigrep.search.io.readFile(file_allocator, entry.path, .{
                .strategy = self.options.read_strategy,
            }) catch |err| {
                if (try self.warnAndSkip(entry.path, err)) return;
                return err;
            };
            defer buffer.deinit(file_allocator);
            const search_bytes = prepareSearchBytes(file_allocator, entry.path, buffer.bytes(), self.options) catch |err| {
                    if (try self.warnAndSkip(entry.path, err)) return;
                    return err;
                };
            const effective_binary_output = if (self.options.search_compressed or self.options.preprocessor != null)
                decideBinaryBehavior(search_bytes, self.options.encoding, self.options.binary_mode) orelse {
                    self.result_reports[index] = .{
                        .bytes = .empty,
                        .searched_bytes = 0,
                        .matched = false,
                        .skipped_binary = true,
                        .path = null,
                    };
                    return;
                }
            else
                suppress_binary_output.?;

            var capture: std.Io.Writer.Allocating = .init(std.heap.smp_allocator);
            defer capture.deinit();

            const matched = try writeFileOutput(
                file_allocator,
                &capture.writer,
                searcher,
                entry.path,
                search_bytes,
                self.options.encoding,
                effective_binary_output,
                self.options.invert_match,
                self.options.output,
                self.options.output_format,
                self.options.report_mode,
                self.options.max_count,
                self.options.context_before,
                self.options.context_after,
            );
            self.result_reports[index] = .{
                .bytes = capture.toArrayList(),
                .searched_bytes = search_bytes.len,
                .matched = matched,
                .skipped_binary = false,
                .path = if (self.options.output.heading) try std.heap.smp_allocator.dupe(u8, entry.path) else null,
            };
        }

        fn warnAndSkip(self: *@This(), path: []const u8, err: anyerror) !bool {
            self.warning_mutex.lock();
            defer self.warning_mutex.unlock();
            const skipped = try warnAndSkipFileError(self.stderr, path, err);
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
                    try writeHeadingBlock(stdout, report.path.?, report.bytes.items, &wrote_heading_group);
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
    try writeReport(stdout, report, output);
}

fn writeJsonString(writer: *std.Io.Writer, bytes: []const u8) !void {
    try writer.writeByte('"');

    var index: usize = 0;
    while (index < bytes.len) {
        const byte = bytes[index];
        if (byte < 0x80) {
            switch (byte) {
                '"' => try writer.writeAll("\\\""),
                '\\' => try writer.writeAll("\\\\"),
                '\n' => try writer.writeAll("\\n"),
                '\r' => try writer.writeAll("\\r"),
                '\t' => try writer.writeAll("\\t"),
                else => {
                    if (isDisplaySafeAscii(byte, false)) {
                        try writer.writeByte(byte);
                    } else {
                        try writer.print("\\\\x{X:0>2}", .{byte});
                    }
                },
            }
            index += 1;
            continue;
        }

        const sequence_len = std.unicode.utf8ByteSequenceLength(byte) catch {
            try writer.print("\\\\x{X:0>2}", .{byte});
            index += 1;
            continue;
        };
        if (index + sequence_len > bytes.len) {
            try writer.print("\\\\x{X:0>2}", .{byte});
            index += 1;
            continue;
        }

        const sequence = bytes[index .. index + sequence_len];
        _ = std.unicode.utf8Decode(sequence) catch {
            try writer.print("\\\\x{X:0>2}", .{byte});
            index += 1;
            continue;
        };
        try writer.writeAll(sequence);
        index += sequence_len;
    }

    try writer.writeByte('"');
}

fn writeJsonMatchEvent(
    writer: *std.Io.Writer,
    report: zigrep.search.grep.MatchReport,
    output: OutputOptions,
) !void {
    const display_slice = if (output.only_matching)
        report.line[report.match_span.start - report.line_span.start .. report.match_span.end - report.line_span.start]
    else
        report.line;

    try writer.writeAll("{\"type\":\"match\",\"data\":{");
    try writer.writeAll("\"path\":");
    try writeJsonString(writer, report.path);
    try writer.print(",\"line_number\":{d},\"column_number\":{d}", .{ report.line_number, report.column_number });
    try writer.writeAll(",\"line\":");
    try writeJsonString(writer, display_slice);
    try writer.print(",\"line_span\":{{\"start\":{d},\"end\":{d}}}", .{ report.line_span.start, report.line_span.end });
    try writer.print(",\"match_span\":{{\"start\":{d},\"end\":{d}}}", .{ report.match_span.start, report.match_span.end });
    try writer.writeAll("}}\n");
}

fn writeJsonCountEvent(writer: *std.Io.Writer, path: []const u8, count: usize) !void {
    try writer.writeAll("{\"type\":\"count\",\"data\":{");
    try writer.writeAll("\"path\":");
    try writeJsonString(writer, path);
    try writer.print(",\"count\":{d}}}\n", .{count});
}

fn writeJsonPathEvent(writer: *std.Io.Writer, path: []const u8, matched: bool) !void {
    try writer.writeAll("{\"type\":\"path\",\"data\":{");
    try writer.writeAll("\"path\":");
    try writeJsonString(writer, path);
    try writer.print(",\"matched\":{s}}}\n", .{if (matched) "true" else "false"});
}

fn writePathResult(writer: *std.Io.Writer, path: []const u8, output: OutputOptions) !void {
    try writer.writeAll(path);
    try writer.writeByte(if (output.null_path_terminator) 0 else '\n');
}

fn writeStats(writer: *std.Io.Writer, stats: SearchStats) !void {
    try writer.print(
        "stats: searched_files={d} matched_files={d} searched_bytes={d} skipped_binary_files={d} warnings_emitted={d}\n",
        .{ stats.searched_files, stats.matched_files, stats.searched_bytes, stats.skipped_binary_files, stats.warnings_emitted },
    );
}

fn writeHeadingBlock(
    writer: *std.Io.Writer,
    path: []const u8,
    bytes: []const u8,
    wrote_previous_group: *bool,
) !void {
    if (wrote_previous_group.*) try writer.writeByte('\n');
    try writer.print("{s}\n", .{path});
    try writer.writeAll(bytes);
    wrote_previous_group.* = true;
}

fn writeBinaryMatchNotice(writer: *std.Io.Writer, path: []const u8) !void {
    try writer.print("{s}: binary file matches\n", .{path});
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

fn writePrefixedDisplayBytes(
    writer: *std.Io.Writer,
    path: []const u8,
    line_number: usize,
    column_number: usize,
    bytes: []const u8,
    output: OutputOptions,
    allow_newlines: bool,
) !void {
    var wrote_prefix = false;
    if (output.with_filename) {
        try writer.print("{s}", .{path});
        wrote_prefix = true;
    }
    if (output.line_number) {
        if (wrote_prefix) try writer.writeByte(':');
        try writer.print("{d}", .{line_number});
        wrote_prefix = true;
    }
    if (output.column_number) {
        if (wrote_prefix) try writer.writeByte(':');
        try writer.print("{d}", .{column_number});
        wrote_prefix = true;
    }
    if (wrote_prefix) try writer.writeByte(':');
    try writeDisplayBytes(writer, bytes, allow_newlines);
    try writer.writeByte('\n');
}

fn warnAndSkipFileError(writer: *std.Io.Writer, path: []const u8, err: anyerror) !bool {
    if (!shouldWarnAndSkipFileError(err)) return false;
    try writer.print("warning: skipping {s}: {s}\n", .{ path, warningMessage(err) });
    return true;
}

fn warningMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "file not found",
        error.AccessDenied => "access denied",
        error.NotDir => "not a directory",
        error.NameTooLong => "name too long",
        error.SymLinkLoop => "symlink loop",
        error.InvalidCompressedInput => "invalid compressed input",
        error.PreprocessorFailed => "preprocessor exited with non-zero status",
        error.PreprocessorSignaled => "preprocessor terminated by signal",
        error.PreprocessorTooMuchOutput => "preprocessor output exceeded limit",
        else => @errorName(err),
    };
}

fn shouldWarnAndSkipFileError(err: anyerror) bool {
    return switch (err) {
        error.FileNotFound,
        error.AccessDenied,
        error.NotDir,
        error.NameTooLong,
        error.SymLinkLoop,
        error.InvalidCompressedInput,
        error.PreprocessorFailed,
        error.PreprocessorSignaled,
        error.PreprocessorTooMuchOutput,
        => true,
        else => false,
    };
}

fn prepareSearchBytes(
    allocator: std.mem.Allocator,
    path: []const u8,
    bytes: []const u8,
    options: CliOptions,
) ![]const u8 {
    if (zigrep.search.preprocess.shouldApply(options.preprocessor, options.pre_globs, path)) {
        return try zigrep.search.preprocess.runAlloc(allocator, options.preprocessor.?, path);
    }
    if (!options.search_compressed) return bytes;
    return if (try zigrep.search.io.decompressAlloc(allocator, bytes)) |decoded| decoded else bytes;
}

fn decideBinaryBehavior(
    bytes: []const u8,
    encoding: zigrep.search.io.InputEncoding,
    binary_mode: BinaryMode,
) ?bool {
    if (encoding != .auto) return false;
    return switch (binary_mode) {
        .text => false,
        .skip, .suppress => switch (zigrep.search.io.detectBinary(bytes, .{})) {
            .text => false,
            .binary => if (binary_mode == .skip) null else true,
        },
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
                .text => try writeReport(self.writer, report, self.output),
                .json => try writeJsonMatchEvent(self.writer, report, self.output),
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

fn writeMultilineReportBlock(
    writer: *std.Io.Writer,
    path: []const u8,
    info: zigrep.search.report.DisplayBlockInfo,
    haystack: []const u8,
    output: OutputOptions,
) !void {
    try writePrefixedDisplayBytes(
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
            try writePrefixedDisplayBytes(
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
    try writeJsonString(writer, path);
    try writer.print(",\"line_number\":{d},\"column_number\":{d}", .{ match_info.display.line_number, match_info.display.column_number });
    try writer.writeAll(",\"line\":");
    try writeJsonString(writer, display_slice);
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
        .json => try writeJsonCountEvent(writer, path, matches.len),
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

fn writeFileOutput(
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
    try writeBinaryMatchNotice(writer, path);
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
            .text => try writeReport(writer, report, output),
            .json => try writeJsonMatchEvent(writer, report, output),
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
            .json => try writeJsonCountEvent(writer, path, count),
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
        .json => try writeJsonCountEvent(writer, path, counter.count),
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
        .text => try writePathResult(writer, path, output),
        .json => try writeJsonPathEvent(writer, path, true),
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
        .text => try writePathResult(writer, path, output),
        .json => try writeJsonPathEvent(writer, path, false),
    }
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

fn writeDisplayBytes(writer: *std.Io.Writer, bytes: []const u8, allow_newlines: bool) !void {
    var index: usize = 0;
    while (index < bytes.len) {
        const byte = bytes[index];
        if (byte < 0x80) {
            if (isDisplaySafeAscii(byte, allow_newlines)) {
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

fn writeDisplayLine(writer: *std.Io.Writer, bytes: []const u8) !void {
    try writeDisplayBytes(writer, bytes, false);
}

fn isDisplaySafeAscii(byte: u8, allow_newlines: bool) bool {
    return switch (byte) {
        '\n' => allow_newlines,
        '\t', ' '...'~' => true,
        else => false,
    };
}

fn parseEncoding(arg: []const u8) CliError!zigrep.search.io.InputEncoding {
    if (std.ascii.eqlIgnoreCase(arg, "auto")) return .auto;
    if (std.ascii.eqlIgnoreCase(arg, "none")) return .none;
    if (std.ascii.eqlIgnoreCase(arg, "utf8")) return .utf8;
    if (std.ascii.eqlIgnoreCase(arg, "latin1")) return .latin1;
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
        \\  --config-path PATH    load default flags from PATH
        \\  --no-config           ignore config file support for this run
        \\  --hidden              include hidden files
        \\  -u, --unrestricted    reduce filtering; repeat to include hidden and binary files
        \\  -v, --invert-match    select non-matching lines instead of matching lines
        \\  --ignore-file PATH    load ignore rules from PATH
        \\  --no-ignore           disable ignore filtering
        \\  --no-ignore-vcs       ignore VCS ignore files like .gitignore
        \\  --no-ignore-parent    ignore parent VCS ignore files
        \\  -t TYPE              include only files matching TYPE
        \\  -T TYPE              exclude files matching TYPE
        \\  --type-add SPEC      add file type definition name:glob[,glob...]
        \\  --type-list          list known file types and exit
        \\  --follow              follow symlinks
        \\  -i, --ignore-case     search case-insensitively
        \\  -S, --smart-case      use ignore-case unless the pattern has uppercase letters
        \\  --text                search binary files and print normal match output
        \\  --binary              search binary files but suppress matching line content
        \\  -z, --search-zip      search gzip-compressed files too
        \\  --pre CMD             run CMD on each selected file path before searching
        \\  --pre-glob GLOB       apply --pre only to paths matching GLOB
        \\  -g, --glob GLOB       include or exclude paths by glob
        \\  --buffered            use the simpler file-reading method
        \\  --mmap                use the faster file-reading method when possible
        \\  -E, --encoding ENC    force input encoding: auto, none, utf8, latin1, utf16le, utf16be
        \\  -U, --multiline       enable searching across multiple lines
        \\  --multiline-dotall    make '.' match newlines in multiline mode
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
        \\  --json                emit newline-delimited JSON events
        \\  --stats               print search summary statistics to stderr
        \\  --null                emit NUL-delimited paths in file path output modes
        \\  --heading             group text line output by file path headings
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
        .run => |opts| opts.deinit(testing.allocator),
        .type_list => |opts| opts.deinit(testing.allocator),
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
            try testing.expectEqual(BinaryMode.skip, opts.binary_mode);
            try testing.expectEqual(zigrep.search.grep.CaseMode.sensitive, opts.case_mode);
            try testing.expectEqual(zigrep.search.io.ReadStrategy.mmap, opts.read_strategy);
            try testing.expectEqual(zigrep.search.io.InputEncoding.auto, opts.encoding);
            try testing.expect(!opts.multiline);
            try testing.expect(!opts.multiline_dotall);
            try testing.expectEqual(@as(?usize, null), opts.parallel_jobs);
            try testing.expectEqual(@as(?usize, null), opts.max_depth);
            try testing.expect(opts.output.with_filename);
            try testing.expect(opts.output.line_number);
            try testing.expect(opts.output.column_number);
            try testing.expect(!opts.output.only_matching);
            try testing.expect(!opts.output.null_path_terminator);
            try testing.expect(!opts.output.heading);
            try testing.expectEqual(OutputFormat.text, opts.output_format);
            try testing.expectEqual(ReportMode.lines, opts.report_mode);
            try testing.expect(!opts.show_stats);
            try testing.expect(!opts.invert_match);
        },
        .help => unreachable,
        .version => unreachable,
        .type_list => unreachable,
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
        .run => |opts| opts.deinit(testing.allocator),
        .type_list => |opts| opts.deinit(testing.allocator),
        .help, .version => {},
    };

    switch (parsed) {
        .run => |opts| {
            try testing.expectEqualStrings("needle", opts.pattern);
            try testing.expectEqual(@as(usize, 1), opts.paths.len);
            try testing.expectEqualStrings("--version", opts.paths[0]);
        },
        .help, .version, .type_list => return error.TestExpectedEqual,
    }
}

test "parseArgs treats help-like args as positional after terminator" {
    const testing = std.testing;

    const parsed = try parseArgs(testing.allocator, &.{ "zigrep", "--", "--help" });
    defer switch (parsed) {
        .run => |opts| opts.deinit(testing.allocator),
        .type_list => |opts| opts.deinit(testing.allocator),
        .help, .version => {},
    };

    switch (parsed) {
        .run => |opts| {
            try testing.expectEqualStrings("--help", opts.pattern);
            try testing.expectEqual(@as(usize, 1), opts.paths.len);
            try testing.expectEqualStrings(".", opts.paths[0]);
        },
        .help, .version, .type_list => return error.TestExpectedEqual,
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
        .run => |opts| opts.deinit(testing.allocator),
        .type_list => |opts| opts.deinit(testing.allocator),
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
        .help, .version, .type_list => unreachable,
    }
}

test "parseArgs accepts files-without-match mode" {
    const testing = std.testing;

    const parsed = try parseArgs(testing.allocator, &.{ "zigrep", "--files-without-match", "needle", "src" });
    defer switch (parsed) {
        .run => |opts| opts.deinit(testing.allocator),
        .type_list => |opts| opts.deinit(testing.allocator),
        .help, .version => {},
    };

    switch (parsed) {
        .run => |opts| {
            try testing.expectEqual(ReportMode.files_without_match, opts.report_mode);
            try testing.expectEqualStrings("needle", opts.pattern);
            try testing.expectEqual(@as(usize, 1), opts.paths.len);
            try testing.expectEqualStrings("src", opts.paths[0]);
        },
        .help, .version, .type_list => unreachable,
    }
}

test "parseArgs accepts max-count mode" {
    const testing = std.testing;

    const parsed = try parseArgs(testing.allocator, &.{ "zigrep", "-m", "2", "needle", "src" });
    defer switch (parsed) {
        .run => |opts| opts.deinit(testing.allocator),
        .type_list => |opts| opts.deinit(testing.allocator),
        .help, .version => {},
    };

    switch (parsed) {
        .run => |opts| {
            try testing.expectEqual(@as(?usize, 2), opts.max_count);
            try testing.expectEqualStrings("needle", opts.pattern);
            try testing.expectEqual(@as(usize, 1), opts.paths.len);
            try testing.expectEqualStrings("src", opts.paths[0]);
        },
        .help, .version, .type_list => unreachable,
    }
}

test "parseArgs accepts before and after context flags" {
    const testing = std.testing;

    const parsed = try parseArgs(testing.allocator, &.{ "zigrep", "-B", "2", "-A", "3", "needle", "src" });
    defer switch (parsed) {
        .run => |opts| opts.deinit(testing.allocator),
        .type_list => |opts| opts.deinit(testing.allocator),
        .help, .version => {},
    };

    switch (parsed) {
        .run => |opts| {
            try testing.expectEqual(@as(usize, 2), opts.context_before);
            try testing.expectEqual(@as(usize, 3), opts.context_after);
        },
        .help, .version, .type_list => unreachable,
    }
}

test "parseArgs accepts repeated glob flags" {
    const testing = std.testing;

    const parsed = try parseArgs(testing.allocator, &.{ "zigrep", "-g", "*.zig", "--glob", "!main.zig", "needle", "src" });
    defer switch (parsed) {
        .run => |opts| opts.deinit(testing.allocator),
        .type_list => |opts| opts.deinit(testing.allocator),
        .help, .version => {},
    };

    switch (parsed) {
        .run => |opts| {
            try testing.expectEqual(@as(usize, 2), opts.globs.len);
            try testing.expectEqualStrings("*.zig", opts.globs[0]);
            try testing.expectEqualStrings("!main.zig", opts.globs[1]);
            try testing.expectEqualStrings("needle", opts.pattern);
        },
        .help, .version, .type_list => unreachable,
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
        .run => |opts| opts.deinit(testing.allocator),
        .type_list => |opts| opts.deinit(testing.allocator),
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
        .help, .version, .type_list => unreachable,
    }
}

test "parseArgs accepts unrestricted flags" {
    const testing = std.testing;

    const parsed = try parseArgs(testing.allocator, &.{
        "zigrep",
        "-uu",
        "--unrestricted",
        "needle",
        "src",
    });
    defer switch (parsed) {
        .run => |opts| opts.deinit(testing.allocator),
        .type_list => |opts| opts.deinit(testing.allocator),
        .help, .version => {},
    };

    switch (parsed) {
        .run => |opts| {
            try testing.expect(opts.no_ignore);
            try testing.expect(opts.include_hidden);
            try testing.expectEqual(BinaryMode.text, opts.binary_mode);
        },
        .help, .version, .type_list => unreachable,
    }
}

test "parseArgs accepts json output flag" {
    const testing = std.testing;

    const parsed = try parseArgs(testing.allocator, &.{ "zigrep", "--json", "needle", "src" });
    defer switch (parsed) {
        .run => |opts| opts.deinit(testing.allocator),
        .type_list => |opts| opts.deinit(testing.allocator),
        .help, .version => {},
    };

    switch (parsed) {
        .run => |opts| {
            try testing.expectEqual(OutputFormat.json, opts.output_format);
            try testing.expectEqual(ReportMode.lines, opts.report_mode);
        },
        .help, .version, .type_list => unreachable,
    }
}

test "parseArgs accepts raw-byte encoding mode" {
    const testing = std.testing;

    const parsed = try parseArgs(testing.allocator, &.{ "zigrep", "-E", "none", "needle", "src" });
    defer switch (parsed) {
        .run => |opts| opts.deinit(testing.allocator),
        .type_list => |opts| opts.deinit(testing.allocator),
        .help, .version => {},
    };

    switch (parsed) {
        .run => |opts| try testing.expectEqual(zigrep.search.io.InputEncoding.none, opts.encoding),
        .help, .version, .type_list => unreachable,
    }
}

test "parseArgs accepts latin1 encoding mode" {
    const testing = std.testing;

    const parsed = try parseArgs(testing.allocator, &.{ "zigrep", "-E", "latin1", "needle", "src" });
    defer switch (parsed) {
        .run => |opts| opts.deinit(testing.allocator),
        .type_list => |opts| opts.deinit(testing.allocator),
        .help, .version => {},
    };

    switch (parsed) {
        .run => |opts| try testing.expectEqual(zigrep.search.io.InputEncoding.latin1, opts.encoding),
        .help, .version, .type_list => unreachable,
    }
}

test "parseArgs accepts multiline flags" {
    const testing = std.testing;

    const parsed = try parseArgs(testing.allocator, &.{ "zigrep", "-U", "--multiline-dotall", "needle", "src" });
    defer switch (parsed) {
        .run => |opts| opts.deinit(testing.allocator),
        .type_list => |opts| opts.deinit(testing.allocator),
        .help, .version => {},
    };

    switch (parsed) {
        .run => |opts| {
            try testing.expect(opts.multiline);
            try testing.expect(opts.multiline_dotall);
        },
        .help, .version, .type_list => unreachable,
    }
}

test "parseArgs rejects multiline-dotall without multiline" {
    const testing = std.testing;

    try testing.expectError(error.InvalidFlagCombination, parseArgs(testing.allocator, &.{
        "zigrep",
        "--multiline-dotall",
        "needle",
        "src",
    }));
}

test "runCli rejects unsupported multiline output combinations for now" {
    const testing = std.testing;

    var stdout_capture: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_capture.deinit();

    try testing.expectError(error.InvalidFlagCombination, runCli(
        testing.allocator,
        &stdout_capture.writer,
        &stderr_capture.writer,
        &.{ "zigrep", "-U", "--max-count", "1", "needle", "." },
    ));
}

test "parseArgs accepts null output flag for path modes" {
    const testing = std.testing;

    const parsed = try parseArgs(testing.allocator, &.{ "zigrep", "--null", "-l", "needle", "src" });
    defer switch (parsed) {
        .run => |opts| opts.deinit(testing.allocator),
        .type_list => |opts| opts.deinit(testing.allocator),
        .help, .version => {},
    };

    switch (parsed) {
        .run => |opts| {
            try testing.expect(opts.output.null_path_terminator);
            try testing.expectEqual(ReportMode.files_with_matches, opts.report_mode);
        },
        .help, .version, .type_list => unreachable,
    }
}

test "parseArgs accepts stats flag" {
    const testing = std.testing;

    const parsed = try parseArgs(testing.allocator, &.{ "zigrep", "--stats", "needle", "src" });
    defer switch (parsed) {
        .run => |opts| opts.deinit(testing.allocator),
        .type_list => |opts| opts.deinit(testing.allocator),
        .help, .version => {},
    };

    switch (parsed) {
        .run => |opts| try testing.expect(opts.show_stats),
        .help, .version, .type_list => unreachable,
    }
}

test "parseArgs accepts heading flag" {
    const testing = std.testing;

    const parsed = try parseArgs(testing.allocator, &.{ "zigrep", "--heading", "needle", "src" });
    defer switch (parsed) {
        .run => |opts| opts.deinit(testing.allocator),
        .type_list => |opts| opts.deinit(testing.allocator),
        .help, .version => {},
    };

    switch (parsed) {
        .run => |opts| {
            try testing.expect(opts.output.heading);
            try testing.expect(!opts.output.with_filename);
            try testing.expectEqual(ReportMode.lines, opts.report_mode);
        },
        .help, .version, .type_list => unreachable,
    }
}

test "parseArgs accepts invert-match flag" {
    const testing = std.testing;

    const parsed = try parseArgs(testing.allocator, &.{ "zigrep", "-v", "needle", "src" });
    defer switch (parsed) {
        .run => |opts| opts.deinit(testing.allocator),
        .type_list => |opts| opts.deinit(testing.allocator),
        .help, .version => {},
    };

    switch (parsed) {
        .run => |opts| try testing.expect(opts.invert_match),
        .help, .version, .type_list => unreachable,
    }
}

test "parseArgs accepts binary mode flag" {
    const testing = std.testing;

    const parsed = try parseArgs(testing.allocator, &.{ "zigrep", "--binary", "needle", "src" });
    defer switch (parsed) {
        .run => |opts| opts.deinit(testing.allocator),
        .type_list => |opts| opts.deinit(testing.allocator),
        .help, .version => {},
    };

    switch (parsed) {
        .run => |opts| try testing.expectEqual(BinaryMode.suppress, opts.binary_mode),
        .help, .version, .type_list => unreachable,
    }
}

test "parseArgs accepts compressed search flag" {
    const testing = std.testing;

    const parsed = try parseArgs(testing.allocator, &.{ "zigrep", "-z", "needle", "src" });
    defer switch (parsed) {
        .run => |opts| opts.deinit(testing.allocator),
        else => unreachable,
    };

    switch (parsed) {
        .run => |opts| try testing.expect(opts.search_compressed),
        else => unreachable,
    }
}

test "parseArgs accepts preprocessor flags" {
    const testing = std.testing;

    const parsed = try parseArgs(testing.allocator, &.{
        "zigrep",
        "--pre",
        "/bin/cat",
        "--pre-glob",
        "*.wrapped",
        "needle",
        "src",
    });
    defer switch (parsed) {
        .run => |opts| opts.deinit(testing.allocator),
        else => unreachable,
    };

    switch (parsed) {
        .run => |opts| {
            try testing.expectEqualStrings("/bin/cat", opts.preprocessor.?);
            try testing.expectEqual(@as(usize, 1), opts.pre_globs.len);
            try testing.expectEqualStrings("*.wrapped", opts.pre_globs[0]);
        },
        else => unreachable,
    }
}

test "parseArgs accepts ignore-case and smart-case flags" {
    const testing = std.testing;

    const parsed = try parseArgs(testing.allocator, &.{
        "zigrep",
        "-i",
        "--smart-case",
        "needle",
        "src",
    });
    defer switch (parsed) {
        .run => |opts| opts.deinit(testing.allocator),
        .type_list => |opts| opts.deinit(testing.allocator),
        .help, .version => {},
    };

    switch (parsed) {
        .run => |opts| {
            try testing.expectEqual(zigrep.search.grep.CaseMode.smart, opts.case_mode);
        },
        .help, .version, .type_list => unreachable,
    }
}

test "parseArgs accepts file type flags" {
    const testing = std.testing;

    const parsed = try parseArgs(testing.allocator, &.{
        "zigrep",
        "-t",
        "zig",
        "-T",
        "markdown",
        "--type-add",
        "web:*.web,*.page",
        "needle",
        "src",
    });
    defer switch (parsed) {
        .run => |opts| opts.deinit(testing.allocator),
        .type_list => |opts| opts.deinit(testing.allocator),
        .help, .version => {},
    };

    switch (parsed) {
        .run => |opts| {
            try testing.expectEqualStrings("needle", opts.pattern);
            try testing.expectEqual(@as(usize, 1), opts.include_types.len);
            try testing.expectEqualStrings("zig", opts.include_types[0]);
            try testing.expectEqual(@as(usize, 1), opts.exclude_types.len);
            try testing.expectEqualStrings("markdown", opts.exclude_types[0]);
            try testing.expectEqual(@as(usize, 1), opts.type_adds.len);
            try testing.expectEqualStrings("web:*.web,*.page", opts.type_adds[0]);
        },
        .help, .version, .type_list => unreachable,
    }
}

test "parseArgs accepts type-list without pattern" {
    const testing = std.testing;

    const parsed = try parseArgs(testing.allocator, &.{
        "zigrep",
        "--type-add",
        "web:*.web",
        "--type-list",
    });
    defer switch (parsed) {
        .run => |opts| opts.deinit(testing.allocator),
        .type_list => |opts| opts.deinit(testing.allocator),
        .help, .version => {},
    };

    switch (parsed) {
        .type_list => |opts| {
            try testing.expectEqual(@as(usize, 1), opts.type_adds.len);
            try testing.expectEqualStrings("web:*.web", opts.type_adds[0]);
        },
        .help, .version, .run => unreachable,
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
        "latin2",
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
    try testing.expectError(error.InvalidFlagCombination, parseArgs(testing.allocator, &.{
        "zigrep",
        "--json",
        "-C",
        "1",
        "needle",
    }));
    try testing.expectError(error.InvalidFlagCombination, parseArgs(testing.allocator, &.{
        "zigrep",
        "--null",
        "needle",
    }));
    try testing.expectError(error.InvalidFlagCombination, parseArgs(testing.allocator, &.{
        "zigrep",
        "--json",
        "--null",
        "-l",
        "needle",
    }));
    try testing.expectError(error.InvalidFlagCombination, parseArgs(testing.allocator, &.{
        "zigrep",
        "--heading",
        "--count",
        "needle",
    }));
    try testing.expectError(error.InvalidFlagCombination, parseArgs(testing.allocator, &.{
        "zigrep",
        "-v",
        "--only-matching",
        "needle",
    }));
    try testing.expectError(error.InvalidFlagCombination, parseArgs(testing.allocator, &.{
        "zigrep",
        "-v",
        "-C",
        "1",
        "needle",
    }));
    try testing.expectError(error.InvalidFlagCombination, parseArgs(testing.allocator, &.{
        "zigrep",
        "--binary",
        "--count",
        "needle",
    }));
    try testing.expectError(error.InvalidFlagCombination, parseArgs(testing.allocator, &.{
        "zigrep",
        "--binary",
        "--json",
        "needle",
    }));
    try testing.expectError(error.InvalidFlagCombination, parseArgs(testing.allocator, &.{
        "zigrep",
        "--pre-glob",
        "*.wrapped",
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

test "runCli unrestricted mode widens filtering progressively" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = ".gitignore",
        .data = "ignored.txt\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "ignored.txt",
        .data = "needle ignored\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = ".hidden.txt",
        .data = "needle hidden\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "binary.bin",
        .data = "xx\x00needleyy",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const one_u = try runCliCaptured(testing.allocator, &.{ "zigrep", "-u", "needle", root_path });
    defer one_u.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), one_u.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, one_u.stdout, 1, "ignored.txt:1:1:needle ignored"));
    try testing.expect(!std.mem.containsAtLeast(u8, one_u.stdout, 1, ".hidden.txt"));
    try testing.expect(!std.mem.containsAtLeast(u8, one_u.stdout, 1, "binary.bin"));

    const two_u = try runCliCaptured(testing.allocator, &.{ "zigrep", "-uu", "needle", root_path });
    defer two_u.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), two_u.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, two_u.stdout, 1, "ignored.txt:1:1:needle ignored"));
    try testing.expect(std.mem.containsAtLeast(u8, two_u.stdout, 1, ".hidden.txt:1:1:needle hidden"));
    try testing.expect(!std.mem.containsAtLeast(u8, two_u.stdout, 1, "binary.bin"));

    const three_u = try runCliCaptured(testing.allocator, &.{ "zigrep", "-uuu", "needle", root_path });
    defer three_u.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), three_u.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, three_u.stdout, 1, "ignored.txt:1:1:needle ignored"));
    try testing.expect(std.mem.containsAtLeast(u8, three_u.stdout, 1, ".hidden.txt:1:1:needle hidden"));
    try testing.expect(std.mem.containsAtLeast(u8, three_u.stdout, 1, "binary.bin"));
}

test "runCli ignore-case matches differing literal case" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "sample.txt",
        .data = "Needle one\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try runCliCaptured(testing.allocator, &.{ "zigrep", "--ignore-case", "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "sample.txt:1:1:Needle one"));
}

test "runCli smart-case keeps uppercase patterns case-sensitive" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "sample.txt",
        .data = "needle lower\nNeedle upper\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try runCliCaptured(testing.allocator, &.{ "zigrep", "--smart-case", "Needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(!std.mem.containsAtLeast(u8, run.stdout, 1, "sample.txt:1:1:needle lower"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "sample.txt:2:1:Needle upper"));
}

test "runCli smart-case uses ignore-case for lowercase patterns" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "sample.txt",
        .data = "Needle one\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try runCliCaptured(testing.allocator, &.{ "zigrep", "--smart-case", "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "sample.txt:1:1:Needle one"));
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

test "runCli config file prepends default flags" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "zigrep.conf",
        .data =
            "--count\n" ++
            "--ignore-case\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "sample.txt",
        .data =
            "Needle one\n" ++
            "needle two\n" ++
            "miss\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);
    const config_path = try std.fs.path.join(testing.allocator, &.{ root_path, "zigrep.conf" });
    defer testing.allocator.free(config_path);

    const run = try runCliCaptured(testing.allocator, &.{
        "zigrep",
        "--config-path",
        config_path,
        "needle",
        root_path,
    });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "sample.txt:2\n"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli command-line flags override config defaults" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "zigrep.conf",
        .data = "--count\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "sample.txt",
        .data = "needle one\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);
    const config_path = try std.fs.path.join(testing.allocator, &.{ root_path, "zigrep.conf" });
    defer testing.allocator.free(config_path);

    const run = try runCliCaptured(testing.allocator, &.{
        "zigrep",
        "--config-path",
        config_path,
        "--files-with-matches",
        "needle",
        root_path,
    });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "sample.txt\n"));
    try testing.expect(!std.mem.containsAtLeast(u8, run.stdout, 1, "sample.txt:1\n"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli no-config disables config file defaults" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "zigrep.conf",
        .data = "--count\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "sample.txt",
        .data = "needle one\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);
    const config_path = try std.fs.path.join(testing.allocator, &.{ root_path, "zigrep.conf" });
    defer testing.allocator.free(config_path);

    const run = try runCliCaptured(testing.allocator, &.{
        "zigrep",
        "--config-path",
        config_path,
        "--no-config",
        "needle",
        root_path,
    });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "sample.txt:1:1:needle one"));
    try testing.expect(!std.mem.containsAtLeast(u8, run.stdout, 1, "sample.txt:1\n"));
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

test "runCli multiline mode prints merged multiline blocks in normal text output" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "multi.txt",
        .data =
            "zero\n" ++
            "abc\n" ++
            "defxxxabc\n" ++
            "defxxx\n" ++
            "tail\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try runCliCaptured(testing.allocator, &.{ "zigrep", "-U", "abc\\ndef", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.endsWith(u8, run.stdout, "multi.txt:2:1:abc\ndefxxxabc\ndefxxx\n"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli multiline only-matching mode prints each exact multiline match" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "multi.txt",
        .data =
            "zero\n" ++
            "abc\n" ++
            "def\n" ++
            "abc\n" ++
            "def\n" ++
            "tail\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try runCliCaptured(testing.allocator, &.{ "zigrep", "-U", "--only-matching", "abc\\ndef", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "multi.txt:2:1:abc\ndef\n"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "multi.txt:4:1:abc\ndef\n"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli multiline count mode counts multiline matches" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "multi.txt",
        .data =
            "abc\n" ++
            "def\n" ++
            "gap\n" ++
            "abc\n" ++
            "def\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try runCliCaptured(testing.allocator, &.{ "zigrep", "-U", "--count", "abc\\ndef", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.endsWith(u8, run.stdout, "multi.txt:2\n"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli multiline context mode expands around merged blocks" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "multi.txt",
        .data =
            "before\n" ++
            "abc\n" ++
            "def\n" ++
            "after\n" ++
            "gap1\n" ++
            "gap2\n" ++
            "abc\n" ++
            "def\n" ++
            "tail\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try runCliCaptured(testing.allocator, &.{ "zigrep", "-U", "-C", "1", "abc\\ndef", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "multi.txt-1-before\n"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "multi.txt:2:1:abc\ndef\n"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "multi.txt-4-after\n"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "--\n"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "multi.txt-6-gap2\n"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "multi.txt:7:1:abc\ndef\n"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "multi.txt-9-tail\n"));
}

test "runCli multiline json mode emits per-match events with raw spans" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "multi.txt",
        .data =
            "abc\n" ++
            "def\n" ++
            "abc\n" ++
            "def\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try runCliCaptured(testing.allocator, &.{ "zigrep", "-U", "--json", "abc\\ndef", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "\"type\":\"match\""));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "\"line_number\":1,\"column_number\":1"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "\"line\":\"abc\\ndef\""));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "\"line_span\":{\"start\":0,\"end\":7}"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "\"match_span\":{\"start\":0,\"end\":7}"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "\"line_number\":3,\"column_number\":1"));
}

test "runCli multiline heading mode groups blocks by file" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "multi.txt",
        .data =
            "abc\n" ++
            "def\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try runCliCaptured(testing.allocator, &.{ "zigrep", "-U", "--heading", "abc\\ndef", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "multi.txt\n1:1:abc\ndef\n"));
}

test "runCli multiline mode keeps leftmost non-overlapping behavior for overlapping exact matches" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "multi.txt",
        .data =
            "pre\n" ++
            "abc\n" ++
            "abc\n" ++
            "abc\n" ++
            "post\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try runCliCaptured(testing.allocator, &.{ "zigrep", "-U", "abc\\nabc", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.endsWith(u8, run.stdout, "multi.txt:2:1:abc\nabc\n"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli multiline mode merges adjacent match groups without duplicating lines" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "multi.txt",
        .data =
            "abc\n" ++
            "abc\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try runCliCaptured(testing.allocator, &.{ "zigrep", "-U", "abc\\n", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.endsWith(u8, run.stdout, "multi.txt:1:1:abc\nabc\n"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli multiline mode keeps dot from matching newline without dotall" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "multi.txt",
        .data =
            "a\n" ++
            "b\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try runCliCaptured(testing.allocator, &.{ "zigrep", "-U", "a.b", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 1), run.exit_code);
    try testing.expectEqualStrings("", run.stdout);
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli multiline dotall makes dot match newline" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "multi.txt",
        .data =
            "a\n" ++
            "b\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try runCliCaptured(testing.allocator, &.{ "zigrep", "-U", "--multiline-dotall", "a.b", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.endsWith(u8, run.stdout, "multi.txt:1:1:a\nb\n"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli multiline buffered mode matches normal full-buffer output" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "multi.txt",
        .data =
            "zero\n" ++
            "abc\n" ++
            "def\n" ++
            "tail\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const default_run = try runCliCaptured(testing.allocator, &.{ "zigrep", "-U", "abc\\ndef", root_path });
    defer default_run.deinit(testing.allocator);

    const buffered_run = try runCliCaptured(testing.allocator, &.{ "zigrep", "-U", "--buffered", "abc\\ndef", root_path });
    defer buffered_run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), default_run.exit_code);
    try testing.expectEqual(@as(u8, 0), buffered_run.exit_code);
    try testing.expectEqualStrings(default_run.stdout, buffered_run.stdout);
    try testing.expectEqualStrings(default_run.stderr, buffered_run.stderr);
}

test "runCli multiline output stays consistent across sequential and parallel search" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "utf8.txt",
        .data =
            "lead\n" ++
            "abc\n" ++
            "def\n" ++
            "tail\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "invalid.bin",
        .data =
            "xx\xff\n" ++
            "abc\n" ++
            "def\n" ++
            "yy\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "utf16le.txt",
        .data =
            "\xff\xfe" ++
            "l\x00e\x00a\x00d\x00\n\x00" ++
            "a\x00b\x00c\x00\n\x00" ++
            "d\x00e\x00f\x00\n\x00" ++
            "t\x00a\x00i\x00l\x00\n\x00",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const sequential = try runCliCaptured(testing.allocator, &.{
        "zigrep",
        "-U",
        "--text",
        "-j",
        "1",
        "abc\\ndef",
        root_path,
    });
    defer sequential.deinit(testing.allocator);

    const parallel = try runCliCaptured(testing.allocator, &.{
        "zigrep",
        "-U",
        "--text",
        "-j",
        "4",
        "abc\\ndef",
        root_path,
    });
    defer parallel.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), sequential.exit_code);
    try testing.expectEqual(@as(u8, 0), parallel.exit_code);
    try testing.expectEqualStrings(sequential.stdout, parallel.stdout);
    try testing.expectEqualStrings(sequential.stderr, parallel.stderr);
}

test "runCli multiline output stays consistent across buffered and mmap reads" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "utf8.txt",
        .data =
            "lead\n" ++
            "abc\n" ++
            "def\n" ++
            "tail\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "invalid.bin",
        .data =
            "xx\xff\n" ++
            "abc\n" ++
            "def\n" ++
            "yy\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "utf16le.txt",
        .data =
            "\xff\xfe" ++
            "l\x00e\x00a\x00d\x00\n\x00" ++
            "a\x00b\x00c\x00\n\x00" ++
            "d\x00e\x00f\x00\n\x00" ++
            "t\x00a\x00i\x00l\x00\n\x00",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const buffered = try runCliCaptured(testing.allocator, &.{
        "zigrep",
        "-U",
        "--text",
        "--buffered",
        "-j",
        "1",
        "abc\\ndef",
        root_path,
    });
    defer buffered.deinit(testing.allocator);

    const mmap = try runCliCaptured(testing.allocator, &.{
        "zigrep",
        "-U",
        "--text",
        "--mmap",
        "-j",
        "1",
        "abc\\ndef",
        root_path,
    });
    defer mmap.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), buffered.exit_code);
    try testing.expectEqual(@as(u8, 0), mmap.exit_code);
    try testing.expectEqualStrings(buffered.stdout, mmap.stdout);
    try testing.expectEqualStrings(buffered.stderr, mmap.stderr);
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

test "runCli type include filter limits matches" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "main.zig",
        .data = "needle one\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "README.md",
        .data = "needle two\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try runCliCaptured(testing.allocator, &.{ "zigrep", "-t", "zig", "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "main.zig:1:1:needle one"));
    try testing.expect(!std.mem.containsAtLeast(u8, run.stdout, 1, "README.md"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli type exclude filter skips matching type" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "main.zig",
        .data = "needle one\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "README.md",
        .data = "needle two\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try runCliCaptured(testing.allocator, &.{ "zigrep", "-T", "markdown", "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "main.zig:1:1:needle one"));
    try testing.expect(!std.mem.containsAtLeast(u8, run.stdout, 1, "README.md"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli type-add defines custom type" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "home.web",
        .data = "needle one\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "main.zig",
        .data = "needle two\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try runCliCaptured(testing.allocator, &.{
        "zigrep",
        "--type-add",
        "web:*.web",
        "-t",
        "web",
        "needle",
        root_path,
    });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "home.web:1:1:needle one"));
    try testing.expect(!std.mem.containsAtLeast(u8, run.stdout, 1, "main.zig"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli type-list prints known types" {
    const testing = std.testing;

    const run = try runCliCaptured(testing.allocator, &.{
        "zigrep",
        "--type-add",
        "web:*.web,*.page",
        "--type-list",
    });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "zig: *.zig\n"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "web: *.web, *.page\n"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli unknown type fails cleanly" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "main.zig",
        .data = "needle one\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    try testing.expectError(error.UnknownType, runCliCaptured(testing.allocator, &.{
        "zigrep",
        "-t",
        "missing",
        "needle",
        root_path,
    }));
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

test "runCli invert-match prints non-matching lines" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "many.txt",
        .data = "needle one\nskip this\nneedle two\nkeep this\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try runCliCaptured(testing.allocator, &.{ "zigrep", "-v", "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "many.txt:2:1:skip this"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "many.txt:4:1:keep this"));
    try testing.expect(!std.mem.containsAtLeast(u8, run.stdout, 1, "needle one"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli invert-match count mode counts non-matching lines" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "many.txt",
        .data = "needle one\nskip this\nneedle two\nkeep this\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try runCliCaptured(testing.allocator, &.{ "zigrep", "-v", "--count", "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "many.txt:2\n"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli invert-match files-without-match mode prints fully matching files" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "all-match.txt",
        .data = "needle one\nneedle two\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "mixed.txt",
        .data = "needle one\nskip this\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try runCliCaptured(testing.allocator, &.{ "zigrep", "-v", "--files-without-match", "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "all-match.txt\n"));
    try testing.expect(!std.mem.containsAtLeast(u8, run.stdout, 1, "mixed.txt\n"));
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

test "runCli null mode emits NUL-delimited matching paths" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "one.txt",
        .data = "needle one\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "two.txt",
        .data = "skip\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try runCliCaptured(testing.allocator, &.{ "zigrep", "--null", "--files-with-matches", "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "one.txt"));
    try testing.expect(std.mem.indexOfScalar(u8, run.stdout, 0) != null);
    try testing.expect(!std.mem.containsAtLeast(u8, run.stdout, 1, "\n"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli null mode emits NUL-delimited non-matching paths" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "one.txt",
        .data = "needle one\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "two.txt",
        .data = "skip\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try runCliCaptured(testing.allocator, &.{ "zigrep", "--null", "--files-without-match", "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "two.txt"));
    try testing.expect(std.mem.indexOfScalar(u8, run.stdout, 0) != null);
    try testing.expect(!std.mem.containsAtLeast(u8, run.stdout, 1, "\n"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli json mode emits match events" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "many.txt",
        .data = "needle one\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try runCliCaptured(testing.allocator, &.{ "zigrep", "--json", "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "\"type\":\"match\""));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "\"path\":"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "many.txt"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "\"line_number\":1"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "\"line\":\"needle one\""));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli json count mode emits count events" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "many.txt",
        .data = "needle one\nneedle two\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try runCliCaptured(testing.allocator, &.{ "zigrep", "--json", "--count", "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "\"type\":\"count\""));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "\"path\":"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "many.txt"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "\"count\":2"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli stats mode prints search summary to stderr" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "one.txt",
        .data = "needle one\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "two.txt",
        .data = "skip\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "binary.bin",
        .data = "xx\x00needleyy",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try runCliCaptured(testing.allocator, &.{ "zigrep", "--stats", "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "one.txt:1:1:needle one"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stderr, 1, "stats: searched_files=2"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stderr, 1, "matched_files=1"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stderr, 1, "skipped_binary_files=1"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stderr, 1, "warnings_emitted=0"));
}

test "runCli json count mode can emit stats on stderr" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "many.txt",
        .data = "needle one\nneedle two\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try runCliCaptured(testing.allocator, &.{
        "zigrep",
        "--json",
        "--count",
        "--stats",
        "needle",
        root_path,
    });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "\"type\":\"count\""));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "\"count\":2"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stderr, 1, "stats: searched_files=1"));
}

test "runCli heading mode groups matches by file" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "one.txt",
        .data = "needle one\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "two.txt",
        .data = "skip\nneedle two\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try runCliCaptured(testing.allocator, &.{ "zigrep", "--heading", "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "one.txt\n1:1:needle one\n"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "two.txt\n2:1:needle two\n"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "\n\n"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runSearch parallel path preserves heading groups" {
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

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    var stdout_capture: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_capture.deinit();

    const exit_code = try runSearch(testing.allocator, &stdout_capture.writer, &stderr_capture.writer, .{
        .pattern = "needle",
        .paths = &.{root_path},
        .parallel_jobs = 4,
        .output = .{ .heading = true, .with_filename = false },
    });

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, stdout_capture.written(), 1, "one.txt\n1:1:needle one"));
    try testing.expect(std.mem.containsAtLeast(u8, stdout_capture.written(), 1, "two.txt\n1:1:needle two"));
    try testing.expectEqualStrings("", stderr_capture.written());
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

test "runCli only-matching mode honors lazy quantifiers" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "sample.txt",
        .data = "axxbxxb\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try runCliCaptured(testing.allocator, &.{ "zigrep", "--only-matching", "a.+?b", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "sample.txt:1:1:axxb\n"));
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

    const result = try searchEntriesSequential(testing.allocator, &stdout_capture.writer, &stderr_capture.writer, &entries, .{
        .pattern = "needle",
        .paths = &.{"."},
    });

    try testing.expect(!result.matched);
    try testing.expectEqual(@as(usize, 0), result.stats.searched_files);
    try testing.expectEqual(@as(usize, 1), result.stats.warnings_emitted);
    try testing.expectEqualStrings("", stdout_capture.written());
    try testing.expect(std.mem.containsAtLeast(u8, stderr_capture.written(), 1, "warning: skipping missing-file-for-zigrep-test: file not found\n"));
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

test "runCli binary mode reports binary matches without line content" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "payload.bin",
        .data = "aa\x00needle\x00bb",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try runCliCaptured(testing.allocator, &.{ "zigrep", "--binary", "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "payload.bin: binary file matches\n"));
    try testing.expect(!std.mem.containsAtLeast(u8, run.stdout, 1, "\\x00bb"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli binary mode supports files-with-matches" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "payload.bin",
        .data = "aa\x00needle\x00bb",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try runCliCaptured(testing.allocator, &.{ "zigrep", "--binary", "--files-with-matches", "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "payload.bin\n"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli raw-byte encoding mode searches binary payloads without text mode" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "payload.bin",
        .data = "aa\x00needle\x00bb",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try runCliCaptured(testing.allocator, &.{ "zigrep", "-E", "none", "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "payload.bin:1:4:aa"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli compressed search mode finds matches in gzip files" {
    const testing = std.testing;

    const gzip_hello = [_]u8{
        0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x03,
        0xf3, 0x48, 0xcd, 0xc9, 0xc9, 0x57, 0x28, 0xcf,
        0x2f, 0xca, 0x49, 0xe1, 0x02, 0x00,
        0xd5, 0xe0, 0x39, 0xb7, 0x0c, 0x00, 0x00, 0x00,
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "sample.txt.gz",
        .data = &gzip_hello,
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const default_run = try runCliCaptured(testing.allocator, &.{ "zigrep", "Hello", root_path });
    defer default_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 1), default_run.exit_code);
    try testing.expectEqualStrings("", default_run.stdout);

    const zip_run = try runCliCaptured(testing.allocator, &.{ "zigrep", "-z", "Hello", root_path });
    defer zip_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), zip_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, zip_run.stdout, 1, "sample.txt.gz:1:1:Hello world"));
}

test "runCli preprocessor takes precedence over compressed search" {
    const testing = std.testing;

    const gzip_hello = [_]u8{
        0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x03,
        0xf3, 0x48, 0xcd, 0xc9, 0xc9, 0x57, 0x28, 0xcf,
        0x2f, 0xca, 0x49, 0xe1, 0x02, 0x00,
        0xd5, 0xe0, 0x39, 0xb7, 0x0c, 0x00, 0x00, 0x00,
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "sample.txt.gz",
        .data = &gzip_hello,
    });
    try tmp.dir.writeFile(.{
        .sub_path = "pre.sh",
        .data =
            "#!/bin/sh\n" ++
            "printf 'needle from pre\\n'\n",
    });

    var script = try tmp.dir.openFile("pre.sh", .{ .mode = .read_write });
    defer script.close();
    try script.chmod(0o755);

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);
    const script_path = try std.fs.path.join(testing.allocator, &.{ root_path, "pre.sh" });
    defer testing.allocator.free(script_path);
    const pre_command = try std.fmt.allocPrint(testing.allocator, "/bin/sh {s}", .{script_path});
    defer testing.allocator.free(pre_command);

    const run = try runCliCaptured(testing.allocator, &.{
        "zigrep",
        "-j",
        "1",
        "-z",
        "--pre",
        pre_command,
        "--pre-glob",
        "*.gz",
        "needle",
        root_path,
    });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "sample.txt.gz:1:1:needle from pre"));
    try testing.expect(!std.mem.containsAtLeast(u8, run.stdout, 1, "Hello world"));
    try testing.expectEqualStrings("", run.stderr);
}

test "runCli compressed search warns and skips invalid compressed input" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "bad.txt.gz",
        .data = "\x1f\x8bbad",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try runCliCaptured(testing.allocator, &.{ "zigrep", "-z", "needle", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 1), run.exit_code);
    try testing.expectEqualStrings("", run.stdout);
    try testing.expect(std.mem.containsAtLeast(u8, run.stderr, 1, "warning: skipping "));
    try testing.expect(std.mem.containsAtLeast(u8, run.stderr, 1, "invalid compressed input\n"));
}

test "runCli preprocessor transforms matching files selected by pre-glob" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "sample.wrapped",
        .data = "original payload\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "plain.txt",
        .data = "plain text\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "pre.sh",
        .data =
            "#!/bin/sh\n" ++
            "case \"$1\" in\n" ++
            "  *.wrapped) printf '\\156\\145\\145\\144\\154\\145 from pre\\n' ;;\n" ++
            "  *) cat \"$1\" ;;\n" ++
            "esac\n",
    });

    var script = try tmp.dir.openFile("pre.sh", .{ .mode = .read_write });
    defer script.close();
    try script.chmod(0o755);

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);
    const script_path = try std.fs.path.join(testing.allocator, &.{ root_path, "pre.sh" });
    defer testing.allocator.free(script_path);

    const default_run = try runCliCaptured(testing.allocator, &.{ "zigrep", "needle", root_path });
    defer default_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 1), default_run.exit_code);

    const pre_command = try std.fmt.allocPrint(testing.allocator, "/bin/sh {s}", .{script_path});
    defer testing.allocator.free(pre_command);

    const pre_run = try runCliCaptured(testing.allocator, &.{
        "zigrep",
        "-j",
        "1",
        "--pre",
        pre_command,
        "--pre-glob",
        "*.wrapped",
        "needle",
        root_path,
    });
    defer pre_run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), pre_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, pre_run.stdout, 1, "sample.wrapped:1:1:needle from pre"));
    try testing.expect(!std.mem.containsAtLeast(u8, pre_run.stdout, 1, "plain.txt"));
}

test "runCli preprocessor failure warns and skips the file" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "sample.txt",
        .data = "needle one\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "fail.sh",
        .data = "#!/bin/sh\nexit 3\n",
    });

    var script = try tmp.dir.openFile("fail.sh", .{ .mode = .read_write });
    defer script.close();
    try script.chmod(0o755);

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);
    const script_path = try std.fs.path.join(testing.allocator, &.{ root_path, "fail.sh" });
    defer testing.allocator.free(script_path);
    const pre_command = try std.fmt.allocPrint(testing.allocator, "/bin/sh {s}", .{script_path});
    defer testing.allocator.free(pre_command);

    const run = try runCliCaptured(testing.allocator, &.{
        "zigrep",
        "-j",
        "1",
        "--pre",
        pre_command,
        "needle",
        root_path,
    });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 1), run.exit_code);
    try testing.expectEqualStrings("", run.stdout);
    try testing.expect(std.mem.containsAtLeast(u8, run.stderr, 1, "preprocessor exited with non-zero status\n"));
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

test "runCli supports shorthand character classes with ASCII semantics" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "sample.txt",
        .data =
            "a5b\n" ++
            "a字b\n" ++
            "word_123\n" ++
            " \t\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "space.txt",
        .data = " \t\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const digit_run = try runCliCaptured(testing.allocator, &.{ "zigrep", "a\\db", root_path });
    defer digit_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), digit_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, digit_run.stdout, 1, "sample.txt:1:1:a5b"));
    try testing.expect(!std.mem.containsAtLeast(u8, digit_run.stdout, 1, "a字b"));

    const word_run = try runCliCaptured(testing.allocator, &.{ "zigrep", "\\w+", root_path });
    defer word_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), word_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, word_run.stdout, 1, "sample.txt:1:1:a5b"));
    try testing.expect(std.mem.containsAtLeast(u8, word_run.stdout, 1, "sample.txt:3:1:word_123"));

    const space_run = try runCliCaptured(testing.allocator, &.{ "zigrep", "-U", "\\s+", root_path });
    defer space_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), space_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, space_run.stdout, 1, "space.txt:1:1: \t"));
}

test "runCli shorthand negation matches invalid UTF-8 bytes on the raw-byte path" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "raw.bin",
        .data = "a\xffb\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try runCliCaptured(testing.allocator, &.{ "zigrep", "a\\Db", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "raw.bin:1:1:a\\xFFb"));
}

test "runCli supports word boundaries on UTF-8 and raw-byte inputs" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "sample.txt",
        .data =
            "a cat!\n" ++
            "scatter\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "raw.bin",
        .data = "\xffcat\xff\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const word_run = try runCliCaptured(testing.allocator, &.{ "zigrep", "\\bcat\\b", root_path });
    defer word_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), word_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, word_run.stdout, 1, "sample.txt:1:3:a cat!"));
    try testing.expect(std.mem.containsAtLeast(u8, word_run.stdout, 1, "raw.bin:1:2:\\xFFcat\\xFF"));
    try testing.expect(!std.mem.containsAtLeast(u8, word_run.stdout, 1, "scatter"));

    const not_word_run = try runCliCaptured(testing.allocator, &.{ "zigrep", "\\Bcat\\B", root_path });
    defer not_word_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), not_word_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, not_word_run.stdout, 1, "sample.txt:2:2:scatter"));
}

test "runCli supports non-capturing groups" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "sample.txt",
        .data =
            "ababx\n" ++
            "abx\n" ++
            "ax\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try runCliCaptured(testing.allocator, &.{ "zigrep", "(?:ab)+x", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "sample.txt:1:1:ababx"));
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "sample.txt:2:1:abx"));
    try testing.expect(!std.mem.containsAtLeast(u8, run.stdout, 1, "sample.txt:3:1:ax"));
}

test "runCli supports Unicode literal escapes" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "sample.txt",
        .data =
            "жар\n" ++
            "日本\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const cyrillic_run = try runCliCaptured(testing.allocator, &.{ "zigrep", "\\u{0436}ар", root_path });
    defer cyrillic_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), cyrillic_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, cyrillic_run.stdout, 1, "sample.txt:1:1:жар"));

    const kanji_run = try runCliCaptured(testing.allocator, &.{ "zigrep", "\\u{65E5}\\u{672C}", root_path });
    defer kanji_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), kanji_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, kanji_run.stdout, 1, "sample.txt:2:1:日本"));
}

test "runCli supports Unicode property escapes on UTF-8 and raw-byte inputs" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "sample.txt",
        .data =
            "ж7\n" ++
            "7ж\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "raw.bin",
        .data = "\xffж7\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const utf8_run = try runCliCaptured(testing.allocator, &.{ "zigrep", "\\p{Letter}+\\p{Number}+", root_path });
    defer utf8_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), utf8_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, utf8_run.stdout, 1, "sample.txt:1:1:ж7"));

    const raw_run = try runCliCaptured(testing.allocator, &.{ "zigrep", "\\P{Letter}+", root_path });
    defer raw_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), raw_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, raw_run.stdout, 1, "raw.bin:1:1:"));
}

test "runCli supports the Alphabetic Unicode property" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "sample.txt",
        .data = "\xCD\x85\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try runCliCaptured(testing.allocator, &.{ "zigrep", "\\p{Alphabetic}+", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "sample.txt:1:1:"));
}

test "runCli supports Cased and Case_Ignorable Unicode properties" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "sample.txt",
        .data =
            "Σ\n" ++
            "\xCD\x85\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const cased_run = try runCliCaptured(testing.allocator, &.{ "zigrep", "\\p{Cased}+", root_path });
    defer cased_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), cased_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, cased_run.stdout, 1, "sample.txt:1:1:Σ"));

    const case_ignorable_run = try runCliCaptured(testing.allocator, &.{ "zigrep", "\\p{Case_Ignorable}+", root_path });
    defer case_ignorable_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), case_ignorable_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, case_ignorable_run.stdout, 1, "sample.txt:2:1:"));
}

test "runCli supports Any and ASCII Unicode properties" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "sample.txt",
        .data =
            "ж\n" ++
            "Az09\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "raw.bin",
        .data = "\xffA\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const any_run = try runCliCaptured(testing.allocator, &.{ "zigrep", "\\p{Any}+", root_path });
    defer any_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), any_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, any_run.stdout, 1, "sample.txt:1:1:ж"));

    const ascii_run = try runCliCaptured(testing.allocator, &.{ "zigrep", "\\p{ASCII}+", root_path });
    defer ascii_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), ascii_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, ascii_run.stdout, 1, "sample.txt:2:1:Az09"));

    const not_any_run = try runCliCaptured(testing.allocator, &.{ "zigrep", "\\P{Any}+", root_path });
    defer not_any_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), not_any_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, not_any_run.stdout, 1, "raw.bin:1:1:"));
}

test "runCli supports initial Script Unicode properties" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "sample.txt",
        .data =
            "A\n" ++
            "Ω\n" ++
            "Ж\n" ++
            "א\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const greek_run = try runCliCaptured(testing.allocator, &.{ "zigrep", "\\p{Greek}+", root_path });
    defer greek_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), greek_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, greek_run.stdout, 1, "sample.txt:2:1:Ω"));

    const latin_run = try runCliCaptured(testing.allocator, &.{ "zigrep", "\\p{Script=Latin}+", root_path });
    defer latin_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), latin_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, latin_run.stdout, 1, "sample.txt:1:1:A"));

    const cyrillic_run = try runCliCaptured(testing.allocator, &.{ "zigrep", "\\p{sc=Cyrl}+", root_path });
    defer cyrillic_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), cyrillic_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, cyrillic_run.stdout, 1, "sample.txt:3:1:Ж"));

    const hebrew_run = try runCliCaptured(testing.allocator, &.{ "zigrep", "\\p{Hebrew}+", root_path });
    defer hebrew_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), hebrew_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, hebrew_run.stdout, 1, "sample.txt:4:1:א"));
}

test "runCli supports identifier-style derived Unicode properties" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "sample.txt",
        .data =
            "A\n" ++
            "0\n" ++
            "\xC2\xAD\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const id_start_run = try runCliCaptured(testing.allocator, &.{ "zigrep", "\\p{ID_Start}+", root_path });
    defer id_start_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), id_start_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, id_start_run.stdout, 1, "sample.txt:1:1:A"));

    const id_continue_run = try runCliCaptured(testing.allocator, &.{ "zigrep", "\\p{ID_Continue}+", root_path });
    defer id_continue_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), id_continue_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, id_continue_run.stdout, 1, "sample.txt:2:1:0"));

    const xid_start_run = try runCliCaptured(testing.allocator, &.{ "zigrep", "\\p{XID_Start}+", root_path });
    defer xid_start_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), xid_start_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, xid_start_run.stdout, 1, "sample.txt:1:1:A"));

    const xid_continue_run = try runCliCaptured(testing.allocator, &.{ "zigrep", "\\p{XID_Continue}+", root_path });
    defer xid_continue_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), xid_continue_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, xid_continue_run.stdout, 1, "sample.txt:2:1:0"));

    const default_ignorable_run = try runCliCaptured(testing.allocator, &.{ "zigrep", "\\p{Default_Ignorable_Code_Point}+", root_path });
    defer default_ignorable_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), default_ignorable_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, default_ignorable_run.stdout, 1, "sample.txt:3:1:"));
}

test "runCli supports Lowercase and Uppercase Unicode properties" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "sample.txt",
        .data =
            "ß\n" ++
            "Σ\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const lower_run = try runCliCaptured(testing.allocator, &.{ "zigrep", "\\p{Lowercase}+", root_path });
    defer lower_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), lower_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, lower_run.stdout, 1, "sample.txt:1:1:ß"));

    const upper_run = try runCliCaptured(testing.allocator, &.{ "zigrep", "\\p{Uppercase}+", root_path });
    defer upper_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), upper_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, upper_run.stdout, 1, "sample.txt:2:1:Σ"));
}

test "runCli supports Mark, Punctuation, Separator, and Symbol Unicode properties" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "sample.txt",
        .data =
            "\xCD\x85\n" ++
            "!\n" ++
            " \n" ++
            "+\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const mark_run = try runCliCaptured(testing.allocator, &.{ "zigrep", "\\p{Mark}+", root_path });
    defer mark_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), mark_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, mark_run.stdout, 1, "sample.txt:1:1:"));

    const punctuation_run = try runCliCaptured(testing.allocator, &.{ "zigrep", "\\p{Punctuation}+", root_path });
    defer punctuation_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), punctuation_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, punctuation_run.stdout, 1, "sample.txt:2:1:!"));

    const separator_run = try runCliCaptured(testing.allocator, &.{ "zigrep", "\\p{Separator}+", root_path });
    defer separator_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), separator_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, separator_run.stdout, 1, "sample.txt:3:1: "));

    const symbol_run = try runCliCaptured(testing.allocator, &.{ "zigrep", "\\p{Symbol}+", root_path });
    defer symbol_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), symbol_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, symbol_run.stdout, 1, "sample.txt:4:1:+"));

    const not_punctuation_run = try runCliCaptured(testing.allocator, &.{ "zigrep", "\\P{Punctuation}+", root_path });
    defer not_punctuation_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), not_punctuation_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, not_punctuation_run.stdout, 1, "sample.txt:1:1:"));
}

test "runCli supports Unicode general-category subgroup properties" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "sample.txt",
        .data =
            "ǅ\n" ++
            "Ⅰ\n" ++
            "_\n" ++
            "\xEE\x80\x80\n" ++
            "\xCD\xB8\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const titlecase_run = try runCliCaptured(testing.allocator, &.{ "zigrep", "\\p{Lt}+", root_path });
    defer titlecase_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), titlecase_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, titlecase_run.stdout, 1, "sample.txt:1:1:ǅ"));

    const letter_number_run = try runCliCaptured(testing.allocator, &.{ "zigrep", "\\p{Nl}+", root_path });
    defer letter_number_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), letter_number_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, letter_number_run.stdout, 1, "sample.txt:2:1:Ⅰ"));

    const connector_run = try runCliCaptured(testing.allocator, &.{ "zigrep", "\\p{Pc}+", root_path });
    defer connector_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), connector_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, connector_run.stdout, 1, "sample.txt:3:1:_"));

    const other_run = try runCliCaptured(testing.allocator, &.{ "zigrep", "\\p{Other}+", root_path });
    defer other_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), other_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, other_run.stdout, 1, "sample.txt:4:1:"));

    const unassigned_run = try runCliCaptured(testing.allocator, &.{ "zigrep", "\\p{Cn}+", root_path });
    defer unassigned_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), unassigned_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, unassigned_run.stdout, 1, "sample.txt:5:1:"));
}

test "runCli supports Unicode property items inside character classes" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "sample.txt",
        .data =
            "ж7\n" ++
            "ΩΣ\n" ++
            " \n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const run = try runCliCaptured(testing.allocator, &.{ "zigrep", "[\\p{Letter}\\P{Whitespace}]+", root_path });
    defer run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, run.stdout, 1, "sample.txt:1:1:ж7"));

    const script_run = try runCliCaptured(testing.allocator, &.{ "zigrep", "[\\p{Greek}\\p{Uppercase}]+", root_path });
    defer script_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), script_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, script_run.stdout, 1, "sample.txt:2:1:ΩΣ"));
}

test "runCli rejects unsupported Unicode properties" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "sample.txt",
        .data = "needle\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    try testing.expectError(error.UnsupportedProperty, runCliCaptured(testing.allocator, &.{ "zigrep", "\\p{Emoji}", root_path }));
}

test "runCli rejects invalid Unicode escapes" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "sample.txt",
        .data = "needle\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    try testing.expectError(error.InvalidUnicodeEscape, runCliCaptured(testing.allocator, &.{ "zigrep", "\\u{}", root_path }));
    try testing.expectError(error.InvalidUnicodeEscape, runCliCaptured(testing.allocator, &.{ "zigrep", "\\u{110000}", root_path }));
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

test "runCli can force latin1 decoding" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "latin1.txt",
        .data = "caf\xe9 needle\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const default_run = try runCliCaptured(testing.allocator, &.{ "zigrep", "café", root_path });
    defer default_run.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 1), default_run.exit_code);

    const forced_run = try runCliCaptured(testing.allocator, &.{
        "zigrep",
        "-E",
        "latin1",
        "café",
        root_path,
    });
    defer forced_run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), forced_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, forced_run.stdout, 1, "latin1.txt:1:1:café needle"));
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
        .text,
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

test "runCli binary detection stays consistent across buffered and mmap reads" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "binary.bin",
        .data = "xx\x00needleyy",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const buffered_default = try runCliCaptured(testing.allocator, &.{
        "zigrep",
        "--buffered",
        "needle",
        root_path,
    });
    defer buffered_default.deinit(testing.allocator);

    const mmap_default = try runCliCaptured(testing.allocator, &.{
        "zigrep",
        "--mmap",
        "needle",
        root_path,
    });
    defer mmap_default.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 1), buffered_default.exit_code);
    try testing.expectEqual(@as(u8, 1), mmap_default.exit_code);
    try testing.expectEqualStrings(buffered_default.stdout, mmap_default.stdout);
    try testing.expectEqualStrings(buffered_default.stderr, mmap_default.stderr);

    const buffered_binary = try runCliCaptured(testing.allocator, &.{
        "zigrep",
        "--buffered",
        "--binary",
        "needle",
        root_path,
    });
    defer buffered_binary.deinit(testing.allocator);

    const mmap_binary = try runCliCaptured(testing.allocator, &.{
        "zigrep",
        "--mmap",
        "--binary",
        "needle",
        root_path,
    });
    defer mmap_binary.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), buffered_binary.exit_code);
    try testing.expectEqual(@as(u8, 0), mmap_binary.exit_code);
    try testing.expectEqualStrings(buffered_binary.stdout, mmap_binary.stdout);
    try testing.expectEqualStrings(buffered_binary.stderr, mmap_binary.stderr);
}

test "runCli type, glob, and ignore controls compose on the end-to-end path" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = ".gitignore",
        .data = "ignored.zig\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "shown.zig",
        .data = "needle shown\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "ignored.zig",
        .data = "needle hidden\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "other.txt",
        .data = "needle text\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const default_run = try runCliCaptured(testing.allocator, &.{
        "zigrep",
        "-t",
        "zig",
        "-g",
        "*.zig",
        "needle",
        root_path,
    });
    defer default_run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), default_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, default_run.stdout, 1, "shown.zig:1:1:needle shown"));
    try testing.expect(!std.mem.containsAtLeast(u8, default_run.stdout, 1, "ignored.zig"));
    try testing.expect(!std.mem.containsAtLeast(u8, default_run.stdout, 1, "other.txt"));

    const unrestricted_run = try runCliCaptured(testing.allocator, &.{
        "zigrep",
        "-u",
        "-t",
        "zig",
        "-g",
        "*.zig",
        "needle",
        root_path,
    });
    defer unrestricted_run.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), unrestricted_run.exit_code);
    try testing.expect(std.mem.containsAtLeast(u8, unrestricted_run.stdout, 1, "shown.zig:1:1:needle shown"));
    try testing.expect(std.mem.containsAtLeast(u8, unrestricted_run.stdout, 1, "ignored.zig:1:1:needle hidden"));
    try testing.expect(!std.mem.containsAtLeast(u8, unrestricted_run.stdout, 1, "other.txt"));
}
