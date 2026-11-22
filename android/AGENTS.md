# Wikidict Android

- Work on main; preserve unrelated edits. Commit validated coherent steps. Do not push unless authorized.
- Do not publish releases or prereleases until the user explicitly approves publication again. The application is not production-ready until the user says it is.
- Shared-host RAM/PSI is an admission check only; do not stop an admitted job for later host pressure. Preserve its own resource limits. Cleanup must verify each task-owned PID and start time; never signal process groups, ancestors or shared infrastructure.
- Keep tools under tools/ and temporary work under .tmp/; remove temporary files before finishing.
- Kotlin/Compose reader of core-compiled semantic dictionary blobs. No JSON dictionary imports, wikitext parsing, Lua, WebView, or bundled executable corpus code.
- Read individual records from disk; never decode an entire language into memory.
- Validate untrusted downloads before atomic installation. Keep all network, decoding, indexing and disk work off the main thread.
- One compact navigation dock. Prioritize reading area; no duplicate state, nested borders, excessive padding or full-screen modal flows. Share themed controls across screens.
- Verify binary conformance, malformed input, offline behavior, settings, media and real-device rendering. Keep the connected phone awake; never lock it.
- Prefix shell commands with rtk (rtk proxy for unsupported commands).
