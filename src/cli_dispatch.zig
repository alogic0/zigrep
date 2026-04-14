const std = @import("std");
const command = @import("command.zig");
const search = @import("search/root.zig");
const runner = @import("search_runner.zig");

// Execution of parsed CLI command variants.
// This keeps command dispatch separate from parsing and from process-level
// entrypoint concerns.

pub const CliOptions = command.CliOptions;

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

pub fn deinitParseResult(parsed: ParseResult, allocator: std.mem.Allocator) void {
    switch (parsed) {
        .run => |opts| opts.deinit(allocator),
        .type_list => |opts| opts.deinit(allocator),
        .help, .version => {},
    }
}

pub fn executeParsedCommand(
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    parsed: ParseResult,
    stdin_bytes: ?[]const u8,
) !u8 {
    return switch (parsed) {
        .type_list => |opts| blk: {
            const matcher = try search.types.init(allocator, opts.type_adds);
            defer matcher.deinit(allocator);
            try search.types.writeTypeList(stdout, matcher);
            break :blk 0;
        },
        .run => |opts| if (stdin_bytes != null and opts.used_default_path) blk: {
            if (opts.list_files) break :blk error.InvalidFlagCombination;
            break :blk runner.runStdinSearch(allocator, stdout, stderr, opts, stdin_bytes.?);
        } else if (opts.list_files)
            runner.runFileList(allocator, stdout, stderr, opts)
        else
            runner.runSearch(allocator, stdout, stderr, opts),
        .help, .version => unreachable,
    };
}
