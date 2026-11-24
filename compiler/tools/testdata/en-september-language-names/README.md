# Reviewed English language-name sources

The `sources` directory retains immutable upstream PHP and CLDR files, their HTTP receipts, and the complete CLDR Git tree. It contains source evidence; it does not contain a dated Wiktionary API capture.

The English-only profile binds MediaWiki `db332802a5f05525b779baadbf8d3394bc7d989e` and CLDR `bf2dd4586bf7e1fdee99630fba7e0cd800c6c5d7`. The retained Scribunto LanguageLibrary bytes match revision `25f7cdefa45a3b8417d7fa296f86b76537927f43`. The English CLDR table contains 1,504 names before the API inventory and configured MediaWiki names are reconciled.

Compared with the existing reviewed generic profile, the relevant core change replaces a string callable with first-class callable syntax in fallback initialization. The CLDR LanguageNames change changes a comment only. Its names table is pinned separately. Core source receipts bind exact revision URLs and bytes; CLDR receipts also join the files to their Git blobs. Original upstream license notices remain in the retained files.

Tests require the exact source tuple and reject changed bytes, crossed receipt paths, other display locales, deployment claims, and unsupported extra direction derivations. Old generic and Italian profiles keep their existing source contracts. A future API capture must still independently establish response identity, complete continuation, exact namespace binding, names and directions; this source fixture does not establish runtime query closure or historical API state.

The separate autonym comparison records the same core's five-file null-display API contract. Four files remain byte-identical to the earlier profile. LanguageNameUtils changes only initialization of a private nullable cache to the null-coalescing assignment syntax. The v2 comparison identifies this changed file explicitly; it does not claim that all five files are identical. Genuine null-display responses remain separate from translated English display names. Continuations retain one second between requests.
