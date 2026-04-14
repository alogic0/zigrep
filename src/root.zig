const std = @import("std");
const regex_mod = @import("regex/root.zig");
const build_options = @import("build_options");

// App-facing root surface.
// Internal decomposition modules are intentionally not re-exported here.

pub const regex = regex_mod;
pub const search = @import("search/root.zig");
pub const search_runner = @import("search_runner.zig");
pub const command = @import("command.zig");
pub const cli = @import("cli.zig");
pub const config = @import("config.zig");
pub const app_version = build_options.app_version;

// Narrow internal namespace for owned module sharing across sibling Zig
// modules without promoting those helpers to the normal app-facing root.
pub const internal = struct {
    pub const sort_capability = @import("sort_capability.zig");
};

// Narrow test-only namespace for internal facades that tests need to exercise
// from inside the owned zigrep module graph.
pub const testing = struct {
    pub const search_reporting = @import("search_reporting.zig");
};

pub fn compile(
    allocator: std.mem.Allocator,
    pattern: []const u8,
) (regex_mod.ParseError || error{OutOfMemory})!regex_mod.Hir {
    return regex_mod.compile(allocator, pattern, .{});
}

test {
    std.testing.refAllDecls(@This());
}
