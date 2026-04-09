const std = @import("std");
const zigrep = @import("zigrep");

const SyntheticBenchCase = struct {
    name: []const u8,
    pattern: []const u8,
    haystack: []u8,
    iterations: usize,
    captures: bool,
};

const CorpusBenchCase = struct {
    name: []const u8,
    pattern: []const u8,
    root: []const u8,
    iterations: usize,
    captures: bool,
    parallel_jobs: ?usize = null,
};

const Result = struct {
    ns_total: u64,
    ns_per_iter: u64,
    matched: bool,
    files: usize = 0,
    bytes: usize = 0,
};

const CorpusRunResult = struct {
    matched: bool,
    files: usize,
    bytes: usize,
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const synthetic_cases = try buildSyntheticCases(allocator);
    defer {
        for (synthetic_cases) |bench_case| allocator.free(bench_case.haystack);
        allocator.free(synthetic_cases);
    }

    const corpus_cases = buildCorpusCases();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.print("kind,name,iterations,total_ns,ns_per_iter,matched,files,bytes\n", .{});
    for (synthetic_cases) |bench_case| {
        const result = try runSyntheticCase(allocator, bench_case);
        try stdout.print("synthetic,{s},{d},{d},{d},{},{d},{d}\n", .{
            bench_case.name,
            bench_case.iterations,
            result.ns_total,
            result.ns_per_iter,
            result.matched,
            result.files,
            result.bytes,
        });
    }
    for (corpus_cases) |bench_case| {
        const result = try runCorpusCase(allocator, bench_case);
        try stdout.print("corpus,{s},{d},{d},{d},{},{d},{d}\n", .{
            bench_case.name,
            bench_case.iterations,
            result.ns_total,
            result.ns_per_iter,
            result.matched,
            result.files,
            result.bytes,
        });
    }
    try stdout.flush();
}

fn runSyntheticCase(allocator: std.mem.Allocator, bench_case: SyntheticBenchCase) !Result {
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
        .files = 1,
        .bytes = bench_case.haystack.len,
    };
}

fn runCorpusCase(allocator: std.mem.Allocator, bench_case: CorpusBenchCase) !Result {
    const hir = try zigrep.compile(allocator, bench_case.pattern, .{});
    defer hir.deinit(allocator);

    const program = try zigrep.regex.Nfa.compile(allocator, hir);
    defer program.deinit(allocator);

    const entries = try zigrep.search.walk.collectFiles(allocator, bench_case.root, .{
        .include_hidden = false,
    });
    defer {
        for (entries) |entry| entry.deinit(allocator);
        allocator.free(entries);
    }

    const schedule = zigrep.search.schedule.plan(entries.len, .{
        .requested_jobs = bench_case.parallel_jobs,
    });

    const start = std.time.nanoTimestamp();
    var last_run: CorpusRunResult = .{
        .matched = false,
        .files = 0,
        .bytes = 0,
    };
    var i: usize = 0;
    while (i < bench_case.iterations) : (i += 1) {
        last_run = if (schedule.parallel)
            try runCorpusParallel(entries, program, bench_case.captures)
        else
            try runCorpusSequential(allocator, entries, program, bench_case.captures);
    }
    const end = std.time.nanoTimestamp();

    const total_ns: u64 = @intCast(end - start);
    return .{
        .ns_total = total_ns,
        .ns_per_iter = total_ns / bench_case.iterations,
        .matched = last_run.matched,
        .files = last_run.files,
        .bytes = last_run.bytes,
    };
}

fn runCorpusSequential(
    allocator: std.mem.Allocator,
    entries: []const zigrep.search.walk.Entry,
    program: zigrep.regex.Nfa.Program,
    captures: bool,
) !CorpusRunResult {
    var engine = zigrep.regex.Vm.MatchEngine.init(allocator);
    var matched = false;
    var total_bytes: usize = 0;

    for (entries) |entry| {
        const buffer = try zigrep.search.io.readFile(allocator, entry.path, .{
            .strategy = .mmap,
        });
        defer buffer.deinit(allocator);

        total_bytes += buffer.bytes().len;
        matched = (try matchHaystack(allocator, &engine, program, buffer.bytes(), captures)) or matched;
    }

    return .{
        .matched = matched,
        .files = entries.len,
        .bytes = total_bytes,
    };
}

