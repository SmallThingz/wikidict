# Retained media registration responses

These are the original first accepted file-metadata responses from the 2026-11-18 Assamese and Cornish normal Figure captures. Both captures stopped at an unreviewed registration check. Their raw request, receipt, namespace, and compressed prefix bytes are retained unchanged. The Cornish header declares six planned batches, but only the first was committed; this fixture does not assert a complete capture.

`file-metadata.response-000001-01.raw.json` restores the exact bytes also retained in `figure-sizing.site.json`, checked against the original accepted receipt's byte count and SHA-256. `file-metadata.namespace-registry.tsv` is an exact copy of the original `site-info.namespace-registry.tsv`, using the maintained retained-request API's filename. `retained-request01.json` is the additive, explicit V4 selection record; it does not change the original request or receipt.

The reviewed complete sets are:

- Core `992ad5e3679f848254828e823860ba8b3ad3b39b`: PagedTiffHandler `b7208776bccdcbbfa4252f67f3e924b79b6587b9`, TimedMediaHandler `7755b61c361899ff83792940cf1eb20923a69bba`.
- Core `bfe24921d500b20f2938fb8fe2a09cf5cac80161`: PagedTiffHandler `39dc5f487287a6921e3ba8ca6affdd6412ac1870`, TimedMediaHandler `a27dbe9cdf6eb97e0e3fb9e8bc762a66b2d7b663`.

Both also retain PDF Handler `6c890ba5064565386a35082e16c0d511b789ac6b` and 3D `43498dc2d52c37d98294e4bbf73a0e8a70bd1aea`. Earlier accepted complete sets remain valid; their members cannot be mixed with these sets.

The exact-revision PagedTiff manifest, handler, and image sources are byte-identical between b720 and 39dc. The two new TimedMediaHandler revisions have identical manifest, registration callback, preset, and namespace sources. Against the reviewed 740f revision, only transcode configuration changed; the MediaHandlers map and registration callback are unchanged. This supports the existing image model, not audio/video rendering or transcoding semantics. Source responses and physical qualification receipts remain under `.tmp/renderer-core-oct28/as-tmh7755-source01` and `as-pagedtiff-b720-source01`.
