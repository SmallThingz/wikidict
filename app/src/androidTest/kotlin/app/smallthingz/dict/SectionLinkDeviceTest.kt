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
