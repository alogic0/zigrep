# Zig 0.15.2 Stdlib Reference From This Project

This document collects examples of using Zig 0.15.2 standard library APIs in
`zigrep`.

Rules for this reference:

- each entry highlights a different `std` function or structure
- examples are taken from this repository
- the goal is breadth, not exhaustive coverage of one API

## Build Graph And Modules

### `std.Build`

Where: `build.zig`

Use:

```zig
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
}
```

Why it matters:

- `std.Build` is the entrypoint for Zig's build graph DSL
- this project uses it to define the executable, library module, tests, and
  benchmark targets

### `std.Build.addModule`

Where: `build.zig`

Use:

```zig
const mod = b.addModule("zigrep", .{
    .root_source_file = b.path("src/root.zig"),
    .target = target,
});
```

Why it matters:

- exposes `zigrep` as an importable module
- this is the same mechanism downstream users rely on in their own `build.zig`

### `std.Build.addExecutable`

Where: `build.zig`

Use:

```zig
const exe = b.addExecutable(.{
    .name = "zigrep",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    }),
});
```

Why it matters:

- defines the `zigrep` CLI executable
- also shows how this project wires importable modules into executables

## Memory And Collections

### `std.heap.ArenaAllocator`

Where: `tools/gen_unicode_props.zig`

Use:

```zig
var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
defer arena_state.deinit();
const arena = arena_state.allocator();
```

Why it matters:

- good fit for one-shot tooling
- the Unicode generator allocates many temporary strings and slices, then frees
  everything at once

### `std.heap.page_allocator`

Where: `tools/gen_unicode_props.zig`, `src/search/io.zig`

Use:

```zig
var buffer = try std.heap.page_allocator.alloc(u8, sample_limit);
defer std.heap.page_allocator.free(buffer);
```

Why it matters:

- used for simple page-backed allocations
- useful when a component needs straightforward heap memory without a custom
  allocator setup

### `std.ArrayList`

Where: `tools/gen_unicode_props.zig`, `src/search/io.zig`, `src/search/preprocess.zig`

Use:

```zig
var contents: std.ArrayList(u8) = .empty;
defer contents.deinit(allocator);

try contents.appendSlice(allocator, scratch[0..read_len]);
```

Why it matters:

- this project uses `ArrayList` as the default growable buffer type
- it shows up in parsers, file readers, Unicode table generation, and search
  planning

### `std.StringHashMapUnmanaged`

Where: `src/search/walk.zig`

Use:

```zig
const VisitedDirs = std.StringHashMapUnmanaged(void);
```

Why it matters:

- tracks visited directories during traversal without storing values
- good example of an unmanaged hash map when the surrounding code wants to own
  allocation strategy explicitly

### `std.AutoHashMap`

Where: `src/regex/dfa.zig`

Use:

```zig
.transitions = std.AutoHashMap(u64, u32).init(self.allocator),
```

Why it matters:

- stores DFA transition tables
- good fit when key/value hashing should be handled by the standard library

## Process And CLI

### `std.process.argsAlloc`

Where: `tools/gen_unicode_props.zig`

Use:

```zig
const args = try std.process.argsAlloc(allocator);
```

Why it matters:

- allocates the process argument vector as owned slices
- this project uses it for the Unicode generator's CLI parsing

### `std.process.exit`

Where: `tools/gen_unicode_props.zig`

Use:

```zig
if (args.len == 1 or hasHelpFlag(args[1..])) {
    try writeUsage();
    std.process.exit(0);
}
```

Why it matters:

- exits immediately after printing usage
- useful in small tools that do not need a larger command-dispatch layer

### `std.process.Child.run`

Where: `src/search/preprocess.zig`

Use:

```zig
const result = std.process.Child.run(.{
    .allocator = allocator,
    .argv = argv.items,
    .max_output_bytes = max_output_bytes,
}) catch |err| switch (err) {
    error.FileNotFound, error.AccessDenied => return error.PreprocessorLaunchFailed,
    else => return err,
};
```

Why it matters:

- runs external preprocessors and captures stdout/stderr
- shows how this project wraps child-process failures into domain-specific
  errors

## Filesystem And Paths

### `std.fs.path.join`

Where: `tools/gen_unicode_props.zig`, `src/search/walk.zig`

Use:

```zig
const default_unicode_data = try std.fs.path.join(
    allocator,
    &.{ default_zg_root, "data", "unicode", "UnicodeData.txt" },
);
```

Why it matters:

- builds portable filesystem paths from components
- heavily used in this repo to avoid hand-concatenating path strings

### `std.fs.cwd().access`

Where: `tools/gen_unicode_props.zig`

Use:

```zig
std.fs.cwd().access(path, .{}) catch return error.FileNotFound;
```

