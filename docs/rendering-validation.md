# Presentation validation — 2026-09-23

The renderer now compiles optional `li`, `tr`, and `td` end tags, leading-space
inline markup, translation layout tables, nested inflection tables, and HTML rows
inside wiki tables. Nested grids within cells become semantic reading-order spans
with explicit row/cell boundaries; DPR2 does not encode recursive grids.

`presentation_document.compileAlloc` rejects source delimiters and tag-shaped text
in the final presentation, including markup split across spans or protected by
`nowiki`. It checks headings, display titles, blocks, tables, references, and media
captions. This is a build error, with no reader-side parsing or cleanup fallback.
It deliberately also rejects literal source examples containing these delimiters;
that is the product's strict no-source-syntax policy, not MediaWiki equivalence.

Reproduce the diagnostic scan (the JSON export is validation-only):

```sh
python3 tools/verify_presentation.py --root DATASET --report REPORT.json
```

A 64-page slice from the 2026-09-01 dump produced 474 language records across 280
languages. After the parser fixes, the combined-text audit still rejects five
records: English **February** and **pound**, and Latin **September**, **gratis**,
and **pie**. February contains a literal invalid interwiki transclusion; pound
contains an escaped `[[Episode 4]]` quotation title; the Latin records contain
malformed generated HTML attributes. The live Wikimedia parse endpoint also
renders February's `{{w:Numa Pompilius|King Numa}}` literally. We do not silently
rewrite quotations or claim that these records passed.

The Android development fixture contains the other 30 English records. Its
instrumentation test decodes every record and audits all displayed text. It is
not a complete dictionary. Full-corpus validation and publication remain blocked.
Local evidence is under `data/renderer-validation/syntax-audit/`.
