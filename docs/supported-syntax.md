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
- Lazy quantifiers `*?`, `+?`, `??`, and `{m}`, `{m,}`, `{m,n}` followed by `?`
- Character classes like `[abc]`, `[a-z]`, and negated classes like `[^a-z]`
- Shorthand classes `\d`, `\D`, `\w`, `\W`, `\s`, and `\S`
- Word boundaries `\b` and `\B`
- Half-word boundaries `\b{start-half}` and `\b{end-half}`
- Non-capturing groups `(?:...)`
- Inline Unicode mode groups `(?-u:...)` and `(?u:...)`
- Inline local case-fold groups `(?i:...)` and `(?-i:...)`
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
- Class-set operators inside bracket classes:
  - subtraction like `[\w--\p{ASCII}]`
  - intersection like `[\p{Greek}&&\p{Uppercase}]`
  - nested forms like `[\w--[\p{ASCII}&&[^_]]]`

Current class-set boundary:

- nested class-set expressions are supported through nested bracketed operands
- each class-set node still uses one explicit operator (`--` or `&&`)
- class-set patterns stay off the raw-byte planner and run on the general VM path

The current engine exposes a growing native Unicode property surface.

Unicode data note:

- the planned Unicode property work borrows checked-in Unicode database files
  from the local `zg` repository at generation time only
- `zigrep` runtime code is expected to use only generated files checked into
  this repo, not a runtime dependency on `zg`
- the current generated Unicode property tables are pinned to Unicode version
  `16.0.0`

Current escape boundary:

- supported control and byte escapes include `\n`, `\r`, `\t`, `\f`, `\v`, `\0`, and `\xNN`
- Unicode literal escapes with braced hex syntax are supported via `\u{...}`
- escaped metacharacters like `\.`, `\(`, `\)`, `\[`, and `\\` are supported
- shorthand classes `\d`, `\D`, `\w`, `\W`, `\s`, and `\S` are supported
  - by default, `\d` and `\D` use Unicode decimal-digit semantics
  - by default, `\w` and `\W` use the Unicode word-character predicate
  - by default, `\s` and `\S` use Unicode whitespace semantics
  - in normal non-multiline search, `\s` does not match `\n`
- word boundaries `\b` and `\B` are supported
  - boundary checks use the same Unicode word-character predicate as `\w`
  - invalid bytes on the raw-byte path are treated as non-word units
- half-word boundaries are supported:
  - `\b{start-half}` checks only the left side for non-word/start-of-input
  - `\b{end-half}` checks only the right side for non-word/end-of-input
  - they use the same Unicode or ASCII word predicate as the surrounding mode
- inline Unicode mode groups are supported:
  - `(?-u:...)` switches shorthand and boundary operators inside the group to ASCII behavior
  - `(?u:...)` switches them back to Unicode-aware behavior inside a nested group
  - inside `(?-u:...)`, Unicode property escapes like `\p{Greek}` remain unsupported
- inline local case-fold groups are supported:
  - `(?i:...)` enables local case-insensitive matching for the group
  - `(?-i:...)` disables local case-insensitive matching for the group
  - they compose with global `--ignore-case` and `--smart-case` by overriding
    only the local subgroup
  - broader inline flag syntax remains unsupported
- explicit ASCII regexes such as `[0-9]` and `[A-Za-z0-9_]` remain the stable
  way to request ASCII-only behavior outside inline mode groups
- explicit ASCII whitespace classes such as `[ \t\r\n\f\v]` remain the stable
  way to request ASCII-only whitespace behavior outside inline mode groups
