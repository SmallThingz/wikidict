package app.smallthingz.dict

import androidx.activity.compose.setContent
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.test.*
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.font.FontWeight
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Valid DPR2 fixtures; audio is disabled so rendering cannot fetch or play media. */
class MediaPlacementDeviceTest {
    @get:Rule val compose = createPhysicalComposeRule()

    private val firstCaptionLine = "First caption line " + "a".repeat(21)
    private val secondCaptionLine = "Second caption line " + "b".repeat(20)
    private val denseCaption = "$firstCaptionLine\n$secondCaptionLine"

    private fun fixture(location: String): ByteArray {
        fun u32(n: Int) = ByteArray(4) { (n ushr (it * 8)).toByte() }
        fun u16(n: Int) = byteArrayOf(n.toByte(), (n ushr 8).toByte())
        fun string(s: String) = s.toByteArray(Charsets.UTF_8).let { u32(it.size) + it }
        fun span(text: String, media: Boolean = false, kind: Int = if (media) 1 else 0, bold: Boolean = false): ByteArray =
            byteArrayOf(kind.toByte(), 0, if (bold) 1 else 0) +
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
        val body = when {
            isTable -> u32(0)
            location == "dense-caption" -> {
                val values = firstCaptionLine.mapIndexed { index, character ->
                    span(character.toString(), media = true, bold = index % 2 == 0)
                } + listOf(span("\n", media = true, kind = 3)) +
                    secondCaptionLine.mapIndexed { index, character ->
                        span(character.toString(), media = true, bold = index % 2 == 0)
                    }
                u32(values.size) + values.fold(byteArrayOf()) { bytes, value -> bytes + value }
            }
            location == "body" || location == "preformatted" -> inline
            else -> plain
        }
        val block = byteArrayOf(blockKind.toByte(), 0, 0) + body + byteArrayOf(0) + string("") + string("") + table
        val display = if (location == "title") inline else u32(0)
        val preamble = if (location == "preamble") inline else u32(0)
        val references = if (location == "reference")
            u32(1) + u32(1) + u32(1) + string("") + string("") + inline else u32(0)
        val media = u32(1) + string("Tone.ogg") + byteArrayOf(1) +
            string(if (location == "dense-caption") denseCaption else "Tone.ogg")
        return "DPR2".toByteArray() + display + u32(1) + byteArrayOf(3) + string("Noun") + u32(1) + block +
            preamble + u32(0) + u32(0) + references + media
    }

    private fun ownerFixture(spans: List<Span>, media: List<Media>): ByteArray {
        fun u32(n: Int) = ByteArray(4) { (n ushr (it * 8)).toByte() }
        fun string(s: String) = s.toByteArray(Charsets.UTF_8).let { u32(it.size) + it }
        fun span(value: Span): ByteArray {
            val kind = listOf("text", "link", "external_link", "line_break").indexOf(value.kind)
            require(kind >= 0)
            return byteArrayOf(kind.toByte(), 0, if (value.bold) 1 else 0) +
                listOf(value.text, value.target, value.trail, value.language, value.classes, value.direction)
                    .fold(byteArrayOf()) { bytes, text -> bytes + string(text) }
        }
        val body = u32(spans.size) + spans.fold(byteArrayOf()) { bytes, value -> bytes + span(value) }
        val block = byteArrayOf(0, 0, 0) + body + byteArrayOf(0) + string("") + string("") + byteArrayOf(0)
        val records = u32(media.size) + media.fold(byteArrayOf()) { bytes, value ->
            bytes + string(value.file) + byteArrayOf(1) + string(value.caption)
        }
        return "DPR2".toByteArray() + u32(0) + u32(1) + byteArrayOf(3) + string("Noun") + u32(1) + block +
            u32(0) + u32(0) + u32(0) + u32(0) + records
    }

