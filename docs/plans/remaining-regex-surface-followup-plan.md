# Remaining Regex Surface Follow-Up Plan

This plan covers the next concrete regex-surface gaps still visible against the
checked local `ripgrep` after the Unicode, class-set, and inline-flag bundle
work.

## Goal

Close the highest-value remaining default-engine regex syntax gaps without:

- introducing a fallback engine
- widening the CLI surface beyond what the regex engine can support cleanly
- conflating regex parsing work with unrelated replacement or output features

## Remaining Gaps In Scope

The current remaining gaps are:

- named capture group syntax:
  - `(?P<name>...)`
- broader inline-flag surface outside the currently implemented native-core
  `i/u/m/s` subset, only where it still makes sense for this engine
- follow-up review of whether named-group syntax needs any additional stable
  user-facing documentation or compatibility notes even before replacement work

## Priority Order

Implementation order for this plan:

1. named capture group syntax
2. broader inline-flag re-check and narrow native-core additions only if still
   justified
3. documentation closeout for the supported regex-surface gap reductions

## Phase 1: Named Capture Groups

- [x] Confirm the exact local `ripgrep` named-capture syntax forms worth
  matching first
- [x] Implement the smallest useful syntax subset:
  - `(?P<name>...)`
- [x] Decide and encode the name validity rules:
  - ASCII-only or broader identifier surface
  - duplicate-name policy
- [x] Extend the parser to preserve capture names without changing ordinary
  numeric capture behavior
- [x] Keep the runtime capture numbering stable and compatible with existing
  capture slots
- [x] Add parser, VM, search-layer, and CLI regressions for named capture
  parsing and matching

## Phase 2: Named Capture Surface Boundary

- [x] Decide whether named groups are syntax-only for now or whether the name
  table becomes part of a stable exported regex surface
- [x] Document the current boundary clearly:
  - named captures parse and match
  - current CLI output may still remain whole-match oriented
- [x] Keep replacement-oriented work explicitly out of scope for this plan

## Phase 3: Broader Inline-Flag Re-Check

- [x] Re-check which inline flags in local `ripgrep` remain outside the current
  `i/u/m/s` implementation
- [x] Separate useful native-core candidates from flags that are outside this
  engine’s intended scope
- [x] Only implement additional inline flags here if:
  - they map cleanly to existing native-core semantics
  - they do not require verbose-mode parsing or unrelated syntax features
- [x] Otherwise, close this phase with an explicit non-goal decision

Result:

- local `ripgrep` still exposes inline flags beyond `i/u/m/s`, most notably
  `R` for CRLF-aware line terminators
- those flags do not map cleanly to the current `zigrep` native core because
  they would require a broader line-terminator model, not just parser syntax
- no additional inline flags are justified inside this plan
- any future work on CRLF-aware regex behavior should be its own narrow plan

## Phase 4: Validation And Docs

- [x] Update [docs/supported-syntax.md](../supported-syntax.md) after each
  implemented slice
- [x] Add focused regressions for any new named-capture and inline-flag
  behavior
- [x] Run:
  - `zig build test`
  - `zig build bench-smoke`

## Recommended Order

- [x] 1. Land named capture syntax first
- [x] 2. Decide the named-capture surface boundary
- [x] 3. Re-check and either implement or explicitly defer any remaining inline
      flags outside `i/u/m/s`

## Explicit Non-Goals

This plan does not include:

- replacement syntax or replacement output features
- fallback-engine work
- verbose / insignificant-whitespace mode unless it becomes independently
  justified in a separate plan
