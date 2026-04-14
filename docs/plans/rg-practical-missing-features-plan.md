# Practical Missing Features Plan

This plan captures the remaining features that still came up as missing while
using `zigrep` directly for normal repository navigation and command-line
search work.

The goal here is not full ripgrep parity. The goal is to record the concrete
features that still forced a fallback or would likely force one in day-to-day
use.

The plan was mostly completed once, but a fresh direct `rg` versus `zigrep`
comparison still showed a small number of behavior-level gaps worth tracking
as follow-up parity work.

## Observed Missing Features

From the latest direct `rg` versus `zigrep` comparison, the remaining behavior
gaps are:

- richer ripgrep-style `--json` parity

## Priority

Priority should stay grounded in actual usage:

1. `--iglob`
2. stdin search
3. sorting controls
4. replacement/substitution

With the earlier practical slices now implemented, the remaining follow-up
priority inside this plan should be:

1. richer `--json` parity

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

- [x] Add support for searching stdin when no path is given and input is piped.
- [x] Decide and document path labeling for stdin results.
- [x] Keep stdin search behavior coherent with current reporting modes:
  - normal line output
  - `--count`
  - `--only-matching`
  - `--json`
- [x] Decide which path-oriented modes remain invalid or become meaningful with
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

- [x] Decide whether to support a small sorting surface for search output.
- [x] If yes, start with the smallest practical options for interactive use.
- [x] Keep sorting scoped to reported results, not to traversal internals.
- [x] Decide and document interactions with:
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

- [x] Decide whether substitution belongs in `zigrep`’s intended CLI scope.
- [x] If yes, define the smallest supported surface:
  - literal replacement only
  - regex replacement without backreferences
  - regex replacement with capture expansion
- [x] Decide whether substitution is output-only, file-rewriting, or both.
- [x] Keep file mutation out of scope unless explicitly designed and isolated.

### Remaining Replacement Gap

- [x] Add capture-expanding replacement for `-r` / `--replace`.
- [x] Decide the initial supported expansion surface:
  - numbered captures like `$1`
  - named captures if already available from the regex compiler/runtime
  - escaping rules for literal `$`
- [x] Keep replacement output-only unless file-rewrite semantics are
  explicitly designed later.

### Replacement Guidance

- Reuse the existing match-span reporting path and current capture support in
  the regex engine.
- Do not redesign the regex compiler just to add replacement expansion.
- If named-capture expansion is materially more invasive than numbered
  captures, land numbered captures first and document the limitation.

## Feature 5: Timestamp Sorting Modes

- [x] Extend `--sort` / `--sortr` beyond `path` to the practical timestamp
  modes:
  - `modified`
  - `accessed`
  - `created`
- [x] Match ripgrep’s behavior closely when a timestamp mode is recognized but
  unsupported on the current platform or filesystem.
- [x] Keep timestamp sorting in the post-collection ordering layer, not in the
  traversal algorithm.

Current status:

- `modified` and `accessed` are implemented with stat-based post-collection ordering
- `created` is recognized but currently rejected as unsupported because the
  current portable stat surface does not expose file birth time directly
- the remaining parity gap is user-facing behavior:
  - `rg` reports a specific creation-time-unavailable message
  - `zigrep` currently reports the generic `UnsupportedSortMode` error name

### Remaining Created-Sort Parity Gap

- [x] Keep `created` as a recognized sort mode.
- [x] Change the runtime failure path to report a ripgrep-like
  creation-time-unavailable message instead of a generic internal error name.
- [x] Keep the current non-implementation of actual birth-time sorting unless
  a portable stat source is added later.
- [x] Implement platform targeting with a narrow split:
  - use Zig `comptime` only to select which created-time backend code is
    compiled for the target
  - keep user-facing support decisions runtime-based when actual availability
    can still vary by filesystem or runtime environment

### Timestamp Sort Guidance

- Reuse the existing sorting surface and ordering hook rather than adding a
  separate family of flags.
- Prefer explicit stat-based ordering over traversal-time heuristics.
- Keep sorting single-threaded when a timestamp mode is active, consistent with
  the current path-sort behavior.
- Keep the CLI surface stable across builds; `created` should stay recognized
  even when the compiled target has no usable implementation backend.
- Isolate target-specific code behind one small capability/backend layer rather
  than scattering `comptime` conditionals through parsing, reporting, or
  search orchestration.
- Prefer a two-step capability model for `created`:
  - `comptime` chooses whether a backend exists for this target
  - runtime decides whether creation time is actually available now

## Feature 7: Ripgrep-Style JSON Output

- [x] Compare the current custom `--json` event shape directly against ripgrep
  and record the minimum parity target.
