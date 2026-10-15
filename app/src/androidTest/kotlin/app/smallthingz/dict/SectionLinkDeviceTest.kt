package app.smallthingz.dict

import androidx.activity.compose.setContent
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.text.TextLayoutResult
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test

/** Supported typed section/reference links; no wikitext parsing or network fixture. */
class SectionLinkDeviceTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()
    private val forwarded = mutableListOf<String>()

    private fun show(target: String, label: String, sectionTitle: String, references: List<Reference> = emptyList()) {
        val entry = Entry("Section link fixture", emptyList(), "language", "English", "en", listOf(
            Section(3, "Noun", listOf(
                Block("definition", 1, listOf(Span("link", label, target = target)))
            ) + List(35) { Block("definition", 1, listOf(Span("text", "Earlier meaning $it"))) }),
            Section(3, sectionTitle, listOf(Block("paragraph", 0, listOf(Span("text", "SECTION DESTINATION BODY")))))
        ), references, preamble = listOf(Span("text", "Preamble keeps its own list row")))
        compose.runOnUiThread {
            compose.activity.setContent {
                MaterialTheme { EntryView(entry, false, {}, onLink = { forwarded.add(it) }, settings = AppSettings()) }
            }
        }
    }

    private fun touchLink(label: String) {
        val node = compose.onNodeWithText(label, useUnmergedTree = true)
        val layouts = mutableListOf<TextLayoutResult>()
        node.performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(layouts) }
        val glyph = layouts.single().getBoundingBox(1).center
        node.performTouchInput { click(glyph) }
        compose.waitForIdle()
    }


    private fun blankHeadingFixture(): ByteArray {
        fun u32(n: Int) = ByteArray(4) { (n ushr (it * 8)).toByte() }
        fun u16(n: Int) = byteArrayOf(n.toByte(), (n ushr 8).toByte())
        fun string(value: String) = value.toByteArray(Charsets.UTF_8).let { u32(it.size) + it }
        fun spans(text: String, target: String = ""): ByteArray =
            u32(1) + byteArrayOf(if (target.isEmpty()) 0 else 1, 0, 0) +
                listOf(text, target, "", "", "", "").fold(byteArrayOf()) { bytes, value -> bytes + string(value) }
        fun block(kind: Int, text: String, target: String = "", path: String = "",
                  table: ByteArray = byteArrayOf(0)): ByteArray =
            byteArrayOf(kind.toByte(), if (kind == 2 || kind == 5) 1 else 0, 0) +
                (if (kind == 12) u32(0) else spans(text, target)) +
                byteArrayOf(0) + string(path) + string("") + table
        fun table(text: String, target: String): ByteArray = block(12, "", table =
            byteArrayOf(1) + u32(0) + u32(1) + u32(1) +
                byteArrayOf(0) + u16(1) + u16(1) + spans(text, target))
        fun section(title: String, blocks: List<ByteArray>): ByteArray =
            byteArrayOf(3) + string(title) + u32(blocks.size) +
                blocks.fold(byteArrayOf()) { bytes, value -> bytes + value }
        val sections = listOf(
            section("", listOf(
                block(0, "Read blank prose", "prose"),
                block(5, "Read blank list", "list", "*"),
                table("Read blank cell", "cell"))),
            section(" \t", listOf(
                block(2, "Blank meaning"),
                block(0, "Read blank detail", "detail"),
                block(5, "Blank detail list", path = "*"),
                table("Blank detail cell", "detail-cell"))),
            section("Notes", listOf(block(0, "Named notes remain folded")))
        )
        return "DPR2".toByteArray() + u32(0) + u32(sections.size) +
            sections.fold(byteArrayOf()) { bytes, value -> bytes + value } +
            u32(0) + u32(0) + u32(0) + u32(0) + u32(0)
    }

    @Test fun decodedBlankHeadingsKeepContentAndLinksReachableWithRetainedFolds() {
        val entry = BlobDecoder.decode(blankHeadingFixture(), "Blank heading fixture", "language", "English", "en")
        assertEquals(listOf("", " \t", "Notes"), entry.sections.map { it.title })
        assertEquals(listOf("paragraph", "list_item", "table"), entry.sections[0].blocks.map { it.kind })
        assertEquals("cell", entry.sections[0].blocks[2].table!!.rows.single().single().spans.single().target)
        assertEquals(listOf("definition", "paragraph", "list_item", "table"), entry.sections[1].blocks.map { it.kind })
        val displayed = androidx.compose.runtime.mutableStateOf(entry)
        compose.runOnUiThread {
            compose.activity.setContent {
                MaterialTheme { EntryView(displayed.value, false, {}, onLink = { forwarded.add(it) }, settings = AppSettings()) }
            }
        }
        fun assertBlankContent() {
            for (label in listOf("Read blank prose", "Read blank list", "Read blank cell", "Blank meaning",
                    "Read blank detail", "Blank detail list", "Blank detail cell")) {
                compose.onNodeWithTag("entry-scroll").performScrollToNode(hasText(label))
                compose.onNodeWithText(label, useUnmergedTree = true).assertIsDisplayed()
            }
            compose.onNodeWithText("Named notes remain folded").assertDoesNotExist()
        }
        assertBlankContent()
        for (label in listOf("Read blank prose", "Read blank list", "Read blank cell", "Read blank detail")) {
            compose.onNodeWithTag("entry-scroll").performScrollToNode(hasText(label))
            touchLink(label)
        }
        compose.runOnIdle { assertEquals(listOf("prose", "list", "cell", "detail"), forwarded) }
        // Keep the same entry key and settings so EntryView retains its actual fold map.
        compose.runOnIdle {
            displayed.value = entry.copy(sections = entry.sections.mapIndexed { index, section ->
                if (index < 2) section.copy(title = "Foldable $index") else section
            })
        }
        for (index in 0..1) {
            val label = "Collapse Foldable $index"
            compose.onNodeWithTag("entry-scroll").performScrollToNode(hasContentDescription(label))
            compose.onNodeWithContentDescription(label).performClick()
            compose.onNodeWithContentDescription("Expand Foldable $index").assertIsDisplayed()
        }
        compose.onNodeWithText("Read blank prose").assertDoesNotExist()
        compose.onNodeWithText("Blank meaning").assertDoesNotExist()
        compose.runOnIdle { displayed.value = entry }
        assertBlankContent()
        // A real named section remains folded and still exposes its ordinary toggle.
        compose.onNodeWithTag("entry-scroll").performScrollToNode(hasContentDescription("Expand Notes"))
        compose.onNodeWithContentDescription("Expand Notes").performClick()
        compose.onNodeWithTag("entry-scroll").performScrollToNode(hasText("Named notes remain folded"))
        compose.onNodeWithText("Named notes remain folded").assertIsDisplayed()
    }

    @Test fun sameEntrySectionLinkOpensFoldedHeadingAndShowsItsBody() {
        show("#Usage_notes", "Read usage notes", "Usage notes")
        compose.onNodeWithText("SECTION DESTINATION BODY").assertDoesNotExist()
        touchLink("Read usage notes")
        compose.onNodeWithText("SECTION DESTINATION BODY").assertIsDisplayed()
        compose.onNodeWithContentDescription("Collapse Usage notes").assertIsDisplayed()
        compose.runOnIdle { assertTrue(forwarded.isEmpty()) }
    }

    @Test fun actualReferenceIdentityKeepsPriorityOverAMatchingSectionTitle() {
        show("#reference-2", "Read the reference", "reference-2", listOf(
            Reference(1, 1, "notes", listOf(Span("text", "Other reference"))),
            Reference(2, 1, "", listOf(Span("text", "REFERENCE DESTINATION BODY")))
        ))
        compose.onNodeWithText("REFERENCE DESTINATION BODY").assertDoesNotExist()
        touchLink("Read the reference")
        compose.onNodeWithText("REFERENCE DESTINATION BODY").assertIsDisplayed()
        compose.onNodeWithText("SECTION DESTINATION BODY").assertDoesNotExist()
        compose.runOnIdle { assertTrue(forwarded.isEmpty()) }
    }
    @Test fun crossEntryFragmentNavigatesOnceThroughTheActualLibraryAndApp(): Unit = runBlocking {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        assumeTrue("Use the isolated validation app", context.packageName.endsWith(".validation"))
        val library = LibraryStore.get(context)
        val learning = LearningStore.get(context)
        val before = library.dictionaries.map { it.id }.toSet()
        val previousSettings = learning.data.settings
        val prefs = context.getSharedPreferences("library", 0)
        val lastKeys = listOf("lastTitle", "lastLanguage", "lastDictionary", "lastRecordKey", "lastContextDictionary", "lastEdition")
        val previousWord = lastKeys.associateWith { prefs.getString(it, null) }
        val fixtureKeys = mutableListOf<String>()
        try {
            library.importFile(name = { "section-navigation.wikblb" }) {
                instrumentation.context.assets.open("section-navigation.wikblb")
            }.join()
            assertNull(library.error)
            val dictionary = library.dictionaries.single { it.id !in before }
            assertEquals(2, dictionary.count)
            val source = library.search("Anchor source").single { it.dictionary == dictionary.id && it.title == "Anchor source" }
            val destination = library.search("Anchor destination").single { it.dictionary == dictionary.id && it.title == "Anchor destination" }
            fixtureKeys += library.read(source).key
            fixtureKeys += library.read(destination).key
            library.rememberWord(source)
            compose.runOnUiThread {
                learning.updateSettings { it.copy(collapseEtymology = true, collapseOtherSections = true, allowImages = false, allowAudio = false) }
                compose.activity.setContent { MaterialTheme { DictApp(library, learning, {}) } }
            }
            fun waitForTitle(title: String) {
                compose.waitUntil(10000) { compose.onAllNodes(hasTestTag("entry-title") and hasText(title)).fetchSemanticsNodes().isNotEmpty() }
            }
            fun assertDestinationOpen() {
                // The destination title is intentionally offscreen after the anchor jump.
                compose.waitUntil(10000) { compose.onAllNodesWithText("DESTINATION USAGE BODY").fetchSemanticsNodes().isNotEmpty() }
                compose.onNodeWithText("DESTINATION USAGE BODY").assertIsDisplayed()
                compose.onNodeWithContentDescription("Collapse Usage notes").assertIsDisplayed()
                compose.onNodeWithText("PARENT SECTION REMAINS FOLDED").assertDoesNotExist()
            }
            fun backToSource() {
                compose.onNodeWithTag("entry-scroll").performScrollToNode(hasText("Back to source"))
                touchLink("Back to source")
                waitForTitle("Anchor source")
            }
            fun leaveAndReturn() {
                compose.onNodeWithContentDescription("Settings").performClick()
                compose.onNodeWithContentDescription("Dictionary").performClick()
                compose.onNodeWithContentDescription("Close search").performClick()
                waitForTitle("Anchor destination")
            }
            waitForTitle("Anchor source")
            touchLink("Read destination notes")
            assertDestinationOpen()
            compose.onNodeWithContentDescription("Collapse Usage notes").performClick()
            leaveAndReturn()
            compose.onNodeWithText("DESTINATION USAGE BODY").assertDoesNotExist()
            // A fresh request to the same word and anchor must still be applied.
            compose.onNodeWithTag("entry-scroll").performScrollToNode(hasText("Read destination notes again"))
            touchLink("Read destination notes again")
            assertDestinationOpen()
            backToSource()
            touchLink("Read destination normally")
            waitForTitle("Anchor destination")
            compose.onNodeWithText("DESTINATION USAGE BODY").assertDoesNotExist()
            compose.onNodeWithText("Earlier destination meaning 0").assertIsDisplayed()
            backToSource()
            touchLink("Read missing anchor")
            waitForTitle("Anchor destination")
            compose.onNodeWithText("Earlier destination meaning 0").assertIsDisplayed()
            compose.onNodeWithText("DESTINATION USAGE BODY").assertDoesNotExist()
            compose.onNodeWithText("This word is not in your installed dictionaries.").assertDoesNotExist()
            leaveAndReturn()
            compose.onNodeWithText("DESTINATION USAGE BODY").assertDoesNotExist()
            compose.onNodeWithText("This word is not in your installed dictionaries.").assertDoesNotExist()
        } finally {
            compose.runOnUiThread {
                learning.updateSettings { previousSettings }
                fixtureKeys.forEach(learning::removeHistory)
            }
            library.dictionaries.map { it.id }.filter { it !in before }.forEach { library.remove(it).join() }
            prefs.edit().apply { previousWord.forEach { (key, value) -> putString(key, value) } }.commit()
        }
    }

}
