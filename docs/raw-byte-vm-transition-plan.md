# Raw-Byte VM Transition Plan

This plan covers the remaining work needed to remove the current lossy `?`
fallback for invalid UTF-8 input and replace it with a general byte-oriented
matcher path.

## Goal

- [x] Remove `sanitizeInvalidUtf8Lossy(...)` from [src/main.zig](/home/oleg/prog/zigrep/src/main.zig)
- [x] Stop using the lossy shadow haystack for any regex shape
- [x] Keep reported output based on the original file bytes
- [x] Preserve current line/column and capture reporting behavior

## Phase 1: Inventory The Remaining Planner Gaps

- [x] Add a focused test matrix for patterns that still return `hasBytePlan() == false`
- [x] Group those failures by HIR shape instead of by individual pattern strings
- [x] Document the unsupported shapes in this file
- [x] Identify which unsupported shapes are structural planner limits versus true matcher-semantic gaps

### Initial Inventory Status

The initial `hasBytePlan() == false` inventory is pinned down by tests in
[src/search/grep.zig](/home/oleg/prog/zigrep/src/search/grep.zig), and the
first recorded unsupported shapes have now been closed:

- interior anchors inside concatenations such as `a^b` and `a$b`
- quantified bare anchors such as `^+`
- grouped concatenations inside larger sequences such as `x(ab)y`
- grouped multi-term sequences inside larger sequences such as `x(a.[0-9]b)y`
- grouped anchored concatenations inside larger sequences such as `x(^ab)y`

This means Phase 1 is complete for the initial inventory pass. Any remaining
lossy-fallback cases now need to be discovered by expanding the inventory
matrix again rather than by relying on the original boundary list.

## Phase 2: Define Engine-Level Raw-Byte Semantics

- [x] Define how literals behave on raw bytes
- [x] Define how `.` behaves on raw bytes
- [x] Define how ASCII classes behave on raw bytes
- [x] Define how UTF-8 literal and range classes behave on malformed input
- [x] Define how negated UTF-8 classes behave when the next byte is not a valid scalar start
- [x] Define anchor behavior on raw bytes
- [x] Define capture-span behavior on raw bytes
- [x] Write those rules into [docs/invalid-utf8-semantics.md](/home/oleg/prog/zigrep/docs/invalid-utf8-semantics.md) as the target semantics, not as a temporary fallback contract

## Phase 3: Introduce A General Raw-Byte Execution Path

- [x] Decide whether to extend the current NFA/VM or add a dedicated byte-oriented VM layer
- [x] Reuse existing HIR lowering where possible instead of creating another ad hoc planner surface
- [x] Add a byte-oriented execution path that can handle all existing HIR node kinds
- [x] Support concatenation, alternation, anchors, repetition, and groups in the raw-byte engine
- [x] Support captures in the raw-byte engine
- [x] Keep newline behavior aligned with the current regex engine

### Phase 3 Decision

The raw-byte path should extend the existing Thompson NFA and Pike VM instead
of adding a third matcher beside the current VM and the planner.

Reasoning:

- the existing HIR already captures the supported regex structure cleanly
- the current NFA already handles concatenation, alternation, anchors,
  repetition, groups, and captures
- the existing VM already has the right slot model for capture reporting
- the current planner has become useful as an optimization boundary, but it is
  the wrong place to keep accumulating correctness logic

Chosen implementation direction:

- keep HIR lowering unchanged as the structural source of truth
- keep the existing NFA instruction set as the structural execution program
- add a byte-oriented VM stepping mode that consumes one raw-byte text unit at
  a time instead of one decoded code point at a time
- define that raw-byte text unit using the Phase 2 semantics:
  - one ASCII byte
  - one full valid UTF-8 scalar when decodable
  - one invalid byte when decoding fails at the current position
- preserve the current newline rule for `.`
- keep capture slots as byte offsets into the original haystack
- keep the current planner only as an optional fast path for obvious cases,
  not as the correctness boundary for invalid UTF-8 matching

### Current Phase 3 Status

The repo now has a general byte-oriented VM execution path in
[src/regex/vm.zig](/home/oleg/prog/zigrep/src/regex/vm.zig) that reuses the
existing NFA program and capture-slot model. `Searcher.firstByteMatch` in
[src/search/grep.zig](/home/oleg/prog/zigrep/src/search/grep.zig) still uses
the planner when available, but now falls back to that general raw-byte VM
when no planner path exists.

## Phase 4: Replace Planner-Only Invalid-UTF-8 Matching

- [x] Route invalid-UTF-8 matching through the general raw-byte engine instead of the current planner/fallback split
- [x] Keep the current planner only if it remains useful as an optimization, not as a correctness boundary
- [x] Make default mode and `--text` differ only by file-selection policy, not by core invalid-UTF-8 matching capability
- [x] Remove the remaining cases where invalid UTF-8 silently degrades to lossy shadow matching

## Phase 5: Remove The Lossy Fallback

- [x] Delete `sanitizeInvalidUtf8Lossy(...)`
- [x] Remove the `allow_lossy_invalid_utf8` control flow from [src/main.zig](/home/oleg/prog/zigrep/src/main.zig)
- [x] Remove lossy-fallback-only tests and replace them with raw-byte engine expectations
- [x] Update docs to remove temporary lossy-fallback wording

## Testing

- [x] Add matcher tests covering every HIR node kind on invalid UTF-8 input
- [x] Add end-to-end CLI tests for default mode on text-like invalid UTF-8 files
- [x] Add end-to-end CLI tests for `--text` on binary-like invalid UTF-8 files
- [x] Add regression tests for captures on invalid UTF-8 input
- [x] Add equivalence tests showing planner-covered patterns and general raw-byte engine patterns report the same spans
- [x] Run `zig build test`

## Cleanup

- [x] Update [docs/supported-syntax.md](/home/oleg/prog/zigrep/docs/supported-syntax.md) to describe the final invalid-UTF-8 behavior
- [x] Update [README.md](/home/oleg/prog/zigrep/README.md) with the user-visible invalid-UTF-8 behavior
- [x] Update [docs/idiomatic-zig-remediation-plan.md](/home/oleg/prog/zigrep/docs/idiomatic-zig-remediation-plan.md) when the lossy fallback is fully removed
- [x] Run `zig build bench` and compare invalid-UTF-8 search behavior before and after

## Recommended Order

- [ ] Finish the unsupported-shape inventory first
- [ ] Freeze the intended raw-byte semantics before changing the engine
- [ ] Build the general raw-byte execution path before deleting planner code
- [ ] Remove the lossy fallback only after test coverage proves the raw-byte engine covers the old fallback cases
