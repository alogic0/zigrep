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