    @Test fun decodedMediaOwnersKeepAuthoredLinksAndDistinctControls() {
        val tone = "wikidict-media wikidict-media-file-546f6e652e6f6767"
        val other = "wikidict-media wikidict-media-file-4f746865722e6f6767"
        val mixed = listOf(
            Span("link", "A ", target = "File:Tone.ogg", classes = tone),
            Span("link", "domestic cat", target = "cat", classes = tone, bold = true),
            Span("link", " and ", target = "File:Tone.ogg", classes = tone),
            Span("external_link", "external", target = "https://example.org", classes = tone),
            Span("link", ".", target = "File:Tone.ogg", classes = tone))
        val allAuthored = listOf(Span("link", "same", target = "cat", classes = tone),
            Span("line_break", "\n"), Span("link", "same", target = "dog", classes = other))
        val dense = List(40) { Span("link", "a", target = "cat", classes = tone, bold = true) } +
            Span("line_break", "\n", classes = tone) +
            List(40) { Span("external_link", "b", target = "https://example.org", classes = tone) }
        for ((name, values, media) in listOf(
            Triple("mixed", mixed, listOf(Media("Tone.ogg", "audio", "A domestic cat and external."))),
            Triple("identical", allAuthored, listOf(Media("Tone.ogg", "audio", "same"), Media("Other.ogg", "audio", "same"))),
            Triple("dense", dense, listOf(Media("Tone.ogg", "audio", "a".repeat(40) + "\n" + "b".repeat(40))))
        )) {
            val entry = BlobDecoder.decode(ownerFixture(values, media), "Owned $name", "language", "English", "en")
            assertEquals(values, entry.sections.single().blocks.single().spans)
            assertEquals(media, entry.media)
            assertEquals(2, entry.readingRows.size)
            val clicked = mutableListOf<String>()
            compose.runOnUiThread {
                compose.activity.setContent { MaterialTheme {
                    EntryView(entry, false, {}, onLink = { clicked.add(it.target) }, settings = AppSettings(
                        collapseOtherSections = false, collapseDetails = false, allowImages = false, allowAudio = false))
                } }
            }
            compose.waitForIdle()
            val caption = values.joinToString("") { if (it.kind == "line_break") "\n" else it.text + it.trail }
            compose.onNodeWithTag("entry-scroll").performScrollToNode(hasText(caption))
            val node = compose.onNodeWithText(caption, useUnmergedTree = true).assertIsDisplayed()
            val text = node.fetchSemanticsNode().config[SemanticsProperties.Text].single()
            assertEquals(caption, text.text)
            val actualLinks = text.getLinkAnnotations(0, text.length)
            val expected = values.filter { it.kind == "link" || it.kind == "external_link" }
            assertEquals(expected.size, actualLinks.size)
            expected.zip(actualLinks).forEach { (span, annotation) ->
                if (span.kind == "link") assertEquals(span.target, (annotation.item as LinkAnnotation.Clickable).tag)
                else assertEquals(span.target, (annotation.item as LinkAnnotation.Url).url)
            }
            compose.onAllNodesWithContentDescription("Play pronunciation").assertCountEquals(media.size)
            compose.onAllNodesWithContentDescription("Play pronunciation").fetchSemanticsNodes().indices.forEach {
                compose.onAllNodesWithContentDescription("Play pronunciation")[it].assertIsNotEnabled()
            }
            val offset = if (name == "mixed") caption.indexOf("domestic cat") + 1 else 1
            val layouts = mutableListOf<TextLayoutResult>()
            node.performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(layouts) }
            node.performTouchInput { click(layouts.single().getBoundingBox(offset).center) }
            compose.runOnIdle { assertEquals(listOf("cat"), clicked) }
            compose.onNodeWithTag("entry-scroll").performScrollToNode(hasText("Wiktionary contributors"))
            compose.onNodeWithText("Media").assertDoesNotExist()
            compose.onNodeWithText("Tone", useUnmergedTree = true).assertDoesNotExist()
            compose.onNodeWithText("Other", useUnmergedTree = true).assertDoesNotExist()
        }
    }

    @Test fun typedInlineMediaKeepsItsLocationAndOnlyUnplacedMediaUsesTheFooter() {
        for (location in listOf("caption", "title", "preamble", "reference", "cell", "body", "preformatted", "dense-caption", "footer")) {
            val entry = BlobDecoder.decode(fixture(location), "Media $location", "language", "English", "en")
            assertEquals("location=$location", listOf(Media("Tone.ogg", "audio",
                if (location == "dense-caption") denseCaption else "Tone.ogg")), entry.media)
            val clicked = mutableListOf<String>()
            if (location == "caption") {
                val table = requireNotNull(entry.sections.single().blocks.single().table)
                assertEquals("Tone.ogg", table.caption.single().text)
                assertEquals("File:Tone.ogg", table.caption.single().target)
                assertEquals("wikidict-media", table.caption.single().classes)
                assertEquals("Body cell", table.rows.single().single().spans.single().text)
            }
            compose.runOnUiThread {
                compose.activity.setContent { MaterialTheme {
                    EntryView(entry, false, {}, onLink = { clicked.add(it.target) }, settings = AppSettings(
                        collapseOtherSections = false, collapseDetails = false, allowImages = false, allowAudio = false))
                } }
            }
            compose.waitForIdle()
            if (location == "dense-caption") {
                val spans = entry.sections.single().blocks.single().spans
                assertEquals(81, spans.size)
                assertTrue(spans.all { it.target == "File:Tone.ogg" && it.hasClassToken("wikidict-media") })
                compose.onNodeWithTag("entry-scroll").performScrollToNode(hasText(denseCaption))
                val node = compose.onNodeWithText(denseCaption, useUnmergedTree = true).assertIsDisplayed()
                val text = node.fetchSemanticsNode().config[SemanticsProperties.Text].single()
                assertEquals(denseCaption, text.text)
                val links = text.getLinkAnnotations(0, text.length)
                assertEquals(80, links.size)
                assertTrue(links.all { (it.item as? LinkAnnotation.Clickable)?.tag == "File:Tone.ogg" })
                for (start in listOf(0, firstCaptionLine.length + 1)) {
                    assertTrue(text.spanStyles.any {
                        it.start == start && it.end == start + 1 && it.item.fontWeight == FontWeight.Bold
                    })
                }
                compose.onAllNodesWithContentDescription("Play pronunciation").assertCountEquals(1)
                compose.onNodeWithContentDescription("Play pronunciation").assertIsNotEnabled()
                val layouts = mutableListOf<TextLayoutResult>()
                node.performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(layouts) }
                node.performTouchInput { click(layouts.single().getBoundingBox(1).center) }
                compose.runOnIdle { assertEquals(listOf("File:Tone.ogg"), clicked) }
            } else if (location != "footer") {
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
