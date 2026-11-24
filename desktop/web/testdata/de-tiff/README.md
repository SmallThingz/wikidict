# Original DE TIFF entries

These are the two unchanged, one-record `WIKBLB08` files emitted by the bounded ordinary `dewiktionary` Writer replay for the 20261001 selection. Both Writer and Verifier exits were zero. Both DPRM records retain an authored container `margin-bottom: -0.5em` at `sections[2].blocks[2]`. Their figures use the registered TIFF originals and compiled 250px sizing. The fixtures are licensed contributions to Wiktionary. [German revision and contributors](https://de.wiktionary.org/w/index.php?title=kakophonisch&oldid=10309883) · [Swedish revision and contributors](https://de.wiktionary.org/w/index.php?title=vit_som_ett_lakan&oldid=10705021)

| Fixture | Selected page and revision | Raw SHA-256 | DPRM range and payload SHA-256 |
| --- | --- | --- | --- |
| `p3289.wikblb` | 3289 / 10309883 | `ca4bdbbdbac2c17d96610f0a34b7d75206b38a75306364f34898a8c687b734e0` | offset 36, length 25788, `ea6b64fcd714b2141c3fd30e497b5bc576b5f39bec8b6bec6dff4a9ce7d008f5` |
| `p519864.wikblb` | 519864 / 10705021 | `217f02b706024d06687f47cad03824ddfc474ea2a7f65688a4aac6a11fc013ec` | offset 43, length 8939, `e29be02d4e4f3de59b158a79e6a45024e29e7787c9fe1640c18e14bae67e3a6e` |

The ordinary native Reader export SHA-256 values are `4490ab5f0360dbc2040ffaf510fc11e61c1a094895b7d46747fe4cbda7f9a2df` and `5b70ec3ed6d2983b202ae9bb848176ef445cb393f11e8cb0ae8cc1eb1e79fcc5`, respectively. The permanent test opens and decodes both raw members and exercises malformed signed padding, legacy DPRL margins, and non-finite margins separately.

```sh
node --test --test-name-pattern='original M container margins' typed-content.test.mjs
```
