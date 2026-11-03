# Wikidict desktop

Work on main. Commit validated changes in small steps; do not push without authorization.
Do not publish releases or prereleases until the user explicitly approves publication again.
The application is not production-ready until the user says it is.
Shared-host RAM/PSI is an admission check only; do not stop an admitted job for later
host pressure. Preserve its own resource limits. Cleanup must verify each task-owned
PID and start time; never signal process groups, ancestors or shared infrastructure.
Use rtk for shell commands. Keep temporary work under .tmp/ and remove it before finishing.
Qt product code is under src/, web under web/. The core decoder is under ../../src/.
WIKIDICT_CORE defaults to the Wikidict repository root; keep build outputs under its .tmp/.
Readers consume compiled presentation only; never execute Lua, templates or wikitext.
Preserve the compact themed reading surface. Validate real blob lookup and rendered layout.

From the repository root, run `ctest --test-dir .tmp/desktop-build --output-on-failure` after the Qt build.
Use the committed compiled fixture under tests/fixtures; tests copy it before opening.
Before any UI test or smoke process, set XDG_CONFIG_HOME, XDG_CACHE_HOME and
XDG_DATA_HOME to a test-specific directory under .tmp. Isolate QSettings NativeFormat
and IniFormat, in both UserScope and SystemScope, before QApplication. Explicit
organization/application constructors use NativeFormat even when the default format
is IniFormat. Assert both explicit and default settings paths stay inside the test
directory; never run UI validation against user preferences or dictionaries.
Keep loading/indexing and imports off the UI thread. Search uses a collection-scoped
Unicode-insensitive title index, while exact lookup preserves original case.
Online media requires explicit opt-in. Stop media on entry changes; offline speech
must use an installed matching-language voice rather than fall back to another language.
