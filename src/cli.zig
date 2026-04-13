const std = @import("std");
const config = @import("config.zig");
const build_options = @import("build_options");
const command = @import("command.zig");
const cli_dispatch = @import("cli_dispatch.zig");
const search = @import("search/root.zig");

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

pub const ParseResult = cli_dispatch.ParseResult;

const ParseState = struct {
    include_hidden: bool = false,
    follow_symlinks: bool = false,
    invert_match: bool = false,
    no_ignore: bool = false,
    no_ignore_vcs: bool = false,
    no_ignore_parent: bool = false,
    binary_mode: BinaryMode = .skip,
    search_compressed: bool = false,
    preprocessor: ?[]const u8 = null,
    unrestricted_level: u8 = 0,
    case_mode: search.grep.CaseMode = .sensitive,
    read_strategy: search.io.ReadStrategy = .mmap,
    encoding: search.io.InputEncoding = .auto,
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
    pattern: ?[]const u8 = null,
    show_type_list: bool = false,
};

const ScalarFlagResult = enum {
    unhandled,
    handled,
    help,
    version,
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
    defer cli_dispatch.deinitParseResult(parsed, allocator);

    switch (parsed) {
        .help => {
            try writeUsage(stdout, resolved.argv[0]);
            return 0;
        },
        .version => {
            try stdout.print("zigrep {s}\n", .{app_version});
            return 0;
        },
        .type_list, .run => return cli_dispatch.executeParsedCommand(allocator, stdout, stderr, parsed),
    }
}

pub fn parseArgs(allocator: std.mem.Allocator, argv: []const []const u8) !ParseResult {
    if (argv.len <= 1) return error.MissingPattern;

    var state: ParseState = .{};
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
        if (!stop_parsing_flags and state.pattern == null and std.mem.eql(u8, arg, "--")) {
            stop_parsing_flags = true;
            continue;
        }

        if (!stop_parsing_flags and state.pattern == null and arg.len > 0 and arg[0] == '-') {
            switch (handleScalarFlag(&state, arg)) {
                .help => return .help,
                .version => return .version,
                .handled => continue,
                .unhandled => {},
            }
            if (try handleValueFlag(
                allocator,
                &state,
                &globs,
                &pre_globs,
                &ignore_files,
                &include_types,
                &exclude_types,
                &type_adds,
                argv,
                &index,
                arg,
            )) {
                continue;
            }
            return error.UnknownFlag;
        }

        if (state.pattern == null) {
            state.pattern = arg;
        } else {
            try paths.append(allocator, arg);
        }
    }

    const owned_type_adds = try type_adds.toOwnedSlice(allocator);
    errdefer allocator.free(owned_type_adds);

    if (state.show_type_list) {
        return .{ .type_list = .{ .type_adds = owned_type_adds } };
    }
    return finalizeRunParse(
        allocator,
        &state,
        &paths,
        &globs,
        &pre_globs,
        &ignore_files,
        &include_types,
        &exclude_types,
        owned_type_adds,
    );
}

