# Idiomatic Zig Remediation Plan

This plan turns the current remediation priorities into a concrete checklist.
The aim is to improve allocator boundaries, error policy, reporting costs, and
encoding behavior without rewriting the whole architecture around generic
"idiomatic Zig" advice.

## Priority 1: Error Policy Cleanup

- [x] Define a search-layer error policy matrix
- [x] Classify failures into `fatal`, `warn-and-skip`, and `silent policy skip`
- [x] Separate CLI usage errors from runtime search errors in `main`
- [x] Stop printing usage text for non-usage runtime failures
- [x] Decide how permission-denied file and directory errors should be reported
- [x] Make sequential and parallel search paths follow the same skip/fail rules
- [x] Add regression tests for unreadable files and unreadable directories

## Priority 2: Per-File Allocator Boundary Cleanup

- [x] Document allocator lifetimes across process, search, worker, and file scopes
- [x] Identify per-file temporary allocations in the search path
- [x] Add a per-file `ArenaAllocator` in the sequential search path
- [x] Move lossy `--text` sanitizing buffers onto the per-file arena
- [x] Move temporary report-formatting buffers onto the per-file arena where useful
- [x] Evaluate whether parallel workers should use per-file or per-chunk arenas
- [x] Confirm behavior remains unchanged with `zig build test`

## Priority 3: Reporting-Path Allocation Reduction

- [x] Keep `MatchReport` slice-based as the default reporting contract
- [x] Treat `owned_line` as an exceptional fallback path only
- [x] Refactor sequential reporting to write directly to the output writer
- [x] Remove unnecessary formatted-line heap allocations in the sequential path
- [x] Revisit parallel output storage to reduce one-line-per-file heap allocation
- [x] Decide whether parallel mode should store compact report structs or arena-backed output buffers
- [x] Add tests to ensure output ordering remains unchanged

## Priority 4: Line And Report Helper Cleanup

- [x] Extract line/column derivation into a dedicated helper under `src/search/`
- [x] Add tests for empty files
- [x] Add tests for files without trailing newlines
- [x] Add tests for very long lines
- [x] Add tests for matches late in large files
- [x] Evaluate whether line-number derivation needs optional indexing for repeated reports
- [x] Keep mmap and buffered paths aligned in report behavior

## Priority 5: Encoding And Byte-Oriented Search Work

- [x] Keep [docs/rg-binary-encoding-plan.md](/home/oleg/prog/zigrep/docs/rg-binary-encoding-plan.md) as the main long-term roadmap
- [x] Add more regression tests around invalid UTF-8 under default mode and `--text`
- [x] Add more regression tests around binary-file heuristics
- [ ] Design a true byte-oriented search path
- [x] Define regex semantics for invalid UTF-8 input
- [x] Add BOM detection
- [x] Add UTF-16LE and UTF-16BE decoding support
- [x] Add explicit encoding configuration
- [x] Normalize output behavior for non-UTF-8 matches
- [ ] Remove the current lossy `?` fallback once byte-oriented handling replaces it

## Cross-Cutting Deliverables

- [x] Write `docs/tmp/error-policy.md` describing the skip/fail/warn rules
- [x] Add tests proving sequential and parallel search behave the same under error conditions
- [ ] Add tests proving allocator-boundary refactors do not change search output
- [ ] Document any user-visible behavior changes in `README.md` and `docs/supported-syntax.md`
- [ ] Benchmark reporting-path changes with `zig build bench` before and after

## Suggested Execution Order

- [ ] Finish Priority 1 before changing allocator structure
- [ ] Finish Priority 2 before larger reporting-path refactors
- [ ] Finish Priority 3 before deeper encoding work
- [ ] Finish Priority 4 as part of reporting cleanup
- [ ] Treat Priority 5 as a dedicated longer-term track

## Progress Notes

- CLI usage errors and runtime search errors now have separate top-level output behavior.
- File-level read/open failures now use a warn-and-skip policy in both sequential
  and parallel search paths.
- Child-directory traversal failures now use a warn-and-skip policy through the
  walker, while root traversal failures remain fatal.
- Unreadable-file and unreadable-directory regression coverage both exist now.
- Sequential search now uses a per-file arena for file-local temporary
  allocations, including buffered file reads, lossy `--text` sanitizing, and
  temporary formatted output.
- Allocator lifetimes are now called out directly in `src/main.zig` for the
  process, search, worker, and file scopes.
- Parallel workers now use per-file arenas for temporary file-local work while
  keeping ordered output lines on `smp_allocator` until the final flush.
- Sequential reporting now writes directly to the output writer instead of
  allocating an intermediate formatted line buffer.
- Parallel reporting now stores compact report data instead of preformatted
  output strings, and formats only during the ordered flush step.
- `owned_line` is now explicitly documented and regression-tested as a lossy
  fallback-only path rather than a normal reporting mechanism.
- Line and column derivation now lives in `src/search/report.zig` with focused
  edge-case coverage for empty input, missing trailing newlines, long lines,
  and late matches.
- The current line-number path intentionally does not build a line index yet,
  because the CLI still reports only the first match per file.
- Buffered and mmap-backed reads now have explicit report-equivalence coverage.
- Priority 5 regression coverage now pins down the current behavior for invalid
  UTF-8 text-like files and for control-byte-heavy binary heuristics under
  default mode versus `--text`.
- The search I/O layer now has explicit BOM detection for UTF-8, UTF-16LE, and
  UTF-16BE inputs, which gives the later encoding work a concrete entry point.
- UTF-16LE and UTF-16BE BOM files now decode to UTF-8 for matching and are
  treated as text by the current binary detector.
- The CLI now supports `-E/--encoding auto|utf8|utf16le|utf16be`, and forced
  UTF-16 modes bypass the binary-file heuristic so unmarked UTF-16 input can
  still be searched through the current decode-to-UTF-8 path.
- The CLI now escapes invalid bytes and unsafe control bytes in displayed match
  lines, so `--text` output stays readable even when the underlying file bytes
  are not safe to print directly.
- The current invalid-UTF-8 fallback semantics are now documented explicitly,
  including which regex constructs observe the temporary `?` placeholder during
  `--text` matching and how output still maps back to the original bytes.
- `--text` now has a first true byte-oriented path for exact, anchored, and
  simple alternated ASCII literal patterns plus simple ASCII concat sequences
  built from literals, dots, and character classes plus repetition,
  transparent grouping, and grouped alternation over that subset on invalid
  UTF-8 input, which reduces reliance on the lossy retry for the simplest and
  most common search cases.
