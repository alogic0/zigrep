# `rg` Code Search Follow-Up Plan

This plan covers the next ripgrep-confirmed code-search behavior that `zigrep`
 should add after the first `--files` / `-F` / `-e` slice.

The goal here is not to invent extra surface area. The goal is to match the
behavior that the installed `rg` already exposes and that is still missing or
incomplete in `zigrep`.

## Verified `rg` Reference Points

Using the installed `/usr/bin/rg` (`ripgrep 13.0.0`), the relevant confirmed
behavior is:

- `rg [OPTIONS] -e PATTERN ... [PATH ...]` is supported
- repeated `-e` means all given patterns are searched, and a line is printed if
  it matches at least one of them
- `-e` is the intended way to search for patterns beginning with `-`
- `-F` composes with `-e`
- `rg [OPTIONS] --files [PATH ...]` is supported
- `--null` applies to `--files`
- `--stats` has no effect with `--files`, `--files-with-matches`, or
  `--files-without-match`
- filtering flags such as `-g`, `-t`, `-T`, `--hidden`, and `-u/-uu/-uuu`
  are part of the normal traversal surface that also matters for `--files`
- `--quiet` is meaningful with `--files`: ripgrep stops after finding the first
  file that would be searched

## Goal

Close the remaining ripgrep-confirmed gaps in `zigrep` by adding:

- ripgrep-aligned `--files` flag interactions
- explicit documentation and remaining cleanup for the already-landed repeated
  `-e` and repeated `-e` with `-F` behavior
- tests proving those behaviors against the existing traversal/filter model

## Current Gap

`zigrep` now has:

- `--files`
- `-F` / `--fixed-strings`
- `-e` / `--regexp`
- support for dash-prefixed explicit patterns

The remaining mismatch is:

- `--files` behavior and policy should stay documented explicitly as the CLI
  surface continues to grow

## Scope

This plan includes:

- `--files` parity cleanup for confirmed flag interactions
- `--quiet` support for `--files`
- any remaining tests needed to lock in the already-landed repeated `-e`,
  repeated `-e` with `-F`, and `--files` behavior
- end-to-end tests for those workflows

This plan does not include:

- new standalone multi-pattern syntax beyond repeated `-e`
- a new pattern-set abstraction unless implementation requires it
- extra code-search features not already confirmed in `rg`
- broader ripgrep parity outside this workflow slice

## Implementation Guardrails

Use the smallest implementation that fits the current architecture:

- prefer CLI/command-layer composition for repeated `-e` instead of introducing
  a broader pattern-set abstraction unless a concrete correctness problem forces
  it
- keep `--files` as a distinct path-only command/report mode and do not route
  it through fake empty-pattern search setup
- keep repeated `-e` with `-F` on the current escaped-regex lowering path
  unless tests expose a real semantic problem
- keep reporting ownership narrow:
  - path-only output should stay on the existing path-output helpers
  - match reporting should stay on the existing search-reporting path

Avoid these implementation directions:

- adding a new general multi-pattern abstraction before it is clearly needed
- special-casing `--files` by faking search execution instead of using the
  existing file-list dispatch path
- adding a dedicated literal-set engine in this slice without a demonstrated
  correctness or architecture need
- adding `--quiet` only as a one-off `--files` hack if broader quiet-mode CLI
  surface is expected shortly after

## Feature 1: Repeated `-e`

- [x] Allow `-e` / `--regexp` to be provided multiple times.
- [x] Define the effective search semantics as “match at least one provided
  pattern,” matching ripgrep’s documented behavior.
- [x] Decide whether the initial implementation should compose repeated `-e`
  into one alternation string at the CLI/command layer or represent them as a
  small explicit pattern list internally.
- [x] Keep the current dash-prefixed explicit-pattern support intact.

### Recommended Initial Policy

- repeated `-e` is allowed
- positional pattern plus any `-e` remains invalid for now unless we decide to
  normalize positional patterns into the same repeated-pattern surface
- repeated `-e` becomes one effective OR-style search

