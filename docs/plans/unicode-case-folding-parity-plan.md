# Unicode Case-Folding Parity Plan

This plan covers the next regex-parity gap after Unicode shorthand and
boundary migration: Unicode-aware case-insensitive matching and smart-case
behavior.

It is intentionally separate from:

- [unicode-shorthand-compatibility-plan.md](unicode-shorthand-compatibility-plan.md)
- [native-unicode-full-property-surface-plan.md](native-unicode-full-property-surface-plan.md)

Those plans changed shorthand and property coverage. This plan focuses on how
`-i` / `--ignore-case` and `-S` / `--smart-case` should behave on Unicode text.

## Goal

Bring `zigrep` closer to ripgrep's default Unicode case-insensitive behavior
without abandoning the current native-engine architecture.

The work should stay inside the current:

- HIR rewrite approach
- Thompson NFA / DFA / Pike VM model
- generated Unicode-data model already used elsewhere in the repo

## Current State

`zigrep` already supports:

- `-i` / `--ignore-case`
- `-S` / `--smart-case`
- Unicode-aware smart-case uppercase detection for non-ASCII patterns
- stable ASCII and selected Unicode ignore-case behavior already covered by the
  native rewrite
- explicit rejection of some large folded class/range rewrites via
  `UnsupportedCaseInsensitivePattern`

Current implementation boundary:

- case-insensitive matching is performed by rewriting HIR, not by a separate
  VM mode
- a direct attempt to switch literal/class folding to the shared Unicode
  fold-set helper caused false negatives for ordinary ignore-case literals and
  was backed out
- full Unicode literal/class parity is still open work, not partially shipped
- broad class/range folding can still fail explicitly
- current docs do not yet frame the exact Unicode parity target clearly

## Decision

Keep the native HIR-rewrite design.

Do not introduce a separate fallback engine for case-insensitive matching in
this plan.

Do not introduce a separate "Unicode case mode" switch in this plan.

The target remains:

- Unicode-aware case-insensitive matching by default under `-i`
- Unicode-aware smart-case behavior under `-S`
- explicit failure only where the native rewrite model genuinely cannot express
  the requested semantics without unreasonable blow-up

## Native-Core Boundary

This work remains in native-core scope because it still fits the existing
execution model:

- simple and data-driven scalar folding
- folded literal and class expansion
- no backtracking-only semantics
- no second engine

Non-goal for this plan:

- locale-sensitive case handling
- full PCRE2 case behavior
- Turkish-special-case locale modes

## Phase 1: Lock Parity Target

- [x] Record the ripgrep parity target explicitly for:
  - Unicode literals
  - Unicode classes
  - smart-case uppercase detection on non-ASCII patterns
  - folded equivalents like Greek sigma forms

- [x] Decide and document the exact supported folding model:
  - simple case folding only
  - no locale-sensitive behavior

- [x] Document the current explicit-failure boundary:
  - broad folded ranges may still fail
  - failure is preferable to silent under-matching
  - current result: folded Unicode literals and literal-class members now use
    generated simple case-fold data, but broad folded ranges still keep the
    explicit rejection boundary
  - current result: the boundary is now pinned by direct search-layer and CLI
    regressions, including a whole-Unicode range example

## Phase 2: Review Existing Folding Coverage

- [x] Audit the current HIR rewrite in [src/regex/hir.zig](../../src/regex/hir.zig)
  for:
  - literal folding
  - class folding
  - Unicode property item preservation
  - large-range rejection
  - current result: the shared Unicode fold-set rewrite is not ready to replace
    the conservative literal/class expansion path because it regressed basic
    ignore-case matching

- [x] Audit uppercase detection in [src/search/grep.zig](../../src/search/grep.zig)
  for smart-case on non-ASCII patterns
  - current result: the old heuristic was replaced with Unicode-property-based
    detection using `Uppercase` and `Titlecase_Letter`

- [x] Write down concrete parity gaps found by that audit before changing code
  - current result: smart-case Unicode detection is ready, but broad Unicode
    literal/class parity needs a better fold-data model before rollout

## Phase 3: Unicode Literal And Class Parity

- [x] Expand tests for Unicode literal folding under `-i`
  - Greek sigma family
  - accented Latin letters
  - non-ASCII lowercase and uppercase pairs
  - current result: representative sigma and accented-latin literal regressions
    are now covered in the search layer and CLI

