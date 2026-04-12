const std = @import("std");

pub const ReadStrategy = enum {
    buffered,
    mmap,
};

pub const InputEncoding = enum {
    auto,
    utf8,
    utf16le,
    utf16be,
};

pub const ReadOptions = struct {
    strategy: ReadStrategy = .buffered,
    buffer_size: usize = 16 * 1024,
};

pub const BinaryDecision = enum {
    text,
    binary,
};

pub const BinaryOptions = struct {
    sample_limit: usize = 1024,
    control_threshold: usize = 8,
};

pub const DecodeError = std.mem.Allocator.Error || error{
    InvalidUtf16Length,
} || std.unicode.Utf16LeToUtf8Error;

pub const Bom = enum {
    none,
    utf8,
    utf16_le,
    utf16_be,
};

pub const OwnedBuffer = struct {
    bytes: []u8,

    pub fn deinit(self: OwnedBuffer, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
    }
};

pub const ReadBuffer = union(enum) {
    owned: OwnedBuffer,
    mapped: struct {
        bytes: []align(std.heap.page_size_min) const u8,
    },

    pub fn bytes(self: ReadBuffer) []const u8 {
        return switch (self) {
            .owned => |buffer| buffer.bytes,
            .mapped => |mapping| mapping.bytes,
        };
    }

    pub fn deinit(self: ReadBuffer, allocator: std.mem.Allocator) void {
        switch (self) {
            .owned => |buffer| buffer.deinit(allocator),
            .mapped => |mapping| std.posix.munmap(mapping.bytes),
        }
    }
};

pub fn readFileOwned(
    allocator: std.mem.Allocator,
    path: []const u8,
    options: ReadOptions,
) !OwnedBuffer {
    const buffer = try readFile(allocator, path, options);
    return switch (buffer) {
        .owned => |owned| owned,
        .mapped => |mapping| .{
            .bytes = try allocator.dupe(u8, mapping.bytes),
        },
    };
}

pub fn readFile(
    allocator: std.mem.Allocator,
    path: []const u8,
    options: ReadOptions,
) !ReadBuffer {
    return switch (options.strategy) {
        .buffered => .{ .owned = try readFileBuffered(allocator, path, options.buffer_size) },
        .mmap => try readFileMapped(allocator, path, options.buffer_size),
    };
}

