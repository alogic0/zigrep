const std = @import("std");

pub const ReadStrategy = enum {
    buffered,
    mmap,
};

pub const BinaryDecision = enum {
    text,
    binary,
};

pub const BinaryOptions = struct {
    sample_limit: usize = 1024,
    control_threshold: usize = 8,
};

pub fn detectBinary(bytes: []const u8, options: BinaryOptions) BinaryDecision {
    const sample_len = @min(bytes.len, options.sample_limit);
    const sample = bytes[0..sample_len];

    var suspicious_controls: usize = 0;
    for (sample) |byte| {
        if (byte == 0) return .binary;
        if (isSuspiciousControl(byte)) {
            suspicious_controls += 1;
            if (suspicious_controls >= options.control_threshold) return .binary;
        }
    }
    return .text;
}

pub fn detectBinaryFile(path: []const u8, options: BinaryOptions) !BinaryDecision {
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const sample_limit = @max(options.sample_limit, 1);
    var buffer = try std.heap.page_allocator.alloc(u8, sample_limit);
    defer std.heap.page_allocator.free(buffer);

    const read_len = try file.readAll(buffer);
    return detectBinary(buffer[0..read_len], options);
}

fn isSuspiciousControl(byte: u8) bool {
    if (byte == '\n' or byte == '\r' or byte == '\t' or byte == '\x0c') return false;
    return byte < 0x20 or byte == 0x7f;
}

test "binary detector treats UTF-8 and plain text as text" {
    const testing = std.testing;

    try testing.expectEqual(BinaryDecision.text, detectBinary("hello world\n", .{}));
    try testing.expectEqual(BinaryDecision.text, detectBinary("emoji © and utf8 Ω", .{}));
}

test "binary detector treats NUL and repeated control bytes as binary" {
    const testing = std.testing;

    try testing.expectEqual(BinaryDecision.binary, detectBinary("abc\x00def", .{}));

    const control_bytes = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 'A' };
    try testing.expectEqual(BinaryDecision.binary, detectBinary(&control_bytes, .{
        .control_threshold = 4,
    }));
}

test "binary detector obeys sampling limits" {
    const testing = std.testing;

    const bytes = "text prefix" ++ [_]u8{ 0 } ++ "ignored suffix";
    try testing.expectEqual(BinaryDecision.text, detectBinary(&bytes, .{
        .sample_limit = 4,
    }));
    try testing.expectEqual(BinaryDecision.binary, detectBinary(&bytes, .{
        .sample_limit = bytes.len,
    }));
}
