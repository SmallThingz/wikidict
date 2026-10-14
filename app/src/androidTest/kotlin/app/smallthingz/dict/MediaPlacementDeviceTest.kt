package app.smallthingz.dict

import androidx.activity.compose.setContent
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Valid DPR2 fixtures; audio is disabled so rendering cannot fetch or play media. */
class MediaPlacementDeviceTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()

    private fun fixture(location: String): ByteArray {
        fun u32(n: Int) = ByteArray(4) { (n ushr (it * 8)).toByte() }
        fun u16(n: Int) = byteArrayOf(n.toByte(), (n ushr 8).toByte())
        fun string(s: String) = s.toByteArray(Charsets.UTF_8).let { u32(it.size) + it }
        fun span(text: String, media: Boolean = false): ByteArray =
            byteArrayOf(if (media) 1 else 0, 0, 0) +
                listOf(text, if (media) "File:Tone.ogg" else "", "", "", if (media) "wikidict-media" else "", "")
                    .fold(byteArrayOf()) { bytes, value -> bytes + string(value) }
        val inline = u32(1) + span("Tone.ogg", media = true)
        val plain = u32(1) + span("Body cell")
        val isTable = location == "caption" || location == "cell"
        val table = if (isTable) {
            val caption = if (location == "caption") inline else u32(1) + span("Table caption")
            val first = byteArrayOf(0) + u16(1) + u16(1) + plain
            val cells = if (location == "cell") first + byteArrayOf(0) + u16(1) + u16(1) + inline else first
            byteArrayOf(1) + caption + u32(1) + u32(if (location == "cell") 2 else 1) + cells
        } else byteArrayOf(0)
        val blockKind = if (isTable) 12 else if (location == "preformatted") 10 else 0
        val body = if (isTable) u32(0) else if (location == "body" || location == "preformatted") inline else plain
        val block = byteArrayOf(blockKind.toByte(), 0, 0) + body + byteArrayOf(0) + string("") + string("") + table
        val display = if (location == "title") inline else u32(0)
        val preamble = if (location == "preamble") inline else u32(0)
        val references = if (location == "reference")
            u32(1) + u32(1) + u32(1) + string("") + string("") + inline else u32(0)
        val media = u32(1) + string("Tone.ogg") + byteArrayOf(1) + string("Tone.ogg")
        return "DPR2".toByteArray() + display + u32(1) + byteArrayOf(3) + string("Noun") + u32(1) + block +
            preamble + u32(0) + u32(0) + references + media
    }

    @Test fun typedInlineMediaKeepsItsLocationAndOnlyUnplacedMediaUsesTheFooter() {
        for (location in listOf("caption", "title", "preamble", "reference", "cell", "body", "preformatted", "footer")) {
            val entry = BlobDecoder.decode(fixture(location), "Media $location", "language", "English", "en")
            assertEquals("location=$location", listOf(Media("Tone.ogg", "audio", "Tone.ogg")), entry.media)
            if (location == "caption") {
                val table = requireNotNull(entry.sections.single().blocks.single().table)
                assertEquals("Tone.ogg", table.caption.single().text)
                assertEquals("File:Tone.ogg", table.caption.single().target)
                assertEquals("wikidict-media", table.caption.single().classes)
                assertEquals("Body cell", table.rows.single().single().spans.single().text)
            }
            compose.runOnUiThread {
                compose.activity.setContent { MaterialTheme {
                    EntryView(entry, false, {}, settings = AppSettings(
                        collapseOtherSections = false, collapseDetails = false, allowImages = false, allowAudio = false))
                } }
            }
            compose.waitForIdle()
            if (location != "footer") {
                compose.onNodeWithText("Tone.ogg", useUnmergedTree = true).performScrollTo().assertIsDisplayed()
                compose.onAllNodesWithContentDescription("Play pronunciation").assertCountEquals(1)
                compose.onNodeWithContentDescription("Play pronunciation").assertIsNotEnabled()
            }
            compose.onNodeWithTag("entry-scroll").performScrollToNode(hasText("Wiktionary contributors"))
            if (location == "footer") {
                compose.onAllNodesWithContentDescription("Play pronunciation").assertCountEquals(1)
                compose.onNodeWithContentDescription("Play pronunciation").assertIsNotEnabled()
                compose.onNodeWithText("Media").assertIsDisplayed()
                compose.onNodeWithText("Tone", useUnmergedTree = true).assertIsDisplayed()
            } else {
                compose.onNodeWithText("Media").assertDoesNotExist()
                compose.onNodeWithText("Tone", useUnmergedTree = true).assertDoesNotExist()
            }
        }
    }
}
