# Edition namespace registry

The build-time registry is edition-local immutable data. Dated dump XML is
checked against captured API namespace IDs, localized names, and case policy.
Aliases and additional API properties retain their current-at-retrieval
provenance; they are not represented as historical dump-time facts.

`tools/namespace_registry_snapshot.py` verifies captured hashes, reparses the
hashed XML, rejects incomplete/duplicate namespace inventories and emits a TSV
plus its provenance manifest. Missing namespace defaultContentModel stays
absent. Known lexical features require an edition/name/ID proof; other subject
namespaces are retained as supplemental content, never assigned English
semantics by their numeric ID.

`src/shared/namespace_registry.zig` owns validated namespace records and a sorted
normalized alias index. Prefix lookup is case-insensitive; title suffixes are
NFC-normalized and retain case except where the namespace requests MediaWiki
first-codepoint capitalization. Qualified Lua loader names are separate from
bare invoke names, so builtins such as `math` cannot become `Module:math`.
Relative transclusions use the concrete host title and namespace subpage policy.

The native Unicode backends are immutable per-registry handles. Allocation
failures propagate; returned normalized titles are exact owned allocations.
Synthetic tests use explicit captured fixtures. Production has no English
registry fallback and must load `namespace-registry.tsv` from its pinned inputs.

Validation for the initial foundation: seven focused Zig tests (including
allocation failures, German aliases/NFC, qualified loader rules and Chinese
first-letter behavior), seven snapshot-generator tests, and all 198 captured
namespace inventories. These checks do not establish completed dictionary
builds or a corpus-wide throughput result.
