# RG Final Parity Follow-Up Plan

This plan captures the small remaining parity differences found in the latest
installed-binary sweep against `rg`. The main practical feature work is
already done. What remains is output-polish parity, not search-core capability.

## Goal

Close the last small ripgrep-facing differences without reopening the recent
architecture cleanup:

- make `--stats` output more ripgrep-like
- decide whether default unsorted path ordering should stay implementation-
  defined or move closer to ripgrep traversal ordering
- tighten minor message-shape differences only if they are worth the churn

## Confirmed Remaining Differences

### 1. `--stats` Output Shape

Current state:

- `rg` prints a multi-line human-readable stats block
- `zigrep` prints a compact single-line summary:
  - `stats: searched_files=... matched_files=... ...`

This is the clearest remaining practical parity gap from the sweep.

### 2. Default Unsorted Path Ordering

Current state:

- modes such as `--files`, `--files-without-match`, and null-terminated
  path-only output return the same file set as `rg`
- but the default order differs in some cases

This is not currently a missing feature. It is an ordering difference.

The main question is whether to:

- keep default ordering implementation-defined and rely on `--sort`
- or treat closer ripgrep traversal ordering as a parity goal

Decision:

- [x] keep default unsorted ordering implementation-defined
- [x] treat `--sort` / `--sortr` as the stable ordering surface
- [x] document this explicitly instead of changing traversal behavior

### 3. Minor Message-Shape Differences

Current state:

- some error text is already very close to `rg`
- but minor presentation differences remain, such as missing `rg:`-style
  prefixing in some fatal-error paths

These are lower priority than `--stats`.

## Feature 1: Ripgrep-Style `--stats`

Target:

- change `zigrep --stats` output from the current compact internal summary to
  a more ripgrep-like human-readable multi-line form

Status:

- [x] implemented in the current repo code
- [ ] installed binary parity depends on rebuilding and reinstalling `zigrep`

Implementation guidance:

- keep the existing internal `SearchStats` shape if possible
- treat this as a formatting-layer change, not a stats-collection redesign
- keep stats ownership in the runner/report orchestration layer, not in the
  regex engine

Validation:

- [x] compare `rg --stats` and repo-built `zigrep --stats` on:
  - [x] one file with matches
  - [x] one file without matches
  - [x] multi-file search
  - [x] binary-skipped cases
  - [x] stdin search

## Feature 2: Path-Order Parity Decision

Target:

- decide explicitly whether unsorted file/path ordering should remain
  implementation-defined or move toward ripgrep parity

Implementation guidance:

- do not change this accidentally
- if left as-is, document that `--sort` is the stable ordering surface
- if changed, do it in traversal/path-runner ownership, not by layering
  ad-hoc sorting into reporting

Validation:

- [x] compare `rg` and `zigrep` for:
  - [x] `--files`
  - [x] `-l`
  - [x] `--files-without-match`
  - [x] `--null -l`

## Feature 3: Minor Message Polish

Target:

- decide whether remaining message-shape differences are worth closing

Likely candidates:

- fatal-error prefix formatting
- any remaining small wording mismatches not tied to real behavior

Implementation guidance:

- keep this low priority
- do not add special cases unless they improve user-facing consistency in a
  durable way

Decision:

- [x] leave minor message-shape differences as-is for now
- [x] do not mirror `rg:`-style prefixing just for cosmetic parity
- [x] keep existing message text improvements where they already help users

## Non-Goals

This follow-up plan does not include:

- new regex features
- new CLI flags
- search-core behavior changes unrelated to parity polish
- reopening the reporting architecture cleanup
