# Output And Allocation Follow-Ups

This plan captures the parts of the recent critique that still make sense for the current `zigrep` codebase.

It intentionally excludes stylistic or low-signal items such as file-as-struct preferences, generic `comptime` advice, or blanket stack-buffer recommendations.

## Goal

Reduce avoidable runtime overhead in output-heavy and allocation-heavy paths without changing search semantics.

## Tasks

- [x] Benchmark the current stdout write path on high-match workloads.
  Measure sequential and parallel runs with many emitted lines to determine whether output syscalls are a real bottleneck.
  Baseline rows were added to `zig build bench` as `output,high_match_seq` and `output,high_match_parallel`.

- [x] Add an optional buffered stdout path in the CLI.
  Implement a `BufferedWriter`-backed output mode inside `runCli` / `runSearch` and keep behavior identical to the current writer path.

- [x] Compare buffered vs unbuffered output with `zig build bench` or a dedicated output benchmark.
  Keep the buffered path only if it produces a meaningful improvement on realistic workloads.
  The buffered path improved the added high-match benchmark rows in both sequential and parallel modes.

- [x] Audit temporary string and buffer allocations in the reporting path.
  Identify where `formatReport`, captured parallel output, decoded text buffers, or line ownership still allocate more than necessary.
  The current audit is summarized in [output-allocation-notes.md](../output-allocation-notes.md), and `formatReport` no longer duplicates its formatted buffer.

- [x] Separate required allocations from convenience allocations in the current search/output path.
  Document which allocations are structurally required for correctness or lifetime reasons and which ones are candidates for removal.
  The tracked split now lives in [output-allocation-notes.md](../output-allocation-notes.md).

- [ ] Reduce avoidable heap duplication in the parallel output path.
  Check whether the current stored-per-file output chunk can be kept correct while reducing copies or intermediate allocation churn.

- [ ] Audit exceptional `owned_line` cases again after the multi-match change.
  Confirm that `owned_line` is still only used where a report must outlive a transformed or temporary haystack.

- [ ] Re-run allocator-boundary and output-equivalence tests after any allocation changes.
  Preserve identical visible output across:
  sequential vs parallel
  buffered vs mmap
  invalid UTF-8 vs normal UTF-8 inputs

- [ ] Update docs if buffering or allocation behavior changes in a user-visible way.
  Keep README and supported-syntax notes aligned with the actual output path behavior.

## Non-Goals

- [ ] Do not rewrite the search engine around stack buffers or `BoundedArray` by default.
- [ ] Do not treat top-level-vs-struct module style as an engineering task.
- [ ] Do not introduce `comptime`-driven pattern specialization for runtime user patterns.
