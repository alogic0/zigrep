const std = @import("std");
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
pub const ParseDiagnostic = parser.ParseDiagnostic;

pub const hir = @import("hir.zig");
pub const Hir = hir.Hir;
pub const Literal = @import("literal.zig");
pub const Nfa = @import("nfa.zig");
pub const vm = @import("vm.zig");
pub const Vm = vm;
pub const Dfa = @import("dfa.zig");

pub const CompileOptions = struct {
    multiline: bool = false,
    multiline_dotall: bool = false,
};

pub const Compiled = struct {
    allocator: std.mem.Allocator,
    hir: Hir,
    program: Nfa.Program,
    engine: Vm.MatchEngine,

    pub fn init(allocator: std.mem.Allocator, pattern: []const u8, options: CompileOptions) (ParseError || Nfa.CompileError)!Compiled {
        const compiled_hir = try compile(allocator, pattern, options);
        errdefer compiled_hir.deinit(allocator);

        const program = try Nfa.compile(allocator, compiled_hir, .{
            .multiline = options.multiline,
            .multiline_dotall = options.multiline_dotall,
        });

        return .{
            .allocator = allocator,
            .hir = compiled_hir,
            .program = program,
            .engine = Vm.MatchEngine.init(allocator),
        };
    }

    pub fn deinit(self: *Compiled) void {
        self.program.deinit(self.allocator);
        self.hir.deinit(self.allocator);
    }

    pub fn isMatch(self: *const Compiled, haystack: []const u8) Vm.MatchError!bool {
        return self.engine.isMatch(self.program, haystack);
    }

    pub fn firstMatch(self: *const Compiled, haystack: []const u8) Vm.MatchError!?Vm.Match {
        return self.engine.firstMatch(self.program, haystack);
    }

    pub fn firstMatchBytes(self: *const Compiled, haystack: []const u8) Vm.MatchError!?Vm.Match {
        return self.engine.firstMatchBytes(self.program, haystack);
    }
};

pub fn compile(allocator: std.mem.Allocator, pattern: []const u8, _: CompileOptions) (ParseError || error{OutOfMemory})!Hir {
    var p = try Parser.init(allocator, pattern);
    const parsed = try p.parse();
    defer parsed.deinit(allocator);
    return hir.lower(allocator, parsed);
}

pub fn compileRe(allocator: std.mem.Allocator, pattern: []const u8, options: CompileOptions) (ParseError || Nfa.CompileError)!Compiled {
    return Compiled.init(allocator, pattern, options);
}

test "Compiled wrapper matches text" {
    const testing = std.testing;

    var compiled = try compileRe(testing.allocator, "needle", .{});
    defer compiled.deinit();

    try testing.expect(try compiled.isMatch("haystack with needle inside"));
    try testing.expect(!(try compiled.isMatch("haystack only")));
}

test "Compiled wrapper exposes captures" {
    const testing = std.testing;

    var compiled = try compileRe(testing.allocator, "([a-z][a-z][a-z])-([0-9][0-9][0-9])", .{});
    defer compiled.deinit();

    const maybe_match = try compiled.firstMatch("abc-123");
    try testing.expect(maybe_match != null);

    const m = maybe_match.?;
    defer m.deinit(testing.allocator);

    try testing.expectEqual(@as(?usize, 0), m.span.start);
    try testing.expectEqual(@as(?usize, 7), m.span.end);
    try testing.expectEqual(@as(usize, 2), m.groups.len);
    try testing.expectEqual(@as(?usize, 0), m.groups[0].start);
    try testing.expectEqual(@as(?usize, 3), m.groups[0].end);
    try testing.expectEqual(@as(?usize, 4), m.groups[1].start);
    try testing.expectEqual(@as(?usize, 7), m.groups[1].end);
}
