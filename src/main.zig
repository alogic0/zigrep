const std = @import("std");
const zigrep = @import("zigrep");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const pattern = "(ab|c)+d?";

    const hir = try zigrep.compile(allocator, pattern, .{});
    defer hir.deinit(allocator);

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.print("pattern: {s}\n", .{pattern});
    try stdout.print("nodes: {d}\n", .{hir.nodes.len});
    try stdout.print("root: {d}\n", .{@intFromEnum(hir.root)});
    try stdout.print("prefix: {s}\n", .{hir.prefix.bytes});
    try stdout.flush();
}
