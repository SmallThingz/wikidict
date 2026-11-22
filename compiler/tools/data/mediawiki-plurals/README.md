# MediaWiki plural rule data

The two XML files are verbatim files from MediaWiki revision
`0d3b507d19ae860ed8a1d22c73fa4bc5abf8dfcc`:

- https://github.com/wikimedia/mediawiki/blob/0d3b507d19ae860ed8a1d22c73fa4bc5abf8dfcc/languages/data/plurals.xml
- https://github.com/wikimedia/mediawiki/blob/0d3b507d19ae860ed8a1d22c73fa4bc5abf8dfcc/languages/data/plurals-mediawiki.xml

`tools/generate_plural_rules.py` verifies their SHA-256 pins, preserves rule
order, and replaces an entire language family when the second file overrides
it. It emits direct Zig conditions and a static language map; there is no
runtime XML, ambient ICU dependency, or new reader/frontend data format.
Run the generator with `--check` to verify the committed output.

Original XML headers are retained. `MEDIAWIKI-COPYING` is the verbatim COPYING
from that revision: MediaWiki's stated default is GPL-2.0-or-later, subject to
its component notices. `UNICODE-LICENSE.txt` is the verbatim Unicode License v3
retrieved from https://www.unicode.org/license.txt on 2026-10-12; the original
base XML's Copyright Unicode, Inc. 1991–2013 notice is also retained. These
component notices do not relicense unrelated project files.

The expansion integration implements deployed positional forms, supported by
saved Arabic/English/Japanese parse controls. It intentionally does not import
the newer master Leximorph named-category syntax. Count coercion follows
CoreParserFunctions::plural (digit-only integer, otherwise decimal-prefix
float), then the existing 14-digit runtime formatting. Operands and integer
set membership follow wikimedia/cldr-plural-rule-parser v3.0.2, commit
108d56942df0caaf175804e0525c9a188b65e94f.

Empty or absent direct families use the captured STRICT fallback sequence in
order, followed by English, matching Language::getFallbackLanguages,
LanguageFallback's default MESSAGES mode and LocalisationCache's appended
English fallback. Missing captured rows remain errors. Language tags are not
truncated or silently aliased. The existing top-level argument/expanded-label
and lazy selected-form boundary is retained; this is not a claim to reproduce
PHP's regular expression over already expanded nested arguments in every case.
