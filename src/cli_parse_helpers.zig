const std = @import("std");
const cli_parse_state = @import("cli_parse_state.zig");
const search = @import("search/root.zig");

pub const CliError = cli_parse_state.CliError;
pub const ParseState = cli_parse_state.ParseState;
pub const ParseBuffers = cli_parse_state.ParseBuffers;
pub const GlobSpec = cli_parse_state.GlobSpec;
pub const SortMode = cli_parse_state.SortMode;

pub const ScalarFlagResult = enum {
    unhandled,
    handled,
    help,
    version,
};

pub fn handleScalarFlag(state: *ParseState, arg: []const u8) ScalarFlagResult {
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
    if (std.mem.eql(u8, arg, "--files")) {
        state.list_files = true;
        return .handled;
    }
    if (std.mem.eql(u8, arg, "--stats")) {
        state.show_stats = true;
        return .handled;
    }
    if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
        state.quiet = true;
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
    if (std.mem.eql(u8, arg, "-F") or std.mem.eql(u8, arg, "--fixed-strings")) {
        state.fixed_strings = true;
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
        state.filename_flag_seen = true;
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
        state.filename_flag_seen = true;
        return .handled;
    }
    if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--line-number")) {
        state.output.line_number = true;
        state.line_number_flag_seen = true;
        return .handled;
    }
    if (std.mem.eql(u8, arg, "--no-line-number")) {
        state.output.line_number = false;
        state.line_number_flag_seen = true;
        return .handled;
    }
    if (std.mem.eql(u8, arg, "--column")) {
        state.output.column_number = true;
        state.column_number_flag_seen = true;
        return .handled;
    }
    if (std.mem.eql(u8, arg, "--no-column")) {
        state.output.column_number = false;
        state.column_number_flag_seen = true;
        return .handled;
    }
    return .unhandled;
}

pub fn handleValueFlag(
    allocator: std.mem.Allocator,
    state: *ParseState,
    buffers: *ParseBuffers,
    argv: []const []const u8,
    index: *usize,
    arg: []const u8,
) !bool {
    if (std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--regexp")) {
        try buffers.explicit_patterns.append(allocator, try requireNextArg(argv, index));
        return true;
    }
    if (std.mem.eql(u8, arg, "-r") or std.mem.eql(u8, arg, "--replace")) {
        state.output.replacement = try requireNextArg(argv, index);
        return true;
    }
    if (std.mem.eql(u8, arg, "--ignore-file")) {
        try buffers.ignore_files.append(allocator, try requireNextArg(argv, index));
        return true;
    }
    if (std.mem.eql(u8, arg, "--type-add")) {
        try buffers.type_adds.append(allocator, try requireNextArg(argv, index));
        return true;
    }
    if (std.mem.eql(u8, arg, "-t")) {
        try buffers.include_types.append(allocator, try requireNextArg(argv, index));
        return true;
    }
    if (std.mem.eql(u8, arg, "-T")) {
        try buffers.exclude_types.append(allocator, try requireNextArg(argv, index));
        return true;
    }
    if (std.mem.eql(u8, arg, "--pre")) {
        state.preprocessor = try requireNextArg(argv, index);
        return true;
    }
    if (std.mem.eql(u8, arg, "--pre-glob")) {
        try buffers.pre_globs.append(allocator, try requireNextArg(argv, index));
        return true;
    }
    if (std.mem.eql(u8, arg, "--sort")) {
        const mode = try parseSortMode(try requireNextArg(argv, index));
        state.sort_mode = mode;
        state.sort_reverse = false;
        return true;
    }
    if (std.mem.eql(u8, arg, "--sortr")) {
        const mode = try parseSortMode(try requireNextArg(argv, index));
        state.sort_mode = mode;
        state.sort_reverse = mode != .none;
        return true;
    }
    if (std.mem.eql(u8, arg, "-g") or std.mem.eql(u8, arg, "--glob")) {
        try buffers.globs.append(allocator, .{
            .pattern = try requireNextArg(argv, index),
            .case_insensitive = false,
        });
        return true;
    }
    if (std.mem.eql(u8, arg, "--iglob")) {
        try buffers.globs.append(allocator, .{
            .pattern = try requireNextArg(argv, index),
            .case_insensitive = true,
        });
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

fn parseEncoding(arg: []const u8) CliError!search.io.InputEncoding {
    if (std.ascii.eqlIgnoreCase(arg, "auto")) return .auto;
    if (std.ascii.eqlIgnoreCase(arg, "none")) return .none;
    if (std.ascii.eqlIgnoreCase(arg, "utf8")) return .utf8;
    if (std.ascii.eqlIgnoreCase(arg, "latin1")) return .latin1;
    if (std.ascii.eqlIgnoreCase(arg, "utf16le")) return .utf16le;
    if (std.ascii.eqlIgnoreCase(arg, "utf16be")) return .utf16be;
    return error.InvalidFlagValue;
}

fn parseSortMode(arg: []const u8) CliError!SortMode {
    if (std.mem.eql(u8, arg, "none")) return .none;
    if (std.mem.eql(u8, arg, "path")) return .path;
    if (std.mem.eql(u8, arg, "modified")) return .modified;
    if (std.mem.eql(u8, arg, "accessed")) return .accessed;
    if (std.mem.eql(u8, arg, "created")) return .created;
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
