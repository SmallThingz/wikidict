# Wikidict Android

- Work on main; preserve unrelated edits. Commit validated coherent steps. Do not push unless authorized.
- Keep tools under tools/ and temporary work under .tmp/; remove temporary files before finishing.
- Kotlin/Compose reader of WIKBLB08/DPR2 semantic data. No JSON dictionary imports, wikitext parsing, Lua, WebView, or bundled executable corpus code.
- Read individual records from disk; never decode an entire language into memory.
- Validate untrusted downloads before atomic installation. Keep all network, decoding, indexing and disk work off the main thread.
- One compact navigation dock. Prioritize reading area; no duplicate state, nested borders, excessive padding or full-screen modal flows. Share themed controls across screens.
- Verify binary conformance, malformed input, offline behavior, settings, media and real-device rendering. Keep the connected phone awake; never lock it.
- Prefix shell commands with rtk (rtk proxy for unsupported commands).
