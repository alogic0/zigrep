# ripgrep-Style Binary and Encoding Plan

This note captures the fuller future work needed to make `zigrep` behave more
like `rg` around binary files, text mode, and encodings. The current
implementation only takes a minimal practical step: `--text` disables the
binary-file skip and retries invalid UTF-8 files through a lossy sanitizing
pass.

## Current Gap

Today:

- default mode skips files classified as binary
- `--text` disables that skip
- invalid UTF-8 still does not flow through a real byte-oriented matcher
- the current fallback replaces invalid bytes with `?` and then re-runs the
  existing UTF-8 matcher

That is useful, but it is not the same behavior as ripgrep.

## Target Behavior

Aim for a search model closer to `rg`:

- default mode uses binary-file detection and avoids noisy binary output
- `--text` treats files as searchable text even when they contain binary bytes
- `--binary` is added as a separate mode if we want ripgrep-style distinction
- files with invalid UTF-8 do not need to be rewritten into placeholder text
- encoding handling is explicit and user-visible

## Required Work

### 1. Add a true byte-oriented search path

- let the search engine operate on raw file bytes
- keep Unicode-aware regex behavior only where it is well-defined
- make line splitting and reporting work without requiring globally valid UTF-8

### 2. Define invalid UTF-8 semantics

- decide which regex features stay available on raw bytes
- define how `.`, character classes, anchors, and captures behave on invalid
  UTF-8
- make those rules consistent across buffered and mmap-backed reads

### 3. Add encoding detection and transcoding

- detect BOMs
- add UTF-16LE and UTF-16BE decoding
- support an explicit `-E/--encoding` flag
- document supported encodings and failure behavior

### 4. Split binary-policy modes

- keep the current default binary-file heuristic
- keep `--text` as "search this file anyway"
- consider adding `--binary` to align more closely with ripgrep's distinction
  between "search binary carefully" and "treat binary as text"

### 5. Normalize output behavior

- define how match lines are printed when the file is not valid UTF-8
- decide whether output should stay raw, escaped, lossy-decoded, or replaced
- make column and span reporting stable under all supported input modes

### 6. Add parity-oriented tests

- port targeted ripgrep behavior tests for binary/text mode
- add cases for NUL bytes, invalid UTF-8, UTF-16 with BOM, and mixed corpora
- verify consistent behavior between `--buffered` and `--mmap`

## Suggested Implementation Order

1. Add byte-oriented matching and reporting for invalid UTF-8 files.
2. Add BOM detection and UTF-16 decoding.
3. Add `-E/--encoding`.
4. Decide whether to add `--binary`.
5. Expand integration coverage against ripgrep-inspired fixtures.

## Short-Term Position

Until that work is done, the current `--text` behavior should be treated as:

- practical
- intentionally incomplete
- not yet ripgrep-compatible in full
