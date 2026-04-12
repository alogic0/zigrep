# Output Allocation Notes

This note separates the current search and output allocations into two groups:

- allocations that are structurally required for correctness, lifetime, or the selected I/O mode
- allocations that are mostly convenience costs and remain candidates for further reduction

## Structurally Required Or Currently Justified

- Decoded text buffers from `decodeToUtf8Alloc(...)`
  These are required when the input encoding needs transformation, such as UTF-16 input that must become UTF-8 for the current matcher and reporting path.

- Per-file buffered reads when the selected read strategy is `.buffered`
  These are the expected ownership allocations for buffered file reading.

- `owned_line` for transformed haystacks
  This is still required when a returned `MatchReport` must outlive a temporary decoded buffer.
  In the normal multi-match write path, decoded reports are written while the transformed haystack is still alive, so they do not require `owned_line`.

- Search-engine capture and slot allocations
  These occur inside the matcher, not the report formatter, and are part of the current engine design.

- Parallel-path stored output chunks
  The current parallel path preserves final output order by storing completed per-file output blobs until flush time. That duplication is intentional today even though it may be reducible.

## Convenience Costs And Current Reduction Candidates

- `runCliCaptured(...)` test helper duplication
  The helper duplicates captured stdout and stderr so those buffers outlive the temporary writers. This is fine for tests, but it is not production-path zero-copy.

- `reportFileMatch(...)` helper duplication for transformed haystacks
  This helper still duplicates line bytes to produce a stable single-report object for tests and targeted helper callers. It is not part of the normal multi-match write path.

## Recent Cleanup

- `formatReport(...)` no longer duplicates its formatted buffer after writing into `std.Io.Writer.Allocating`.
  It now transfers ownership of the existing allocation instead of copying it again.

- The parallel worker output path no longer duplicates formatted bytes after capture.
  It now transfers ownership of the worker-local `Writer.Allocating` buffer directly into the stored output slot.

## Practical Conclusion

The current search/output path is tighter than earlier revisions:

- sequential search writes reports directly
- the CLI search path can use internal buffered output without changing visible results
- `formatReport(...)` no longer pays an extra copy

The next worthwhile allocation targets are the helper/test duplication paths rather than the main sequential or parallel formatter paths.
