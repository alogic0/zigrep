const std = @import("std");

pub const CapturedCliRun = struct {
    exit_code: u8,
    stdout: []u8,
    stderr: []u8,

    pub fn deinit(self: CapturedCliRun, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

pub fn runCliCaptured(
    allocator: std.mem.Allocator,
    run_cli: *const fn (
        allocator: std.mem.Allocator,
        stdout: *std.Io.Writer,
        stderr: *std.Io.Writer,
        argv: []const []const u8,
    ) anyerror!u8,
    argv: []const []const u8,
) !CapturedCliRun {
    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    const exit_code = try run_cli(
        allocator,
        &stdout_capture.writer,
        &stderr_capture.writer,
        argv,
    );

    return .{
        .exit_code = exit_code,
        .stdout = try allocator.dupe(u8, stdout_capture.written()),
        .stderr = try allocator.dupe(u8, stderr_capture.written()),
    };
}
