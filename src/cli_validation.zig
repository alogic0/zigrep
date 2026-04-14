const std = @import("std");
const command = @import("command.zig");
const cli_dispatch = @import("cli_dispatch.zig");
const cli_parse_state = @import("cli_parse_state.zig");

pub const CliError = cli_parse_state.CliError;
pub const CliOptions = command.CliOptions;
pub const ParseResult = cli_dispatch.ParseResult;
pub const ParseState = cli_parse_state.ParseState;
pub const ParseBuffers = cli_parse_state.ParseBuffers;

pub fn finalizeParse(
    allocator: std.mem.Allocator,
    state: *ParseState,
    buffers: *ParseBuffers,
) !ParseResult {
    const owned_type_adds = try buffers.type_adds.toOwnedSlice(allocator);
    errdefer allocator.free(owned_type_adds);

    if (state.show_type_list) {
        return .{ .type_list = .{ .type_adds = owned_type_adds } };
    }

    return finalizeRunParse(allocator, state, buffers, owned_type_adds);
}

fn finalizeRunParse(
    allocator: std.mem.Allocator,
    state: *ParseState,
    buffers: *ParseBuffers,
    owned_type_adds: []const []const u8,
) !ParseResult {
    errdefer allocator.free(owned_type_adds);

    try normalizeState(allocator, state, buffers);
    try validateRunState(state, buffers);

    const pattern_info = try buildPatternInfo(allocator, state, buffers);
    errdefer if (pattern_info.owned_pattern) |pattern| allocator.free(pattern);

    const owned_paths = try buffers.paths.toOwnedSlice(allocator);
    errdefer allocator.free(owned_paths);
    const owned_globs = try buffers.globs.toOwnedSlice(allocator);
    errdefer allocator.free(owned_globs);
    const owned_pre_globs = try buffers.pre_globs.toOwnedSlice(allocator);
    errdefer allocator.free(owned_pre_globs);
    const owned_ignore_files = try buffers.ignore_files.toOwnedSlice(allocator);
    errdefer allocator.free(owned_ignore_files);
    const owned_include_types = try buffers.include_types.toOwnedSlice(allocator);
    errdefer allocator.free(owned_include_types);
    const owned_exclude_types = try buffers.exclude_types.toOwnedSlice(allocator);
    errdefer allocator.free(owned_exclude_types);

    return .{ .run = .{
        .pattern = pattern_info.pattern,
        .owned_pattern = pattern_info.owned_pattern,
        .paths = owned_paths,
        .used_default_path = state.used_default_path,
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
        .show_stats = pattern_info.show_stats,
        .quiet = state.quiet,
        .filename_flag_seen = state.filename_flag_seen,
        .fixed_strings = pattern_info.fixed_strings,
        .list_files = state.list_files,
        .sort_mode = state.sort_mode,
        .sort_reverse = state.sort_reverse,
        .output = state.output,
        .output_format = state.output_format,
        .report_mode = state.report_mode,
    } };
}

fn normalizeState(
    allocator: std.mem.Allocator,
    state: *ParseState,
    buffers: *ParseBuffers,
) !void {
    if (state.unrestricted_level >= 1) state.no_ignore = true;
    if (state.unrestricted_level >= 2) state.include_hidden = true;
    if (state.unrestricted_level >= 3) state.binary_mode = .text;
    if (buffers.paths.items.len == 0) {
        try buffers.paths.append(allocator, ".");
        state.used_default_path = true;
    }
    if (state.output.heading) {
        state.output.with_filename = false;
    }
}

