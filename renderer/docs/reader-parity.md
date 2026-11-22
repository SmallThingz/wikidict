# Reader acceptance — 2026-09-23

| Capability | Android | Web | Terminal |
| --- | --- | --- | --- |
| Raw / seekable XZ binary dictionaries | Device tested | Browser + decoder tested | Storage + install tested |
| Meanings first, configurable folds | Device tested | Browser tested | PTY tested; section keyboard control |
| Saved / History / Search / Learn / Settings | Device tested | Browser tested | PTY tested |
| Persistent history and bookmarks | Existing device checks | Reload tested | Exit/reload data checked |
| Cards / quiz / scramble | Existing app | Cards browser tested; quiz/scramble implemented | PTY tested |
| History 100,000; media 4 GiB | Endpoint device test | Endpoint browser test | Settings implemented; populated-limit performance not tested |
| Catalogue download / import | Existing app + XZ device import | Import tested; remote CORS dependent | Compressed local install tested; curl catalogue/download commands |
| Tables / inline styles / references | Existing fixture checks | DPR2 decode equivalence, responsive layout | Existing semantic text tests |
| Images / recorded audio | Existing Android media path | Opt-in inline, browser cache | Opt-in external desktop player; synchronous fetch |
| Offline TTS | Device tested; user confirmed pronunciation | Local browser voices only; unverified live | espeak-ng/espeak adapter; unverified live |

Limits: the terminal does not render images inline and its catalogue management uses CLI commands. Browser downloads rely on Blob/IndexedDB quota and HTTPS CORS. Neither terminal speech/media nor live web media was validated in this run. This is a substantial parity implementation, not an assertion that every feature behaves identically or that the whole corpus has been built.

On the 30-entry fixture, Node web-reader smoke timings were raw index 3.17 ms / 100 reads 309.87 ms, XZ index 85.97 ms / 100 reads 400.09 ms. XZ used 1 MiB blocks and 371,560 bytes versus 3,365,898 raw. These single-run observations are not representative corpus benchmarks.
