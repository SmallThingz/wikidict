# Saved-preview regression fixture

`af-spinal-cord.dpr2` is the exact 1,269-byte compiled presentation record for
[spinal cord](https://af.wiktionary.org/wiki/spinal_cord), from the complete
Engels (`en`) language collection in `afwiktionary/20261001`, attempt 144.
The bytes are copied unchanged from decompressed offset 2,504,657.

- Payload SHA-256: `69bd17c95eba52f739e1105216acb4ed565efa0f384ebcaff8ee662f3914addc`.
- Source compressed blob SHA-256: `c0e89c271f5b7d7b8939761162e4fdd1b8a12431e9e6c24f631310f34507085a`.
- Source decompressed blob SHA-256: `39425a3f45c9e340db4ffca75f552eca68fedf9ba6cf443b3b26b710b5cae2d7`.
- Closed publication `complete.json` SHA-256: `704bc5d2b5765c4a50f423de65f63db05f81e24b507a6bcd8cfe25bbbdb71379`.
- Producer commit: `927e84b696da71f31b01964588614ec9dce8efae`.

The record has an indented pronunciation block containing compiled media/audio
controls, followed by the indented meaning `(anatomie) Rugmurg`. It has no
`definition` block. The regression verifies useful saved-preview selection
without changing the full reader body or using a heading-language allowlist.

Content is by [Wiktionary contributors](https://af.wiktionary.org/w/index.php?title=spinal_cord&action=history),
under [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/).
The historical English `cat` regression uses the existing debug fixture and
retains its genuine top-level definition, `Terms relating to animals.`.
# Compiler grammar fixture

`grammar-fixture-v2.dpr2` is the exact 2,706-byte compiled record payload for
`Grammar fixture_猫` from a synthetic compiler/codec fixture. Its source is
`grammar-fixture-v2.wikitext`; neither file represents a published dictionary.
The Android tests decode the compiled payload directly and never parse the source.

- Payload SHA-256: `8e0d146bd768ba65b7c4d99b1a027d8e25682f17c85db87edcf6b265db8fb9eb`.
- Full 2,748-byte WIKBLB08 fixture SHA-256: `80c3448a3204271d69bf9b3041aacc424193fc8be9efb5d482a39b71cc6ef958`.
- Source SHA-256: `f81684bd6ad8ac6113ce9ce15b83e6232ec3655536db7a0ee0cf5d00185e83dc`.
- Candidate compiler SHA-256: `aea09540f75c37217394ed007556928ce66222e0dc5aadb6cc894ccf1307054c`.
- Strict compiler/codec and existing reader export receipt SHA-256: `039d01e28b0b5e9e2edee147172a3bd5cf317a00659175db6a32f9dff12ea396`.

The fixture covers ordered labels, independent nested HTML lists, nested tables
and terms, one true dictionary sense, grouped references, and protected literal
text. It supersedes the earlier experimental grammar fixture.

# Genuine Japanese typed Ruby

`zh-tabiji-typed-ruby.wikblb` is the exact 1,852-byte `WIKBLB08` language blob
produced by the ordinary Writer for the genuine Chinese Wiktionary page
[たびぢ, revision 6019530](https://zh.wiktionary.org/w/index.php?title=たびぢ&oldid=6019530)
(page ID 1502032, selected ordinal 1950). It contains one Japanese-language
record (`日語`, `ja`) with a `DPRS` presentation payload. No JSON or Kotlin model
was encoded to create this fixture.

- Blob SHA-256: `5a674511ec65701532d90c002e9285d76dcbe806c050a488c463b79a24bfcce4`.
- Ordinary Writer executable SHA-256: `4951a8e6930b2e20ff49e055c2cd582852416f81f0bdeee0dd06c02768bfb2f7`.
- Producer result SHA-256: `479c12ef184f327413b35a7655e45efd77098dff3a5cf1c26f17c0fc43f5c28b`.
- Independently reviewed complete Reader JSON SHA-256: `5913dbd3dee9ed33caa2f8cdb72c15073d039b0b4b65594cebc933cc4a0f59e0`.
- Source/body review SHA-256: `de92670c71f584fcfd457669a112d169a08213bf4118d64d04bfd3bafba79cee`.

`BlobDecoderTest.genuineJapaneseTabijiBlobPreservesTypedRubyAndCompleteBody`
feeds these binary bytes through the production envelope reader and decoder.
Its independent expected graph retains the entire two-table body, introductory
and historical notes, all five links, Ruby owner/child font scales and bases,
annotation line height, and absent optional fields. It also checks the graphical
base/reading UTF-16 action ranges and text fallback. This is host decoding and
semantic coverage, not Android rendering, accessibility or navigation acceptance.
The blob has no destination record for its `旅路#日語` links. The producer's
`unresolved_table_style` finding remains: absent outer table style is intentional
in the expected graph and is not a claim of full CSS fidelity.

Content is by [Wiktionary contributors](https://zh.wiktionary.org/w/index.php?title=たびぢ&action=history),
under [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/).

# Genuine Chinese cross-reference table minimum

`zh-cheng-khi-minimum229.wikblb` is the exact 880-byte ordinary Writer229
`WIKBLB08` output for [chèng-khì, revision 8249000](https://zh.wiktionary.org/w/index.php?title=chèng-khì&oldid=8249000)
(page ID 1500191, selected ordinal 190). It contains one `泉漳話` (`nan-hbl`)
record with a `DPRZ` payload. No model or JSON was encoded to create the fixture.

- Blob SHA-256: `8ace2c6c99c42a29e1fd49e78616873a9f107c58bd3782a58c2adea42dcea8e6`.
- Ordinary Writer229 closure SHA-256: `6b1f618e13871bb13d157249d8ab03eb0cd1f6f89da568eb82e81e5372a32910`.
- Independent complete Reader JSON SHA-256: `b3f6ed638e59e54d437d609f8b2fbd1f84d8b0b0af14184f2d5a018ebdb4df16`.
- Source/body review SHA-256: `e579ba3f583cfc95f40fa7898fe916e1059a9e922b46e3df57ba8c27f3cef871`.
- Original 949-byte expanded source SHA-256: `3906c6f1fda2ffbef248b70866aac3ebea22edc40321470a7655a5b67f90e14f`.

The two `BlobDecoderTest.genuineChineseChengKhi229...` controls use the same
`CountingInput` envelope and `BlobDecoder` validation used by import. The complete
expected model preserves the owner, section anchors, one table, eleven spans,
three links, 70% minimum width and 0.5em left cell padding. The sizing control
feeds this decoded table into the production sizing helpers with explicitly
controlled cell intrinsic inputs; it does not measure device fonts or execute
Compose layout. Percentage width uses the actual containing width, while em
padding uses the supplied body font size. Narrow content minima are retained.

This is host decoder and sizing coverage, not SQLite installation, physical
rendering, accessibility or navigation acceptance. The blob has no destination
records for its links. The producer's `unresolved_table_style` warning remains:
custom-property background is null, not an inferred palette value.

Content is by [Wiktionary contributors](https://zh.wiktionary.org/w/index.php?title=chèng-khì&action=history),
under [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/).
