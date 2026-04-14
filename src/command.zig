const std = @import("std");
const search = @import("search/root.zig");

pub const OutputOptions = struct {
    with_filename: bool = true,
    line_number: bool = true,
    column_number: bool = true,
    only_matching: bool = false,
    null_path_terminator: bool = false,
    heading: bool = false,
};

pub const OutputFormat = enum {
    text,
    json,
};

pub const BinaryMode = enum {
    skip,
    text,
    suppress,
};

pub const ReportMode = enum {
    lines,
    count,
    files_with_matches,
    files_without_match,
};

pub const GlobSpec = struct {
    pattern: []const u8,
    case_insensitive: bool = false,
};

pub const CliOptions = struct {
    pattern: []const u8 = "",
    owned_pattern: ?[]u8 = null,
    paths: []const []const u8,
    globs: []const GlobSpec = &.{},
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
    quiet: bool = false,
    fixed_strings: bool = false,
    list_files: bool = false,
    output: OutputOptions = .{},
    output_format: OutputFormat = .text,
    report_mode: ReportMode = .lines,
    buffer_output: bool = false,

    pub fn deinit(self: CliOptions, allocator: std.mem.Allocator) void {
        if (self.owned_pattern) |pattern| allocator.free(pattern);
        allocator.free(self.paths);
        allocator.free(self.globs);
        allocator.free(self.pre_globs);
        allocator.free(self.ignore_files);
        allocator.free(self.include_types);
        allocator.free(self.exclude_types);
        allocator.free(self.type_adds);
    }
};
