package app.smallthingz.dict

import androidx.activity.compose.setContent
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.platform.UriHandler
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.text.TextLayoutResult
import androidx.test.platform.app.InstrumentationRegistry
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.security.MessageDigest
import java.util.UUID
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test

/** Real typed import and DictApp routing; intercepted URIs cannot launch a browser. */
class BookSourcesDeviceTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()

    private fun fixture(source: String, destination: String): ByteArray {
        fun u32(n: Int) = ByteArray(4) { (n ushr (it * 8)).toByte() }
        fun string(s: String) = s.toByteArray(Charsets.UTF_8).let { u32(it.size) + it }
        fun span(text: String, target: String = "") = byteArrayOf(if (target.isEmpty()) 0 else 1, 0, 0) +
            listOf(text, target, "", "", "", "").fold(byteArrayOf()) { bytes, value -> bytes + string(value) }
        fun block(text: String, target: String = "") = byteArrayOf(2, 1, 0) + u32(1) + span(text, target) +
            byteArrayOf(0) + string("") + string("") + byteArrayOf(0)
        fun section(title: String, blocks: List<ByteArray>) = byteArrayOf(3) + string(title) + u32(blocks.size) +
            blocks.fold(byteArrayOf()) { bytes, value -> bytes + value }
        fun presentation(sections: List<ByteArray>) = "DPR2".toByteArray() + u32(0) + u32(sections.size) +
            sections.fold(byteArrayOf()) { bytes, value -> bytes + value } + ByteArray(20)
        val records = mapOf(
            source to presentation(listOf(section("Noun", listOf(
                block("ISBN 9780306406157", "Special:BookSources/9780306406157"),
                block("Read ordinary target", destination), block("Read source notes", "#Usage_notes"))),
                section("Usage notes", listOf(block("BOOK SOURCE SECTION BODY"))))),
            destination to presentation(listOf(section("Noun", listOf(block("ORDINARY TARGET BODY")))))
        )
        return ByteArrayOutputStream().apply {
            fun nul(value: String) { write(value.toByteArray(Charsets.UTF_8)); write(0) }
            write("WIKBLB08".toByteArray()); write(1); nul("fr"); nul("French")
            records.toSortedMap().forEach { (title, payload) ->
                nul(title); var size = payload.size
                while (size >= 128) { write((size and 127) or 128); size = size ushr 7 }
                write(size); write(payload)
            }
        }.toByteArray()
    }

    private fun touchLink(label: String) {
        compose.onNodeWithTag("entry-scroll").performScrollToNode(hasText(label))
        val node = compose.onNodeWithText(label, useUnmergedTree = true).performScrollTo()
        val layouts = mutableListOf<TextLayoutResult>()
        node.performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(layouts) }
        node.performTouchInput { click(layouts.single().getBoundingBox(1).center) }
        compose.waitForIdle()
    }

    @Test fun compiledBookSourceUsesEditionWhileOrdinaryAndSectionLinksStayLocal(): Unit = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        assumeTrue("Use the isolated validation app", context.packageName.endsWith(".validation"))
        val library = LibraryStore.get(context)
        val learning = LearningStore.get(context)
        val before = library.dictionaries.map { it.id }.toSet()
        val previousSettings = learning.data.settings
        val prefs = context.getSharedPreferences("library", 0)
        val lastKeys = listOf("lastTitle", "lastLanguage", "lastDictionary", "lastRecordKey", "lastContextDictionary", "lastEdition")
        val previousWord = lastKeys.associateWith { prefs.getString(it, null) }
        val fixtureKeys = mutableListOf<String>()
        val opened = mutableListOf<String>()
        val suffix = UUID.randomUUID().toString()
        val sourceTitle = "Book source $suffix"
        val destinationTitle = "Book destination $suffix"
        val edition = "arwiktionary-20261001"
        val payload = fixture(sourceTitle, destinationTitle)
        val fixtureId = MessageDigest.getInstance("SHA-256").digest(payload)
            .joinToString("") { "%02x".format(it) } + "-$edition"
        try {
            val hash = MessageDigest.getInstance("SHA-256").digest("French".toByteArray(Charsets.UTF_8))
                .joinToString("") { "%02x".format(it) }
            library.importFile(name = { "$edition-$hash.wikblb" }) {
                ByteArrayInputStream(payload)
            }.join()
            assertNull(library.error)
            val dictionary = library.dictionaries.single { it.id == fixtureId && it.id !in before }
            assertEquals(2, dictionary.count)
            val source = library.search(sourceTitle).single { it.dictionary == dictionary.id && it.title == sourceTitle }
            val destination = library.search(destinationTitle).single { it.dictionary == dictionary.id && it.title == destinationTitle }
            val decoded = library.read(source)
            assertEquals("French", decoded.language)
            assertEquals(edition, decoded.edition)
            assertEquals("Special:BookSources/9780306406157", decoded.sections.first().blocks.first().spans.single().target)
            fixtureKeys += decoded.key
            fixtureKeys += library.read(destination).key
            library.rememberWord(source)
            compose.runOnUiThread {
                learning.updateSettings { it.copy(collapseOtherSections = true, collapseDetails = false, allowImages = false, allowAudio = false) }
                compose.activity.setContent { MaterialTheme {
                    CompositionLocalProvider(LocalUriHandler provides object : UriHandler {
                        override fun openUri(uri: String) { opened.add(uri) }
                    }) { DictApp(library, learning, {}) }
                } }
            }
            compose.waitUntil(10000) { compose.onAllNodes(hasTestTag("entry-title") and hasText(sourceTitle))
                .fetchSemanticsNodes(atLeastOneRootRequired = false).isNotEmpty() }
            touchLink("ISBN 9780306406157")
            compose.runOnIdle {
                assertEquals(listOf("https://ar.wiktionary.org/wiki/Special%3ABookSources%2F9780306406157"), opened)
                assertEquals(sourceTitle, prefs.getString("lastTitle", null))
                assertEquals("French", prefs.getString("lastLanguage", null))
                assertEquals(edition, prefs.getString("lastEdition", null))
            }
            compose.onNode(hasTestTag("entry-title") and hasText(sourceTitle)).assertIsDisplayed()
            touchLink("Read source notes")
            compose.waitUntil(10000) { compose.onNodeWithText("BOOK SOURCE SECTION BODY").isDisplayed() }
            compose.onNodeWithText("BOOK SOURCE SECTION BODY").assertIsDisplayed()
            touchLink("Read ordinary target")
            compose.waitUntil(10000) { compose.onAllNodes(hasTestTag("entry-title") and hasText(destinationTitle))
                .fetchSemanticsNodes(atLeastOneRootRequired = false).isNotEmpty() }
            compose.onNodeWithText("ORDINARY TARGET BODY").assertIsDisplayed()
            compose.runOnIdle { assertEquals(listOf("https://ar.wiktionary.org/wiki/Special%3ABookSources%2F9780306406157"), opened) }
        } finally {
            compose.runOnUiThread {
                learning.updateSettings { previousSettings }
                fixtureKeys.forEach(learning::removeHistory)
            }
            library.dictionaries.map { it.id }.filter { it == fixtureId && it !in before }.forEach { library.remove(it).join() }
            prefs.edit().apply { previousWord.forEach { (key, value) -> putString(key, value) } }.commit()
        }
    }
}
