package app.smallthingz.dict

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.runBlocking
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
        compose.waitUntil(15000) { compose.onAllNodesWithTag("entry-scroll").fetchSemanticsNodes().isNotEmpty() }
    }
    private fun search(word:String) {
        compose.onNodeWithContentDescription("Dictionary").performClick()
        compose.onNode(hasSetTextAction()).performTextInput(word)
        compose.waitUntil(10000){compose.onAllNodesWithText(word).fetchSemanticsNodes().isNotEmpty()}
        compose.onAllNodesWithText(word).onFirst().performClick()
        compose.waitUntil(10000){compose.onAllNodesWithTag("entry-scroll").fetchSemanticsNodes().isNotEmpty()}
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
        compose.activityRule.scenario.recreate()
        compose.waitUntil(15000){compose.onAllNodesWithTag("entry-scroll").fetchSemanticsNodes().isNotEmpty()}
    }
    @Test fun checksumFailureDoesNotInstallOrDamageLibrary() = runBlocking {
        val before=library.dictionaries.map{it.id}
        library.download(library.catalog.first().copy(sha256="0".repeat(64))).join()
        assertTrue(library.error!!.contains("checksum"))
        assertEquals(before,library.dictionaries.map{it.id})
        assertEquals("cat",library.read(library.exact("cat")!!).title)
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
        assertEquals(1024, learning.data.settings.mediaCacheMb)
        slide("Remember words", 1f)
        assertEquals(500, learning.data.settings.historyLimit)
        slide("Remember words", 0f)
        assertFalse(learning.data.settings.historyEnabled)
        slide("Questions per round", .5f)
        assertEquals(27, learning.data.settings.quizLength)
        compose.runOnIdle { learning.updateSettings { it.copy(mediaCacheMb=100, historyEnabled=true, historyLimit=100, quizLength=10) } }
    }
}