fn runCorpusParallel(
    entries: []const zigrep.search.walk.Entry,
    program: zigrep.regex.Nfa.Program,
    captures: bool,
) !CorpusRunResult {
    const worker_allocator = std.heap.smp_allocator;
    const schedule = zigrep.search.schedule.plan(entries.len, .{});
    if (!schedule.parallel) {
        return runCorpusSequential(worker_allocator, entries, program, captures);
    }

    const Context = struct {
        entries: []const zigrep.search.walk.Entry,
        program: zigrep.regex.Nfa.Program,
        captures: bool,
        schedule: zigrep.search.schedule.Plan,
        next_index: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
        any_matched: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        total_bytes: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
        first_error: ?anyerror = null,
        error_mutex: std.Thread.Mutex = .{},

        fn setError(self: *@This(), err: anyerror) void {
            self.error_mutex.lock();
            defer self.error_mutex.unlock();
            if (self.first_error == null) self.first_error = err;
        }

        fn runWorker(self: *@This()) void {
            var engine = zigrep.regex.Vm.MatchEngine.init(std.heap.smp_allocator);

            while (true) {
                if (self.first_error != null) return;

                const start = self.next_index.fetchAdd(self.schedule.chunk_size, .monotonic);
                if (start >= self.entries.len) return;

                const end = @min(start + self.schedule.chunk_size, self.entries.len);
                for (start..end) |index| {
                    const entry = self.entries[index];
                    self.processEntry(&engine, entry) catch |err| {
                        self.setError(err);
                        return;
                    };
                }
            }
        }

        fn processEntry(
            self: *@This(),
            engine: *zigrep.regex.Vm.MatchEngine,
            entry: zigrep.search.walk.Entry,
        ) !void {
            const buffer = try zigrep.search.io.readFile(std.heap.smp_allocator, entry.path, .{
                .strategy = .mmap,
            });
            defer buffer.deinit(std.heap.smp_allocator);

            _ = self.total_bytes.fetchAdd(buffer.bytes().len, .monotonic);
            if (try matchHaystack(std.heap.smp_allocator, engine, self.program, buffer.bytes(), self.captures)) {
                self.any_matched.store(true, .monotonic);
            }
        }
    };

    var pool: std.Thread.Pool = undefined;
    try pool.init(.{
        .allocator = worker_allocator,
        .n_jobs = schedule.worker_count,
    });
    defer pool.deinit();

    var wait_group: std.Thread.WaitGroup = .{};
    var context = Context{
        .entries = entries,
        .program = program,
        .captures = captures,
        .schedule = schedule,
    };

    for (0..schedule.worker_count) |_| {
        pool.spawnWg(&wait_group, Context.runWorker, .{&context});
    }
    wait_group.wait();

    if (context.first_error) |err| return err;

    return .{
        .matched = context.any_matched.load(.monotonic),
        .files = entries.len,
        .bytes = context.total_bytes.load(.monotonic),
    };
}

fn matchHaystack(
    allocator: std.mem.Allocator,
    engine: *zigrep.regex.Vm.MatchEngine,
    program: zigrep.regex.Nfa.Program,
    haystack: []const u8,
    captures: bool,
) !bool {
    if (captures) {
        const found = try engine.firstMatch(program, haystack);
        if (found) |match| {
            match.deinit(allocator);
            return true;
        }
        return false;
    }
    return engine.isMatch(program, haystack);
}

fn buildSyntheticCases(allocator: std.mem.Allocator) ![]SyntheticBenchCase {
    const cases = try allocator.alloc(SyntheticBenchCase, 3);
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

fn buildCorpusCases() []const CorpusBenchCase {
    return &.{
        .{
            .name = "repo_src_literal_seq",
            .pattern = "allocator",
            .root = "src",
            .iterations = 8,
            .captures = false,
            .parallel_jobs = 1,
        },
        .{
            .name = "repo_src_literal_parallel",
            .pattern = "allocator",
            .root = "src",
            .iterations = 8,
            .captures = false,
            .parallel_jobs = 4,
        },
        .{
            .name = "repo_docs_regex_seq",
            .pattern = "Completed in the [a-z-]+ pass",
            .root = "docs",
            .iterations = 10,
            .captures = false,
            .parallel_jobs = 1,
        },
        .{
            .name = "repo_src_capture_seq",
            .pattern = "(pub fn )([A-Za-z_]+)",
            .root = "src",
            .iterations = 6,
            .captures = true,
            .parallel_jobs = 1,
        },
    };
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
