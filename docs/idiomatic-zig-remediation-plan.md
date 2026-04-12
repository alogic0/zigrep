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
- [~] Treat `owned_line` as an exceptional fallback path only
- [x] Refactor sequential reporting to write directly to the output writer
- [x] Remove unnecessary formatted-line heap allocations in the sequential path
- [ ] Revisit parallel output storage to reduce one-line-per-file heap allocation
- [ ] Decide whether parallel mode should store compact report structs or arena-backed output buffers
- [ ] Add tests to ensure output ordering remains unchanged

## Priority 4: Line And Report Helper Cleanup

- [ ] Extract line/column derivation into a dedicated helper under `src/search/`
- [ ] Add tests for empty files
- [ ] Add tests for files without trailing newlines
- [ ] Add tests for very long lines
- [ ] Add tests for matches late in large files
- [ ] Evaluate whether line-number derivation needs optional indexing for repeated reports
- [ ] Keep mmap and buffered paths aligned in report behavior

## Priority 5: Encoding And Byte-Oriented Search Work

- [ ] Keep [docs/rg-binary-encoding-plan.md](/home/oleg/prog/zigrep/docs/rg-binary-encoding-plan.md) as the main long-term roadmap
- [ ] Add more regression tests around invalid UTF-8 under default mode and `--text`
- [ ] Add more regression tests around binary-file heuristics
- [ ] Design a true byte-oriented search path
- [ ] Define regex semantics for invalid UTF-8 input
- [ ] Add BOM detection
- [ ] Add UTF-16LE and UTF-16BE decoding support
- [ ] Add explicit encoding configuration
- [ ] Normalize output behavior for non-UTF-8 matches
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
