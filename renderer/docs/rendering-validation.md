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

Here, publication means finalizing verified local dictionary files. It does not
approve a release or establish production readiness; those require user approval.

The build report has one JSON object per recovered page:

```json
{"namespace":0,"title":"example","reasons":["literal_markup","unclosed_formatting"]}
```

`complete.json` records the validated line count as `fallback_pages` and names the
report as `fallback_report`. Read that field to choose either plain
`fallback-pages.jsonl` or `fallback-pages.jsonl.gz`. For gzip reports,
`fallback_report_decoded` records the exact original size and SHA-256. Native
shards and failure diagnostics continue to use plain JSONL. Publication rejects
blank or malformed JSONL records, invalid identities, empty or duplicate reasons,
and duplicate `(namespace,title)` records before compression or rename.

The current presentation reasons are defined by
[`presentation_fallback.Report`](../../compiler/src/encoder/presentation_fallback.zig).
They include unresolved language/style decisions, unrepresented figures and image
maps, rejected targets, and visible Lua/extension errors as well as the original
syntax and expansion failures. The builder also records
`unsupported_parser_function` and specific operational failures such as
`expansion_error:Timeout` or `expansion_error:expand:ErrorName`. When finalizing
or reopening an edition, the builder rejects timeouts, out-of-memory errors,
infrastructure failures, and expansion failures caused by missing file metadata,
interface messages or language names (`FileMetadataSnapshotMissing`,
`InterfaceMessageSnapshotMissing`, `LanguageNameSnapshotMissing`). The diagnostic
names the affected title. Supply a snapshot covering that lookup and rebuild the edition.
Other recorded rendering defects remain available for comparison with the source.

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
in the fallback report.

## Comparing compiled definitions to the original dump

Pass `--definition-dump` to the Reader presentation audit to compare numbered
source lines with the compiled entry. Supply the original XML member from the
edition's `complete.json`, or repeat the option for each split member.

```sh
python3 tools/verify_presentation.py --root "$edition" --report "$report" \
    --definition-dump "$dump"
```

With a Reader built from the matching audit-reference source, select it
explicitly to reuse fixed-feature bodies across repeated language-view redirects.

```sh
python3 tools/verify_presentation.py --binary "$reader" --root "$edition" \
    --report "$report" --definition-dump "$dump" --batch-size 32 \
    --audit-reference-hints
```

The audit still resolves each redirect in its selected view. It reads the full
body on first use and again for a different destination record, so conflicts
remain detectable. The default works with older Readers using ordinary exports.
If an opted-in export fails, the audit reports an incomplete scan.

For editions with hundreds of language headings or many redirects, the current
Reader can keep the language index open while browsing and exporting entries.
`--audit-browse-session` fetches each search page through that same process.
This avoids reopening the redirect index for every 1,000 titles. The following
command exports up to 64 titles per request. If a redirect target is
absent in the selected language, the audit can reuse the original redirect
record after checking its content identity. It still follows targets that exist
in that language.

```sh
python3 tools/verify_presentation.py --binary "$reader" --root "$edition" \
    --report "$report" --definition-dump "$dump" --batch-size 64 \
    --catalog-page-size 64 --audit-export-session --audit-browse-session --audit-reference-hints \
    --audit-alias-references
```

For a scan that may span several runs, add `--checkpoint "$work/reader.sqlite"`.
Keep the database and its SQLite sidecar files outside the dictionary directory.
Rerun the command with the same dictionary, Reader, source dump, registry and
options. It verifies those inputs and resumes at the last committed search page.
The final report includes findings from every page. Use a fresh checkpoint when
changing the inputs or the verifier.

For a large edition, give `--report` a filename ending in `.json.gz`. The audit
writes compressed JSON directly, including findings from failed scans. `gzip -dc`
returns the same UTF-8 JSON as the plain report. Use `--summary-json` in batch
scripts to read the status and counts from standard output after the report has
been written. This avoids loading every flagged field a second time.

`render-diagnostic` marks visible text such as `[malformed link]`, `[missing
parameter]` and `[render output truncated]`. Check the original page to distinguish
an authored example from a message inserted during rendering.

The audit verifies each compressed member against its recorded size and SHA-1.
It checks plain text and internal links under literal language headings
on template-free pages. A match requires the expected language, definition
order, numbering depth, visible text and destination of each linked range.
A nested sense written with `##` must still be a second-level definition in the
Reader. The audit skips numbered examples and quotations (`#:`, `##*`). Swapping
two links with the same display text fails the check. A single balanced italic
or bold passage must cover the same Unicode character range in the decoded spans.
In the Albanian entry for English `foot`, this checks both linked translations
and their italic qualifiers, `skaj` and `njësi matëse`. `source_definitions` reports eligible,
matched and unmatched counts with up to 32 examples and their page and revision
IDs. Review unmatched lines against the source, including numbered examples
and lists of related terms. Expanded templates, more complex formatting and
the appearance of the rendered page need separate checks.

When a line matches, `matched_example` gives its source page, revision, line,
lookup title, compiled language heading and visible definition. The last three
fields can be passed to the terminal check with the selected publication path
and manifest digest. The field is null when no line matched.

When an edition uses localized headings such as Tulu `ತುಳು`, pass
`--definition-registry` with the `language-registry.tsv` used for that build.
The audit checks its SHA-256 against `complete.json` and compares each
unambiguous primary MediaWiki name with the language code in the decoded entry.
This also finds eligible definitions when the compiled catalog omitted their language.

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
expansion, and XZ work; `--jobs` overlaps edition pipelines. At that historical
checkpoint, orchestration gated new jobs against CPU load and an 8 GiB aggregate
memory cap. Current resource rules are in [AGENTS.md](../../AGENTS.md): corpus jobs
have their own 8 GiB budget, and admission checks the new allocation plus its
reserve against available memory, including explicitly verified eligible swap.
Prepared jobs are not allocations. Once a job starts, host RAM and PSI changes
are telemetry only; its own memory, CPU, task and time limits still apply.
Correctness checks do not require a quiet benchmark host. The individual native
link command remains one link operation and is not claimed to be internally
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

## Focused failure diagnosis

When preparing a necessary focused native test build, use the existing
`prepare-tests` selection with `-Dprepare-test-error-tracing=true` to retain
error-return locations in the selected test root. This avoids rebuilding an
otherwise useful test binary solely to locate an assertion. The option does not
recursively enable tracing in separately imported modules: a Tools test traces
its own assertion and file imports, but its named `encoder` dependency keeps
that module's original setting.

Preparation only compiles the selected executables. Record the tests actually
executed and their failures separately; neither successful preparation nor a
focused pass replaces the required full suite or real dictionary/UI checks.
