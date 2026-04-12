# zigrep

`zigrep` is a Zig-native grep-style search tool with an automata-friendly regex
engine and a small ripgrep-style CLI.

## Requirements

- Zig 0.15.2 or compatible 0.15.x toolchain

## Build

From the repository root:

```bash
zig build
```

This builds the CLI and installs it under:

```text
zig-out/bin/zigrep
```

## Test

Run the full test suite:

```bash
zig build test
```

Run the benchmark harness:

```bash
zig build bench
```

## Run

Run through the Zig build step:

```bash
zig build run -- PATTERN [PATH...]
```

Examples:

```bash
zig build run -- needle src
zig build run -- --text --no-filename needle .
zig build run -- -j 4 --max-depth 2 needle src docs
```

Run the built binary directly:

```bash
./zig-out/bin/zigrep PATTERN [PATH...]
```

## Install

To build and install into the default local prefix:

```bash
zig build install
```

That places the binary under:

```text
zig-out/bin/zigrep
```

To install into a custom prefix:

```bash
zig build install --prefix /usr/local
```

Then run:

```bash
/usr/local/bin/zigrep PATTERN [PATH...]
```

## Exit Codes

- `0` if at least one match was found
- `1` if no matches were found
- `2` for CLI or runtime errors

## Supported Syntax

Regex and CLI scope are documented in:

- [docs/supported-syntax.md](docs/supported-syntax.md)
- [docs/invalid-utf8-semantics.md](docs/invalid-utf8-semantics.md)

That document also explains the `--buffered` and `--mmap` options in
non-technical terms.

## Invalid UTF-8 Behavior

`zigrep` can search files that contain invalid UTF-8 bytes.

- By default, binary-looking files may still be skipped by heuristic.
- `--text` disables that binary-file skipping and forces the file through the matcher.
- Once a file is searched, invalid UTF-8 is matched against the original file bytes through the raw-byte matcher path.
- Invalid bytes and unsafe control bytes are printed as `\xNN` escapes instead of being written raw to the terminal.

The exact matching rules are documented in
[docs/invalid-utf8-semantics.md](docs/invalid-utf8-semantics.md).

## Project Notes

Almost all parts of this project were developed with AI-assisted code writing and review.
Final design and code decisions remain project-owned.
