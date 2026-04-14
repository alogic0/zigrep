const std = @import("std");
const command = @import("command.zig");
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

pub const ParseState = struct {
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
    quiet: bool = false,
    fixed_strings: bool = false,
    list_files: bool = false,
    output: OutputOptions = .{},
    output_format: OutputFormat = .text,
    report_mode: ReportMode = .lines,
    line_number_flag_seen: bool = false,
    column_number_flag_seen: bool = false,
    positional_pattern: ?[]const u8 = null,
    show_type_list: bool = false,
};

pub const ParseBuffers = struct {
    explicit_patterns: std.ArrayList([]const u8) = .empty,
    paths: std.ArrayList([]const u8) = .empty,
    globs: std.ArrayList([]const u8) = .empty,
    pre_globs: std.ArrayList([]const u8) = .empty,
    ignore_files: std.ArrayList([]const u8) = .empty,
    include_types: std.ArrayList([]const u8) = .empty,
    exclude_types: std.ArrayList([]const u8) = .empty,
    type_adds: std.ArrayList([]const u8) = .empty,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.explicit_patterns.deinit(allocator);
        self.paths.deinit(allocator);
        self.globs.deinit(allocator);
        self.pre_globs.deinit(allocator);
        self.ignore_files.deinit(allocator);
        self.include_types.deinit(allocator);
        self.exclude_types.deinit(allocator);
        self.type_adds.deinit(allocator);
    }
};