fn finalizeRunParse(
    allocator: std.mem.Allocator,
    state: *ParseState,
    paths: *std.ArrayList([]const u8),
    globs: *std.ArrayList([]const u8),
    pre_globs: *std.ArrayList([]const u8),
    ignore_files: *std.ArrayList([]const u8),
    include_types: *std.ArrayList([]const u8),
    exclude_types: *std.ArrayList([]const u8),
    owned_type_adds: []const []const u8,
) !ParseResult {
    errdefer allocator.free(owned_type_adds);

    if (state.pattern == null) return error.MissingPattern;
    if (state.preprocessor == null and pre_globs.items.len != 0) return error.InvalidFlagCombination;
    if (state.multiline_dotall and !state.multiline) return error.InvalidFlagCombination;
    if (state.unrestricted_level >= 1) state.no_ignore = true;
    if (state.unrestricted_level >= 2) state.include_hidden = true;
    if (state.unrestricted_level >= 3) state.binary_mode = .text;
    if (paths.items.len == 0) try paths.append(allocator, ".");
    if ((state.context_before != 0 or state.context_after != 0) and
        (state.report_mode != .lines or state.output.only_matching or state.invert_match))
    {
        return error.InvalidFlagCombination;
    }
    if (state.invert_match and state.output.only_matching) return error.InvalidFlagCombination;
    if (state.output_format == .json and (state.context_before != 0 or state.context_after != 0)) {
        return error.InvalidFlagCombination;
    }
    if (state.output.null_path_terminator and (state.output_format == .json or
        (state.report_mode != .files_with_matches and state.report_mode != .files_without_match)))
    {
        return error.InvalidFlagCombination;
    }
    if (state.output.heading and (state.output_format != .text or state.report_mode != .lines)) {
        return error.InvalidFlagCombination;
    }
    if (state.binary_mode == .suppress and (state.output_format != .text or state.output.only_matching or
        state.report_mode == .count or state.output.heading))
    {
        return error.InvalidFlagCombination;
    }
    if (state.output.heading) {
        state.output.with_filename = false;
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
        .pattern = state.pattern.?,
        .paths = owned_paths,
        .globs = owned_globs,
        .pre_globs = owned_pre_globs,
        .ignore_files = owned_ignore_files,
        .include_types = owned_include_types,
        .exclude_types = owned_exclude_types,
        .type_adds = owned_type_adds,
        .include_hidden = state.include_hidden,
        .follow_symlinks = state.follow_symlinks,
        .invert_match = state.invert_match,
        .no_ignore = state.no_ignore,
        .no_ignore_vcs = state.no_ignore_vcs,
        .no_ignore_parent = state.no_ignore_parent,
        .binary_mode = state.binary_mode,
        .search_compressed = state.search_compressed,
        .preprocessor = state.preprocessor,
        .case_mode = state.case_mode,
        .read_strategy = state.read_strategy,
        .encoding = state.encoding,
        .multiline = state.multiline,
        .multiline_dotall = state.multiline_dotall,
        .parallel_jobs = state.parallel_jobs,
        .max_depth = state.max_depth,
        .max_count = state.max_count,
        .context_before = state.context_before,
        .context_after = state.context_after,
        .show_stats = state.show_stats,
        .output = state.output,
        .output_format = state.output_format,
        .report_mode = state.report_mode,
    } };
}

fn handleScalarFlag(state: *ParseState, arg: []const u8) ScalarFlagResult {
    if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) return .help;
    if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V")) return .version;
    if (std.mem.eql(u8, arg, "--unrestricted")) {
        state.unrestricted_level = @min(state.unrestricted_level + 1, 3);
        return .handled;
    }
    if (shortUnrestrictedCount(arg)) |count| {
        state.unrestricted_level = @min(state.unrestricted_level + count, 3);
        return .handled;
    }
    if (std.mem.eql(u8, arg, "--hidden")) {
        state.include_hidden = true;
        return .handled;
    }
    if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--invert-match")) {
        state.invert_match = true;
        return .handled;
    }
    if (std.mem.eql(u8, arg, "--type-list")) {
        state.show_type_list = true;
        return .handled;
    }
    if (std.mem.eql(u8, arg, "--json")) {
        state.output_format = .json;
        return .handled;
    }
    if (std.mem.eql(u8, arg, "--stats")) {
        state.show_stats = true;
        return .handled;
    }
    if (std.mem.eql(u8, arg, "--null")) {
        state.output.null_path_terminator = true;
        return .handled;
    }
    if (std.mem.eql(u8, arg, "--heading")) {
        state.output.heading = true;
        return .handled;
    }
    if (std.mem.eql(u8, arg, "--no-ignore")) {
        state.no_ignore = true;
        return .handled;
    }
    if (std.mem.eql(u8, arg, "--no-ignore-vcs")) {
        state.no_ignore_vcs = true;
        return .handled;
    }
    if (std.mem.eql(u8, arg, "--no-ignore-parent")) {
        state.no_ignore_parent = true;
        return .handled;
    }
    if (std.mem.eql(u8, arg, "--follow")) {
        state.follow_symlinks = true;
        return .handled;
    }
    if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--ignore-case")) {
        state.case_mode = .insensitive;
        return .handled;
    }
    if (std.mem.eql(u8, arg, "-S") or std.mem.eql(u8, arg, "--smart-case")) {
        state.case_mode = .smart;
        return .handled;
    }
    if (std.mem.eql(u8, arg, "--text")) {
        state.binary_mode = .text;
        return .handled;
    }
    if (std.mem.eql(u8, arg, "--binary")) {
        state.binary_mode = .suppress;
        return .handled;
    }
    if (std.mem.eql(u8, arg, "-z") or std.mem.eql(u8, arg, "--search-zip")) {
        state.search_compressed = true;
        return .handled;
    }
    if (std.mem.eql(u8, arg, "--buffered")) {
        state.read_strategy = .buffered;
        return .handled;
    }
    if (std.mem.eql(u8, arg, "--mmap")) {
        state.read_strategy = .mmap;
        return .handled;
    }
    if (std.mem.eql(u8, arg, "-U") or std.mem.eql(u8, arg, "--multiline")) {
        state.multiline = true;
        return .handled;
    }
    if (std.mem.eql(u8, arg, "--multiline-dotall")) {
        state.multiline_dotall = true;
        return .handled;
    }
    if (std.mem.eql(u8, arg, "-H") or std.mem.eql(u8, arg, "--with-filename")) {
        state.output.with_filename = true;
        return .handled;
    }
    if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--count")) {
        state.report_mode = .count;
        return .handled;
    }
    if (std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "--files-with-matches")) {
        state.report_mode = .files_with_matches;
        return .handled;
    }
    if (std.mem.eql(u8, arg, "-L") or std.mem.eql(u8, arg, "--files-without-match")) {
        state.report_mode = .files_without_match;
        return .handled;
    }
    if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--only-matching")) {
        state.output.only_matching = true;
        return .handled;
    }
    if (std.mem.eql(u8, arg, "--no-filename")) {
        state.output.with_filename = false;
        return .handled;
    }
    if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--line-number")) {
        state.output.line_number = true;
        return .handled;
    }
    if (std.mem.eql(u8, arg, "--no-line-number")) {
        state.output.line_number = false;
        return .handled;
    }
    if (std.mem.eql(u8, arg, "--column")) {
        state.output.column_number = true;
        return .handled;
    }
    if (std.mem.eql(u8, arg, "--no-column")) {
        state.output.column_number = false;
        return .handled;
    }
    return .unhandled;
}

