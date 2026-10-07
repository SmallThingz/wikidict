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
