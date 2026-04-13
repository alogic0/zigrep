const std = @import("std");
const config = @import("config.zig");
const build_options = @import("build_options");
const command = @import("command.zig");
const search = @import("search/root.zig");
const runner = @import("search_runner.zig");

pub const CliError = error{
    MissingPattern,
    UnknownFlag,
    UnknownType,
    MissingFlagValue,
    InvalidFlagValue,
    InvalidFlagCombination,
    InvalidTypeAddSpec,
};

pub const OutputOptions = command.OutputOptions;
pub const OutputFormat = command.OutputFormat;
pub const BinaryMode = command.BinaryMode;
pub const ReportMode = command.ReportMode;
pub const CliOptions = command.CliOptions;
pub const app_version = build_options.app_version;

pub const ParseResult = union(enum) {
    help,
    version,
    type_list: struct {
        type_adds: []const []const u8,

        pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
            allocator.free(self.type_adds);
        }
    },
    run: CliOptions,
};

pub fn writeFatalError(writer: *std.Io.Writer, argv0: []const u8, err: anyerror) !void {
    try writer.print("error: {s}\n", .{@errorName(err)});
    if (isUsageError(err)) {
        try writeUsage(writer, argv0);
    }
}

pub fn runCli(
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    argv: []const []const u8,
) !u8 {
    const resolved = try config.resolveArgs(allocator, argv);
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
            try stdout.print("zigrep {s}\n", .{app_version});
            return 0;
        },
        .type_list => |opts| {
            const matcher = try search.types.init(allocator, opts.type_adds);
            defer matcher.deinit(allocator);
            try search.types.writeTypeList(stdout, matcher);
            return 0;
        },
        .run => |opts| {
            return runner.runSearch(allocator, stdout, stderr, opts);
        },
    }
}

pub fn parseArgs(allocator: std.mem.Allocator, argv: []const []const u8) !ParseResult {
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
    var case_mode: search.grep.CaseMode = .sensitive;
    var read_strategy: search.io.ReadStrategy = .mmap;
    var encoding: search.io.InputEncoding = .auto;
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

fn parseEncoding(arg: []const u8) CliError!search.io.InputEncoding {
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

pub fn writeUsage(writer: *std.Io.Writer, argv0: []const u8) !void {
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
