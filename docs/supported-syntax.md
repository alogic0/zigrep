# Supported Syntax and Non-Goals

This document describes the regex and CLI surface that `zigrep` implements
today. It is intentionally narrower than PCRE2 and other backtracking engines.

## Regex Syntax

The current engine supports:

- Literals, including UTF-8 literals
- Concatenation
- Alternation with `|`
- Capturing groups with `(...)`
- Wildcard `.` matching any character except newline
- Anchors `^` and `$`
- Quantifiers `*`, `+`, `?`
- Counted repetition with `{m}`, `{m,}`, and `{m,n}`
- Character classes like `[abc]`, `[a-z]`, and negated classes like `[^a-z]`
- Escaped metacharacters such as `\.`, `\(`, `\)`, `\[`, `\]`, `\{`, `\}`, `\|`, `\*`, `\+`, `\?`, `\^`, `\$`, and `\\`

Notes:

- `.` does not match `\n` by default.
- Matching is UTF-8 aware but stays byte-oriented in the hot path.
- Captures are supported by the engine, but the current CLI only reports whole-line matches.

## Character Class Behavior

Character classes support:

- Literal members: `[abc]`
- Ranges: `[a-zA-Z0-9]`
- Negation in the leading position: `[^0-9]`
- Literal `]`, `-`, and `^` when used in non-special positions or escaped

The current engine does not yet expose named Unicode properties or shorthand
class syntax such as `\d`, `\w`, or `\s` in the user-facing regex syntax.

## Explicit Non-Goals

The following syntax is intentionally unsupported and should be treated as out
of scope for the main engine:

- Backreferences
- Lookahead and lookbehind
- Non-capturing groups like `(?:...)`
- Conditional groups and PCRE2 control verbs
- Recursion and subroutine calls
- Features that require general backtracking semantics
- Full PCRE2 compatibility

In particular, `(?...)` group forms are rejected explicitly rather than being
interpreted partially.

## CLI Behavior

The current CLI supports:

- `zigrep [FLAGS] PATTERN [PATH...]`
- Recursive search from each path, defaulting to `.`
- Hidden-file inclusion with `--hidden`
- Symlink following with `--follow`
- Binary-file search opt-in with `--text`
- Buffered or mmap-backed reads with `--buffered` and `--mmap`
- Worker-count control with `-j` or `--threads`
- Walk depth limiting with `--max-depth`
- Output toggles with `-H`/`--with-filename`, `--no-filename`, `-n`/`--line-number`, `--no-line-number`, `--column`, and `--no-column`
- `--` to terminate flag parsing

For non-technical users:

- `--buffered` means "use the simpler, safer read method for every file"
- `--mmap` means "use the faster read method when possible"

Practical guidance:

- use `--buffered` if you want the most conservative behavior
- use `--mmap` if you want normal fast behavior on regular files
- if you are unsure, the default behavior is already reasonable for typical use

Current `--text` note:

- `--text` disables binary-file skipping and tries to search the file anyway
- if a file contains invalid UTF-8 bytes, the current implementation uses raw-byte matching against the original file bytes instead of retrying through a lossy shadow buffer
- planner-friendly literal, grouping, and simple byte-sequence regexes use the planner fast path, and remaining supported shapes fall through to the general raw-byte VM path
- planner-friendly empty capture groups like `a()b` are covered by that raw-byte path too
- default mode now uses that same raw-byte matcher for text-like invalid UTF-8 files; `--text` mainly changes file-selection policy by disabling binary-file skipping
- literal-only UTF-8 classes like `[ж]`, negated literal-only UTF-8 classes like `[^ж]`, small positive UTF-8 ranges like `[а-я]`, negated small UTF-8 ranges like `[^а-я]`, larger Unicode ranges like `[Ā-ӿ]`, `[^Ā-ӿ]`, or `[Ā-ӿ]+`, bare anchors like `^` or `$`, grouped alternation branches that use those anchored forms, and anchored grouped patterns like `(^ab)+c` are covered by that planner too while keeping normal anchor semantics; the remaining misses are broader regex shapes that still fall outside the planner
- when a reported line contains invalid bytes or unsafe control bytes, the CLI prints those bytes as `\xNN` escapes instead of sending them raw to the terminal
- this is still not full ripgrep-compatible encoding behavior
- the exact current rules are documented in [docs/invalid-utf8-semantics.md](invalid-utf8-semantics.md)

Output is line-oriented. When enabled, prefixes are emitted in this order:

- file path
- line number
- column number

## Search-Tool Non-Goals

The current search tool does not yet implement:

- `.gitignore` compatibility beyond the small internal ignore-rule subset
- stdin search
- replacement/substitution
- multiline output formatting
- context lines before or after matches
- counting-only, files-with-matches-only, or inverted-match modes
- full ripgrep flag compatibility

## Performance Model

The engine is designed around predictable automata-friendly execution:

- literal prefilters before full matching
- lazy DFA for non-capturing search
- Pike VM for captures and general correctness
- ASCII-first fast paths
- optional SIMD-gated literal scanning

This is why the supported syntax is intentionally smaller than backtracking
regex engines.
