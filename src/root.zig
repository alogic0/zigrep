const std = @import("std");
const regex_mod = @import("regex/root.zig");
const build_options = @import("build_options");

pub const regex = regex_mod;
pub const search = @import("search/root.zig");
pub const search_runner = @import("search_runner.zig");
pub const search_execution = @import("search_execution.zig");
pub const search_output = @import("search_output.zig");
pub const search_filtering = @import("search_filtering.zig");
pub const command = @import("command.zig");
pub const cli = @import("cli.zig");
pub const cli_dispatch = @import("cli_dispatch.zig");
pub const config = @import("config.zig");
pub const app_version = build_options.app_version;

pub fn compile(
    allocator: std.mem.Allocator,
    pattern: []const u8,
) (regex_mod.ParseError || error{OutOfMemory})!regex_mod.Hir {
    return regex_mod.compile(allocator, pattern, .{});
}

test {
    std.testing.refAllDecls(@This());
}