- Unicode property escapes are supported for:
  - `\p{Any}` and `\P{Any}`
  - `\p{ASCII}` and `\P{ASCII}`
  - `\p{Alphabetic}` and `\P{Alphabetic}`
  - `\p{Cased}` and `\P{Cased}`
  - `\p{Case_Ignorable}` and `\P{Case_Ignorable}`
  - `\p{ID_Start}` and `\P{ID_Start}`
  - `\p{ID_Continue}` and `\P{ID_Continue}`
  - `\p{Letter}` and `\P{Letter}`
  - `\p{Lowercase}` and `\P{Lowercase}`
  - `\p{Titlecase_Letter}` and `\P{Titlecase_Letter}`
  - `\p{Modifier_Letter}` and `\P{Modifier_Letter}`
  - `\p{Other_Letter}` and `\P{Other_Letter}`
  - `\p{Mark}` and `\P{Mark}`
  - `\p{Nonspacing_Mark}`, `\p{Spacing_Mark}`, and `\p{Enclosing_Mark}`
  - `\p{Number}` and `\P{Number}`
  - `\p{Decimal_Number}`, `\p{Letter_Number}`, and `\p{Other_Number}`
  - `\p{Punctuation}` and `\P{Punctuation}`
  - `\p{Connector_Punctuation}`, `\p{Dash_Punctuation}`, `\p{Open_Punctuation}`, `\p{Close_Punctuation}`, `\p{Initial_Punctuation}`, `\p{Final_Punctuation}`, and `\p{Other_Punctuation}`
  - `\p{Separator}` and `\P{Separator}`
  - `\p{Space_Separator}`, `\p{Line_Separator}`, and `\p{Paragraph_Separator}`
  - `\p{Symbol}` and `\P{Symbol}`
  - `\p{Math_Symbol}`, `\p{Currency_Symbol}`, `\p{Modifier_Symbol}`, and `\p{Other_Symbol}`
  - `\p{Other}` and `\P{Other}`
  - `\p{Control}`, `\p{Format}`, `\p{Surrogate}`, `\p{Private_Use}`, and `\p{Unassigned}`
  - `\p{Uppercase}` and `\P{Uppercase}`
  - `\p{Whitespace}` and `\P{Whitespace}`
  - `\p{XID_Start}` and `\P{XID_Start}`
  - `\p{XID_Continue}` and `\P{XID_Continue}`
  - `\p{Default_Ignorable_Code_Point}` and `\P{Default_Ignorable_Code_Point}`
  - `\p{Emoji}` and `\P{Emoji}`
  - Script support is also available in these forms:
    - direct names like `\p{Greek}` and `\p{Hebrew}`
    - qualified names like `\p{Script=Greek}`
    - short aliases like `\p{sc=Grek}`
  - `Script_Extensions` support is also available in these forms:
    - qualified names like `\p{Script_Extensions=Greek}`
    - short aliases like `\p{scx=Grek}`
  - script names and `sc=` aliases are generated from the pinned Unicode
    `Scripts.txt` and `PropertyValueAliases.txt` data
  - `Script_Extensions` data is generated from the pinned Unicode
    `ScriptExtensions.txt` data
  - `Unknown` / `Zzzz` follows the script fallback behavior for unassigned,
    private-use, and surrogate code points
  - the same property items may also appear inside bracket classes
    - for example `[\p{Letter}\P{Whitespace}]`
    - this also applies to `Script`, `Any`, and `ASCII` forms
  - accepted aliases currently include:
    - family aliases such as `L`, `N`, `M`, `P`, `S`, `Z`, and `C`
    - subgroup aliases such as `Ll`, `Lu`, `Lt`, `Lm`, `Lo`, `Mn`, `Mc`, `Me`, `Nd`, `Nl`, `No`, `Pc`, `Pd`, `Ps`, `Pe`, `Pi`, `Pf`, `Po`, `Sm`, `Sc`, `Sk`, `So`, `Zs`, `Zl`, `Zp`, `Cc`, `Cf`, `Cs`, `Co`, and `Cn`
    - long-name aliases such as `alpha`, `lower`, `upper`, `punct`, `space`, `white_space`, and `private_use`
  - property names are normalized by ignoring ASCII case, `_`, `-`, and ASCII whitespace
  - `Any` matches any valid Unicode scalar
  - `ASCII` matches only scalars in `U+0000..U+007F`
  - invalid raw bytes do not match positive Unicode properties and do match
    negated Unicode properties
