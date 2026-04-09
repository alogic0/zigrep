const std = @import("std");
const reader = @import("reader.zig");

pub const LexError = reader.ReaderError || error{
    TrailingEscape,
    InvalidHexEscape,
};

pub const Span = struct {
    start: usize,
    end: usize,
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
    l_bracket,
    r_bracket,
    l_brace,
    r_brace,
    star,
    plus,
    question,
    comma,
    hyphen,
};

pub const SpannedToken = struct {
    token: Token,
    span: Span,
};

pub fn Lexer(comptime T: type) type {
    return struct {
        const Self = @This();
        const Input = reader.CodePointReader(T);

        input: Input,
        source_len: usize,

        pub fn init(source: []const T) Self {
            return .{
                .input = Input.init(source),
                .source_len = source.len,
            };
        }

        pub fn next(self: *Self) LexError!Token {
            return (try self.nextSpanned()).token;
        }

        pub fn nextSpanned(self: *Self) LexError!SpannedToken {
            const start = self.input.pos;
            const cp = (try self.input.next()) orelse return .{
                .token = .eof,
                .span = .{ .start = self.source_len, .end = self.source_len },
            };

            const token = switch (cp) {
                '\\' => try self.readEscape(),
                '.' => Token.dot,
                '^' => Token.anchor_start,
                '$' => Token.anchor_end,
                '|' => Token.alternation,
                '(' => Token.l_paren,
                ')' => Token.r_paren,
                '[' => Token.l_bracket,
                ']' => Token.r_bracket,
                '{' => Token.l_brace,
                '}' => Token.r_brace,
                '*' => Token.star,
                '+' => Token.plus,
                '?' => Token.question,
                ',' => Token.comma,
                '-' => Token.hyphen,
                else => Token{ .literal = cp },
            };

            return .{
                .token = token,
                .span = .{ .start = start, .end = self.input.pos },
            };
        }

        fn readEscape(self: *Self) LexError!Token {
            const escaped = (try self.input.next()) orelse return error.TrailingEscape;
            return switch (escaped) {
                'n' => .{ .literal = '\n' },
                'r' => .{ .literal = '\r' },
                't' => .{ .literal = '\t' },
                'f' => .{ .literal = 0x0c },
                'v' => .{ .literal = 0x0b },
                '0' => .{ .literal = 0 },
                'x' => .{ .literal = try self.readHexEscape() },
                else => .{ .literal = escaped },
            };
        }

        fn readHexEscape(self: *Self) LexError!u32 {
            const hi = (try self.input.next()) orelse return error.InvalidHexEscape;
            const lo = (try self.input.next()) orelse return error.InvalidHexEscape;

            const hi_nibble = std.fmt.charToDigit(@as(u8, @intCast(hi)), 16) catch return error.InvalidHexEscape;
            const lo_nibble = std.fmt.charToDigit(@as(u8, @intCast(lo)), 16) catch return error.InvalidHexEscape;
            return (hi_nibble << 4) | lo_nibble;
        }
    };
}

test "Lexer tokenizes core regex operators" {
    const testing = @import("std").testing;
    var lexer = Lexer(u8).init("a(b|c)+d?\\.[x]{2,4}-");

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
    try testing.expectEqualDeep(Token.l_bracket, try lexer.next());
    try testing.expectEqualDeep(Token{ .literal = 'x' }, try lexer.next());
    try testing.expectEqualDeep(Token.r_bracket, try lexer.next());
    try testing.expectEqualDeep(Token.l_brace, try lexer.next());
    try testing.expectEqualDeep(Token{ .literal = '2' }, try lexer.next());
    try testing.expectEqualDeep(Token.comma, try lexer.next());
    try testing.expectEqualDeep(Token{ .literal = '4' }, try lexer.next());
    try testing.expectEqualDeep(Token.r_brace, try lexer.next());
    try testing.expectEqualDeep(Token.hyphen, try lexer.next());
    try testing.expectEqualDeep(Token.eof, try lexer.next());
}

test "Lexer decodes common escapes and tracks spans" {
    const testing = @import("std").testing;

    var lexer = Lexer(u8).init("\\n\\t\\x41");

    const newline = try lexer.nextSpanned();
    try testing.expectEqualDeep(Token{ .literal = '\n' }, newline.token);
    try testing.expectEqualDeep(Span{ .start = 0, .end = 2 }, newline.span);

    const tab = try lexer.nextSpanned();
    try testing.expectEqualDeep(Token{ .literal = '\t' }, tab.token);
    try testing.expectEqualDeep(Span{ .start = 2, .end = 4 }, tab.span);

    const hex = try lexer.nextSpanned();
    try testing.expectEqualDeep(Token{ .literal = 'A' }, hex.token);
    try testing.expectEqualDeep(Span{ .start = 4, .end = 8 }, hex.span);
}