- [x] Expand tests for class folding under `-i`
  - mixed ASCII and Unicode classes
  - Unicode literals inside bracket classes
  - property-containing classes under ignore-case
  - current result: representative sigma and accented-latin class regressions
    are now covered, and case-related Unicode properties such as
    `Lowercase`, `Uppercase`, and `Titlecase_Letter` now fold under `-i` in
    both top-level property atoms and bracket classes

- [x] Tighten the behavior of explicit rejection cases so they are:
  - deterministic
  - documented
  - covered by regressions
  - current result: explicit rejection is now covered for oversized Unicode
    case-insensitive ranges; broader boundary re-evaluation is still open

## Phase 4: Smart-Case Unicode Behavior

- [x] Verify and, if needed, fix uppercase detection for:
  - Greek
  - Cyrillic
  - titlecase characters
  - edge cases where uppercase detection should keep smart-case sensitive
  - current result: smart-case sensitivity now follows `Uppercase` only;
    titlecase characters no longer force case-sensitive search

- [x] Add end-to-end CLI regressions for:
  - lowercase non-ASCII patterns under `--smart-case`
  - uppercase non-ASCII patterns under `--smart-case`

## Phase 5: Range And Blow-Up Boundary

- [x] Review the current `max_case_folded_range_size` boundary in
  [src/regex/hir.zig](../../src/regex/hir.zig)
  - current result: the existing bounded expansion limit still stands; the
    whole-Unicode range regression is now the pinned example of the current
    rejection boundary

- [x] Decide whether current rejection behavior is still the right boundary or
  whether small targeted improvements are justified
  - current result: keep the current explicit rejection behavior for now and
    defer any relaxation to a separate focused follow-up

- [x] Keep the core rule explicit:
  - do not silently under-match
  - either rewrite correctly or reject explicitly

## Phase 6: Documentation

- [x] Update [supported-syntax.md](../supported-syntax.md) to describe:
  - Unicode-aware ignore-case behavior
  - smart-case behavior on Unicode patterns
  - explicit rejection for unsupported broad folded range rewrites

- [x] Add migration notes only if visible behavior changes from the current
  release

## Phase 7: Validation

- [x] Add search-layer regressions for representative Unicode ignore-case and
  smart-case cases

- [x] Add end-to-end CLI regressions for multilingual case-insensitive search

- [x] Compare a focused matrix against local `ripgrep` behavior for:
  - literals
  - classes
  - smart-case
  - explicit rejection boundaries
  - current result: literals, classes, case-related property folding, and
    smart-case titlecase behavior now match the checked local `ripgrep`
    samples; the deliberate remaining divergence is broad folded ranges like
    `[\u{0000}-\u{FFFF}]` under `-i`, which `ripgrep` accepts and `zigrep`
    still rejects explicitly

## Recommended Order

- [x] 1. Lock the parity target and supported folding model
- [x] 2. Audit the current rewrite and smart-case implementation
- [x] 3. Expand Unicode literal and class folding coverage
- [x] 4. Fix smart-case Unicode edge cases
- [x] 5. Re-evaluate the broad-range rejection boundary
- [x] 6. Update docs and finalize validation against ripgrep

## Status

This plan is complete.

Implemented outcome:

- generated simple case-fold data now backs Unicode-aware literal and class
  folding under `-i`
- case-related Unicode properties fold under `-i`
- smart-case uses Unicode-aware uppercase detection and treats titlecase
  patterns as ignore-case, matching the checked local `ripgrep` behavior
- the universal scalar range `[\u{0000}-\u{10FFFF}]` is now accepted under
  `-i`, while broader folded ranges still keep the explicit native-core
  rejection boundary

Remaining divergence from local `ripgrep`:

- `ripgrep` accepts broad folded ranges such as `[\u{0000}-\u{FFFF}]` under
  `-i`
- `zigrep` still rejects those patterns explicitly with
  `UnsupportedCaseInsensitivePattern`

## Explicit Non-Goals

The following are outside this plan:

- locale-sensitive case modes
- fallback-engine work
- unrelated Unicode property expansion
- shorthand or boundary migration work already completed elsewhere
