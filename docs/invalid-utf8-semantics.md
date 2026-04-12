# Invalid UTF-8 Semantics

This note defines the current `zigrep` behavior for files that are treated as
searchable text but still contain invalid UTF-8 bytes.

It is a temporary contract until the repo grows a true byte-oriented search
path. The long-term replacement plan remains in
[docs/rg-binary-encoding-plan.md](/home/oleg/prog/zigrep/docs/rg-binary-encoding-plan.md).

## Current Rules

- Default mode does not abort the whole search on invalid UTF-8.
- If a file is classified as binary, default mode still skips it before matching.
- If a file is classified as text and the pattern is covered by the current
  raw-byte planner, default mode uses that raw-byte path too.
- If a file is classified as text but the pattern still falls outside the
  raw-byte planner, the file currently behaves like "no match" in default
  mode.
- `--text` first uses the raw-byte planner when a pattern stays inside the
  current planner-friendly subset and only falls back to a temporary lossy
  shadow haystack for patterns outside that subset.
- Before that lossy retry, exact, anchored, and simple alternated literal
  patterns get a true raw-byte search path against the original file bytes.
- Those literal-byte paths now cover UTF-8 literals from the pattern too, not
  just ASCII-only literals.
- The current raw-byte path also covers simple concat sequences built from
  literals, dots, and character classes, such as `a[0-9]b`, `a[^x]b`,
  `a.[0-9]b`, `жар`, literal-only UTF-8 classes like `[ж]`, and small
  positive UTF-8 ranges like `[а-я]`, plus negated literal-only UTF-8 classes
  like `[^ж]`, negated small UTF-8 ranges like `[^а-я]`, and larger single
  UTF-8 ranges like `[Ā-ӿ]` or `[^Ā-ӿ]` when they are not quantified.
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
- Planner-friendly captures on that same subset now preserve group spans on
  the raw-byte path too, including simple repeated-group cases such as
  `(ab)+c`.
- The lossy shadow haystack replaces each invalid byte that breaks UTF-8
  decoding with the single ASCII byte `?`.
- Matching uses that lossy shadow haystack only as an internal aid. Printed
  output still comes from the original file bytes.
- The lossy shadow haystack is now only used for patterns that still do not
  have a planner-backed raw-byte path.

## Regex Meaning In The Current Invalid-UTF-8 Path

Under the current invalid-UTF-8 behavior:

- Exact, anchored, and simple alternated literal patterns plus simple concat
  sequences built from literals, dots, and character classes plus repetition,
  transparent grouping, grouped alternation, and quantified grouped alternation
  over that subset, plus empty branches including inside quantified grouped
  alternation and anchored empty matches, match against the original file
  bytes.
- Literal-only UTF-8 classes are part of that subset when they are positive
  sets of explicit code points like `[ж]` or `[жё]`. Small positive UTF-8
  ranges are also part of it when they can be expanded safely, such as
  `[а-я]`. Negated literal-only UTF-8 classes like `[^ж]` and negated small
  UTF-8 ranges like `[^а-я]` are also part of it. Larger Unicode ranges are
  also part of it when they are unquantified, such as `[Ā-ӿ]` or `[^Ā-ӿ]`.
  Quantified larger Unicode ranges still fall outside the current byte
  planner.
- Planner-friendly capture groups on that raw-byte subset keep capture spans
  instead of degrading to whole-match-only reporting.
- Under `--text`, patterns outside that subset still retry through the lossy
  shadow haystack, so `.` can match a replaced invalid byte because the matcher
  sees `?`.
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
