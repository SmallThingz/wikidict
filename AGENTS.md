# Wikidict desktop

Work on main. Commit validated changes in small steps; do not push without authorization.
Use rtk for shell commands. Keep temporary work under .tmp/ and remove it before finishing.
Qt product code is under src/, web under web/. The core decoder is maintained in
https://github.com/SmallThingz/wikidict; configure CMake with WIKIDICT_CORE pointing to its checkout.
Readers consume compiled presentation only; never execute Lua, templates or wikitext.
Preserve the compact themed reading surface. Validate real blob lookup and rendered layout.
