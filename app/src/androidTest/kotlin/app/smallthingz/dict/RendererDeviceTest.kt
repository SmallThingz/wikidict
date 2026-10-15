package app.smallthingz.dict

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.*
import org.junit.Before
import org.junit.Rule
import org.junit.Test

class RendererDeviceTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()
    private val library get() = LibraryStore.get(InstrumentationRegistry.getInstrumentation().targetContext)
    @Before fun installRealBinaryDictionary() {
        runBlocking {
            library.refreshCatalogs().join()
            assertNull(library.error)
            library.download(library.catalog.first()).join()
            assertNull(library.error)
        }
        compose.waitUntil(15000) { compose.onAllNodesWithTag("entry-scroll").fetchSemanticsNodes(atLeastOneRootRequired = false).isNotEmpty() }
    }
    private fun search(word:String) {
        compose.onNodeWithContentDescription("Dictionary").performClick()
        compose.onNode(hasSetTextAction()).performTextInput(word)
        compose.waitUntil(10000){compose.onAllNodesWithText(word).fetchSemanticsNodes().isNotEmpty()}
        compose.onAllNodesWithText(word).onFirst().performClick()
        compose.waitUntil(10000){compose.onAllNodesWithTag("entry-scroll").fetchSemanticsNodes().isNotEmpty()}
    }
    private fun capture(name: String) {
        compose.waitForIdle()
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val directory = java.io.File(instrumentation.targetContext.filesDir,"qa-screenshots").apply { mkdirs() }
        val bitmap = requireNotNull(instrumentation.uiAutomation.takeScreenshot())
        try { java.io.File(directory,name).outputStream().use { assertTrue(bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG,100,it)) } }
        finally { bitmap.recycle() }
    }
    @Test fun corpusArabicAndCompiledAliasRemainReadableInPortrait(): Unit = runBlocking {
        val before = library.dictionaries.map { it.id }.toSet()
        val assets = InstrumentationRegistry.getInstrumentation().context.assets
        try {
            for ((name,asset) in listOf(
                "arwiktionary-20261001-d274159863057eb5c633116c3b54e4f8659167f0b73fabbee256e881fa1ac8c8.wikblb" to "arabic-visual.wikblb",
                "bgwiktionary-20261001-aliases.wikblb" to "compiled-aliases.wikblb",
                "bgwiktionary-20261001-ba118bf7fc9c1aedc1edb28a0aa86e0b43b681f222af6616e13c43be87815b06.wikblb" to "compiled-alias-targets.wikblb")) {
                library.importFile(name={name}) { assets.open(asset) }.join()
                assertNull(library.error)
            }
            assertEquals("ar",library.read(library.exact("-هُم","العربية","arwiktionary-20261001")!!).languageCode)
            search("ChainA")
            compose.onNodeWithContentDescription("Pronounce word offline").performClick()
            compose.onNodeWithText("This entry has no identified language for speech.").assertExists()
            search("-هُم")
            compose.onAllNodesWithText("This entry has no identified language for speech.").assertCountEquals(0)
            val layouts = mutableListOf<androidx.compose.ui.text.TextLayoutResult>()
            compose.onNodeWithTag("entry-title").performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.GetTextLayoutResult) { it(layouts) }
            assertEquals(1,layouts.single().lineCount)
            capture("actual-arabic-excerpt.png")
            search("ChainA")
            compose.onNodeWithText("ChainA -> ChainB#Incoming").assertExists()
            compose.onNodeWithText("gainst",substring=true).assertExists()
            capture("synthetic-alias-chain.png")
            compose.onNodeWithContentDescription("Settings").performClick()
            compose.onNodeWithTag("settings-scroll").performScrollToNode(hasText("Images & sound"))
            capture("portrait-media-settings.png")
        } finally {
            library.dictionaries.map { it.id }.filter { it !in before }.forEach { library.remove(it).join() }
        }
    }
    @Test fun binaryLibrarySearchDecodeAndRandomCoverMultipleWords() = runBlocking {
        assertTrue(library.dictionaries.sumOf{it.count}>20)
        val words=library.search("")
        assertTrue(words.size>20)
        for(hit in words) {
            val entry = library.read(hit)
            assertEquals(hit.title, entry.title)
            val texts = buildList {
                add(textOf(entry.displayTitle)); add(textOf(entry.preamble))
                entry.sections.forEach { section ->
                    add(section.title)
                    section.blocks.forEach { block ->
                        add(textOf(block.spans))
                        block.table?.let { table -> add(textOf(table.caption)); table.rows.flatten().forEach { add(textOf(it.spans)) } }
                    }
                }
                entry.references.forEach { add(textOf(it.spans)) }
                entry.media.forEach { add(it.caption) }
            }
            for (text in texts) assertFalse("Unrendered syntax in ${entry.title}: $text", Regex("\\[\\[|\\]\\]|\\{\\{|\\}\\}|</?[A-Za-z][^>]*>|\\{\\||\\|\\}").containsMatchIn(text))
        }
        assertNotNull(library.exact("cat"));assertTrue(library.search("not-in-this-corpus").isEmpty())
        assertTrue((1..20).map{library.random()!!.title}.distinct().size>1)
    }
    @Test fun foldedSectionsSearchAndRecreationRemainUsable() {
        search("cat")
        compose.onNodeWithTag("entry-scroll").performScrollToNode(hasContentDescription("Expand Etymology 1"))
        compose.onNodeWithContentDescription("Expand Etymology 1").performClick()
        compose.onNodeWithContentDescription("Collapse Etymology 1").assertExists()
        compose.onNodeWithContentDescription("Collapse Etymology 1").performClick()
        val screen=compose.onRoot().fetchSemanticsNode().boundsInRoot
        val reading=compose.onNodeWithTag("entry-scroll").fetchSemanticsNode().boundsInRoot
        assertTrue(reading.height/screen.height>0.85f)
        compose.onNodeWithContentDescription("Settings").performClick()
        compose.onNodeWithText("Dark").performClick()
        compose.onNodeWithText("Light").performClick()
        compose.onNodeWithContentDescription("Dictionary").performClick()
        compose.onNode(hasSetTextAction()).performTextInput("ca")
        compose.activityRule.scenario.recreate()
        compose.waitUntil(15000) { compose.onAllNodes(hasSetTextAction()).fetchSemanticsNodes(atLeastOneRootRequired = false).isNotEmpty() }
        compose.onNode(hasSetTextAction()).assertTextEquals("ca")
        compose.onAllNodesWithTag("entry-scroll").assertCountEquals(0)
        compose.onNodeWithContentDescription("Close search").performClick()
        compose.waitUntil(15000){compose.onAllNodesWithTag("entry-scroll").fetchSemanticsNodes().isNotEmpty()}
        compose.onNodeWithTag("entry-title").assertTextEquals("cat")

        compose.onNodeWithContentDescription("Dictionary").performClick()
        compose.onNode(hasSetTextAction()).performTextInput("ca")
        compose.activityRule.scenario.recreate()
        compose.waitUntil(15000) { compose.onAllNodes(hasSetTextAction()).fetchSemanticsNodes(atLeastOneRootRequired = false).isNotEmpty() }
        compose.onNode(hasSetTextAction()).assertTextEquals("ca")
        compose.onAllNodesWithTag("entry-scroll").assertCountEquals(0)
        compose.activityRule.scenario.onActivity { it.onBackPressedDispatcher.onBackPressed() }
        compose.waitUntil(15000){compose.onAllNodesWithTag("entry-scroll").fetchSemanticsNodes().isNotEmpty()}
        compose.onNodeWithTag("entry-title").assertTextEquals("cat")

        compose.activityRule.scenario.recreate()
        compose.waitUntil(15000){compose.onAllNodesWithTag("entry-scroll").fetchSemanticsNodes().isNotEmpty()}
        compose.onNodeWithTag("entry-title").assertTextEquals("cat")
    }
    @Test fun checksumFailureDoesNotInstallOrDamageLibrary() = runBlocking {
        val before=library.dictionaries.map{it.id}
        library.download(library.catalog.first().copy(sha256="0".repeat(64))).join()
        assertTrue(library.error!!.contains("checksum"))
        assertEquals(before,library.dictionaries.map{it.id})
        assertEquals("cat",library.read(library.exact("cat")!!).title)
    }
    @Suppress("DEPRECATION")
    @Test fun failedSystemDownloadVerificationAllowsCompletedRowRecovery() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val manager = context.getSystemService(android.content.Context.DOWNLOAD_SERVICE) as android.app.DownloadManager
        val prefs = context.getSharedPreferences("library", android.content.Context.MODE_PRIVATE)
        val keys = listOf("downloadId", "downloadUrl", "downloadLabel", "downloadBytes", "downloadHash")
        val saved = prefs.all.filterKeys { it in keys }
        assertEquals("A genuine retained download must not be replaced", -1L, prefs.getLong("downloadId", -1))
        assertTrue(saved.values.all { it is String || it is Long })
        val fixture = library.catalog.first()
        assertTrue(fixture.url.startsWith("asset://"))
        val bytes = requireNotNull(fixture.bytes)
        val hash = requireNotNull(fixture.sha256)
        val item = CatalogItem("https://example.invalid/recovery/English.wikblb", "Local completed download", bytes, hash)
        val before = library.dictionaries.map { it.id }.toSet()
        val ids = mutableListOf<Long>()
        val files = mutableListOf<java.io.File>()
        val directory = requireNotNull(context.getExternalFilesDir("downloads"))
        val parts = java.io.File(context.filesDir, "dictionaries")
        val oldParts = parts.listFiles().orEmpty().filter { it.extension == "part" }.map { it.name }.toSet()
        fun completed(value: CatalogItem): Long {
            val file = java.io.File(directory, "recovery-${java.util.UUID.randomUUID()}.wikblb")
            files.add(file)
            context.assets.open(fixture.url.removePrefix("asset://")).use { input -> file.outputStream().use { input.copyTo(it) } }
            assertEquals(bytes, file.length())
            val id = manager.addCompletedDownload("Wikidict recovery fixture", value.label, false, "application/octet-stream", file.absolutePath, file.length(), true)
            assertTrue(id >= 0)
            ids.add(id)
            manager.query(android.app.DownloadManager.Query().setFilterById(id)).use { c ->
                assertTrue(c.moveToFirst())
                assertEquals(android.app.DownloadManager.STATUS_SUCCESSFUL, c.getInt(c.getColumnIndexOrThrow(android.app.DownloadManager.COLUMN_STATUS)))
            }
            assertTrue(prefs.edit().putLong("downloadId", id).putString("downloadUrl", value.url).putString("downloadLabel", value.label)
                .putLong("downloadBytes", value.bytes ?: -1).putString("downloadHash", value.sha256).commit())
            return id
        }
        fun cleared(id: Long) {
            manager.query(android.app.DownloadManager.Query().setFilterById(id)).use { assertFalse(it.moveToFirst()) }
            keys.forEach { assertFalse("Stale download field: $it", prefs.contains(it)) }
            assertNull(library.busy)
            assertEquals(oldParts, parts.listFiles().orEmpty().filter { it.extension == "part" }.map { it.name }.toSet())
        }
        try {
            for ((bad, message) in listOf(item.copy(sha256 = "0".repeat(64)) to "checksum", item.copy(bytes = bytes + 1) to "Incomplete download")) {
                val id = completed(bad)
                library.download(bad).join()
                assertTrue("Expected $message verification failure; observed library.error=${library.error}",
                    library.error.orEmpty().contains(message, ignoreCase = true))
                cleared(id)
                assertEquals(before, library.dictionaries.map { it.id }.toSet())
                assertEquals("cat", library.read(library.exact("cat")!!).title)
            }
            // Re-enter the real completed-row verifier with the same URL, then another URL.
            // Every row is local and pre-completed; this is not a network/enqueue assertion.
            for (valid in listOf(item, item.copy(url = "https://example.invalid/another/English.wikblb"))) {
                val id = completed(valid)
                library.download(valid).join()
                assertNull(library.error)
                cleared(id)
                assertEquals(before, library.dictionaries.map { it.id }.toSet())
                assertEquals("cat", library.read(library.exact("cat")!!).title)
            }
        } finally {
            ids.forEach { runCatching { manager.remove(it) } }
            files.forEach { it.delete() }
            library.dictionaries.map { it.id }.filter { it !in before }.forEach { library.remove(it).join() }
            val editor = prefs.edit()
            keys.forEach { editor.remove(it) }
            saved.forEach { (key, value) -> when (value) { is String -> editor.putString(key, value); is Long -> editor.putLong(key, value) } }
            assertTrue(editor.commit())
        }
    }
    @Test fun liveMediaDownloadsAndCacheHonorsLimits() = runBlocking {
        org.junit.Assume.assumeTrue("Opt in with -Pandroid.testInstrumentationRunnerArguments.liveMedia=true", InstrumentationRegistry.getArguments().getString("liveMedia") == "true")
        val context=InstrumentationRegistry.getInstrumentation().targetContext
        val cache=MediaCache.get(context)
        cache.clear()
        val entry=library.read(library.exact("cat")!!)
        val image=cache.get(entry.media.first{it.kind=="image"},25)
        assertTrue(image.file.length()>0)
        assertNotNull(android.graphics.BitmapFactory.decodeFile(image.file.absolutePath))
        assertTrue(image.source.startsWith("https://"))
        val audio=cache.get(entry.media.first{it.kind=="audio"},25)
        assertTrue(audio.file.length()>0)
        val retriever=android.media.MediaMetadataRetriever()
        try { retriever.setDataSource(audio.file.absolutePath); assertTrue(retriever.extractMetadata(android.media.MediaMetadataRetriever.METADATA_KEY_DURATION)!!.toLong()>0) } finally { retriever.release() }
        assertEquals(image.file,cache.get(entry.media.first{it.kind=="image"},25).file)
        cache.trim(0)
        assertFalse(image.file.exists());assertFalse(audio.file.exists())
    }


    @Test fun supportingSectionsAndSenseNotesStartFolded() {
        search("A")
        compose.onNodeWithTag("entry-scroll").performScrollToNode(hasContentDescription("Expand Alternative forms"))
        compose.onAllNodesWithText("Centennial", substring = true).assertCountEquals(0)
        compose.onNodeWithContentDescription("Expand Alternative forms").performClick()
        compose.onNodeWithContentDescription("Collapse Alternative forms").assertExists()
        compose.onAllNodesWithText("Centennial", substring = true).onFirst().assertExists()
        compose.onNodeWithContentDescription("Collapse Alternative forms").performClick()
        compose.onAllNodesWithText("Centennial", substring = true).assertCountEquals(0)
        compose.onNodeWithTag("entry-scroll").performScrollToNode(hasContentDescription("Show examples and notes for Letter"))
        compose.onNodeWithContentDescription("Show examples and notes for Letter").performClick()
        compose.onNodeWithContentDescription("Hide examples and notes for Letter").assertExists()
        compose.onNodeWithContentDescription("Hide examples and notes for Letter").performClick()
        compose.onNodeWithContentDescription("Show examples and notes for Letter").assertExists()
    }

    @Test fun preferenceSlidersCommitAccessibleValues() {
        val learning = LearningStore.get(compose.activity)
        compose.onNodeWithContentDescription("Settings").performClick()
        fun slide(label: String, position: Float) {
            compose.onNodeWithTag("settings-scroll").performScrollToNode(hasContentDescription(label))
            compose.onNodeWithContentDescription(label).performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.SetProgress) { it(position) }
            compose.waitForIdle()
        }
        slide("Media cache", 0f)
        assertEquals(0, learning.data.settings.mediaCacheMb)
        slide("Media cache", 1f)
        assertEquals(4096, learning.data.settings.mediaCacheMb)
        slide("Remember words", 1f)
        assertEquals(100_000, learning.data.settings.historyLimit)
        slide("Remember words", 0f)
        assertFalse(learning.data.settings.historyEnabled)
        slide("Questions per round", .5f)
        assertEquals(27, learning.data.settings.quizLength)
        compose.runOnIdle { learning.updateSettings { it.copy(mediaCacheMb=100, historyEnabled=true, historyLimit=100, quizLength=10) } }
    }
    @Test fun systemDownloadManagerFetchesAndVerifiesDictionary() = runBlocking {
        val item = CatalogItem(
            InstrumentationRegistry.getArguments().getString("dictionaryUrl") ?: "https://github.com/SmallThingz/wikidict/releases/download/applications-20261010/wikidict-app-qa-English-30words.wikblb",
            "English device transfer", 3365898,
            "1388760245fdfc7aaadebe1770415f44cf26e391811abae8d62b4044528b4ee3",
        )
        val before = library.dictionaries.map { it.id }.toSet()
        try {
            withTimeout(120_000) { library.download(item).join() }
            assertNull(library.error)
            val edition = dictionaryEdition(java.net.URI(item.url).path.substringAfterLast('/'))
            val id = if (edition.isEmpty()) item.sha256 else "${item.sha256}-$edition"
            assertTrue(library.dictionaries.any { it.id == id && it.edition == edition })
            assertEquals("cat",library.read(library.search("cat").single { it.dictionary == id && it.title == "cat" }).title)
        } finally {
            library.dictionaries.map { it.id }.filter { it !in before }.forEach { library.remove(it).join() }
        }
    }
    @Test fun searchChoicesDistinguishTheSameWordInDifferentSourceEditions(): Unit = runBlocking {
        val before = library.dictionaries.map { it.id }.toSet()
        val bytes = InstrumentationRegistry.getInstrumentation().context.assets.open("compiled-alias-targets.wikblb").use { it.readBytes() }
        try {
            for (edition in listOf("ar","bg")) {
                library.importFile(name={"${edition}wiktionary-20261001-ba118bf7fc9c1aedc1edb28a0aa86e0b43b681f222af6616e13c43be87815b06.wikblb"}) { java.io.ByteArrayInputStream(bytes) }.join()
                assertNull(library.error)
            }
            compose.onNodeWithContentDescription("Dictionary").performClick()
            compose.onNode(hasSetTextAction()).performTextInput("animus")
            compose.waitUntil(10000){compose.onAllNodesWithText("ar.wiktionary.org · 2026-10-01").fetchSemanticsNodes().isNotEmpty()}
            compose.onNodeWithText("ar.wiktionary.org · 2026-10-01").assertExists()
            compose.onNodeWithText("bg.wiktionary.org · 2026-10-01").assertExists()
            capture("source-edition-choices.png")
        } finally {
            library.dictionaries.map { it.id }.filter { it !in before }.forEach { library.remove(it).join() }
        }
    }
    @Test fun compressedDictionaryIndexesAndReadsWithoutExpandingOnDisk() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val rawHit = library.exact("elephant", "English")!!
        val expected = library.read(rawHit)
        val before = library.dictionaries.map { it.id }.toSet()
        val compressed = java.io.File(context.cacheDir, "test.wikblb.xz")
        try {
            InstrumentationRegistry.getInstrumentation().context.assets.open("English-extreme.wikblb.xz").use { input ->
                compressed.outputStream().use { output -> input.copyTo(output) }
            }
            library.importFile { compressed.inputStream() }.join()
            assertNull(library.error)
            val info = library.dictionaries.single { it.id !in before }
            val hit = library.search("elephant").first { it.dictionary == info.id && it.title == "elephant" }
            val actual = library.read(hit)
            assertEquals(rawHit.dictionary, expected.contentDictionary)
            assertEquals(hit.dictionary, actual.contentDictionary)
            assertEquals(expected.copy(origin=null, contentDictionary=null), actual.copy(origin=null, contentDictionary=null))
            assertNotEquals(expected.origin?.dictionary, actual.origin?.dictionary)
            assertEquals(compressed.length(), java.io.File(context.filesDir, "dictionaries/${info.id}.wikblb").length())
            library.remove(info.id).join()
        } finally {
            library.dictionaries.map { it.id }.filter { it !in before }.forEach { library.remove(it).join() }
            compressed.delete()
        }
    }

}