pub fn detectBinary(bytes: []const u8, options: BinaryOptions) BinaryDecision {
    if (detectBom(bytes) != .none) return .text;

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

pub fn detectBom(bytes: []const u8) Bom {
    if (std.mem.startsWith(u8, bytes, "\xef\xbb\xbf")) return .utf8;
    if (std.mem.startsWith(u8, bytes, "\xff\xfe")) return .utf16_le;
    if (std.mem.startsWith(u8, bytes, "\xfe\xff")) return .utf16_be;
    return .none;
}

pub fn decodeBomToUtf8Alloc(allocator: std.mem.Allocator, bytes: []const u8) DecodeError!?[]u8 {
    return switch (detectBom(bytes)) {
        .utf16_le => try decodeUtf16BomToUtf8Alloc(allocator, bytes, .little),
        .utf16_be => try decodeUtf16BomToUtf8Alloc(allocator, bytes, .big),
        else => null,
    };
}

pub fn decodeToUtf8Alloc(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    encoding: InputEncoding,
) DecodeError!?[]u8 {
    return switch (encoding) {
        .auto => try decodeBomToUtf8Alloc(allocator, bytes),
        .utf8 => null,
        .utf16le => try decodeUtf16ToUtf8Alloc(allocator, bytes, .little),
        .utf16be => try decodeUtf16ToUtf8Alloc(allocator, bytes, .big),
    };
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

fn readFileBuffered(
    allocator: std.mem.Allocator,
    path: []const u8,
    buffer_size: usize,
) !OwnedBuffer {
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const chunk_size = @max(buffer_size, 256);
    const source_buffer = try allocator.alloc(u8, chunk_size);
    defer allocator.free(source_buffer);

    var reader = file.reader(source_buffer);
    const source = &reader.interface;

    var contents: std.ArrayList(u8) = .empty;
    defer contents.deinit(allocator);

    var scratch = try allocator.alloc(u8, chunk_size);
    defer allocator.free(scratch);

    while (true) {
        const read_len = try source.readSliceShort(scratch);
        if (read_len == 0) break;
        try contents.appendSlice(allocator, scratch[0..read_len]);
    }

    return .{ .bytes = try contents.toOwnedSlice(allocator) };
}

fn readFileMapped(
    allocator: std.mem.Allocator,
    path: []const u8,
    buffer_size: usize,
) !ReadBuffer {
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const stat = try file.stat();
    if (stat.kind != .file or stat.size == 0) {
        return .{ .owned = try readFileBuffered(allocator, path, buffer_size) };
    }

    const mapped = try std.posix.mmap(
        null,
        @intCast(stat.size),
        std.posix.PROT.READ,
        .{ .TYPE = .PRIVATE },
        file.handle,
        0,
    );
    return .{ .mapped = .{ .bytes = mapped } };
}

fn isSuspiciousControl(byte: u8) bool {
    if (byte == '\n' or byte == '\r' or byte == '\t' or byte == '\x0c') return false;
    return byte < 0x20 or byte == 0x7f;
}

fn decodeUtf16BomToUtf8Alloc(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    endian: std.builtin.Endian,
) DecodeError![]u8 {
    const body = bytes[2..];
    return decodeUtf16UnitsToUtf8Alloc(allocator, body, endian);
}

fn decodeUtf16ToUtf8Alloc(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    endian: std.builtin.Endian,
) DecodeError![]u8 {
    const body = switch (endian) {
        .little => if (detectBom(bytes) == .utf16_le) bytes[2..] else bytes,
        .big => if (detectBom(bytes) == .utf16_be) bytes[2..] else bytes,
    };
    return decodeUtf16UnitsToUtf8Alloc(allocator, body, endian);
}

fn decodeUtf16UnitsToUtf8Alloc(
    allocator: std.mem.Allocator,
    body: []const u8,
    endian: std.builtin.Endian,
) DecodeError![]u8 {
    if (body.len % 2 != 0) return error.InvalidUtf16Length;

    const unit_count = body.len / 2;
    const units = try allocator.alloc(u16, unit_count);
    defer allocator.free(units);

    for (0..unit_count) |index| {
        const start = index * 2;
        const pair: *const [2]u8 = @ptrCast(body[start .. start + 2].ptr);
        units[index] = std.mem.readInt(u16, pair, endian);
    }

    return try std.unicode.utf16LeToUtf8Alloc(allocator, units);
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

test "binary detector does not treat isolated invalid UTF-8 bytes as binary by themselves" {
    const testing = std.testing;

    try testing.expectEqual(BinaryDecision.text, detectBinary("xx\xffneedleyy", .{}));
}

test "binary detector threshold controls suspicious control-byte classification" {
    const testing = std.testing;

    const bytes = [_]u8{ 1, 2, 3, 'n', 'e', 'e', 'd', 'l', 'e' };
    try testing.expectEqual(BinaryDecision.text, detectBinary(&bytes, .{
        .control_threshold = 4,
    }));
    try testing.expectEqual(BinaryDecision.binary, detectBinary(&bytes, .{
        .control_threshold = 3,
    }));
}

test "BOM detector recognizes common Unicode BOMs" {
    const testing = std.testing;

    try testing.expectEqual(Bom.utf8, detectBom("\xef\xbb\xbfhello"));
    try testing.expectEqual(Bom.utf16_le, detectBom("\xff\xfeh\x00i\x00"));
    try testing.expectEqual(Bom.utf16_be, detectBom("\xfe\xff\x00h\x00i"));
    try testing.expectEqual(Bom.none, detectBom("plain text"));
    try testing.expectEqual(Bom.none, detectBom(""));
}

test "UTF-16 BOM decoder converts UTF-16LE and UTF-16BE inputs to UTF-8" {
    const testing = std.testing;

    const utf16le = "\xff\xfeh\x00i\x00";
    const decoded_le = (try decodeBomToUtf8Alloc(testing.allocator, utf16le)).?;
    defer testing.allocator.free(decoded_le);
    try testing.expectEqualStrings("hi", decoded_le);

    const utf16be = "\xfe\xff\x00h\x00i";
    const decoded_be = (try decodeBomToUtf8Alloc(testing.allocator, utf16be)).?;
    defer testing.allocator.free(decoded_be);
    try testing.expectEqualStrings("hi", decoded_be);

    try testing.expect((try decodeBomToUtf8Alloc(testing.allocator, "plain text")) == null);
}

test "explicit UTF-16 decoder converts BOM and non-BOM inputs to UTF-8" {
    const testing = std.testing;

    const utf16le = "h\x00i\x00";
    const decoded_le = (try decodeToUtf8Alloc(testing.allocator, utf16le, .utf16le)).?;
    defer testing.allocator.free(decoded_le);
    try testing.expectEqualStrings("hi", decoded_le);

    const utf16be = "\x00h\x00i";
    const decoded_be = (try decodeToUtf8Alloc(testing.allocator, utf16be, .utf16be)).?;
    defer testing.allocator.free(decoded_be);
    try testing.expectEqualStrings("hi", decoded_be);

    const utf16le_with_bom = "\xff\xfeh\x00i\x00";
    const decoded_le_bom = (try decodeToUtf8Alloc(testing.allocator, utf16le_with_bom, .utf16le)).?;
    defer testing.allocator.free(decoded_le_bom);
    try testing.expectEqualStrings("hi", decoded_le_bom);

    try testing.expect((try decodeToUtf8Alloc(testing.allocator, "plain text", .utf8)) == null);
}

test "buffered I/O reads whole files into owned buffers" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "sample.txt",
        .data = "line one\nline two\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);
    const file_path = try std.fs.path.join(testing.allocator, &.{ root_path, "sample.txt" });
    defer testing.allocator.free(file_path);

    const buffer = try readFileOwned(testing.allocator, file_path, .{
        .strategy = .buffered,
        .buffer_size = 8,
    });
    defer buffer.deinit(testing.allocator);

    try testing.expectEqualStrings("line one\nline two\n", buffer.bytes);
}

test "mmap strategy exposes mapped bytes for non-empty files" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "mapped.txt",
        .data = "mapped contents\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);
    const file_path = try std.fs.path.join(testing.allocator, &.{ root_path, "mapped.txt" });
    defer testing.allocator.free(file_path);

    const buffer = try readFile(testing.allocator, file_path, .{
        .strategy = .mmap,
    });
    defer buffer.deinit(testing.allocator);

    try testing.expectEqualStrings("mapped contents\n", buffer.bytes());
}

test "mmap strategy falls back for empty files" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "empty.txt",
        .data = "",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);
    const file_path = try std.fs.path.join(testing.allocator, &.{ root_path, "empty.txt" });
    defer testing.allocator.free(file_path);

    const buffer = try readFile(testing.allocator, file_path, .{
        .strategy = .mmap,
    });
    defer buffer.deinit(testing.allocator);

    try testing.expectEqualStrings("", buffer.bytes());
    try testing.expectEqual(.owned, std.meta.activeTag(buffer));
}
