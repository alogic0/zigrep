const std = @import("std");
const search = @import("search/root.zig");

pub const OutputOptions = struct {
    with_filename: bool = true,
    line_number: bool = true,
    column_number: bool = true,
    only_matching: bool = false,
    null_path_terminator: bool = false,
    heading: bool = false,
    replacement: ?[]const u8 = null,
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

pub const SortMode = enum {
    none,
    path,
    modified,
    accessed,
    created,
};

pub const GlobSpec = struct {
    pattern: []const u8,
    case_insensitive: bool = false,
};

pub const TraversalOptions = struct {
    paths: []const []const u8,
    used_default_path: bool,
    globs: []const GlobSpec,
    pre_globs: []const []const u8,
    ignore_files: []const []const u8,
    include_types: []const []const u8,
    exclude_types: []const []const u8,
    type_adds: []const []const u8,
    include_hidden: bool,
    follow_symlinks: bool,
    no_ignore: bool,
    no_ignore_vcs: bool,
    no_ignore_parent: bool,
    search_compressed: bool,
    preprocessor: ?[]const u8,
    read_strategy: search.io.ReadStrategy,
    parallel_jobs: ?usize,
    max_depth: ?usize,
    sort_mode: SortMode,
    sort_reverse: bool,
    quiet: bool,
    list_files: bool,
    buffer_output: bool,
};

pub const MatchOptions = struct {
    pattern: []const u8,
    fixed_strings: bool,
    invert_match: bool,
    binary_mode: BinaryMode,
    case_mode: search.grep.CaseMode,
    encoding: search.io.InputEncoding,
    multiline: bool,
    multiline_dotall: bool,
};

pub const ReportExecutionOptions = struct {
    output: OutputOptions,
    output_format: OutputFormat,
    report_mode: ReportMode,
    max_count: ?usize,
    context_before: usize,
    context_after: usize,
    show_stats: bool,
    quiet: bool,
};

pub const ParseHints = struct {
    used_default_path: bool,
    filename_flag_seen: bool,
    line_number_flag_seen: bool,
    column_number_flag_seen: bool,
};

pub const CliOptions = struct {
    pattern: []const u8 = "",
    owned_pattern: ?[]u8 = null,
    paths: []const []const u8,
    used_default_path: bool = false,
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
    filename_flag_seen: bool = false,
    line_number_flag_seen: bool = false,
    column_number_flag_seen: bool = false,
    fixed_strings: bool = false,
    list_files: bool = false,
    sort_mode: SortMode = .none,
    sort_reverse: bool = false,
    output: OutputOptions = .{},
    output_format: OutputFormat = .text,
    report_mode: ReportMode = .lines,
    buffer_output: bool = false,

    pub fn traversal(self: CliOptions) TraversalOptions {
        return .{
            .paths = self.paths,
            .used_default_path = self.used_default_path,
            .globs = self.globs,
            .pre_globs = self.pre_globs,
            .ignore_files = self.ignore_files,
            .include_types = self.include_types,
            .exclude_types = self.exclude_types,
            .type_adds = self.type_adds,
            .include_hidden = self.include_hidden,
            .follow_symlinks = self.follow_symlinks,
            .no_ignore = self.no_ignore,
            .no_ignore_vcs = self.no_ignore_vcs,
            .no_ignore_parent = self.no_ignore_parent,
            .search_compressed = self.search_compressed,
            .preprocessor = self.preprocessor,
            .read_strategy = self.read_strategy,
            .parallel_jobs = self.parallel_jobs,
            .max_depth = self.max_depth,
            .sort_mode = self.sort_mode,
            .sort_reverse = self.sort_reverse,
            .quiet = self.quiet,
            .list_files = self.list_files,
            .buffer_output = self.buffer_output,
        };
    }

    pub fn matcher(self: CliOptions) MatchOptions {
        return .{
            .pattern = self.pattern,
            .fixed_strings = self.fixed_strings,
            .invert_match = self.invert_match,
            .binary_mode = self.binary_mode,
            .case_mode = self.case_mode,
            .encoding = self.encoding,
            .multiline = self.multiline,
            .multiline_dotall = self.multiline_dotall,
        };
    }

    pub fn reporting(self: CliOptions) ReportExecutionOptions {
        return .{
            .output = self.output,
            .output_format = self.output_format,
            .report_mode = self.report_mode,
            .max_count = self.max_count,
            .context_before = self.context_before,
            .context_after = self.context_after,
            .show_stats = self.show_stats,
            .quiet = self.quiet,
        };
    }

    pub fn parseHints(self: CliOptions) ParseHints {
        return .{
            .used_default_path = self.used_default_path,
            .filename_flag_seen = self.filename_flag_seen,
            .line_number_flag_seen = self.line_number_flag_seen,
            .column_number_flag_seen = self.column_number_flag_seen,
        };
    }

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
