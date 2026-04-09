const std = @import("std");

pub const ReaderError = error{
    InvalidUtf8,
};

pub fn CodePointReader(comptime T: type) type {
    return struct {
        const Self = @This();

        buffer: []const T,
        pos: usize = 0,

        pub fn init(buffer: []const T) Self {
            return .{ .buffer = buffer };
        }

        pub fn next(self: *Self) ReaderError!?u32 {
            if (self.pos >= self.buffer.len) return null;

            if (T == u8) {
                const byte = self.buffer[self.pos];
                if (byte < 0x80) {
                    self.pos += 1;
                    return @as(u32, byte);
                }

                const len = std.unicode.utf8ByteSequenceLength(byte) catch return error.InvalidUtf8;
                if (self.pos + len > self.buffer.len) return error.InvalidUtf8;

                const cp = std.unicode.utf8Decode(self.buffer[self.pos .. self.pos + len]) catch return error.InvalidUtf8;
                self.pos += len;
                return cp;
            }

            if (T == u32) {
                const cp = self.buffer[self.pos];
                self.pos += 1;
                return cp;
            }

            @compileError("Unsupported character type. Use u8 or u32.");
        }

        pub fn peek(self: *Self) ReaderError!?u32 {
            const pos = self.pos;
            defer self.pos = pos;
            return self.next();
        }
    };
}

test "CodePointReader decodes UTF-8 and UTF-32 inputs" {
    const expectEqual = std.testing.expectEqual;

    var utf8_reader = CodePointReader(u8).init("A©");
    try expectEqual(@as(?u32, 'A'), try utf8_reader.next());
    try expectEqual(@as(?u32, 0x00A9), try utf8_reader.next());
    try expectEqual(@as(?u32, null), try utf8_reader.next());

    const utf32_input = [_]u32{ 'A', 0x00A9 };
    var utf32_reader = CodePointReader(u32).init(&utf32_input);
    try expectEqual(@as(?u32, 'A'), try utf32_reader.next());
    try expectEqual(@as(?u32, 0x00A9), try utf32_reader.next());
    try expectEqual(@as(?u32, null), try utf32_reader.next());
}