Why it matters:

- quick existence/access check
- used here to validate required Unicode input files before generation starts

### `std.fs.cwd().openFile`

Where: `src/search/io.zig`

Use:

```zig
var file = try std.fs.cwd().openFile(path, .{});
defer file.close();
```

Why it matters:

- entrypoint for reading search targets from disk
- reused by binary detection, buffered reads, and mmap-backed reads

### `std.fs.cwd().openDir`

Where: `src/search/walk.zig`

Use:

```zig
var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| {
    warning_handler.warn(dir_path, err);
    return;
};
```

Why it matters:

- opens directories for recursive traversal
- this project uses it together with warning callbacks to skip unreadable
  directories safely

### `std.fs.cwd().realpathAlloc`

Where: `src/search/walk.zig`

Use:

```zig
const canonical = std.fs.cwd().realpathAlloc(allocator, dir_path) catch |err| {
    warning_handler.warn(dir_path, err);
    return;
};
```

Why it matters:

- canonicalizes paths while allocating the result
- used to detect revisited directories and avoid traversal loops

### `std.posix.mmap`

Where: `src/search/io.zig`

Use:

```zig
const mapped = try std.posix.mmap(
    null,
    @intCast(stat.size),
    std.posix.PROT.READ,
    .{ .TYPE = .PRIVATE },
    file.handle,
    0,
);
```

Why it matters:

- memory-maps regular files for the search path
- used when the file is a good candidate for mapped I/O instead of buffered reads

## Text And Parsing

### `std.mem.eql`

Where: `tools/gen_unicode_props.zig`, `src/regex/dfa.zig`

Use:

```zig
if (std.mem.eql(u8, arg, "--zg-root")) {
    // ...
}
```

Why it matters:

- byte-slice equality check
- used all over the codebase for CLI flags, parser checks, and DFA state
  equality

### `std.mem.tokenizeScalar`

Where: `tools/gen_unicode_props.zig`

Use:

```zig
var lines = std.mem.tokenizeScalar(u8, bytes, '\n');
```

Why it matters:

- fast line tokenization without allocating new strings
- used to parse Unicode data files line by line

### `std.mem.tokenizeAny`

Where: `src/search/preprocess.zig`

Use:

```zig
var iter = std.mem.tokenizeAny(u8, command, " \t");
```

Why it matters:

- tokenizes on any character in a delimiter set
- useful here for turning a preprocessor command string into argv parts

### `std.mem.splitScalar`

Where: `tools/gen_unicode_props.zig`

Use:

```zig
var fields = std.mem.splitScalar(u8, line, ';');
```

Why it matters:

- simple field splitting for delimited text
- this project uses it heavily for Unicode property and alias files

### `std.mem.trimRight`

Where: `tools/gen_unicode_props.zig`

Use:

```zig
const line = std.mem.trimRight(u8, line_raw, "\r");
```

Why it matters:

- removes trailing carriage returns from line input
- important when parsing files that may use CRLF line endings

### `std.mem.readInt`

Where: `src/search/io.zig`

Use:

```zig
const pair: *const [2]u8 = @ptrCast(body[start .. start + 2].ptr);
units[index] = std.mem.readInt(u16, pair, endian);
```

Why it matters:

- decodes raw integer values from byte slices with explicit endianness
- used here to turn UTF-16 byte pairs into `u16` code units

### `std.fmt.parseInt`

Where: `tools/gen_unicode_props.zig`

Use:

```zig
const cp = try std.fmt.parseInt(u32, code_field, 16);
```

Why it matters:

- parses numeric text into integers
- essential for Unicode table generation because the source data is mostly
  hex-encoded code points

### `std.fmt.charToDigit`

Where: `src/lexer.zig`

Use:

```zig
const hi_nibble = std.fmt.charToDigit(@as(u8, @intCast(hi)), 16) catch
    return error.InvalidHexEscape;
```

Why it matters:

- converts one digit character into its numeric value
- used in the regex lexer to parse `\x..` and `\u{...}` escapes

## Unicode And Encoding

### `std.unicode.utf8Decode`

Where: `src/search/grep.zig`, `src/regex/unicode.zig`

Use:

```zig
const cp = std.unicode.utf8Decode(pattern[index .. index + width]) catch {
    // ...
};
```

Why it matters:

- turns a UTF-8 byte sequence into a Unicode scalar
- used in search planning and Unicode-aware regex behavior

### `std.unicode.utf8Encode`

Where: `src/search/grep.zig`

Use:

```zig
var buf: [4]u8 = undefined;
const len = std.unicode.utf8Encode(scalar, &buf) catch unreachable;
```

Why it matters:

