# Next-Stage Decisions Plan

This plan covers the remaining larger product and architecture decisions after
the current ripgrep-gap implementation work.

The completed gap plan closed the practical CLI surface that fit the current
design cleanly. What remains is not more flag work. It is a smaller set of
decisions that materially change engine semantics, input architecture, or
maintenance cost.

## Decision 1: Multiline Search

- [x] Support multiline search as an explicit opt-in mode.
  Ripgrep already implements this as `-U/--multiline`, so this remains valid
  parity work and should not be treated as a non-goal.

- [x] Implement multiline as native engine work, not as a separate fallback
  engine.

- [x] Keep the current whole-buffer search model and add a multiline-aware
  iteration path over full-haystack match spans.
  This fits `zigrep` better than copying ripgrep’s line-buffer versus
  multiline-buffer split.

### Phase 1: Semantics And CLI Surface

- [x] Add CLI flags:
  - `-U/--multiline`
  - `--multiline-dotall`

- [x] Define the regex semantics to match ripgrep’s boundary:
  - multiline mode permits matches to span line terminators
  - `.` still does not match `\n` by default
  - `--multiline-dotall` makes `.` match `\n`
  - newline-oriented constructs that are currently rejected must become valid
    only when multiline mode is enabled

- [x] Add parser-level tests for:
  - `-U`
  - `--multiline`
  - `--multiline-dotall`
  - invalid combinations if any are intentionally disallowed

### Phase 2: Engine Enablement

- [x] Add multiline and dotall options to the regex compile / VM path.

- [x] Make the matcher accept newline-spanning patterns only when multiline is
  enabled.

- [x] Preserve the ripgrep boundary where multiline does not imply dotall.

- [ ] Add engine-level tests for:
  - `\n` matching across lines in multiline mode
  - `.` not matching `\n` in multiline mode without dotall
  - `.` matching `\n` with multiline plus dotall
  - zero-width and repeated multiline matches advancing correctly

### Phase 3: Span Projection And Reporting

- [ ] Add a span-to-display projection layer:
  - compute the full matched span over the haystack
  - expand each multiline match to the covered display line range
  - derive line numbers, columns, and surrounding line spans after matching

- [ ] Add multiline block grouping similar to ripgrep’s `MultiLine` behavior:
  - merge overlapping display line ranges
  - merge adjacent display line ranges when they touch
  - emit one display block per merged range so no printed line is duplicated

- [ ] Decide and encode column semantics for multiline output.
  Current default should remain byte-oriented and anchored to the first matched
  line unless a different rule is explicitly chosen.

- [ ] Add reporting tests for:
  - overlapping multiline matches
  - adjacent multiline matches
  - no duplicated printed lines when grouped blocks touch

### Phase 4: Output Modes

- [ ] Wire normal text output:
  - print the merged covered line block for each multiline match group

- [ ] Wire `--only-matching`:
  - print the exact matched substring, even across lines

- [ ] Wire `--count`:
  - count multiline matches, not lines

- [ ] Wire context mode:
  - expand around merged display blocks, not around individual internal lines

- [ ] Define and implement JSON semantics:
  - whether match text is the exact match or projected line block
  - whether byte spans remain raw match spans or displayed block spans

- [ ] Explicitly review `--heading`, `--stats`, `--max-count`, `-v`,
  `--files-with-matches`, and `--files-without-match` under multiline mode.

### Phase 5: End-To-End Validation

- [ ] Add a focused multiline test matrix modeled after ripgrep’s coverage:
  - overlapping multiline matches
  - adjacent multiline matches
  - `.` not matching newline without dotall
  - dotall behavior with `--multiline-dotall`
  - `--only-matching` in multiline mode
  - context output in multiline mode
  - stdin / non-mmap full-buffer behavior

- [ ] Add sequential versus parallel output-equivalence tests for multiline
  results.

- [ ] Add buffered versus mmap output-equivalence tests for multiline results.

- [ ] Run targeted benchmarks comparing multiline-off versus multiline-on on:
  - UTF-8 text
  - invalid UTF-8 text-like files
  - decoded UTF-16 input

### Zig-specific guidance

- Do not copy ripgrep’s reader split mechanically. `zigrep` already has a
  file-buffered search architecture, so the reusable part is ripgrep’s
  semantic split between matching spans and rendering lines.
- Do not bolt multiline semantics onto the current line-oriented reporting path
  without defining reporting behavior first.
- Keep multiline as an explicit slower mode if it forces whole-input buffering
  on paths that are currently more incremental.

## Decision 2: Richer Regex Surface

- [ ] Audit which regex-surface gaps are still strategically worth closing.
  Candidates:
  - broader grep/ripgrep escape syntax
  - more class aliases
  - richer anchors/boundaries

- [ ] Decide whether to keep the native engine as the only regex engine.

- [ ] If richer regex fallback is wanted, define a strict boundary:
  - explicit opt-in
  - separate compile path
  - clearly different guarantees from the native engine

### Zig-specific guidance

- Keep the current native engine coherent.
- Do not compromise linear-time expectations for the common path just to
  emulate PCRE-like behavior everywhere.

## Decision 3: Search Surface Consolidation

- [ ] Review whether the public search API should be stabilized as a reusable
  library boundary or remain CLI-first.

- [ ] If library support matters, define which APIs are public contracts:
  - searcher initialization
  - line/match iteration
  - raw-byte and encoding behavior
  - report structures

- [ ] If library support does not matter, explicitly document that internal
  APIs may remain unstable.

### Zig-specific guidance

- Zig repos benefit from clear public-vs-internal boundaries.
- Avoid accidental public API commitments through re-exports alone.

## Decision 4: Output Schema Stability

- [ ] Decide whether the current JSON event format should become stable.

- [ ] If yes, define:
  - required event types
  - field stability promises
  - archive-member path representation if full zip search lands

- [ ] If no, document the current JSON output as intentionally unstable.

### Zig-specific guidance

- Stable machine-readable output is a real compatibility promise.
- Make that promise explicitly or avoid implying it.

## Recommended Order

- [ ] 1. Decide multiline support boundary.
- [ ] 2. Decide whether richer regex support needs an explicit fallback engine.
- [ ] 3. Decide whether the search layer is a supported library surface.
- [ ] 4. Decide whether JSON output is a stable interface.

## Explicit Non-Goals For This Plan

- [ ] Do not reopen the already-completed ripgrep-gap checklist here.
- [ ] Do not mix multiline and richer-regex work in one implementation step.
- [ ] Do not add full `.zip` archive traversal under the current parity-driven
  roadmap.
