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
        .pattern = state.pattern orelse "",
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
        .fixed_strings = state.fixed_strings,
        .list_files = state.list_files,
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
    if (buffers.paths.items.len == 0) try buffers.paths.append(allocator, ".");
    if (state.output.heading) {
        state.output.with_filename = false;
    }
}

fn validateRunState(
    state: *const ParseState,
    buffers: *const ParseBuffers,
) CliError!void {
    if (state.list_files) {
        if (state.pattern != null or state.fixed_strings or state.invert_match or state.search_compressed or
            state.preprocessor != null or state.multiline or state.multiline_dotall or
            state.max_count != null or state.context_before != 0 or state.context_after != 0 or
            state.show_stats or state.output_format != .text or state.report_mode != .lines or
            state.output.only_matching or state.output.heading or state.binary_mode != .skip or
            state.case_mode != .sensitive or state.encoding != .auto)
        {
            return error.InvalidFlagCombination;
        }
        return;
    }

    if (state.pattern == null) return error.MissingPattern;
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