- [x] Decide whether to move toward ripgrep-style `begin` / `match` / `end` /
  `summary` events or to keep a documented smaller schema.
- [x] If parity is the goal, include path encoding, line text, submatch spans,
  and summary events in the matching shape.

Current status:

- line-mode JSON now follows the ripgrep-style `begin` / `match` / `end` /
  `summary` framing closely enough for practical parity work
- `match` events now keep the full line payload in `lines.text`, including the
  trailing `\n` when present, even under `--only-matching`
- top-level `summary` aggregation now reports real printed-byte and
  match-count totals instead of placeholder zero values
- `--count` and file-path-only modes now fall back to normal text output when
  `--json` is present, matching ripgrep more closely than the earlier custom
  `count` and `path` events
- remaining gaps are mostly longer-tail schema parity such as elapsed timing
  fields

### JSON Guidance

- Keep this as a reporting-layer change, not a search-core change.
- Reuse existing match and count information rather than recomputing search
  results only for JSON.
- If full ripgrep JSON parity is too large for one slice, land the schema in
  phases but keep the target shape explicit.

## Feature 8: Binary Text Output Parity

- [x] Compare `--text` output on binary-containing files directly against
  ripgrep and match the intended byte-display behavior.
- [x] Decide whether `zigrep` should print raw bytes, escaped bytes, or a mode
  split that matches ripgrep more closely.
- [x] Keep binary-text behavior coherent with normal text output, JSON, and
  replacement semantics.

### Binary Text Guidance

- Treat this as an output-policy question, not as a binary-detection change.
- Be explicit about invalid UTF-8 and NUL-byte display rules.
- Prefer one centralized display policy rather than separate ad hoc escaping
  paths for binary-text mode.

## Feature 9: Binary Match Notice Parity

- [x] Compare `--binary` notice text directly against ripgrep and decide the
  desired parity target.
- [x] Include enough detail to explain why line content was suppressed, such as
  the first binary offset if available.
- [x] Keep the behavior distinct from `--text`, which should still print match
  content.

### Binary Notice Guidance

- Keep this as a user-facing reporting change.
- Reuse existing binary-detection information if the offset is already known;
  do not add expensive rescans just to decorate the notice unless justified.
- Keep the emitted message stable and testable once the target wording is set.

## Feature 6: Single-File Explicit-Path Output Defaults

- [x] Make default filename-prefix behavior match ripgrep more closely when the
  search target is one explicit file.
- [x] Keep stdin behavior separate from explicit single-file path behavior.
- [x] Preserve `-H` / `--with-filename`, `--no-filename`, `--heading`, and
  multi-path behavior as explicit overrides.

### Remaining Single-File Output Gap

- [x] Suppress line and column prefixes by default too when searching one
  explicit file path in normal text output.
- [x] Decide whether the same default should apply to `--count`,
  `--only-matching`, and any other line-oriented modes, based on direct
  ripgrep behavior rather than assumption.
- [x] Keep explicit formatting overrides authoritative:
  - `-n` / `--line-number`
  - `--column`
  - `-H` / `--with-filename`
  - `--no-filename`
  - `--heading`
- [x] Make `--column` imply line numbers, matching ripgrep behavior for both
  single-file and multi-file output.

### Filename Guidance

- Keep this as a CLI/reporting policy adjustment, not a traversal change.
- Avoid broad output-policy refactors; the gap is specifically the default case
  for one explicit file versus multi-file search.
- Prefer one centralized “effective output defaults” decision point rather than
  scattering explicit-file checks across multiple reporting functions.

### Design Guidance

- Treat substitution as a separate product decision, not just “one more flag”.
- Do not mix file-rewriting semantics into the current grep-style reporting path
  casually.
- If substitution lands, start with a non-destructive output mode unless there
  is a strong reason to do more.

## Cross-Cutting Constraints

- [x] Keep new work aligned with the current architecture:
  - traversal and filtering stay in the search path layer
  - reporting stays separate from filtering
  - command dispatch stays explicit
- [x] Avoid introducing broad new abstractions before there is a concrete need.
- [x] Prefer narrow extensions of the current command model and search pipeline.

## Validation

- [x] Add parser tests for each new flag surface.
- [x] Add integration coverage for the practical workflows that motivated the
  feature.
- [x] Run `zig build test`.

## Outcome

If this plan is complete, `zigrep` should cover the remaining practical gaps
that still came up during real use:

- case-insensitive glob filtering
- pipeline-friendly stdin search
- basic result ordering controls
- an output-only replacement story with capture expansion
- closer behavior parity for explicit single-file output defaults
- closer behavior parity for unsupported `--sort created`
