# zigrep 0.2.0

## Highlights

- Invalid UTF-8 matching now uses the raw-byte matcher path instead of the old lossy `?` fallback.
- The search layer now has a general raw-byte VM fallback, not just planner-based byte fast paths.
- Default mode and `--text` now share the same invalid-UTF-8 matching semantics once a file is searched.
- Invalid bytes and unsafe control bytes continue to print as `\xNN` escapes.

## User-Visible Changes

- More regex shapes now match correctly in files that contain invalid UTF-8 bytes.
- Public search-layer behavior is now aligned with CLI behavior on invalid UTF-8 input.
- Planner fast paths still exist, but correctness no longer depends on planner coverage.

## Verification

- `zig build test`
- `zig build bench`
