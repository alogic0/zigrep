# Unicode Data Generation

This note documents how `zigrep` generates checked-in Unicode data files for
native regex support.

## Purpose

`zigrep` does not depend on an external Unicode library or checkout at runtime.

Instead:

- Unicode database files are borrowed at generation time
- generator output is written into checked-in Zig source files in this repo
- runtime code imports only those generated local files

## Current Generator

The generator tool is:

- [tools/gen_unicode_props.zig](../tools/gen_unicode_props.zig)

Its current target output is intended to be:

- `src/regex/unicode_props_generated.zig`

## Default Data Source

By default, the generator reads Unicode data from the local `zg` checkout at:

- `../zig-libs/zg/data/unicode`

Specifically, the current property generator reads:

- `UnicodeData.txt`
- `PropList.txt`
- `DerivedCoreProperties.txt`
- `extracted/DerivedGeneralCategory.txt`
- `Scripts.txt`
- `ScriptExtensions.txt`
- `PropertyValueAliases.txt`
- `emoji/emoji-data.txt`
- `CaseFolding.txt`
- Unicode version `16.0.0`

This is a generation-time input only.

`zigrep` source and runtime behavior must not depend on the `zg` checkout being
present.

## Commands

Default local `zg` checkout:

```bash
zig run tools/gen_unicode_props.zig -- --output src/regex/unicode_props_generated.zig
```

Explicit `zg` root:

```bash
zig run tools/gen_unicode_props.zig -- --zg-root ../zig-libs/zg --output src/regex/unicode_props_generated.zig
```

Explicit Unicode data files:

```bash
zig run tools/gen_unicode_props.zig -- \
  --unicode-data /path/to/UnicodeData.txt \
  --prop-list /path/to/PropList.txt \
  --derived-core-properties /path/to/DerivedCoreProperties.txt \
  --derived-general-category /path/to/DerivedGeneralCategory.txt \
  --scripts /path/to/Scripts.txt \
  --script-extensions /path/to/ScriptExtensions.txt \
  --property-value-aliases /path/to/PropertyValueAliases.txt \
  --emoji-data /path/to/emoji-data.txt \
  --case-folding /path/to/CaseFolding.txt \
  --output src/regex/unicode_props_generated.zig
```

## Contributor Rule

When Unicode data changes:

- run the generator
- commit the generated Zig file into this repo
- do not add a runtime dependency on `zg`
- do not add absolute filesystem paths to runtime code

## What Is Borrowed From `zg`

Borrowed:

- checked-in Unicode database files under `zg/data/unicode`
- the general idea of generating compact Zig-friendly Unicode tables from those
  files

Not borrowed:

- a runtime module dependency on `zg`
- direct imports from `zg` in `zigrep` runtime code
- absolute local checkout paths in `src/...`
