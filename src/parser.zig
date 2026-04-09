const std = @import("std");
const lexer_mod = @import("lexer.zig");

pub const NodeId = enum(u32) {
    _,
};

pub const Quantifier = struct {
    min: u32,
    max: ?u32,
    greedy: bool = true,
};

pub const Node = union(enum) {
    empty,
    literal: u32,
    dot,
    anchor_start,
    anchor_end,
    concat: []const NodeId,
    alternation: []const NodeId,
    repetition: struct {
        child: NodeId,
        quantifier: Quantifier,
    },
};

pub const Ast = struct {
    nodes: []Node,
    root: NodeId,

    pub fn deinit(self: Ast, allocator: std.mem.Allocator) void {
        for (self.nodes) |node| {
            switch (node) {
                .concat => |children| allocator.free(children),
                .alternation => |branches| allocator.free(branches),
                else => {},
            }
        }
        allocator.free(self.nodes);
    }
};

pub const ParseError = lexer_mod.LexError || error{
    OutOfMemory,
    UnexpectedToken,
    UnterminatedGroup,
    TrailingInput,
};

pub const Parser = struct {
    allocator: std.mem.Allocator,
    lexer: lexer_mod.Lexer(u8),
    lookahead: lexer_mod.Token,
    nodes: std.ArrayList(Node),

    pub fn init(allocator: std.mem.Allocator, pattern: []const u8) ParseError!Parser {
        var lex = lexer_mod.Lexer(u8).init(pattern);
        const first = try lex.next();

        return .{
            .allocator = allocator,
            .lexer = lex,
            .lookahead = first,
            .nodes = .empty,
        };
    }

    pub fn parse(self: *Parser) ParseError!Ast {
        defer self.nodes.deinit(self.allocator);

        const root = try self.parseAlternation();
        if (self.lookahead != .eof) return error.TrailingInput;

        return .{
            .nodes = try self.nodes.toOwnedSlice(self.allocator),
            .root = root,
        };
    }

    fn advance(self: *Parser) ParseError!void {
        self.lookahead = try self.lexer.next();
    }

    fn parseAlternation(self: *Parser) ParseError!NodeId {
        var branches: std.ArrayList(NodeId) = .empty;
        defer branches.deinit(self.allocator);

        try branches.append(self.allocator, try self.parseConcatenation());

        while (self.lookahead == .alternation) {
            try self.advance();
            try branches.append(self.allocator, try self.parseConcatenation());
        }

        if (branches.items.len == 1) return branches.items[0];
        return self.push(.{ .alternation = try branches.toOwnedSlice(self.allocator) });
    }

    fn parseConcatenation(self: *Parser) ParseError!NodeId {
        var parts: std.ArrayList(NodeId) = .empty;
        defer parts.deinit(self.allocator);

        while (self.canStartPrimary()) {
            try parts.append(self.allocator, try self.parseQuantified());
        }

        return switch (parts.items.len) {
            0 => self.push(.empty),
            1 => parts.items[0],
            else => self.push(.{ .concat = try parts.toOwnedSlice(self.allocator) }),
        };
    }

    fn parseQuantified(self: *Parser) ParseError!NodeId {
        var node_id = try self.parsePrimary();

        while (true) {
            const quantifier = switch (self.lookahead) {
                .star => Quantifier{ .min = 0, .max = null },
                .plus => Quantifier{ .min = 1, .max = null },
                .question => Quantifier{ .min = 0, .max = 1 },
                else => return node_id,
            };

            try self.advance();
            node_id = try self.push(.{
                .repetition = .{
                    .child = node_id,
                    .quantifier = quantifier,
                },
            });
        }
    }

    fn parsePrimary(self: *Parser) ParseError!NodeId {
        switch (self.lookahead) {
            .literal => |cp| {
                try self.advance();
                return self.push(.{ .literal = cp });
            },
            .dot => {
                try self.advance();
                return self.push(.dot);
            },
            .anchor_start => {
                try self.advance();
                return self.push(.anchor_start);
            },
            .anchor_end => {
                try self.advance();
                return self.push(.anchor_end);
            },
            .l_paren => {
                try self.advance();
                const expr = try self.parseAlternation();
                if (self.lookahead != .r_paren) return error.UnterminatedGroup;
                try self.advance();
                return expr;
            },
            else => return error.UnexpectedToken,
        }
    }

    fn canStartPrimary(self: *const Parser) bool {
        return switch (self.lookahead) {
            .literal, .dot, .anchor_start, .anchor_end, .l_paren => true,
            else => false,
        };
    }

    fn push(self: *Parser, node: Node) !NodeId {
        try self.nodes.append(self.allocator, node);
        return @enumFromInt(self.nodes.items.len - 1);
    }
};

test "Parser builds an AST for grouped alternation and quantifiers" {
    const testing = std.testing;

    var parser = try Parser.init(testing.allocator, "(ab|c)+d?");
    const ast = try parser.parse();
    defer ast.deinit(testing.allocator);

    try testing.expect(ast.nodes.len > 0);
    try testing.expectEqual(.concat, std.meta.activeTag(ast.nodes[@intFromEnum(ast.root)]));

    const root = ast.nodes[@intFromEnum(ast.root)].concat;
    try testing.expectEqual(@as(usize, 2), root.len);

    const repeated = ast.nodes[@intFromEnum(root[0])].repetition;
    try testing.expectEqual(@as(u32, 1), repeated.quantifier.min);
    try testing.expectEqual(@as(?u32, null), repeated.quantifier.max);

    const optional = ast.nodes[@intFromEnum(root[1])].repetition;
    try testing.expectEqual(@as(u32, 0), optional.quantifier.min);
    try testing.expectEqual(@as(?u32, 1), optional.quantifier.max);
}

test "Parser accepts empty alternation branches" {
    const testing = std.testing;

    var parser = try Parser.init(testing.allocator, "a|");
    const ast = try parser.parse();
    defer ast.deinit(testing.allocator);

    try testing.expectEqual(.alternation, std.meta.activeTag(ast.nodes[@intFromEnum(ast.root)]));
    const branches = ast.nodes[@intFromEnum(ast.root)].alternation;
    try testing.expectEqual(@as(usize, 2), branches.len);
    try testing.expectEqual(.empty, std.meta.activeTag(ast.nodes[@intFromEnum(branches[1])]));
}