That matches ripgrep’s user-facing semantics without forcing a larger internal
abstraction up front.

## Feature 2: Repeated `-e` With `-F`

- [x] Make repeated explicit patterns compose correctly under fixed-string mode.
- [x] Ensure each explicit fixed string is escaped independently before
  composition.
- [x] Preserve current case-mode behavior when multiple fixed strings are used.
- [x] Add regression tests for repeated `-e` under `-F` with literals such as:
  - `a.b`
  - `[x]`
  - `@import("search/root.zig")`
  - patterns beginning with `-`

### Design Guidance

- Keep the current escaped-regex lowering if it remains semantically correct.
- Do not add a dedicated literal-set engine in this step unless tests expose a
  real correctness or architecture problem.

## Feature 3: `--files` Parity Cleanup

- [x] Verify and document which existing traversal/filter flags compose with
  `--files`.
- [x] Keep `--files` compatible with:
  - `--null`
  - `-g`
  - `-t` / `-T`
  - `--hidden`
  - `-u` / `-uu` / `-uuu`
- [x] Change `--stats` handling to match ripgrep’s documented behavior:
  - no effect in `--files`, `--files-with-matches`, and
    `--files-without-match` modes
  - no hard error just because `--stats` is present
- [x] Keep rejecting match-only flags that do not make sense in file-list mode.

### Recommended Initial Policy

- `--files` remains a path-only mode
- filtering/traversal flags still apply
- `--stats` becomes a no-op in path-only modes instead of an invalid
  combination

## Feature 4: `--quiet` For `--files`

- [x] Add `-q` / `--quiet` if it is not already present as part of this parity
  slice, or at minimum support the ripgrep-confirmed `--files` early-stop
  behavior once quiet mode exists.
- [x] In `--files` mode, stop traversal/output after the first file that would
  be searched.
- [x] Define the exit-code behavior consistently with existing search-mode
  quiet semantics if quiet mode already exists elsewhere by the time this is
  implemented.

### Design Guidance

- Do not add `--quiet` only as a `--files` special case if the flag is going to
  become general CLI surface shortly after.
- If quiet mode is deferred, keep this item as a clearly blocked parity task.

## Cross-Cutting Parser And Command Work

- [x] Refactor explicit pattern handling so it can represent one or more `-e`
  patterns cleanly instead of a single optional slot.
- [x] Keep file-list mode as a distinct command/report path rather than routing
  through fake empty-pattern search behavior.
- [x] Preserve precise CLI errors for:
  - missing patterns
  - illegal mixing of positional and explicit pattern sources
  - invalid file-list-only combinations

## Validation

- [x] Add parser tests for repeated `-e`.
- [x] Add parser tests for repeated `-e` with `-F`.
- [x] Add integration tests for:
  - `-e foo -e bar`
  - `-F -e 'a.b' -e '[x]'`
  - `-e -dash`
  - `--files -g '*.zig'`
  - `--files -t zig`
  - `--files -uu`
  - `--files --stats`
- [x] If quiet mode lands here, add integration coverage for `--files --quiet`.
- [x] Run `zig build test`

## Suggested Implementation Order

- [x] 1. Add repeated `-e` parsing and internal representation.
- [x] 2. Implement repeated-pattern composition for regex and fixed-string
  modes.
- [x] 3. Align `--files` with ripgrep-confirmed `--stats` and filtering
  behavior.
- [x] 4. Add or defer `--quiet` for `--files` explicitly.
- [x] 5. Expand integration coverage for the ripgrep-confirmed workflows.

## Outcome

If this plan is complete, `zigrep` should match the next meaningful layer of
installed ripgrep code-search behavior:

- multiple explicit patterns with repeated `-e`
- repeated explicit patterns under `-F`
- path listing with the expected filtering flags
- quiet path listing that stops after the first candidate file
- ripgrep-style `--stats` treatment in file-list mode

That keeps the follow-up work grounded in actual `rg` behavior instead of
drifting into unverified extra features.
