const std = @import("std");
const regex_mod = @import("regex/root.zig");
const build_options = @import("build_options");

pub const regex = regex_mod;
pub const search = @import("search/root.zig");
pub const search_runner = @import("search_runner.zig");
pub const config = @import("config.zig");
pub const app_version = build_options.app_version;
pub const reader = regex_mod.reader;
pub const decoder = reader;
pub const lexer = regex_mod.lexer;
pub const Parser = regex_mod.Parser;
pub const Ast = regex_mod.Ast;
pub const Hir = regex_mod.Hir;
pub const Node = regex_mod.Node;
pub const NodeId = regex_mod.NodeId;
pub const ParseError = regex_mod.ParseError;
pub const ParseDiagnostic = regex_mod.ParseDiagnostic;

pub const CompileOptions = regex_mod.CompileOptions;

pub fn compile(allocator: std.mem.Allocator, pattern: []const u8, _: CompileOptions) (ParseError || error{OutOfMemory})!Hir {
    return regex_mod.compile(allocator, pattern, .{});
}

test {
    std.testing.refAllDecls(@This());
}