fn validateRunState(
    state: *const ParseState,
    buffers: *const ParseBuffers,
) CliError!void {
    if (state.list_files) {
        if (state.positional_pattern != null or buffers.explicit_patterns.items.len != 0 or state.fixed_strings or state.invert_match or state.search_compressed or
            state.preprocessor != null or state.multiline or state.multiline_dotall or
            state.max_count != null or state.context_before != 0 or state.context_after != 0 or
            state.output_format != .text or state.report_mode != .lines or
            state.output.only_matching or state.output.heading or state.binary_mode != .skip or
            state.case_mode != .sensitive or state.encoding != .auto or
            state.line_number_flag_seen or state.column_number_flag_seen)
        {
            return error.InvalidFlagCombination;
        }
        return;
    }

    if (state.positional_pattern != null and buffers.explicit_patterns.items.len != 0) return error.InvalidFlagCombination;
    if (state.positional_pattern == null and buffers.explicit_patterns.items.len == 0) return error.MissingPattern;
    if (state.preprocessor == null and buffers.pre_globs.items.len != 0) return error.InvalidFlagCombination;
    if (state.multiline_dotall and !state.multiline) return error.InvalidFlagCombination;
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
}

const PatternInfo = struct {
    pattern: []const u8,
    owned_pattern: ?[]u8 = null,
    fixed_strings: bool,
    show_stats: bool,
};

fn buildPatternInfo(
    allocator: std.mem.Allocator,
    state: *const ParseState,
    buffers: *const ParseBuffers,
) !PatternInfo {
    if (state.list_files) {
        return .{
            .pattern = "",
            .fixed_strings = false,
            .show_stats = false,
        };
    }

    if (buffers.explicit_patterns.items.len == 0) {
        if (state.fixed_strings) {
            const escaped = try escapeRegexLiteralAlloc(allocator, state.positional_pattern.?);
            return .{
                .pattern = escaped,
                .owned_pattern = escaped,
                .fixed_strings = false,
                .show_stats = state.show_stats and !isPathOnlyReportMode(state.report_mode),
            };
        }
        return .{
            .pattern = state.positional_pattern.?,
            .fixed_strings = false,
            .show_stats = state.show_stats and !isPathOnlyReportMode(state.report_mode),
        };
    }

    if (buffers.explicit_patterns.items.len == 1 and !state.fixed_strings) {
        return .{
            .pattern = buffers.explicit_patterns.items[0],
            .fixed_strings = false,
            .show_stats = state.show_stats and !isPathOnlyReportMode(state.report_mode),
        };
    }

    const combined = try composeAlternationPatternAlloc(allocator, buffers.explicit_patterns.items, state.fixed_strings);
    return .{
        .pattern = combined,
        .owned_pattern = combined,
        .fixed_strings = false,
        .show_stats = state.show_stats and !isPathOnlyReportMode(state.report_mode),
    };
}

fn composeAlternationPatternAlloc(
    allocator: std.mem.Allocator,
    patterns: []const []const u8,
    fixed_strings: bool,
) ![]u8 {
    var combined: std.ArrayList(u8) = .empty;
    defer combined.deinit(allocator);

    for (patterns, 0..) |pattern, index| {
        if (index != 0) try combined.append(allocator, '|');
        try combined.appendSlice(allocator, "(?:");
        if (fixed_strings) {
            try appendEscapedRegexLiteral(&combined, allocator, pattern);
        } else {
            try combined.appendSlice(allocator, pattern);
        }
        try combined.append(allocator, ')');
    }

    return combined.toOwnedSlice(allocator);
}

fn escapeRegexLiteralAlloc(allocator: std.mem.Allocator, pattern: []const u8) ![]u8 {
    var escaped: std.ArrayList(u8) = .empty;
    defer escaped.deinit(allocator);

    try appendEscapedRegexLiteral(&escaped, allocator, pattern);
    return escaped.toOwnedSlice(allocator);
}

fn appendEscapedRegexLiteral(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    pattern: []const u8,
) !void {
    for (pattern) |byte| {
        switch (byte) {
            '\\', '.', '+', '*', '?', '(', ')', '[', ']', '{', '}', '|', '^', '$' => {
                try out.append(allocator, '\\');
                try out.append(allocator, byte);
            },
            else => try out.append(allocator, byte),
        }
    }
}

fn isPathOnlyReportMode(report_mode: command.ReportMode) bool {
    return switch (report_mode) {
        .files_with_matches, .files_without_match => true,
        .lines, .count => false,
    };
}
