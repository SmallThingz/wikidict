# Native responsive caption table fixtures

These seven DPRa frames and complete Stored JSON records are byte-identical exports of the shared native codec qualification (`hu-caption-native-rd02/native03`). They are synthetic controls, not captured dictionary source or browser geometry evidence.

The original native manifest is retained unchanged as `manifest.json` (SHA-256 `a8bf4678143967bc5f0d539c8faccd1f6fb8e5404fa873403ea97c8dd0b86f7c`). It authenticates two standalone global-bit25 positives with opposite containing/grid directions and five malformed records. The test verifies both binary and JSON hashes and the embedded DPR hex before decoding.

Both complete Tables must validate and compare exactly. The only test-side normalization fills an absent legacy Span.background with null in the expected caption/cell spans; no field is removed and no numeric tolerance is used. Both native positives also reject every altered pending-feature byte except the exact owed 0x84.

Provenance: native closure `fa30963374d8ee681312084480a74468ade0d4c6ed012d51ba2f6c85988f3279`; Cloud mirror `2831f03f13b6780e63c3a23749d8041e6f17e706382d99c903043e9dbe1bf75d`; original private Web qualification `27ee5967228789ac6b07152188f1e9e16d3dd7d63d132dc8e8dc8e458c6c80f4`; source/parity review `2232e8805143e5f0c492e8d94e9750835e1ae572275e054201fd5967d372b059`.

Maintained-path execution must be qualified separately. This test has eight groups (seven native frames and exhaustive pending-byte controls). The private qualification's ninth group comparing against a historical DE28 decoder remains in its original evidence; it is not silently credited to this relocated test. Existing DE28 regressions remain separately required.
