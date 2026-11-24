# Babua compiled Web fixtures

`r19-responsive.wikblb.xz` is the unchanged 1,252-byte ordinary R19 Writer member for `idwiktionary`, Buginese (`bug`), `babua`, page 1720, revision 1280692. Its 20261001 dump selection used zero-based page ordinal 161. The R19 producer source manifest SHA-256 was `915c8c39ca3b9f73d5b95d1934409749ed7562389f240621217e865dfcd1ef44`. The Writer result SHA-256 was `eca9db7961964a342a2d3f755eb19d0c68a1d6e8bf188c14da22efdcb5009563` and the matching independent Reader output SHA-256 was `e1e938f1c8b612eb1d843d3d2da5de2fda3f5fbc7acb594802056cce2baf8047`. Source attribution belongs to Wiktionary contributors. [Original revision](https://id.wiktionary.org/w/index.php?title=babua&oldid=1280692)

| Fixture | File SHA-256 | Decoded payload location and SHA-256 |
| --- | --- | --- |
| `r19-responsive.wikblb.xz` | `b04077322097ea8bcdee4e3ca45f037f376617ff56b64170358f79e6aa775fe5` | DPRa at offset 30, length 4,259, `e735f12e030813c6e2b8496729fb3f88e9066a78f70409bb0c430f3ce7ed47dc` |
| `r08-image-occurrence.wikblb.xz` | `a788ede6b4cc2745defe1c3250b5158a24ede116c07b7429c65ef96b22df3859` | DPRZ at offset 30, length 3,970, `b6add840169fc5bc93563f36ace2fea1777b74983d8d3011377978d0ad69d6d0` |
| `synthetic-dpry-occurrence.bin` | `9700880c55b1f2b34c5a7fad69f218595a2392b31abfde922c91435ee452a067` | Entire 310-byte DPRY payload |

The R08 member is the retained genuine predecessor for the same page. It exercises the feature-absent screen-band framing with the image occurrence capability. The DPRY payload came from the native encoder's `image-y` control. It is synthetic, contains a single image occurrence, and exercises DPRY flag `0x20` through the ordinary index parser. Malformed variants are made in memory by the tests.

Run from `desktop/web` with Node 24.22.3 and pnpm 11.25.0. The checked-in lockfile pins `@noble/hashes` 2.4.0, `xz-decompress` 0.2.3, esbuild 0.28.2 and Playwright 1.63.0.

```sh
pnpm install --frozen-lockfile --store-dir ../../.tmp/babua-web-pnpm-store
node --test babua-r19.test.mjs
pnpm test
```

The focused tests need only these local fixtures. The full suite additionally recognizes the existing external corpus manifest variables documented in the Web tests.