- converts a Unicode scalar back into UTF-8 bytes
- used when building byte-search plans from Unicode-aware regex pieces

### `std.unicode.utf16LeToUtf8Alloc`

Where: `src/search/io.zig`

Use:

```zig
return try std.unicode.utf16LeToUtf8Alloc(allocator, units);
```

Why it matters:

- converts UTF-16 units into owned UTF-8 text
- this project uses it to support BOM-based UTF-16 decoding before search

### `std.builtin.Endian`

Where: `src/search/io.zig`

Use:

```zig
fn decodeUtf16ToUtf8Alloc(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    endian: std.builtin.Endian,
) DecodeError![]u8
```

Why it matters:

- explicit endian modeling instead of boolean flags
- useful when handling UTF-16LE and UTF-16BE as distinct input formats

## I/O, Compression, And Writers

### `std.Io.Writer.Allocating`

Where: `src/search/io.zig`, `src/search/walk.zig`

Use:

```zig
var output: std.Io.Writer.Allocating = .init(allocator);
defer output.deinit();
```

Why it matters:

- allocating writer that collects output into memory
- used for gzip decompression and for capturing warnings in tests

### `std.compress.flate.Decompress`

Where: `src/search/io.zig`

Use:

```zig
var decompress: std.compress.flate.Decompress = .init(&input, .gzip, &.{});
_ = decompress.reader.streamRemaining(&output.writer) catch
    return error.InvalidCompressedInput;
```

Why it matters:

- handles gzip decompression with standard-library primitives
- this is the basis for the compressed-input read path

## Concurrency, Math, And Algorithms

### `std.Thread.getCpuCount`

Where: `src/search/schedule.zig`

Use:

```zig
const available_jobs = options.requested_jobs orelse
    (std.Thread.getCpuCount() catch 1);
```

Why it matters:

- provides a reasonable worker-count default
- this project uses it to size parallel search scheduling automatically

### `std.math.divCeil`

Where: `src/search/schedule.zig`

Use:

```zig
const raw_chunk_size = std.math.divCeil(
    usize,
    entry_count,
    target_chunks,
) catch 1;
```

Why it matters:

- integer division rounded up
- useful for chunk planning when splitting work across workers

### `std.math.clamp`

Where: `src/search/schedule.zig`

Use:

```zig
.chunk_size = std.math.clamp(raw_chunk_size, 1, options.max_chunk_size),
```

Why it matters:

- bounds a computed value safely
- here it keeps chunk sizes inside scheduling limits

### `std.sort.heap`

Where: `src/regex/dfa.zig`

Use:

```zig
std.sort.heap(nfa.InstPtr, insts, {}, comptime std.sort.asc(nfa.InstPtr));
```

Why it matters:

- sorts DFA state instruction sets into canonical order
- important for deterministic state interning

## Diagnostics And Testing

### `std.debug.print`

Where: `tools/gen_unicode_props.zig`, docs examples

Use:

```zig
std.debug.print("matched={}\n", .{matched});
```

Why it matters:

- lightweight formatted debug output
- this project uses it in tooling and small examples instead of building a
  custom output layer

### `std.debug.assert`

Where: `src/search/grep.zig`

Use:

```zig
std.debug.assert(span.start != null);
std.debug.assert(span.end != null);
```

Why it matters:

- documents invariants in internal logic
- used here to assert assumptions about match spans before formatting them

### `std.meta.activeTag`

Where: `src/regex/nfa.zig`, `src/search/grep.zig`

Use:

```zig
if (std.meta.activeTag(inst) == .split) {
    saw_split = true;
}
```

Why it matters:

- inspects the active tag of tagged unions
- this repo uses it for tests and for decisions over regex instruction types

### `std.testing.tmpDir`

Where: `src/search/walk.zig`, `src/search/io.zig`

Use:

```zig
var tmp = std.testing.tmpDir(.{});
defer tmp.cleanup();
```

Why it matters:

- creates disposable filesystem fixtures for tests
- heavily used here for search, traversal, and file I/O tests

## Practical Reading Guide

If you want to explore these APIs in the codebase, start here:

- build graph and modules:
  - `build.zig`
- Unicode data parsing and CLI-tool style code:
  - `tools/gen_unicode_props.zig`
- file I/O, encoding, and compression:
  - `src/search/io.zig`
- directory traversal and path handling:
  - `src/search/walk.zig`
- process execution:
  - `src/search/preprocess.zig`
- scheduling, concurrency, and numeric helpers:
  - `src/search/schedule.zig`
- maps, sorting, and internal automata:
  - `src/regex/dfa.zig`

This is not a substitute for Zig's official stdlib documentation, but it is a
useful project-local map of how Zig 0.15.2 std APIs are actually used in a real
codebase.
