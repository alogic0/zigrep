# Practical Missing Features Plan

This plan captures the remaining features that still came up as missing while
using `zigrep` directly for normal repository navigation and command-line
search work.

The goal here is not full ripgrep parity. The goal is to record the concrete
features that still forced a fallback or would likely force one in day-to-day
use.

## Observed Missing Features

From direct `zigrep` use in this repository, the remaining missing features
were:

- case-insensitive glob filtering via `--iglob`
- stdin-driven search for pipeline workflows
- replacement/substitution support
- sorting controls for result ordering

## Priority

Priority should stay grounded in actual usage:

1. `--iglob`
2. stdin search
3. sorting controls
4. replacement/substitution

That ordering reflects how often these features still affect normal code-search
work.

## Feature 1: `--iglob`

- [x] Add `--iglob GLOB` as a case-insensitive variant of `-g` / `--glob`.
- [x] Keep repeated `--iglob` semantics aligned with repeated `--glob`:
  - positive patterns act as an allow-list
  - `!pattern` exclusions are still supported
- [x] Decide and document how `-g` and `--iglob` compose when both are present.
- [x] Keep `--files`, normal search, and file-type filtering behavior aligned
  with the current glob pipeline.

### Design Guidance

- Reuse the current path-filtering architecture in `src/search/glob.zig` and
  `src/search_filtering.zig`.
- Do not invent a separate filtering pipeline just for case-insensitive globs.
- If composition rules are ambiguous, prefer a single ordered glob list with an
  explicit case-sensitivity mode per entry.

## Feature 2: Stdin Search

- [ ] Add support for searching stdin when no path is given and input is piped.
- [ ] Decide and document path labeling for stdin results.
- [ ] Keep stdin search behavior coherent with current reporting modes:
  - normal line output
  - `--count`
  - `--only-matching`
  - `--json`
- [ ] Decide which path-oriented modes remain invalid or become meaningful with
  stdin:
  - `--files`
  - `--files-with-matches`
  - `--files-without-match`
  - `--null`

### Design Guidance

- Keep stdin handling in the CLI / command-entry layer, not in directory walk
  code.
- Do not let stdin support distort the existing path-walk execution model.
- If needed, model stdin as a separate command path rather than a fake single
  walked file.

## Feature 3: Sorting Controls

- [ ] Decide whether to support a small sorting surface for search output.
- [ ] If yes, start with the smallest practical options for interactive use.
- [ ] Keep sorting scoped to reported results, not to traversal internals.
- [ ] Decide and document interactions with:
  - `--files`
  - `--files-with-matches`
  - `--files-without-match`
  - `--json`
  - `--quiet`

### Design Guidance

- Prefer explicit post-collection ordering over changing traversal semantics.
- Avoid introducing a broad reporting abstraction just to support many sort
  variants.
- If sorting materially conflicts with streaming output, make the limitation
  explicit instead of hiding buffering costs.

## Feature 4: Replacement / Substitution

- [ ] Decide whether substitution belongs in `zigrep`’s intended CLI scope.
- [ ] If yes, define the smallest supported surface:
  - literal replacement only
  - regex replacement without backreferences
  - regex replacement with capture expansion
- [ ] Decide whether substitution is output-only, file-rewriting, or both.
- [ ] Keep file mutation out of scope unless explicitly designed and isolated.

### Design Guidance

- Treat substitution as a separate product decision, not just “one more flag”.
- Do not mix file-rewriting semantics into the current grep-style reporting path
  casually.
- If substitution lands, start with a non-destructive output mode unless there
  is a strong reason to do more.

## Cross-Cutting Constraints

- [ ] Keep new work aligned with the current architecture:
  - traversal and filtering stay in the search path layer
  - reporting stays separate from filtering
  - command dispatch stays explicit
- [ ] Avoid introducing broad new abstractions before there is a concrete need.
- [ ] Prefer narrow extensions of the current command model and search pipeline.

## Validation

- [x] Add parser tests for each new flag surface.
- [ ] Add integration coverage for the practical workflows that motivated the
  feature.
- [x] Run `zig build test`.

## Outcome

If this plan is complete, `zigrep` should cover the remaining practical gaps
that still came up during real use:

- case-insensitive glob filtering
- pipeline-friendly stdin search
- basic result ordering controls
- a clearly decided substitution story