- `\u{...}` accepts 1 to 6 hex digits and rejects surrogate code points and values above `U+10FFFF`

## Explicit Non-Goals

The following syntax is intentionally unsupported and should be treated as out
of scope for the main engine:

- Backreferences
- Lookahead and lookbehind
- Conditional groups and PCRE2 control verbs
- Recursion and subroutine calls
- Features that require general backtracking semantics
- Full PCRE2 compatibility

In particular, `(?:...)`, `(?-u:...)`, `(?u:...)`, `(?i:...)`, and `(?-i:...)`
are supported, but other `(?...)` group forms are rejected explicitly rather
than being interpreted partially.

## CLI Behavior

The current CLI supports:

- `zigrep [FLAGS] PATTERN [PATH...]`
- Recursive search from each path, defaulting to `.`
- Hidden-file inclusion with `--hidden`
- Ripgrep-style unrestricted search with `-u`, `-uu`, and `-uuu`
- Ignore controls with `--ignore-file`, `--no-ignore`, `--no-ignore-vcs`, and `--no-ignore-parent`
- Symlink following with `--follow`
- Case-insensitive search with `-i` / `--ignore-case` and `-S` / `--smart-case`
- Case-sensitive path glob filtering with repeated `-g` / `--glob`
- File type filters with `-t`, `-T`, `--type-add`, and `--type-list`
- Binary-file search controls with `--text` and `--binary`
- Buffered or mmap-backed reads with `--buffered` and `--mmap`
- Worker-count control with `-j` or `--threads`
- Walk depth limiting with `--max-depth`
- Context lines with `-A` / `--after-context`, `-B` / `--before-context`, and `-C` / `--context`
- Matching-line limit with `-m` or `--max-count`
- Count-only output with `-c` or `--count`
- Matching-file output with `-l` or `--files-with-matches`
- Non-matching-file output with `-L` or `--files-without-match`
- Inverted line selection with `-v` or `--invert-match`
- Match-only output with `-o` or `--only-matching`
- Newline-delimited JSON output with `--json`
- NUL-delimited path output with `--null` for file-path reporting modes
- Search summary output with `--stats`
- Grouped text output with `--heading`
- Output toggles with `-H`/`--with-filename`, `--no-filename`, `-n`/`--line-number`, `--no-line-number`, `--column`, and `--no-column`
- `--` to terminate flag parsing

`--max-count` note:

- `-m N` or `--max-count N` stops after `N` matching lines per file
- in normal output, that limits printed matching lines
- with `--count`, that limits the counted matching lines too
- with `--only-matching`, `zigrep` still prints every match occurrence from the first `N` matching lines

`--invert-match` note:

- `-v` or `--invert-match` selects non-matching lines instead of matching lines
- with normal output, it prints the lines that do not match the pattern
- with `--count`, it counts non-matching lines
- with `--files-with-matches` and `--files-without-match`, it uses the inverted line-selection semantics
- `--invert-match` is currently rejected with `--only-matching` and with context output

Context mode note:

- `-A N` prints `N` trailing context lines after each matching line
- `-B N` prints `N` leading context lines before each matching line
- `-C N` prints both leading and trailing context lines
- overlapping context groups are merged, and disjoint groups are separated by `--`
- context mode is currently supported only for normal line output
- combinations with `--count`, `--files-with-matches`, `--files-without-match`, or `--only-matching` are rejected
- context mode is also rejected with `--json` in the current implementation

`--json` note:

- `--json` emits one newline-delimited JSON event per result
- line and only-matching output emit `match` events
- `--count` emits `count` events
- `--files-with-matches` and `--files-without-match` emit `path` events
- displayed line content uses the same escaping rules as text output, including `\xNN` escapes for invalid or unsafe bytes
- this is a smaller event schema than ripgrep's full JSON format

