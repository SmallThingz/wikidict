# Dictionary download catalogues

Android's default catalogue is:

`https://github.com/SmallThingz/wikidict/releases/latest/download/dictionaries.list`

Publish that UTF-8 text file as a GitHub release asset alongside the dictionaries. The app also accepts additional HTTPS catalogue URLs configured in its Dictionaries screen. Creating the repositories does not publish a corpus or a release automatically.

Each nonempty, non-comment line contains one absolute HTTPS URL to a raw `.wikblb` file. Optional tab-separated columns supply a display label, byte length and SHA-256 checksum:

```text
# wikidict-list-v1
https://example.org/English.wikblb	English	4180609	<SHA-256 hex digest>
https://example.org/French.wikblb
```

Use actual tab characters, not spaces. The checksum column contains exactly 64 hexadecimal characters. Prefer all four columns so clients can verify integrity and display download progress. Empty lines and lines starting with `#` are ignored. Catalogue limits are 2 MiB and 10,000 distinct dictionary URLs. Links and redirects use HTTPS; userinfo/credentials are forbidden.

Generate a catalogue after `zig build verify-blobs -- PATH` passes:

```sh
python3 tools/make_catalog.py PATH \
  --base-url https://github.com/SmallThingz/wikidict/releases/download/TAG \
  --output dictionaries.list
```

Upload all referenced files under their generated names. Use versioned dictionary URLs and replace the catalogue in a newer release when the corpus changes. The generator reads language labels from the binary header and streams checksums. It does not replace full corpus validation.

Android currently reads raw WIKBLB08 files with DPR2 semantic records. Compressed `.xz` files, JSON exports, Lua and template sources are not installable dictionaries. Installation streams to a temporary file, verifies any advertised size/checksum, checks framing and sorted titles, creates a local SQLite title/offset index, and atomically commits the file and index. Records are decoded on demand; the index contains no replacement dictionary representation.

Debug builds substitute the default catalogue with a local multiword corpus slice. Custom catalogue URLs still use the network. Release/performance builds contain no development dictionary and use the default remote URL.
