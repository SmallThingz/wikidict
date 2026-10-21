package app.smallthingz.dict

import androidx.activity.compose.setContent
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.*
import androidx.compose.ui.text.TextLayoutResult
import androidx.test.platform.app.InstrumentationRegistry
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test

/** Real import/search/navigation over synthetic typed records, with no source parser or network. */
class AliasSectionDeviceTest {
    @get:Rule val compose = createPhysicalComposeRule()

    private fun aliases(): ByteArray {
        fun u32(value: Int) = ByteArray(4) { (value ushr (it * 8)).toByte() }
        fun vu(value: Int): ByteArray {
            val out = ByteArrayOutputStream(); var n = value
            while (n >= 128) { out.write((n and 127) or 128); n = n ushr 7 }
            out.write(n); return out.toByteArray()
        }
        fun fixed(value: String): ByteArray = value.toByteArray().let { u32(it.size) + it }
        fun field(value: ByteArray) = vu(value.size) + value
        fun record(source: String, target: String, fragment: String, label: String): ByteArray {
            val link = target + if (fragment.isEmpty()) "" else "#$fragment"
            val span = byteArrayOf(1, 0, 0) + listOf(label, link, "", "", "", "").fold(byteArrayOf()) { a, v -> a + fixed(v) }
            val presentation = "DPR2".toByteArray() + u32(0) + u32(0) + u32(1) + span + ByteArray(16)
            val payload = "DAL1".toByteArray() + u32(0) + byteArrayOf(1, 1) + u32(0) + byteArrayOf(1) +
                listOf(source, source, link, target, target, fragment).fold(byteArrayOf()) { a, v -> a + field(v.toByteArray()) } + field(presentation)
            return "1\t$source".toByteArray() + byteArrayOf(0) + field(payload)
        }
        return "WIKBLB08".toByteArray() + byteArrayOf(8) +
            record("Alias chain", "Alias click", "", "Continue one edge") +
            record("Alias click", "Alias notes", "Etymology_2", "Use explicit etymology") +
            record("Alias notes", "Anchor destination", "Usage_notes", "Use alias notes")
    }

    private fun touchLink(label: String) {
        val node = compose.onNodeWithText(label, useUnmergedTree = true)
        val layouts = mutableListOf<TextLayoutResult>()
        node.performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(layouts) }
        node.performTouchInput { click(layouts.single().getBoundingBox(1).center) }
        compose.waitForIdle()
    }

    @Test fun searchAliasOpensFoldedFragmentAndExplicitLinkWinsWithoutFollowingAnotherEdge(): Unit = runBlocking {
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
        val fixtureKeys = mutableSetOf<String>()
        try {
            val edition = "anchornavwiktionary-20261001"
            val english = "ba118bf7fc9c1aedc1edb28a0aa86e0b43b681f222af6616e13c43be87815b06"
            library.importFile(name = { "$edition-$english.wikblb" }) {
                instrumentation.context.assets.open("section-navigation.wikblb")
            }.join()
            assertNull(library.error)
            val targetDictionary = library.dictionaries.single { it.id !in before }
            library.importFile(name = { "$edition-aliases.wikblb" }) { ByteArrayInputStream(aliases()) }.join()
            assertNull(library.error)
            val aliasDictionary = library.dictionaries.single { it.id !in before && it.id != targetDictionary.id }
            val source = library.search("Anchor source").single { it.dictionary == targetDictionary.id && it.title == "Anchor source" }
            val alias = library.search("Alias notes").single { it.dictionary == aliasDictionary.id && it.title == "Alias notes" }
            val followed = library.read(alias)
            assertEquals("Anchor destination", followed.title)
            assertEquals("English", followed.language)
            assertEquals(edition, followed.edition)
            val redirect = requireNotNull(followed.redirect)
            assertEquals("Usage_notes", redirect.fragment)
            assertTrue(redirect.followed)
            val chain = library.search("Alias chain").single { it.dictionary == aliasDictionary.id && it.title == "Alias chain" }
            assertEquals("Alias click", library.read(chain).title)
            for (hit in library.search("", 500).filter { it.dictionary == targetDictionary.id || it.dictionary == aliasDictionary.id })
                fixtureKeys.add(library.read(hit).key)
            library.rememberWord(source)
            compose.runOnUiThread {
                learning.updateSettings { it.copy(collapseEtymology = true, collapseOtherSections = true, allowImages = false, allowAudio = false) }
                compose.activity.setContent { MaterialTheme { DictApp(library, learning, {}) } }
            }
            compose.waitUntil(10000) { compose.onAllNodes(hasTestTag("entry-title") and hasText("Anchor source")).fetchSemanticsNodes(atLeastOneRootRequired = false).isNotEmpty() }
            fun search(title: String) {
                compose.onNodeWithContentDescription("Dictionary").performClick()
                compose.onNode(hasSetTextAction()).performTextInput(title)
                compose.waitUntil(10000) { compose.onAllNodes(hasText(title) and hasClickAction() and !hasSetTextAction()).fetchSemanticsNodes(atLeastOneRootRequired = false).isNotEmpty() }
                compose.onNode(hasText(title) and hasClickAction() and !hasSetTextAction()).performClick()
            }
            search("Alias notes")
            compose.waitUntil(10000) { compose.onAllNodesWithText("DESTINATION USAGE BODY").fetchSemanticsNodes(atLeastOneRootRequired = false).isNotEmpty() }
            compose.onNodeWithText("DESTINATION USAGE BODY").assertIsDisplayed()
            compose.onNodeWithContentDescription("Collapse Usage notes").assertIsDisplayed()
            compose.onNodeWithText("PARENT SECTION REMAINS FOLDED").assertDoesNotExist()
            compose.runOnIdle {
                assertEquals(aliasDictionary.id, prefs.getString("lastDictionary", null))
                assertEquals(targetDictionary.id, prefs.getString("lastContextDictionary", null))
            }
            // A chain still stops after one edge. Its displayed link supplies a fragment
            // that must override the next alias's different, inherited Usage_notes fragment.
            search("Alias chain")
            compose.waitUntil(10000) { compose.onAllNodes(hasTestTag("entry-title") and hasText("Alias click")).fetchSemanticsNodes(atLeastOneRootRequired = false).isNotEmpty() }
            compose.onNodeWithText("DESTINATION USAGE BODY").assertDoesNotExist()
            touchLink("Use explicit etymology")
            compose.waitUntil(10000) { compose.onNodeWithText("PARENT SECTION REMAINS FOLDED").isDisplayed() }
            compose.onNodeWithText("PARENT SECTION REMAINS FOLDED").assertIsDisplayed()
            compose.onNodeWithContentDescription("Collapse Etymology 2").assertIsDisplayed()
            compose.onNodeWithText("DESTINATION USAGE BODY").assertDoesNotExist()
            compose.runOnIdle {
                assertEquals(aliasDictionary.id, prefs.getString("lastDictionary", null))
                assertEquals("1\tAlias notes", prefs.getString("lastRecordKey", null))
            }
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
