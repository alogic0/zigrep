const reader = @import("reader.zig");

pub const LexError = reader.ReaderError || error{
    TrailingEscape,
};

pub const Token = union(enum) {
    eof,
    literal: u32,
    dot,
    anchor_start,
    anchor_end,
    alternation,
    l_paren,
    r_paren,
    star,
    plus,
    question,
};

pub fn Lexer(comptime T: type) type {
    return struct {
        const Self = @This();
        const Input = reader.CodePointReader(T);

        input: Input,

        pub fn init(source: []const T) Self {
            return .{ .input = Input.init(source) };
        }

        pub fn next(self: *Self) LexError!Token {
            const cp = (try self.input.next()) orelse return .eof;

            return switch (cp) {
                '\\' => .{ .literal = (try self.input.next()) orelse return error.TrailingEscape },
                '.' => .dot,
                '^' => .anchor_start,
                '$' => .anchor_end,
                '|' => .alternation,
                '(' => .l_paren,
                ')' => .r_paren,
                '*' => .star,
                '+' => .plus,
                '?' => .question,
                else => .{ .literal = cp },
            };
        }
    };
}

test "Lexer tokenizes core regex operators" {
    const testing = @import("std").testing;
    var lexer = Lexer(u8).init("a(b|c)+d?\\.");

    try testing.expectEqualDeep(Token{ .literal = 'a' }, try lexer.next());
    try testing.expectEqualDeep(Token.l_paren, try lexer.next());
    try testing.expectEqualDeep(Token{ .literal = 'b' }, try lexer.next());
    try testing.expectEqualDeep(Token.alternation, try lexer.next());
    try testing.expectEqualDeep(Token{ .literal = 'c' }, try lexer.next());
    try testing.expectEqualDeep(Token.r_paren, try lexer.next());
    try testing.expectEqualDeep(Token.plus, try lexer.next());
    try testing.expectEqualDeep(Token{ .literal = 'd' }, try lexer.next());
    try testing.expectEqualDeep(Token.question, try lexer.next());
    try testing.expectEqualDeep(Token{ .literal = '.' }, try lexer.next());
    try testing.expectEqualDeep(Token.eof, try lexer.next());
}
