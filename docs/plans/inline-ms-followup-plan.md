# Inline `m`/`s` Follow-Up Plan

This plan covers the next regex parity slice after the completed Unicode and
class-set work.

## Goal

Close the highest-value remaining inline-flag gap against local `ripgrep`
without:

- introducing a fallback engine
- weakening current multiline correctness rules
- pretending the byte planner or DFA already have equivalent semantics where
  they do not

## Remaining Gaps In Scope

- scoped multiline-anchor groups:
  - `(?m:...)`
  - `(?-m:...)`
- scoped dotall groups:
  - `(?s:...)`
  - `(?-s:...)`

Deferred follow-ups after this slice:

- broader unscoped inline-flag forms like `(?i)` and grouped flag bundles
- any deeper class-set algebra re-check if local `ripgrep` behavior justifies it

## Phase 1: Scoped `m`/`s` Surface

- [x] Confirm the local `ripgrep` scoped forms worth targeting first
- [x] Keep the first slice scoped only:
  - `(?m:...)`
  - `(?-m:...)`
  - `(?s:...)`
  - `(?-s:...)`
- [x] Keep broader inline-flag syntax explicit non-goals for this slice

## Phase 2: Native-Core Representation

- [x] Represent scoped `m` as parser-time anchor metadata on `^` and `$`
- [x] Represent scoped `s` as parser-time metadata on `.`
- [x] Keep Unicode and case-fold scoped groups working unchanged

## Phase 3: Matcher Integration

- [x] Thread scoped anchor and dot behavior through HIR, NFA, and VM
- [x] Keep scoped line-mode patterns off the byte planner until equivalence is
  proven
- [x] Keep scoped line-mode patterns off the DFA where current context flags do
  not model their semantics fully

## Phase 4: Validation And Docs

- [x] Add parser, VM, search-layer, and CLI regressions for:
  - `(?m:^...$)`
  - `(?-m:^...$)`
  - `(?s:.)`
  - `(?-s:.)`
  - composition with `-U` / `--multiline-dotall`
- [x] Update [docs/supported-syntax.md](../supported-syntax.md)
- [x] Run:
  - `zig build test`
  - `zig build bench-smoke`

## Status

The scoped inline `m`/`s` slice is implemented.

The remaining future work in this area, if we choose to pursue it, should be
handled by separate narrow follow-ups for:

- unscoped inline flag forms like `(?i)` and grouped flag bundles
- any remaining class-set algebra gap that is still justified by local
  `ripgrep`

## Explicit Non-Goals

This plan does not include:

- unscoped inline flags like `(?i)` or grouped flag bundles
- planner optimization for the new scoped line-mode constructs
- CLI-level flag changes to multiline or dotall behavior
