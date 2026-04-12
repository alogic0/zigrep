# Raw-Byte VM Transition Plan

This plan covers the remaining work needed to remove the current lossy `?`
fallback for invalid UTF-8 input and replace it with a general byte-oriented
matcher path.

## Goal

- [ ] Remove `sanitizeInvalidUtf8Lossy(...)` from [src/main.zig](/home/oleg/prog/zigrep/src/main.zig)
- [ ] Stop using the lossy shadow haystack for any regex shape
- [ ] Keep reported output based on the original file bytes
- [ ] Preserve current line/column and capture reporting behavior

## Phase 1: Inventory The Remaining Planner Gaps

- [x] Add a focused test matrix for patterns that still return `hasBytePlan() == false`
- [x] Group those failures by HIR shape instead of by individual pattern strings
- [x] Document the unsupported shapes in this file
- [x] Identify which unsupported shapes are structural planner limits versus true matcher-semantic gaps

### Current Unsupported Planner Shapes

The current `hasBytePlan() == false` boundary is now pinned down by tests in
[src/search/grep.zig](/home/oleg/prog/zigrep/src/search/grep.zig).

Current unsupported shapes:

- Interior anchor nodes inside a concatenation, such as `a^b` or `a$b`
- Quantified bare anchors, such as `^+`
- Plain grouped concatenations embedded inside a larger sequence, such as `x(ab)y`
- Plain grouped multi-term sequences embedded inside a larger sequence, such as `x(a.[0-9]b)y`
- Grouped anchored concatenations embedded inside a larger sequence, such as `x(^ab)y`

Current classification:

- Structural planner limits:
  - interior anchors inside term streams
  - plain grouped subpatterns inside a larger sequence when the group child is a concat-shaped byte pattern rather than an alternation term or a directly appendable node
- Matcher-semantic gaps:
  - quantified bare anchors, because the planner does not currently define repetition semantics for zero-width anchor atoms

## Phase 2: Define Engine-Level Raw-Byte Semantics

- [ ] Define how literals behave on raw bytes
- [ ] Define how `.` behaves on raw bytes
- [ ] Define how ASCII classes behave on raw bytes
- [ ] Define how UTF-8 literal and range classes behave on malformed input
- [ ] Define how negated UTF-8 classes behave when the next byte is not a valid scalar start
- [ ] Define anchor behavior on raw bytes
- [ ] Define capture-span behavior on raw bytes
- [ ] Write those rules into [docs/invalid-utf8-semantics.md](/home/oleg/prog/zigrep/docs/invalid-utf8-semantics.md) as the target semantics, not as a temporary fallback contract

## Phase 3: Introduce A General Raw-Byte Execution Path

- [ ] Decide whether to extend the current NFA/VM or add a dedicated byte-oriented VM layer
- [ ] Reuse existing HIR lowering where possible instead of creating another ad hoc planner surface
- [ ] Add a byte-oriented execution path that can handle all existing HIR node kinds
- [ ] Support concatenation, alternation, anchors, repetition, and groups in the raw-byte engine
- [ ] Support captures in the raw-byte engine
- [ ] Keep newline behavior aligned with the current regex engine

## Phase 4: Replace Planner-Only Invalid-UTF-8 Matching

- [ ] Route invalid-UTF-8 matching through the general raw-byte engine instead of the current planner/fallback split
- [ ] Keep the current planner only if it remains useful as an optimization, not as a correctness boundary
- [ ] Make default mode and `--text` differ only by file-selection policy, not by core invalid-UTF-8 matching capability
- [ ] Remove the remaining cases where invalid UTF-8 silently degrades to lossy shadow matching

## Phase 5: Remove The Lossy Fallback

- [ ] Delete `sanitizeInvalidUtf8Lossy(...)`
- [ ] Remove the `allow_lossy_invalid_utf8` control flow from [src/main.zig](/home/oleg/prog/zigrep/src/main.zig)
- [ ] Remove lossy-fallback-only tests and replace them with raw-byte engine expectations
- [ ] Update docs to remove temporary lossy-fallback wording

## Testing

- [ ] Add matcher tests covering every HIR node kind on invalid UTF-8 input
- [ ] Add end-to-end CLI tests for default mode on text-like invalid UTF-8 files
- [ ] Add end-to-end CLI tests for `--text` on binary-like invalid UTF-8 files
- [ ] Add regression tests for captures on invalid UTF-8 input
- [ ] Add equivalence tests showing planner-covered patterns and general raw-byte engine patterns report the same spans
- [ ] Run `zig build test`

## Cleanup

- [ ] Update [docs/supported-syntax.md](/home/oleg/prog/zigrep/docs/supported-syntax.md) to describe the final invalid-UTF-8 behavior
- [ ] Update [README.md](/home/oleg/prog/zigrep/README.md) with the user-visible invalid-UTF-8 behavior
- [ ] Update [docs/idiomatic-zig-remediation-plan.md](/home/oleg/prog/zigrep/docs/idiomatic-zig-remediation-plan.md) when the lossy fallback is fully removed
- [ ] Run `zig build bench` and compare invalid-UTF-8 search behavior before and after

## Recommended Order

- [ ] Finish the unsupported-shape inventory first
- [ ] Freeze the intended raw-byte semantics before changing the engine
- [ ] Build the general raw-byte execution path before deleting planner code
- [ ] Remove the lossy fallback only after test coverage proves the raw-byte engine covers the old fallback cases
