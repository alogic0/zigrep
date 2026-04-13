# Library Usage

This document shows how to use `zigrep` as a library.

The current intended stable library-facing surface is:

- `zigrep.regex`
- `zigrep.search`

The current intended app-facing execution entrypoint is:

- `zigrep.search_runner.runSearch(...)`

If you want to embed regex compilation and matching in your own Zig code, use
`zigrep.regex`.

## Importing `zigrep`

At the top level:

```zig
const std = @import("std");
const zigrep = @import("zigrep");
```

## Simplest Regex Match

This is the smallest useful example:

```zig
const std = @import("std");
const zigrep = @import("zigrep");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const hir = try zigrep.compile(allocator, "needle");
    defer hir.deinit(allocator);

    const program = try zigrep.regex.Nfa.compile(allocator, hir, .{});
    defer program.deinit(allocator);

    var engine = zigrep.regex.Vm.MatchEngine.init(allocator);

    const matched = try engine.isMatch(program, "haystack with needle inside");
    std.debug.print("matched={}\n", .{matched});
}
```

What happens here:

- `zigrep.compile(...)` parses and lowers the pattern to HIR
- `zigrep.regex.Nfa.compile(...)` compiles the HIR to the executable regex program
- `zigrep.regex.Vm.MatchEngine` runs the program on text

## Getting The First Match Span

If you need the first match location:

```zig
const std = @import("std");
const zigrep = @import("zigrep");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const haystack = "abc needle xyz";

    const hir = try zigrep.compile(allocator, "needle");
    defer hir.deinit(allocator);

    const program = try zigrep.regex.Nfa.compile(allocator, hir, .{});
    defer program.deinit(allocator);

    var engine = zigrep.regex.Vm.MatchEngine.init(allocator);

    const maybe_match = try engine.firstMatch(program, haystack);
    if (maybe_match) |m| {
        defer m.deinit(allocator);
        std.debug.print("match start={?} end={?}\n", .{ m.span.start, m.span.end });
    }
}
```

## Matching With Captures

Capturing groups are available through `firstMatch(...)`:

```zig
const std = @import("std");
const zigrep = @import("zigrep");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const haystack = "abc-123";

    const hir = try zigrep.compile(allocator, "([a-z]+)-([0-9]+)");
    defer hir.deinit(allocator);

    const program = try zigrep.regex.Nfa.compile(allocator, hir, .{});
    defer program.deinit(allocator);

    var engine = zigrep.regex.Vm.MatchEngine.init(allocator);

    const maybe_match = try engine.firstMatch(program, haystack);
    if (maybe_match) |m| {
        defer m.deinit(allocator);

        std.debug.print("full={?}..{?}\n", .{ m.span.start, m.span.end });
        for (m.groups, 0..) |group, index| {
            std.debug.print("group[{d}]={?}..{?}\n", .{ index, group.start, group.end });
        }
    }
}
```

## Multiline Compilation

If your pattern can match across newlines, pass multiline options to the NFA
compiler:

```zig
const std = @import("std");
const zigrep = @import("zigrep");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const haystack = "first line\nsecond line\n";

    const hir = try zigrep.compile(allocator, "first.*second");
    defer hir.deinit(allocator);

    const program = try zigrep.regex.Nfa.compile(allocator, hir, .{
        .multiline = true,
        .multiline_dotall = true,
    });
    defer program.deinit(allocator);

    var engine = zigrep.regex.Vm.MatchEngine.init(allocator);
    const matched = try engine.isMatch(program, haystack);
    std.debug.print("matched={}\n", .{matched});
}
```

Important detail:

- `zigrep.compile(...)` is a convenience wrapper
- multiline behavior is controlled at `zigrep.regex.Nfa.compile(...)`

## Unicode-Aware Matching

Unicode-aware shorthand and property matching work through the same regex path:

```zig
const std = @import("std");
const zigrep = @import("zigrep");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const hir = try zigrep.compile(allocator, "\\p{Greek}+\\d");
    defer hir.deinit(allocator);

    const program = try zigrep.regex.Nfa.compile(allocator, hir, .{});
    defer program.deinit(allocator);

    var engine = zigrep.regex.Vm.MatchEngine.init(allocator);

    try std.debug.print("{}\n", .{
        try engine.isMatch(program, "αβγ1"),
    });
}
```

## When To Use `search_runner`

Use `zigrep.search_runner.runSearch(...)` only if you want app-style search
execution:

- recursive path walking
- ignore rules
- CLI-style output/reporting
- buffered vs mmap read strategy
- threading and search scheduling

Use `zigrep.regex` if you want:

- compile a pattern yourself
- run it on your own in-memory text
- control matching directly without file traversal and reporting

## Current Boundary

Current intended stability:

- stable library-facing:
  - `zigrep.regex`
  - `zigrep.search`
- stable app-facing execution/support:
  - `zigrep.search_runner.runSearch(...)`
  - `zigrep.cli`
  - `zigrep.config`
  - `zigrep.command`
  - `zigrep.app_version`
- unstable compatibility/tooling:
  - `zigrep.search_reporting`

So if you are embedding the regex engine in another program, prefer:

- `zigrep.regex`
- or the top-level convenience wrapper `zigrep.compile(...)`

and avoid building new code on top of:

- `zigrep.search_reporting`
