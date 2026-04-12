const std = @import("std");

pub const max_config_bytes: usize = 64 * 1024;

pub const ResolvedArgs = struct {
    argv: []const []const u8,
    argv_storage: []const []const u8,
    config_buffer: ?[]u8 = null,
    env_config_path: ?[]u8 = null,

    pub fn deinit(self: ResolvedArgs, allocator: std.mem.Allocator) void {
        allocator.free(self.argv_storage);
        if (self.config_buffer) |buffer| allocator.free(buffer);
        if (self.env_config_path) |path| allocator.free(path);
    }
};

pub fn resolveArgs(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
) (std.mem.Allocator.Error || std.process.GetEnvVarOwnedError || std.fs.File.OpenError || std.fs.File.ReadError || error{MissingFlagValue})!ResolvedArgs {
    var passthrough: std.ArrayList([]const u8) = .empty;
    defer passthrough.deinit(allocator);

    try passthrough.append(allocator, argv[0]);

    var no_config = false;
    var explicit_config_path: ?[]const u8 = null;
    var stop_parsing_flags = false;
    var pattern_started = false;

    var index: usize = 1;
    while (index < argv.len) : (index += 1) {
        const arg = argv[index];
        if (!stop_parsing_flags and !pattern_started and std.mem.eql(u8, arg, "--")) {
            stop_parsing_flags = true;
            try passthrough.append(allocator, arg);
            continue;
        }

        if (!stop_parsing_flags and !pattern_started and arg.len > 0 and arg[0] == '-') {
            if (std.mem.eql(u8, arg, "--no-config")) {
                no_config = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--config-path")) {
                index += 1;
                if (index >= argv.len) return error.MissingFlagValue;
                explicit_config_path = argv[index];
                continue;
            }
        }

        if (!pattern_started) pattern_started = true;
        try passthrough.append(allocator, arg);
    }

    if (no_config) {
        const owned = try passthrough.toOwnedSlice(allocator);
        return .{
            .argv = owned,
            .argv_storage = owned,
        };
    }

    var env_config_path: ?[]u8 = null;
    const config_path = if (explicit_config_path) |path|
        path
    else blk: {
        env_config_path = std.process.getEnvVarOwned(allocator, "ZIGREP_CONFIG_PATH") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => null,
            else => return err,
        };
        break :blk if (env_config_path) |path| path else null;
    };

    if (config_path == null) {
        const owned = try passthrough.toOwnedSlice(allocator);
        return .{
            .argv = owned,
            .argv_storage = owned,
            .env_config_path = env_config_path,
        };
    }

    const config_buffer = try std.fs.cwd().readFileAlloc(allocator, config_path.?, max_config_bytes);
    errdefer allocator.free(config_buffer);

    var config_args: std.ArrayList([]const u8) = .empty;
    defer config_args.deinit(allocator);

    var lines = std.mem.splitScalar(u8, config_buffer, '\n');
    while (lines.next()) |raw_line| {
        const trimmed = std.mem.trim(u8, raw_line, " \t\r");
        if (trimmed.len == 0) continue;
        if (trimmed[0] == '#') continue;
        try config_args.append(allocator, trimmed);
    }

    const combined = try allocator.alloc([]const u8, 1 + config_args.items.len + passthrough.items.len - 1);
    combined[0] = passthrough.items[0];
    @memcpy(combined[1 .. 1 + config_args.items.len], config_args.items);
    @memcpy(combined[1 + config_args.items.len ..], passthrough.items[1..]);

    return .{
        .argv = combined,
        .argv_storage = combined,
        .config_buffer = config_buffer,
        .env_config_path = env_config_path,
    };
}

test "resolveArgs prepends config args before CLI args" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "zigrep.conf",
        .data =
            "# comment\n" ++
            "--count\n" ++
            "--ignore-case\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);
    const config_path = try std.fs.path.join(testing.allocator, &.{ root_path, "zigrep.conf" });
    defer testing.allocator.free(config_path);

    const resolved = try resolveArgs(testing.allocator, &.{
        "zigrep",
        "--config-path",
        config_path,
        "needle",
        "src",
    });
    defer resolved.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 5), resolved.argv.len);
    try testing.expectEqualStrings("zigrep", resolved.argv[0]);
    try testing.expectEqualStrings("--count", resolved.argv[1]);
    try testing.expectEqualStrings("--ignore-case", resolved.argv[2]);
    try testing.expectEqualStrings("needle", resolved.argv[3]);
    try testing.expectEqualStrings("src", resolved.argv[4]);
}

test "resolveArgs honors no-config over explicit config path" {
    const testing = std.testing;

    const resolved = try resolveArgs(testing.allocator, &.{
        "zigrep",
        "--config-path",
        "ignored.conf",
        "--no-config",
        "needle",
    });
    defer resolved.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), resolved.argv.len);
    try testing.expectEqualStrings("zigrep", resolved.argv[0]);
    try testing.expectEqualStrings("needle", resolved.argv[1]);
}

