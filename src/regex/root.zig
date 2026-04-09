const syntax = @import("syntax/root.zig");

pub const reader = syntax.reader;
pub const lexer = syntax.lexer;
pub const parser = syntax.parser;
pub const ast = syntax.ast;
pub const unicode = @import("unicode.zig");

pub const ReaderError = reader.ReaderError;
pub const CodePointReader = reader.CodePointReader;
pub const Token = lexer.Token;
pub const LexError = lexer.LexError;
pub const Parser = parser.Parser;
pub const Ast = parser.Ast;
pub const Node = parser.Node;
pub const NodeId = parser.NodeId;
pub const ParseError = parser.ParseError;

pub const Hir = @import("hir.zig");
pub const Literal = @import("literal.zig");
pub const Nfa = @import("nfa.zig");
pub const Vm = @import("vm.zig");
pub const Dfa = @import("dfa.zig");

pub const CompileOptions = struct {};

pub fn compile(allocator: @import("std").mem.Allocator, pattern: []const u8, _: CompileOptions) ParseError!Ast {
    var p = try Parser.init(allocator, pattern);
    return p.parse();
}
