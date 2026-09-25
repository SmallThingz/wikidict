# Presentation validation - 2026-09-25

The shipped reader format remains data-only. Lua modules, template source, wikitext,
LLVM bitcode, native expander code, and deferred executable presentation are build
inputs only. Readers decode compiled `.wikblb` presentation records and do not
repair or re-expand source.

## Strict and publication compilers

`presentation_document.compileAlloc` is still the strict boundary. Literal source
delimiters, tag-shaped source text, unresolved templates, and other uncompiled
presentation are errors.

The corpus builder uses `compileReportedAlloc`. It applies only explicit recovery
needed to keep a build usable, records every affected page, and still emits the
same data-only presentation schema. Recovery never installs a second Lua engine
or a reader-side wikitext fallback.

The build report is `fallback-pages.jsonl`, with one JSON object per recovered
page:

```json
{"namespace":0,"title":"example","reasons":["literal_markup","unclosed_formatting"]}
```

`complete.json` records the validated line count as `fallback_pages` and names the
report as `fallback_report`. Publication rejects blank or malformed JSONL records,
invalid identities, empty/duplicate reasons, and duplicate `(namespace,title)`
records before compression or rename.

Current fixed reasons are `literal_markup`, `unclosed_formatting`,
`malformed_table`, `unsupported_element`, `render_limit`,
`template_presentation`, `missing_template`, `display_title_rejected`,
`missing_language_heading`, and `expansion_error`. Operational expansion failures
also add a specific reason such as `expansion_error:Timeout` or
`expansion_error:expand:ErrorName`.

## MediaWiki recovery oracle

Recovery rules that claim MediaWiki behavior are checked against the live
Wiktionary `action=parse` endpoint:

```sh
python3 tools/check_mediawiki_recovery.py --out .tmp/mediawiki-recovery-report.json
```

The twelve current cases passed a fresh live check on 2026-09-25. The checker
disables edit-section controls and checks heading levels as well as semantic
visible text:

- an unclosed `[[` opener remains literal;
- orphan `]]` closers remain literal;
- unclosed `<small>` formatting still renders its contents;
- empty `[[]]` remains literal;
- an orphan `|}` table closer remains literal;
- a rowless table retains readable list/link contents;
- disallowed `<script>...</script>` source is escaped and visible literally;
- `<graph>...</graph>` contributes no visible text in the checked case;
- a nonexistent template renders as a red `Template:name` link and its arguments
  are not displayed or shipped as executable/custom template data.
- asymmetric heading delimiters use the smaller delimiter count as their level
  and retain extra equals signs in the visible title; 7+ balanced delimiters
  clamp to heading level 6;
- valid `itemprop` metadata contributes no visible text.

The compiler follows those observed results instead of inserting cleanup prose.
For example, it no longer emits invented `[unsupported HTML: ...]` or
`[unsupported extension: ...]` markers.

Data-backed or interactive extensions that this offline format cannot reproduce
are omitted and reported as `unsupported_element`. This is an explicit fidelity
limitation, not a claim that every extension has MediaWiki-equivalent output.

Ordinary Scribunto call failures are recovered inside the build-time expander as
MediaWiki-style `Lua error in ...` markup. An outer worker timeout, oversized
request, or unrecovered expansion failure is different: there is no live-page
semantic result to copy. The builder therefore retains the page under
`Unclassified` with no fabricated body text and puts the exact failure category
in `fallback-pages.jsonl`.

## Whole-dump evidence

The earlier recovery checkpoint was exercised against complete indexed
2026-09-01 dumps using retained compiled expanders, then `verify-blobs`.
These historical results do not qualify the later link-trail, heading, URL-scan,
or shard-coverage changes:

| edition | pages | main pages | language records | language blobs | fallback pages |
| --- | ---: | ---: | ---: | ---: | ---: |
| Afrikaans | 36,290 | 29,931 | 29,935 | 10 | 29,144 |
| Old English | 3,942 | 2,515 | 2,568 | 68 | 480 |
| Asturian | 88,086 | 78,312 | 120,658 | 89 | 247 |
| Arabic | 146,530 | 84,260 | 84,749 | 122 | 15,686 |

Every listed report parsed through the same strict publication validator. The
Afrikaans change is deliberately large: 29,144 main pages without a recognized
language heading are now retained under `Unclassified` and reported instead of
being silently dropped.

A fresh end-to-end Old English build from the downloaded dump also passed native
Lua compilation/linking, page expansion, blob verification, XZ
compression and round-trip verification. It published 68 `.wikblb.xz` files,
kept all 480 fallback records, removed the raw `.wikblb` files, and wrote matching
`complete.json` metadata.

A separate real two-edition run built `aawiktionary` and `abwiktionary` with two
concurrent edition jobs and two workers per edition. Their compile/link/expand
pipelines overlapped and both published verified compressed output with fallback
reports. `--threads` controls per-edition Lua parsing, LLVM compilation, page
expansion, and XZ work; `--jobs` overlaps edition pipelines. Current orchestration
also gates new jobs against live CPU load and available memory, so those are
upper bounds rather than a promise to saturate the machine. The individual native
link command is still one link operation and is not claimed to be internally
multithreaded.

## What this does not prove

Successful whole-dump encoding is not whole-corpus semantic parity. Language
classification remains edition-dependent, large `Unclassified` counts need
upstream/data-model review, and unsupported data-backed extensions remain
reported omissions. The fallback report is the audit surface for those cases;
build success must not be used to hide them.

The full `zig build test -Doptimize=ReleaseFast` suite and bundle integration were
run at that earlier recovery checkpoint. Its bundle integration reported
`BUNDLE_INTEGRATION_PASS checks=19` and verifies the final tree contains compiled
data only.
