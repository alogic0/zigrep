# Manual Test Plan

This document describes how to manually validate `zigrep` and how to report
issues with enough detail to reproduce them.

## 1. Build and Baseline Verification

From the repository root:

```bash
zig build
zig build test
```

Record:

- Zig version
- current commit hash
- whether `zig build test` passed

Useful commands:

```bash
zig version
git rev-parse HEAD
uname -a
```

## 2. CLI Smoke Test

Run:

```bash
./zig-out/bin/zigrep --help
./zig-out/bin/zigrep needle .
echo $?
```

Check:

- help text prints without crashing
- the binary exits with a documented status code
- obvious matches print in the default `path:line:column:text` form

Exit code expectations:

- `0` if at least one match was found
- `1` if no matches were found
- `2` for CLI or runtime errors

## 3. Regex Basics

Create a temporary directory with small text files that cover:

- literals
- alternation with `|`
- grouping and captures with `(...)`
- `.` not matching newline
- anchors `^` and `$`
- quantifiers `*`, `+`, `?`, `{m,n}`
- character classes
- negated character classes
- escaped metacharacters

Suggested fixture:

```text
tmp/
  basics.txt
  multiline.txt
  classes.txt
```

Suggested contents:

```text
basics.txt
abc
abd
zzz

multiline.txt
foo
bar

classes.txt
abc123
XYZ
```

Example commands:

```bash
./zig-out/bin/zigrep 'ab(c|d)' tmp
./zig-out/bin/zigrep '^foo$' tmp
./zig-out/bin/zigrep 'a[0-9]+' tmp
./zig-out/bin/zigrep 'foo.bar' tmp
```

Check that reported lines match expectations and that `foo.bar` does not cross
line breaks.

## 4. Unsupported Syntax Rejection

Try patterns that should be rejected:

```text
(?:x)
(?=x)
(?!x)
\d
\w
\s
\1
```

Example:

```bash
./zig-out/bin/zigrep '(?:x)' tmp
echo $?
```

Check:

- the command fails cleanly
- the error is explicit
- the process does not hang or crash

## 5. File Traversal Behavior

Create a directory tree with:

- nested directories
- hidden files
- symlinks
- more than one depth level

Suggested layout:

```text
tree/
  root.txt
  .hidden.txt
  nested/
    child.txt
    deeper/
      grandchild.txt
```

Run:

```bash
./zig-out/bin/zigrep needle tree
./zig-out/bin/zigrep --hidden needle tree
./zig-out/bin/zigrep --max-depth 1 needle tree
./zig-out/bin/zigrep --follow needle tree
```

Check:

- hidden files are skipped unless `--hidden` is used
- files deeper than `--max-depth` are excluded
- symlink behavior matches `--follow`
- results are not duplicated unexpectedly

## 6. Binary File Handling

Create:

- one normal UTF-8 text file
- one binary file containing NUL bytes and the target literal

Example:

```bash
printf 'hello needle\n' > text.txt
printf 'aa\0needle\0bb' > payload.bin
```

Run:

```bash
./zig-out/bin/zigrep needle .
./zig-out/bin/zigrep --text needle .
```

Check:

- binary files are skipped by default
- binary files are searched with `--text`

## 7. Output Formatting Flags

Run combinations of:

- default output
- `--no-filename`
- `--no-line-number`
- `--no-column`
- `-H`
- `-n`
- `--column`

Examples:

```bash
./zig-out/bin/zigrep needle tmp
./zig-out/bin/zigrep --no-filename needle tmp
./zig-out/bin/zigrep --no-column needle tmp
./zig-out/bin/zigrep --no-filename --no-column needle tmp
```

Check:

- prefixes appear in the expected order
- suppressed prefixes are actually absent
- the line text still prints correctly

## 8. Parallel Consistency

Use a directory with several matching files and compare:

```bash
./zig-out/bin/zigrep -j 1 needle tree
./zig-out/bin/zigrep -j 4 needle tree
```

Check:

- the same files match
- the same lines match
- output ordering remains stable
- no results disappear intermittently

Repeat a few times if needed to catch race-related issues.

## 9. Read Strategy Consistency

Run the same search twice:

```bash
./zig-out/bin/zigrep --mmap needle tree
./zig-out/bin/zigrep --buffered needle tree
```

Check:

- results are identical
- empty files do not crash either mode
- small files behave the same as larger files

## 10. Larger Corpus Sanity Pass

Search this repository itself:

```bash
./zig-out/bin/zigrep allocator src docs
./zig-out/bin/zigrep -j 4 pub src
./zig-out/bin/zigrep --max-depth 3 Completed docs
```

Check:

- the command completes in reasonable time
- output looks stable and correctly formatted
- no hangs, crashes, or memory blowups are observed

## Reporting Errors

For each bug, capture:

- exact command
- expected result
- actual result
- exit code
- stdout and stderr
- minimal file contents needed to reproduce
- commit hash
- Zig version
- OS details

Use this template:

```text
Title: short summary

Environment:
- commit:
- zig version:
- OS:

Command:
<exact command>

Input files:
<minimal file tree and contents>

Expected:
<what should happen>

Actual:
<what happened>

Exit code:
<n>

Output:
<stdout/stderr>

Notes:
<is it reproducible every time? only with -j? only with --mmap?>
```

## Suggested Severity Labels

- `critical`: crash, hang, data loss, or obviously wrong matches on common input
- `high`: incorrect search results or broken CLI behavior in normal usage
- `medium`: formatting bugs, edge-case traversal issues, inconsistent flags
- `low`: doc mismatches, poor error text, minor usability problems
