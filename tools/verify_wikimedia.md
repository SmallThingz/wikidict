# Wikimedia differential verification

Run the native expander against deterministic reservoir samples, targeted multilingual pages and synthetic parser edge cases, then compare with the read-only English Wiktionary Action API:

```sh
python -B tools/verify_wikimedia.py \
  --dump data/wiktionary-latest/enwiktionary-20260901-pages-meta-current.xml \
  --root data/wiktionary-20260901-complete/.bundle-expander \
  --worker data/wiktionary-20260901-complete/.bundle-expander/dict-bundle-expander \
  --report data/wikimedia-check --samples 32 --seed 20260922
```

Use a new report directory for each run. `--cache PATH` reuses recorded API responses, including their timestamps. The checker honors `Retry-After` across all cases in a run, including HTTP 200 responses with a `maxlag` error. When more than 30 seconds remain, it records uncached comparisons as deferred and continues with local and cached evidence. The report preserves the failure for each affected case. Exit zero means every selected case passed. Run `python -B tools/verify_wikimedia_test.py` for offline protocol, sampling, normalization and classification tests.

Exact expanded text is checked first. Differences are compared as rendered DOM tokens, including whitespace, attributes and categories. The presentation oracle parses the original page source: reparsing the output of `expandtemplates` can introduce fragment-context tracking categories. Unresolved local template syntax cannot receive a rendered-equivalence pass because the remote parser might repair it.

The live API's `revid` parameter supplies revision context; it does not freeze template/module revisions to the dump date. Dependency revision differences are recorded and mismatches remain unresolved. Matching errors are not successes except in intentional error probes. A sample pass also does not prove successful blob encoding or reader fidelity; run the separate corpus builder/verifier and reader tests.
