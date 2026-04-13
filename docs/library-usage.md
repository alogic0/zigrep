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

To make `@import("zigrep")` work, your project must add `zigrep` as a Zig
module in its `build.zig`.

Minimal example:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zigrep_mod = b.addModule("zigrep", .{
        .root_source_file = b.path("../zigrep/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "demo",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe.root_module.addImport("zigrep", zigrep_mod);
    b.installArtifact(exe);
}
```

After that, your Zig source can import `zigrep` normally:

At the top level:

```zig
const std = @import("std");
const zigrep = @import("zigrep");
```

Practical note:

- your build must define a module named `zigrep`
- the most reliable setup today is to use `src/root.zig` as the module root
- if you want dependency management instead of a raw path, package or vendor
  `zigrep` and expose that same root module through your own build graph

## Importing `zigrep` With `build.zig.zon`

If you want to manage `zigrep` as a Zig dependency, add it in
`build.zig.zon` and then expose its module from `build.zig`.

Example `build.zig.zon` shape:

```zig
.{
    .name = "demo",
    .version = "0.0.0",
    .dependencies = .{
        .zigrep = .{
            .path = "../zigrep",
        },
    },
}
```

Then in `build.zig`:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zigrep_dep = b.dependency("zigrep", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "demo",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe.root_module.addImport("zigrep", zigrep_dep.module("zigrep"));
    b.installArtifact(exe);
}
```

This gives you the same source-level usage:

```zig
const zigrep = @import("zigrep");
```

Practical note:

- this assumes the `zigrep` package exposes a module named `zigrep`
- if you vendor or rename the dependency, keep the imported module name as
  `zigrep` on your side for the examples in this document
- if the package layout changes later, the dependency wiring may need to be
  adjusted even if the source-level API stays the same

## Importing `zigrep` From The Git Repository

With Zig 0.15.2, the simplest way to add the GitHub repository as a dependency
is to let `zig fetch` update `build.zig.zon` for you:

```bash
zig fetch --save=zigrep git+https://github.com/alogic0/zigrep.git
```

Exact requirement:

- run this inside a real Zig project
- Zig 0.15.2 expects:
  - a `build.zig`
  - a valid `build.zig.zon`
  - a top-level `.paths` field in `build.zig.zon`

Minimal manifest shape before running `zig fetch --save`:

```zig
.{
    .name = "demo",
    .version = "0.0.0",
    .paths = .{
        "build.zig",
        "build.zig.zon",
    },
}
```

That command:

- downloads the package into Zig's global cache
- computes the package hash
- adds the dependency entry to `build.zig.zon`

Generated entry shape:

```zig
.dependencies = .{
    .zigrep = .{
        .url = "git+https://github.com/alogic0/zigrep.git#<commit>",
        .hash = "zigrep-<package-hash>",
    },
},
```

After that, wire the dependency into your `build.zig` the same way:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zigrep_dep = b.dependency("zigrep", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "demo",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe.root_module.addImport("zigrep", zigrep_dep.module("zigrep"));
    b.installArtifact(exe);
}
```

Practical note:

- `zig fetch --save` is better than hand-writing the hash because Zig computes
  the correct dependency entry for you
- in a verified Zig 0.15.2 test, Zig rewrote the Git URL to an exact
  commit-pinned URL and added the computed package hash automatically
- if you want the dependency URL stored verbatim, Zig also supports
  `zig fetch --save-exact=zigrep ...`
- if you specifically need a branch, tag, or commit, fetch the exact Git URL
  you want Zig to record before wiring it in `build.zig`

## Simplest Regex Match

This is the smallest useful example:

```zig
const std = @import("std");
const zigrep = @import("zigrep");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var re = try zigrep.regex.compileRe(allocator, "needle", .{});
    defer re.deinit();

    const matched = try re.isMatch("haystack with needle inside");
    std.debug.print("matched={}\n", .{matched});
}
```

What happens here:

- `zigrep.regex.compileRe(...)` parses the pattern, lowers it, compiles it,
  and returns one reusable compiled regex object
- `re.isMatch(...)` runs that compiled regex on text

## Getting The First Match Span

If you need the first match location:

```zig
const std = @import("std");
const zigrep = @import("zigrep");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const haystack = "abc needle xyz";

    var re = try zigrep.regex.compileRe(allocator, "needle", .{});
    defer re.deinit();

    const maybe_match = try re.firstMatch(haystack);
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

    var re = try zigrep.regex.compileRe(
        allocator,
        "([a-z][a-z][a-z])-([0-9][0-9][0-9])",
        .{},
    );
    defer re.deinit();

    const maybe_match = try re.firstMatch(haystack);
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

If your pattern can match across newlines, pass multiline options to
`compileRe(...)`:

```zig
const std = @import("std");
const zigrep = @import("zigrep");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const haystack = "first line\nsecond line\n";

    var re = try zigrep.regex.compileRe(allocator, "first.*second", .{
        .multiline = true,
        .multiline_dotall = true,
    });
    defer re.deinit();

    const matched = try re.isMatch(haystack);
    std.debug.print("matched={}\n", .{matched});
}
```

## Unicode-Aware Matching

Unicode-aware shorthand and property matching work through the same regex path:

```zig
const std = @import("std");
const zigrep = @import("zigrep");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var re = try zigrep.regex.compileRe(allocator, "\\p{Greek}+\\d", .{});
    defer re.deinit();

    try std.debug.print("{}\n", .{
        try re.isMatch("αβγ1"),
    });
}
```

## Lower-Level Pipeline

If you need direct access to the engine pipeline, the lower-level path is still
available:

- `zigrep.compile(...)` for HIR lowering
- `zigrep.regex.Nfa.compile(...)` for executable program compilation
- `zigrep.regex.Vm.MatchEngine` for direct execution

That path is useful if you specifically need to work with:

- HIR values
- executable programs
- direct VM usage

But it is no longer the recommended first example for ordinary embedding.

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

- `zigrep.regex.compileRe(...)`
- and the `Compiled` wrapper methods like:
  - `isMatch(...)`
  - `firstMatch(...)`
  - `firstMatchBytes(...)`

and avoid building new code on top of:

- `zigrep.search_reporting`
