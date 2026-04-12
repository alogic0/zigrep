# Invalid UTF-8 Semantics

This note defines the current `zigrep` behavior for files that are treated as
searchable text but still contain invalid UTF-8 bytes.

## Current Rules

- Default mode does not abort the whole search on invalid UTF-8.
- If a file is classified as binary, default mode still skips it before matching.
- If a file is classified as text and the pattern is covered by the current
  raw-byte matcher, default mode uses that raw-byte path too.
- If a file is classified as text, both default mode and `--text` use the same
  raw-byte matcher semantics on invalid UTF-8 input.
- The current implementation has a planner fast path plus a general raw-byte VM
  fallback, both operating against the original file bytes.
- Those literal-byte paths now cover UTF-8 literals from the pattern too, not
  just ASCII-only literals.
- The current raw-byte path also covers simple concat sequences built from
  literals, dots, and character classes, such as `a[0-9]b`, `a[^x]b`,
  `a.[0-9]b`, `жар`, literal-only UTF-8 classes like `[ж]`, and small
  positive UTF-8 ranges like `[а-я]`, plus negated literal-only UTF-8 classes
  like `[^ж]`, negated small UTF-8 ranges like `[^а-я]`, and larger UTF-8
  ranges like `[Ā-ӿ]`, `[^Ā-ӿ]`, or `[Ā-ӿ]+`, plus bare anchors like `^` and
  `$`, grouped alternation branches that carry those anchors, and anchored
  grouped patterns like `(^ab)+c` while still keeping the normal anchor
  semantics.
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
- Empty capture groups inside that same subset are also supported, such as
  `a()b`.
- Empty branches are also supported inside quantified grouped alternation, such
  as `((|ab))+c` and `((|ab)){2}c`.
- Planner-friendly captures on that same subset now preserve group spans on
  the raw-byte path too, including simple repeated-group cases such as
  `(ab)+c`.
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
  also part of it, including quantified forms, such as `[Ā-ӿ]`, `[^Ā-ӿ]`, or
  `[Ā-ӿ]+`. The remaining gap is now patterns that still fall outside the
  planner for structural reasons, not because the class itself is larger.
- Planner-friendly capture groups on that raw-byte subset keep capture spans
  instead of degrading to whole-match-only reporting.
- Patterns outside the planner subset still use the same raw-byte matcher
  semantics through the general byte-oriented VM path.
- Anchors and newline behavior still follow the current regex engine rules.
- Column numbers and line spans stay byte-oriented against the original file
  bytes.

## Output Behavior

- Reported lines come from the original file bytes.
- Invalid bytes and unsafe control bytes are escaped as `\xNN` when printed.
- This avoids writing raw binary noise to the terminal while still showing the
  real underlying bytes that contributed to the match.

## Target Engine-Level Semantics

The intended replacement for the current temporary fallback is a general
byte-oriented matcher path with the following rules.

### Literals

- A literal from the pattern matches the exact UTF-8 byte sequence produced by
  that literal code point.
- ASCII literals therefore match one byte.
- Non-ASCII literals match their full UTF-8 byte sequence.
- Literal matching does not require the surrounding haystack bytes to form a
  globally valid UTF-8 string.

### Dot

- `.` matches one byte-oriented text unit.
- For ASCII bytes, that unit is one byte.
- For a valid UTF-8 leading byte sequence, that unit is the full decoded
  scalar width.
- For an invalid byte that cannot start a valid UTF-8 scalar, that unit is the
  single invalid byte.
- `.` still does not match `\n`.

### ASCII Classes

- ASCII-only classes continue to match one byte at a time.
- Negated ASCII classes also operate on one byte at a time.

### UTF-8 Literal And Range Classes

- Positive non-ASCII classes operate on one decoded UTF-8 scalar when the next
  bytes form a valid scalar.
- A positive non-ASCII class does not match an invalid leading byte.
- Negated non-ASCII classes operate on one decoded UTF-8 scalar when the next
  bytes form a valid scalar.
- If the next byte is invalid and cannot begin a valid scalar, a negated
  non-ASCII class matches that single invalid byte.

### Anchors

- `^` and `$` remain zero-width assertions over byte offsets.
- `^` matches only byte offset `0`.
- `$` matches only byte offset `haystack.len`.
- Anchors keep the same regex meaning whether they appear alone, inside groups,
  or inside larger concatenations.
- Repetition over zero-width anchors must not create infinite loops; repeated
  zero-width matches collapse to the same zero-width assertion semantics.

### Captures

- Whole-match and group spans remain byte offsets into the original file bytes.
- Captures must preserve the current “last iteration wins” behavior for
  repeated groups.
- Printed output continues to come from the original file bytes, not from any
  transformed shadow buffer.

### Default Mode And `--text`

- The matcher semantics should be the same in default mode and `--text`.
- The difference between those modes should only be file-selection policy:
  default mode may skip files by binary heuristic, while `--text` forces the
  file through the matcher.
