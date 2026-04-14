const std = @import("std");
const cli_entry = @import("cli_entry");

pub const CapturedCliRun = struct {
    exit_code: u8,
    stdout: []u8,
    stderr: []u8,

    pub fn deinit(self: CapturedCliRun, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

pub fn runCliCapturedWith(
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

pub fn runCliCaptured(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
) !CapturedCliRun {
    const RunCliWithoutInput = struct {
        fn run(
            run_allocator: std.mem.Allocator,
            stdout: *std.Io.Writer,
            stderr: *std.Io.Writer,
            run_argv: []const []const u8,
        ) anyerror!u8 {
            return cli_entry.runCliWithInput(run_allocator, stdout, stderr, run_argv, null);
        }
    };

    return runCliCapturedWith(allocator, RunCliWithoutInput.run, argv);
}

pub fn runCliCapturedWithStdin(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    stdin_bytes: []const u8,
) !CapturedCliRun {
    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    const exit_code = try cli_entry.runCliWithInput(
        allocator,
        &stdout_capture.writer,
        &stderr_capture.writer,
        argv,
        stdin_bytes,
    );

    return .{
        .exit_code = exit_code,
        .stdout = try allocator.dupe(u8, stdout_capture.written()),
        .stderr = try allocator.dupe(u8, stderr_capture.written()),
    };
}
