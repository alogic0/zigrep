const std = @import("std");
const zigrep = @import("zigrep");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const pattern = "(ab|c)+d?";

    const ast = try zigrep.compile(allocator, pattern, .{});
    defer ast.deinit(allocator);

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.print("pattern: {s}\n", .{pattern});
    try stdout.print("nodes: {d}\n", .{ast.nodes.len});
    try stdout.print("root: {d}\n", .{@intFromEnum(ast.root)});
    try stdout.flush();
}
