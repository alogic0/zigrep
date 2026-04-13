# Root API Policy Plan

This plan defines the next architecture step after the recent boundary cleanup
work. The goal is not another refactor first. The goal is to decide what the
top-level `zigrep` module is supposed to mean.

## Goal

Turn the current root surface into an explicit policy by deciding:

- which exports are intentional public surface
- which exports are app-facing support only
- which exports should remain internal in future cleanup work

## Current Surface

The current `src/root.zig` surface exports:

- `regex`
- `search`
- `search_runner`
- `search_reporting`
- `command`
- `cli`
- `config`
- `app_version`

## Phase 1: Surface Classification

- [x] classify each root export as one of:
  - public library surface
  - app-facing support surface
  - temporary compatibility/tooling surface
- [x] make the intended audience of each export explicit

Phase 1 classification:

- `regex`
  - public library surface
  - intended audience: low-level regex and engine consumers
- `search`
  - public library surface
  - intended audience: low-level search-layer consumers
- `search_runner`
  - app-facing support surface
  - intended audience: app, bench, and runner-surface tests through
    `search_runner.runSearch(...)`
- `search_reporting`
  - temporary compatibility/tooling surface
  - intended audience: current runner/report tests and tooling only
- `command`
  - app-facing support surface
  - intended audience: CLI/search command-shaping code
- `cli`
  - app-facing support surface
  - intended audience: CLI parsing and usage behavior
- `config`
  - app-facing support surface
  - intended audience: CLI config-resolution behavior
- `app_version`
  - app-facing support surface
  - intended audience: CLI/runtime version reporting

## Phase 2: Policy Decision

- [x] decide whether `zigrep` is intended to be:
  - a real consumable library
  - primarily an app with a few exposed helper modules
  - a mixed surface with explicitly different stability expectations
- [x] write the policy in plain terms instead of relying on architecture history

Phase 2 decision:

- `zigrep` is a mixed surface with explicitly different stability expectations

Current policy:

- stable library-facing surface:
  - `regex`
  - `search`
- stable app-facing execution/support surface:
  - `search_runner.runSearch(...)`
  - `cli`
  - `config`
  - `command`
  - `app_version`
- unstable compatibility/tooling surface:
  - `search_reporting`

Interpretation:

- `regex` and `search` are intentional library modules
- `search_runner.runSearch(...)` is the intentional app-facing execution
  entrypoint
- `cli`, `config`, `command`, and `app_version` are app-facing support modules
- `search_reporting` is intentionally non-stable and may be internalized by a
  later tooling/test-driven cleanup

## Phase 3: Documentation Update

- [x] update `docs/architecture-overview.md`
- [x] update `docs/module-boundary-rules.md`
- [x] document the intended stability expectations for root exports

## Validation

- [x] ensure the policy matches the current codebase and build graph

## Outcome

- the root API policy is now explicit
- no code changes are needed in this plan
- any future narrowing or stabilization work should start from this policy
  instead of from implicit historical usage

## Explicit Non-Goals

This plan does not include:

- immediate export removals
- new feature work
- regex or search behavior changes
- build-graph rewrites unless a later policy-driven plan requires them
