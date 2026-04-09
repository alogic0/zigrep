const std = @import("std");

pub const Plan = struct {
    parallel: bool,
    worker_count: usize,
    chunk_size: usize,
};

pub const Options = struct {
    requested_jobs: ?usize = null,
    serial_threshold: usize = 2,
    max_chunk_size: usize = 32,
};

pub fn plan(entry_count: usize, options: Options) Plan {
    if (entry_count == 0) {
        return .{
            .parallel = false,
            .worker_count = 1,
            .chunk_size = 1,
        };
    }

    const available_jobs = options.requested_jobs orelse (std.Thread.getCpuCount() catch 1);
    const worker_count = @max(@min(available_jobs, entry_count), 1);

    if (entry_count < options.serial_threshold or worker_count <= 1) {
        return .{
            .parallel = false,
            .worker_count = 1,
            .chunk_size = 1,
        };
    }

    const target_chunks = worker_count * 4;
    const raw_chunk_size = std.math.divCeil(usize, entry_count, target_chunks) catch 1;
    return .{
        .parallel = true,
        .worker_count = worker_count,
        .chunk_size = std.math.clamp(raw_chunk_size, 1, options.max_chunk_size),
    };
}

test "scheduler stays serial for small workloads" {
    const testing = std.testing;

    const single = plan(1, .{ .requested_jobs = 8 });
    try testing.expect(!single.parallel);
    try testing.expectEqual(@as(usize, 1), single.worker_count);
    try testing.expectEqual(@as(usize, 1), single.chunk_size);

    const below_threshold = plan(2, .{
        .requested_jobs = 8,
        .serial_threshold = 3,
    });
    try testing.expect(!below_threshold.parallel);
}

test "scheduler bounds worker count and chooses chunk size" {
    const testing = std.testing;

    const scheduled = plan(100, .{
        .requested_jobs = 6,
        .max_chunk_size = 10,
    });

    try testing.expect(scheduled.parallel);
    try testing.expectEqual(@as(usize, 6), scheduled.worker_count);
    try testing.expectEqual(@as(usize, 5), scheduled.chunk_size);

    const capped = plan(1000, .{
        .requested_jobs = 8,
        .max_chunk_size = 7,
    });
    try testing.expectEqual(@as(usize, 7), capped.chunk_size);
}
