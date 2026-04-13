const std = @import("std");
const command = @import("command.zig");

const zigrep = struct {
    pub const search = @import("search/root.zig");
};

pub const CliOptions = command.CliOptions;
pub const BinaryMode = command.BinaryMode;

pub fn warnAndSkipFileError(writer: *std.Io.Writer, path: []const u8, err: anyerror) !bool {
    if (!shouldWarnAndSkipFileError(err)) return false;
    try writer.print("warning: skipping {s}: {s}\n", .{ path, warningMessage(err) });
    return true;
}

pub fn warningMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "file not found",
        error.AccessDenied => "access denied",
        error.NotDir => "not a directory",
        error.NameTooLong => "name too long",
        error.SymLinkLoop => "symlink loop",
        error.InvalidCompressedInput => "invalid compressed input",
        error.PreprocessorFailed => "preprocessor exited with non-zero status",
        error.PreprocessorSignaled => "preprocessor terminated by signal",
        error.PreprocessorTooMuchOutput => "preprocessor output exceeded limit",
        else => @errorName(err),
    };
}

pub fn prepareSearchBytes(
    allocator: std.mem.Allocator,
    path: []const u8,
    bytes: []const u8,
    options: CliOptions,
) ![]const u8 {
    if (zigrep.search.preprocess.shouldApply(options.preprocessor, options.pre_globs, path)) {
        return try zigrep.search.preprocess.runAlloc(allocator, options.preprocessor.?, path);
    }
    if (!options.search_compressed) return bytes;
    return if (try zigrep.search.io.decompressAlloc(allocator, bytes)) |decoded| decoded else bytes;
}

pub fn decideBinaryBehavior(
    bytes: []const u8,
    encoding: zigrep.search.io.InputEncoding,
    binary_mode: BinaryMode,
) ?bool {
    if (encoding != .auto) return false;
    return switch (binary_mode) {
        .text => false,
        .skip, .suppress => switch (zigrep.search.io.detectBinary(bytes, .{})) {
            .text => false,
            .binary => if (binary_mode == .skip) null else true,
        },
    };
}

fn shouldWarnAndSkipFileError(err: anyerror) bool {
    return switch (err) {
        error.FileNotFound,
        error.AccessDenied,
        error.NotDir,
        error.NameTooLong,
        error.SymLinkLoop,
        error.InvalidCompressedInput,
        error.PreprocessorFailed,
        error.PreprocessorSignaled,
        error.PreprocessorTooMuchOutput,
        => true,
        else => false,
    };
}