`--null` note:

- `--null` currently applies to `--files-with-matches` and `--files-without-match`
- those modes emit matching or non-matching file paths terminated with `\0` instead of `\n`
- `--null` is currently rejected with normal line output, count output, context output, and `--json`

`--stats` note:

- `--stats` prints a compact search summary to stderr after the normal search output
- the current summary includes searched file count, matched file count, searched byte count, and skipped binary-file count
- `--stats` does not change normal exit codes or stdout search results

`--heading` note:

- `--heading` groups text line output by file
- each matching file is printed once as a heading, followed by its matching lines without the filename prefix
- groups are separated by a blank line
- `--heading` is currently supported only for text line output, including context mode
- `--heading` is rejected with count output, file-path-only output, `--json`, and `--null`

Multiline status note:

- `-U` / `--multiline` enables searches that can span line terminators
- `--multiline-dotall` makes `.` match `\n` in multiline mode
- the pinned target semantics for implementation are:
  - multiline mode permits matches to span line terminators
  - `.` still does not match `\n` by default
  - `--multiline-dotall` makes `.` match `\n`
  - multiline reporting will stay line-oriented by projecting full match spans back to covered display lines
- the current text output prints one merged display block per multiline match group, with line and column prefixes anchored to the first matched line
- `--only-matching` in multiline mode prints the exact matched substring, even across lines, with prefixes anchored to the first matched line
- `--count` in multiline mode counts multiline matches, not lines
- context mode in multiline mode expands around merged display blocks instead of individual internal match lines
- `--json` in multiline mode emits one `match` event per raw multiline match
  - `line_number` and `column_number` stay anchored to the first matched line
  - `match_span` stays the raw exact match span
  - `line_span` is the projected display-block span in normal multiline line mode and the raw exact match span in multiline `--only-matching`
- `--heading`, `--stats`, `--files-with-matches`, and `--files-without-match` are supported in multiline mode
- unsupported multiline combinations are still rejected for now:
  - `-v` / `--invert-match`
  - `-m` / `--max-count`

For non-technical users:

- `--buffered` means "use the simpler, safer read method for every file"
- `--mmap` means "use the faster read method when possible"

Practical guidance:

- use `--buffered` if you want the most conservative behavior
- use `--mmap` if you want normal fast behavior on regular files
- if you are unsure, the default behavior is already reasonable for typical use
- binary-file detection is intentionally normalized across `--buffered` and `--mmap`

`--glob` note:

- `-g GLOB` or `--glob GLOB` filters searched file paths relative to each root path
- repeated `-g` flags are allowed
- a plain glob like `*.zig` includes matching paths
- a bang-prefixed glob like `!main.zig` excludes matching paths
- if any positive globs are present, `zigrep` treats them as an allow-list
- matching is currently case-sensitive only; `--iglob` is not implemented yet

File type note:

- `-t TYPE` includes only files matching the named file type
- `-T TYPE` excludes files matching the named file type
- `--type-add name:glob[,glob...]` adds or extends a file type definition at runtime
- `--type-list` prints the current built-in and runtime-added file type definitions and exits
- type filtering is applied to file paths relative to each searched root
- `zigrep` currently ships a small built-in type table; it is not yet ripgrep's full file type catalog

Ignore-control note:

- by default, `zigrep` applies the current small internal `.gitignore`-subset matcher
- it loads `.gitignore` from the searched root and, unless disabled, parent directories too
- `--ignore-file PATH` adds extra ignore rules from `PATH`
- `--no-ignore` disables all ignore filtering
- `--no-ignore-vcs` disables `.gitignore` loading but still allows explicit `--ignore-file` rules
- `--no-ignore-parent` keeps the searched root's own `.gitignore` but skips parent `.gitignore` files
- `-u` is a shortcut for disabling ignore filtering
- `-uu` disables ignore filtering and includes hidden files
- `-uuu` disables ignore filtering, includes hidden files, and searches binary files

