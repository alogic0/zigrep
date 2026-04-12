# Invalid UTF-8 Semantics

This note defines the current `zigrep` behavior for files that are treated as
searchable text but still contain invalid UTF-8 bytes.

It is a temporary contract until the repo grows a true byte-oriented search
path. The long-term replacement plan remains in
[docs/rg-binary-encoding-plan.md](/home/oleg/prog/zigrep/docs/rg-binary-encoding-plan.md).

## Current Rules

- Default mode does not abort the whole search on invalid UTF-8.
- If a file is classified as binary, default mode still skips it before matching.
- If a file is classified as text but the matcher hits invalid UTF-8, the file
  currently behaves like "no match" in default mode.
- `--text` retries matching through a temporary lossy shadow haystack after an
  `InvalidUtf8` failure.
- Before that lossy retry, exact, anchored, and simple alternated ASCII literal
  patterns plus simple single-dot ASCII concat patterns get a true raw-byte
  search path against the original file bytes.
- The current raw-byte path also covers simple ASCII concat sequences built
  from literals, dots, and character classes, such as `a[0-9]b`, `a[^x]b`, and
  `a.[0-9]b`.
- Repetition over that same ASCII subset is also supported when it applies to a
  single literal, dot, or class atom, including `+`, `*`, `?`, and counted
  forms such as `ab+c`, `a.*b`, `a[0-9]{1,3}b`, and `a.{2}[0-9]{2}b`.
- Transparent groups over that same subset are also supported, including
  grouped repetition for simple byte patterns such as `(ab)+c` and
  `(a[0-9]){2}`.
- Grouped alternation over that same subset is also supported inside a larger
  byte pattern when each branch stays within the current planner subset, such
  as `a(ab|cd)e` and `a((b.)|([0-9]x))c`.
- Quantified grouped alternation over that same subset is also supported, such
  as `((ab)|(cd))+e` and `((a[0-9])|(b.)){2}c`.
- Empty subpatterns and empty alternation branches inside that same subset are
  also supported, such as `a(|b)c` and anchored empty matches like `^$`.
- Empty branches are also supported inside quantified grouped alternation, such
  as `((|ab))+c` and `((|ab)){2}c`.
- The lossy shadow haystack replaces each invalid byte that breaks UTF-8
  decoding with the single ASCII byte `?`.
- Matching uses that lossy shadow haystack only as an internal aid. Printed
  output still comes from the original file bytes.

## Regex Meaning In The Temporary `--text` Path

Under the current `--text` fallback:

- Exact, anchored, and simple alternated ASCII literal patterns plus simple
  ASCII concat sequences built from literals, dots, and character classes plus
  repetition, transparent grouping, grouped alternation, and quantified grouped
  alternation over that subset, plus empty branches including inside quantified
  grouped alternation and anchored empty matches, match against the original
  file bytes.
- `.` can match a replaced invalid byte because the matcher sees `?`.
- Anchors and newline behavior still follow the current regex engine rules.
- Column numbers and line spans stay byte-oriented against the original file
  bytes.

## Output Behavior

- Reported lines come from the original file bytes, not the lossy shadow
  haystack.
- Invalid bytes and unsafe control bytes are escaped as `\xNN` when printed.
- This avoids writing raw binary noise to the terminal while still showing the
  real underlying bytes that contributed to the match.

## Scope

This note only describes the current temporary behavior. It is not the intended
final design for raw-byte matching.
