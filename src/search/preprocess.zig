const std = @import("std");
const glob = @import("glob.zig");

pub const max_output_bytes: usize = 32 * 1024 * 1024;

pub const Error = std.mem.Allocator.Error || error{
    PreprocessorFailed,
    PreprocessorSignaled,
    PreprocessorTooMuchOutput,
    PreprocessorLaunchFailed,
};

pub fn shouldApply(command: ?[]const u8, globs: []const []const u8, path: []const u8) bool {
    if (command == null) return false;
    if (globs.len == 0) return true;
    return glob.allowsPathStrings(globs, path);
}

pub fn runAlloc(
    allocator: std.mem.Allocator,
    command: []const u8,
    path: []const u8,
) (std.process.Child.RunError || Error)![]u8 {
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);

    var iter = std.mem.tokenizeAny(u8, command, " \t");
    while (iter.next()) |part| {
        try argv.append(allocator, part);
    }
    if (argv.items.len == 0) return error.PreprocessorLaunchFailed;
    try argv.append(allocator, path);

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv.items,
        .max_output_bytes = max_output_bytes,
    }) catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied => return error.PreprocessorLaunchFailed,
        error.StdoutStreamTooLong, error.StderrStreamTooLong => return error.PreprocessorTooMuchOutput,
        else => return err,
    };
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| {
            if (code != 0) {
                allocator.free(result.stdout);
                return error.PreprocessorFailed;
            }
        },
        else => {
            allocator.free(result.stdout);
            return error.PreprocessorSignaled;
        },
    }

    return result.stdout;
}

test "shouldApply respects command presence and globs" {
    const testing = std.testing;

    try testing.expect(!shouldApply(null, &.{}, "sample.txt"));
    try testing.expect(shouldApply("cat", &.{}, "sample.txt"));
    try testing.expect(shouldApply("cat", &.{"*.txt"}, "sample.txt"));
    try testing.expect(!shouldApply("cat", &.{"*.txt"}, "sample.bin"));
}
