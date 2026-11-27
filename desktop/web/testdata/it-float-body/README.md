# Italian floating declension table

`crepans.dpr` is the complete compiled Latin record for Italian Wiktionary
`crepans`, page 500363. It comes from the ordinary Writer05 compilation of the
retained source, with the corrected four-column case cells. No body or table
content has been removed or replaced for this fixture.

- Expanded source SHA-256: `70200a29a88f5fddfc06a9506ab5d8f272ada9de30383653c2945a24f01b6667`
- Publication member SHA-256: `dcc454ab143582cec68e96f093f79dd59c21ab92b86eef30c5d378ee8405896d`
- Record offset: 29; length: 10710 bytes.
- Record SHA-256: `73e12e7e2e0717ab9dc1079a1c5659d37899d6d25baf43e1a858d7d4dbdb01f2`

The browser regression decodes these bytes through the product reader. At a
360-pixel viewport, the right float formerly squeezed “Voce verbale” and the
following bold “crepans” into one-character lines. The heading must move below
the table when it cannot fit beside it, and return beside it after widening.
A separately labelled synthetic long-heading control checks that avoiding the
float does not introduce page overflow.
