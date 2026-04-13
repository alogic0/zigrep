# Inline Flag Bundles Follow-Up Plan

This plan covers the next regex parity slice after the completed scoped inline
`m`/`s` work.

## Goal

Close the remaining high-value inline-flag syntax gap against local `ripgrep`
without:

- introducing a fallback engine
- weakening the current native-core flag semantics
- blurring the distinction between parser-time mode changes and HIR-time
  case-fold rewriting

## Remaining Gaps In Scope

The strongest remaining inline-flag gaps are:

- unscoped flag toggles that affect the following pattern:
  - `(?i)`
  - `(?-i)`
  - `(?m)`
  - `(?-m)`
  - `(?s)`
  - `(?-s)`
  - `(?u)`
  - `(?-u)`
- grouped scoped bundles:
  - `(?im:...)`
  - `(?i-m:...)`
  - similar combinations within the native-core flag subset

Out of scope for this plan:

- verbose / insignificant-whitespace mode
- flags unrelated to the current native engine surface
- any fallback-engine behavior

## Phase 1: Parity Target

- [x] Confirm the exact local `ripgrep` inline-flag bundle surface worth
  matching first
- [x] Separate the supported native-core subset into:
  - parser-time mode flags:
    - `u`
    - `m`
    - `s`
  - case-fold flags:
    - `i`
- [x] Keep unsupported flags explicit rather than partially accepted
  - current result:
    - local `ripgrep` supports unscoped toggles like `(?i)`, `(?-u)`, `(?m)`,
      and `(?s)`
    - local source/tests also show bundled forms like `(?i-u)`
    - this first implementation slice lands only unscoped single-flag toggles
    - grouped bundles remain the next step

## Phase 2: Unscoped Flag Toggles

- [x] Extend the parser to accept unscoped flag toggles that affect the
  remainder of the current enclosing group or pattern
- [x] Make the mode stack explicit so nested scoped groups still restore
  correctly
- [x] Keep `(?-u)` semantics aligned with the current explicit restriction on
  Unicode property escapes inside ASCII mode

## Phase 3: Scoped Flag Bundles

- [ ] Extend scoped groups from one-flag forms to supported bundles like:
  - `(?im:...)`
  - `(?i-m:...)`
- [ ] Define a stable parse rule for:
  - enabling multiple flags
  - disabling a suffix set after `-`
  - rejecting duplicate or contradictory bundle syntax where needed
- [ ] Ensure grouped flag bundles compose correctly with existing:
  - scoped Unicode groups
  - scoped multiline/dotall groups
  - scoped case-fold groups

## Phase 4: Engine Integration

- [ ] Keep parser-time flags (`u`, `m`, `s`) represented directly on the parsed
  nodes they affect
- [ ] Keep case-fold flag changes in the existing scoped HIR rewrite model
- [ ] Keep planner and DFA gating conservative for any new bundled line-mode
  cases until equivalence is proven

## Phase 5: Validation And Docs

- [x] Add parser regressions for:
  - unscoped toggles
  - explicit rejection of unsupported flags
- [ ] Add parser regressions for grouped scoped bundles
- [x] Add VM, search-layer, and CLI regressions for representative mixed cases
- [x] Update [docs/supported-syntax.md](../supported-syntax.md)
- [x] Run:
  - `zig build test`
  - `zig build bench-smoke`

## Recommended Order

- [x] 1. Land unscoped `i` / `u` / `m` / `s` toggles for the remainder of the
      pattern
- [ ] 2. Land grouped scoped bundles for the same supported subset
- [ ] 3. Re-check whether any other inline flags are still materially useful

## Status

The first slice of this plan is implemented:

- unscoped single-flag toggles for `i`, `u`, `m`, and `s`

The next remaining work in this plan is:

- grouped scoped bundles like `(?im:...)` and `(?i-m:...)`

## Explicit Non-Goals

This plan does not include:

- verbose-mode parsing
- planner optimization for the new bundled flag constructs
- fallback-engine work
