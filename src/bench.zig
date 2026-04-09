const std = @import("std");
const zigrep = @import("zigrep");

const BenchCase = struct {
    name: []const u8,
    pattern: []const u8,
    haystack: []u8,
    iterations: usize,
    captures: bool,
};

const Result = struct {
    ns_total: u64,
    ns_per_iter: u64,
    matched: bool,
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const cases = try buildCases(allocator);
    defer {
        for (cases) |bench_case| allocator.free(bench_case.haystack);
        allocator.free(cases);
    }

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.print("name,iterations,total_ns,ns_per_iter,matched\n", .{});
    for (cases) |bench_case| {
        const result = try runCase(allocator, bench_case);
        try stdout.print("{s},{d},{d},{d},{}\n", .{
            bench_case.name,
            bench_case.iterations,
            result.ns_total,
            result.ns_per_iter,
            result.matched,
        });
    }
    try stdout.flush();
}

fn runCase(allocator: std.mem.Allocator, bench_case: BenchCase) !Result {
    const hir = try zigrep.compile(allocator, bench_case.pattern, .{});
    defer hir.deinit(allocator);

    const program = try zigrep.regex.Nfa.compile(allocator, hir);
    defer program.deinit(allocator);

    var engine = zigrep.regex.Vm.MatchEngine.init(allocator);

    const start = std.time.nanoTimestamp();
    var matched = false;
    var i: usize = 0;
    while (i < bench_case.iterations) : (i += 1) {
        if (bench_case.captures) {
            const found = try engine.firstMatch(program, bench_case.haystack);
            if (found) |match| {
                matched = true;
                match.deinit(allocator);
            } else {
                matched = false;
            }
        } else {
            matched = try engine.isMatch(program, bench_case.haystack);
        }
    }
    const end = std.time.nanoTimestamp();

    const total_ns: u64 = @intCast(end - start);
    return .{
        .ns_total = total_ns,
        .ns_per_iter = total_ns / bench_case.iterations,
        .matched = matched,
    };
}

fn buildCases(allocator: std.mem.Allocator) ![]BenchCase {
    const cases = try allocator.alloc(BenchCase, 3);
    errdefer allocator.free(cases);

    cases[0] = .{
        .name = "prefilter_miss_ascii",
        .pattern = "needle.*suffix",
        .haystack = try buildHaystack(allocator, "abcdefghijklmnoqrstuvwxzy0123456789", 512, ""),
        .iterations = 40,
        .captures = false,
    };
    errdefer allocator.free(cases[0].haystack);

    cases[1] = .{
        .name = "lazy_dfa_ascii_match",
        .pattern = "error:[0-9]+:panic",
        .haystack = try buildHaystack(allocator, "info:123:keep-going\n", 256, "error:42:panic"),
        .iterations = 20,
        .captures = false,
    };
    errdefer allocator.free(cases[1].haystack);

    cases[2] = .{
        .name = "pike_vm_capture_match",
        .pattern = "(user=)([a-z0-9_]+)(.*)(status=)(ok|fail)",
        .haystack = try buildHaystack(allocator, "ts=1 component=auth latency=12\n", 128, "user=alice_42 role=admin status=ok"),
        .iterations = 10,
        .captures = true,
    };
    errdefer allocator.free(cases[2].haystack);

    return cases;
}

fn buildHaystack(allocator: std.mem.Allocator, chunk: []const u8, repeat_count: usize, suffix: []const u8) ![]u8 {
    const total_len = chunk.len * repeat_count + suffix.len;
    const buffer = try allocator.alloc(u8, total_len);

    var offset: usize = 0;
    var i: usize = 0;
    while (i < repeat_count) : (i += 1) {
        @memcpy(buffer[offset .. offset + chunk.len], chunk);
        offset += chunk.len;
    }
    @memcpy(buffer[offset..], suffix);
    return buffer;
}
