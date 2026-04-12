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
- Before that lossy retry, exact and anchored ASCII literal patterns get a true
  raw-byte search path against the original file bytes.
- The lossy shadow haystack replaces each invalid byte that breaks UTF-8
  decoding with the single ASCII byte `?`.
- Matching uses that lossy shadow haystack only as an internal aid. Printed
  output still comes from the original file bytes.

## Regex Meaning In The Temporary `--text` Path

Under the current `--text` fallback:

- Exact and anchored ASCII literal patterns match against the original file
  bytes.
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