fn handleValueFlag(
    allocator: std.mem.Allocator,
    state: *ParseState,
    globs: *std.ArrayList([]const u8),
    pre_globs: *std.ArrayList([]const u8),
    ignore_files: *std.ArrayList([]const u8),
    include_types: *std.ArrayList([]const u8),
    exclude_types: *std.ArrayList([]const u8),
    type_adds: *std.ArrayList([]const u8),
    argv: []const []const u8,
    index: *usize,
    arg: []const u8,
) !bool {
    if (std.mem.eql(u8, arg, "--ignore-file")) {
        try ignore_files.append(allocator, try requireNextArg(argv, index));
        return true;
    }
    if (std.mem.eql(u8, arg, "--type-add")) {
        try type_adds.append(allocator, try requireNextArg(argv, index));
        return true;
    }
    if (std.mem.eql(u8, arg, "-t")) {
        try include_types.append(allocator, try requireNextArg(argv, index));
        return true;
    }
    if (std.mem.eql(u8, arg, "-T")) {
        try exclude_types.append(allocator, try requireNextArg(argv, index));
        return true;
    }
    if (std.mem.eql(u8, arg, "--pre")) {
        state.preprocessor = try requireNextArg(argv, index);
        return true;
    }
    if (std.mem.eql(u8, arg, "--pre-glob")) {
        try pre_globs.append(allocator, try requireNextArg(argv, index));
        return true;
    }
    if (std.mem.eql(u8, arg, "-g") or std.mem.eql(u8, arg, "--glob")) {
        try globs.append(allocator, try requireNextArg(argv, index));
        return true;
    }
    if (std.mem.eql(u8, arg, "-E") or std.mem.eql(u8, arg, "--encoding")) {
        state.encoding = try parseEncoding(try requireNextArg(argv, index));
        return true;
    }
    if (std.mem.eql(u8, arg, "-j") or std.mem.eql(u8, arg, "--threads")) {
        state.parallel_jobs = try parsePositiveUsize(try requireNextArg(argv, index));
        return true;
    }
    if (std.mem.eql(u8, arg, "--max-depth")) {
        state.max_depth = try parseNonNegativeUsize(try requireNextArg(argv, index));
        return true;
    }
    if (std.mem.eql(u8, arg, "-A") or std.mem.eql(u8, arg, "--after-context")) {
        state.context_after = try parseNonNegativeUsize(try requireNextArg(argv, index));
        return true;
    }
    if (std.mem.eql(u8, arg, "-B") or std.mem.eql(u8, arg, "--before-context")) {
        state.context_before = try parseNonNegativeUsize(try requireNextArg(argv, index));
        return true;
    }
    if (std.mem.eql(u8, arg, "-C") or std.mem.eql(u8, arg, "--context")) {
        const context = try parseNonNegativeUsize(try requireNextArg(argv, index));
        state.context_before = context;
        state.context_after = context;
        return true;
    }
    if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--max-count")) {
        state.max_count = try parsePositiveUsize(try requireNextArg(argv, index));
        return true;
    }
    return false;
}

fn requireNextArg(argv: []const []const u8, index: *usize) CliError![]const u8 {
    index.* += 1;
    if (index.* >= argv.len) return error.MissingFlagValue;
    return argv[index.*];
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