Case-mode note:

- `-i` or `--ignore-case` enables case-insensitive search
- `-S` or `--smart-case` enables ignore-case unless the pattern contains uppercase letters
- when both are present, the last one wins
- case-insensitive matching works through a folded regex rewrite instead of a separate VM mode
- the current rewrite uses generated simple case-fold data for Unicode literal and
  class folding, including cases like Greek sigma and accented Latin literals
- under `-i`, case-related Unicode properties such as `Lowercase`,
  `Uppercase`, and `Titlecase_Letter` are folded through the same simple
  case-fold closure in both top-level `\p{...}` atoms and bracket classes
- smart-case uppercase detection is Unicode-aware and currently treats
  `Uppercase` code points as case-sensitive triggers
- titlecase characters do not force smart-case sensitivity; they stay on the
  ignore-case path, matching the current observed ripgrep behavior
- case-folded patterns currently stay off the raw-byte planner and use the
  general VM path
- broad Unicode case-insensitive class ranges now use a dedicated folded-range
  representation instead of expanding every code point into literal class
  members
- examples such as `[\u{0000}-\u{FFFF}]` under `-i` are now accepted and stay
  on the general VM path instead of the raw-byte planner

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

Encoding note:

- `-E auto` is the default and allows BOM-based UTF-16 decoding
- `-E utf8`, `-E latin1`, `-E utf16le`, and `-E utf16be` force those decode paths
- `-E none` treats input as raw bytes and bypasses decode/transcode handling
- explicit non-`auto` encodings also bypass the default binary-file skip check tied to auto-detection

Compressed-input note:

- `-z` and `--search-zip` enable gzip-compressed file search
- this currently searches single gzip-compressed file payloads, not archive members
- compressed bytes are decompressed before binary detection, encoding handling, and match reporting
- this is an initial compressed-stream step, not full ripgrep-compatible compressed-input coverage

Preprocessor note:

- `--pre CMD` runs `CMD <path>` and searches the command's stdout instead of the file's original bytes
- `--pre-glob GLOB` limits that transform to matching paths; without `--pre-glob`, `--pre` applies to every searched file
- `--pre` uses simple whitespace splitting for the command string, not shell parsing or quoting
- when both `--pre` and `-z` are present, `--pre` takes precedence for files selected by `--pre-glob`

Config note:

- `--config-path PATH` loads default flags from `PATH`
- `ZIGREP_CONFIG_PATH` provides the same behavior through the environment when `--config-path` is not given
- `--no-config` disables config loading for a single run
- config files are line-oriented: each non-empty, non-comment line becomes one extra CLI argument
- config arguments are prepended before command-line arguments, so later CLI flags still override config defaults

Status and warning note:

- exit code `0` means at least one match was found
- exit code `1` means no matches were found
- exit code `2` means a fatal CLI or runtime error stopped the search
- non-fatal file and directory skips remain warnings on stderr and do not change the grep-style `0` or `1` result
- `--stats` now includes `warnings_emitted` alongside the existing search counters
- compressed-input and preprocessor skips use readable warning text instead of raw internal error names

`--binary` note:

- `--binary` searches binary files but suppresses matching line content
- in normal text output, a matching binary file prints `path: binary file matches`
- with `--files-with-matches` and `--files-without-match`, it uses file-selection semantics over binary files
- `--binary` is currently rejected with `--count`, `--only-matching`, `--heading`, and `--json`

Output is line-oriented. When enabled, prefixes are emitted in this order:

- file path
- line number
- column number

## Search-Tool Non-Goals

The current search tool does not yet implement:

- `.gitignore` compatibility beyond the small internal ignore-rule subset
- stdin search
- replacement/substitution
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
