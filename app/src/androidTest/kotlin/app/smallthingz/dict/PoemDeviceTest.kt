package app.smallthingz.dict

import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.width
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.ResolvedTextDirection
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Valid DPR2 only; media stays disabled and the observed link is intercepted. */
class PoemDeviceTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()
    private val rtlText = "Latin text wraps across this indented poem line and keeps every continuation at its enclosing logical start."
    private val hebrew = "שלום"
    private val defaultHebrew = "עברית"
    private val defaultLatin = "Container direction owns this line"
    private val expected = "Before\n\u00a0\u00a0First  \n\n  Read target  \n\u2066$rtlText\u2069\n\u2067$hebrew\u2069\n\u2067$defaultHebrew\u2069\n\u2066$defaultLatin\u2069\nTone.ogg\n"

    private fun fixture(): ByteArray {
        fun u32(n: Int) = ByteArray(4) { (n ushr (it * 8)).toByte() }
        fun string(s: String) = s.toByteArray(Charsets.UTF_8).let { u32(it.size) + it }
        fun span(kind: Int, text: String, classes: String = "", target: String = "", trail: String = "",
                 direction: String = "", bold: Boolean = false): ByteArray =
            byteArrayOf(kind.toByte(), 0, if (bold) 1 else 0) +
                listOf(text, target, trail, "", classes, direction).fold(byteArrayOf()) { bytes, value -> bytes + string(value) }
        val poem = "wikidict-poem"
        val one = "$poem mw-poem-indented wikidict-poem-indent-1 wikidict-poem-dir-ltr"
        val two = "$poem mw-poem-indented wikidict-poem-indent-2 wikidict-poem-dir-rtl"
        val container = "$poem mw-poem-indented wikidict-poem-indent-1"
        val invalidDirection = "$container wikidict-poem-dir-invalid"
        val values = listOf(
            span(0, "Before"), span(3, ""),
            span(0, "\u00a0\u00a0First  ", poem), span(3, "", poem), span(3, "", poem),
            span(0, "  ", one), span(1, "Read target", one, "dog#Usage_notes", trail = "  ", bold = true), span(3, "", one),
            span(0, rtlText, two, direction = "ltr"), span(3, "", two),
            span(0, hebrew, one, direction = "rtl"), span(3, "", one),
            span(0, defaultHebrew, container, direction = "rtl"), span(3, "", container),
            span(0, defaultLatin, invalidDirection, direction = "ltr"), span(3, "", invalidDirection),
            span(1, "Tone.ogg", "$poem wikidict-media", "File:Tone.ogg"), span(3, "", poem))
        val spans = u32(values.size) + values.fold(byteArrayOf()) { bytes, value -> bytes + value }
        val block = byteArrayOf(0, 0, 0) + spans + byteArrayOf(0) + string("") + string("") + byteArrayOf(0)
        val media = u32(1) + string("Tone.ogg") + byteArrayOf(1) + string("Tone.ogg")
        return "DPR2".toByteArray() + u32(0) + u32(1) + byteArrayOf(3) + string("Noun") + u32(1) + block +
            u32(0) + u32(0) + u32(0) + u32(0) + media
    }

    private fun assertStartMargin(
        layout: TextLayoutResult, start: Int, end: Int, indent: Int,
        direction: ResolvedTextDirection, label: String,
    ) {
        val text = layout.layoutInput.text.text
        val fontPixels = with(layout.layoutInput.density) { layout.layoutInput.style.fontSize.toPx() }
        val margin = indent * fontPixels
        for (line in layout.getLineForOffset(start)..layout.getLineForOffset(end - 1)) {
            val lineEnd = layout.getLineEnd(line)
            val offsets = (maxOf(start, layout.getLineStart(line)) until minOf(end, lineEnd))
                .filter { !text[it].isWhitespace() && Character.getType(text[it]) != Character.FORMAT.toInt() }
            assertTrue("$label: no visible characters on visual line $line", offsets.isNotEmpty())
            // Compose's upstream line-end fallback uses scroll extents. This fixture's
            // wrap spaces and terminal isolates/newlines keep every visible glyph interior.
            assertTrue("$label: visible character reaches the line-edge metric on line $line: offsets=$offsets, end=$lineEnd",
                offsets.all { it + 1 < lineEnd })
            val boxes = offsets.map { layout.getBoundingBox(it) }
            val edge = if (direction == ResolvedTextDirection.Rtl) boxes.maxOf { it.right } else boxes.minOf { it.left }
            val boundary = if (direction == ResolvedTextDirection.Rtl) layout.size.width - margin else margin
            assertTrue("$label on visual line $line: edge=$edge, boundary=$boundary, margin=$margin, " +
                "width=${layout.size.width}, fontSize=${layout.layoutInput.style.fontSize}, fontPixels=$fontPixels, " +
                "density=${layout.layoutInput.density.density}, fontScale=${layout.layoutInput.density.fontScale}, " +
                "lineOffsets=${layout.getLineStart(line)}..$lineEnd, checkedOffsets=$offsets, boxes=$boxes",
                if (direction == ResolvedTextDirection.Rtl) edge <= boundary + 1f else edge >= boundary - 1f)
        }
    }

    @Test fun typedPoemKeepsWhitespaceWrappedIndentationLinksAndInlineMedia() {
        val entry = BlobDecoder.decode(fixture(), "Poem fixture", "language", "English", "en")
        assertEquals(listOf(Media("Tone.ogg", "audio", "Tone.ogg")), entry.media)
        val clicked = mutableListOf<String>()
        val containerDirection = mutableStateOf(LayoutDirection.Ltr)
        compose.runOnUiThread {
            compose.activity.setContent { MaterialTheme { CompositionLocalProvider(LocalLayoutDirection provides containerDirection.value) {
                Box(Modifier.width(240.dp)) {
                    EntryView(entry, false, {}, onLink = { clicked.add(it) },
                        settings = AppSettings(collapseOtherSections = false, allowImages = false, allowAudio = false))
                }
            } } }
        }
        compose.onNodeWithTag("entry-scroll").performScrollToNode(hasText(expected))
        val node = compose.onNodeWithText(expected, useUnmergedTree = true).assertIsDisplayed()
        val text = node.fetchSemanticsNode().config[SemanticsProperties.Text].single()
        assertEquals(expected, text.text)
        val layouts = mutableListOf<TextLayoutResult>()
        node.performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(layouts) }
        val layout = layouts.single()
        assertEquals(text, layout.layoutInput.text)
        assertFalse(layout.hasVisualOverflow)
        val rtlStart = expected.indexOf(rtlText)
        val rtlFirst = layout.getLineForOffset(rtlStart)
        val rtlLast = layout.getLineForOffset(rtlStart + rtlText.length - 1)
        assertTrue("The indented line must wrap in the bounded reader", rtlLast > rtlFirst)
        assertEquals(ResolvedTextDirection.Rtl, layout.getParagraphDirection(rtlStart))
        val hebrewStart = expected.indexOf(hebrew)
        assertEquals(ResolvedTextDirection.Ltr, layout.getParagraphDirection(hebrewStart))
        val defaultHebrewStart = expected.indexOf(defaultHebrew)
        val defaultLatinStart = expected.indexOf(defaultLatin)
        assertEquals(ResolvedTextDirection.Ltr, layout.getParagraphDirection(defaultHebrewStart))
        assertEquals(ResolvedTextDirection.Ltr, layout.getParagraphDirection(defaultLatinStart))
        assertStartMargin(layout, rtlStart, rtlStart + rtlText.length, 2, ResolvedTextDirection.Rtl,
            "RTL start margin")
        assertStartMargin(layout, hebrewStart, hebrewStart + hebrew.length, 1, ResolvedTextDirection.Ltr,
            "LTR start margin survives opposite lexical direction")
        assertStartMargin(layout, defaultHebrewStart, defaultHebrewStart + defaultHebrew.length, 1, ResolvedTextDirection.Ltr,
            "Absent direction uses the LTR container despite RTL lexical content")
        val rtlStyle = text.paragraphStyles.single { it.start <= rtlStart && it.end > rtlStart }
        assertEquals(2.em, rtlStyle.item.textIndent!!.firstLine)
        assertEquals(2.em, rtlStyle.item.textIndent!!.restLine)
        val link = text.getLinkAnnotations(0, text.length).single {
            (it.item as? LinkAnnotation.Clickable)?.tag == "dog#Usage_notes"
        }
        val linkStart = expected.indexOf("Read target")
        assertEquals(linkStart, link.start)
        assertEquals(linkStart + "Read target  ".length, link.end)
        assertTrue(text.spanStyles.any {
            it.start == link.start && it.end == link.end && it.item.fontWeight == FontWeight.Bold
        })
        compose.onAllNodesWithContentDescription("Play pronunciation").assertCountEquals(1)
        compose.onNodeWithContentDescription("Play pronunciation").assertIsNotEnabled()
        node.performTouchInput { click(layout.getBoundingBox(linkStart + 1).center) }
        compose.runOnIdle {
            assertEquals(listOf("dog#Usage_notes"), clicked)
            containerDirection.value = LayoutDirection.Rtl
        }
        // Reuse the same entry/spans so cached paragraph styles must follow the container.
        compose.onNodeWithTag("entry-scroll").performScrollToNode(hasText(expected))
        val rtlLayouts = mutableListOf<TextLayoutResult>()
        compose.onNodeWithText(expected, useUnmergedTree = true)
            .performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(rtlLayouts) }
        val containerRtl = rtlLayouts.single()
        assertEquals(expected, containerRtl.layoutInput.text.text)
        assertEquals(ResolvedTextDirection.Rtl, containerRtl.getParagraphDirection(defaultHebrewStart))
        assertEquals(ResolvedTextDirection.Rtl, containerRtl.getParagraphDirection(defaultLatinStart))
        assertEquals(ResolvedTextDirection.Ltr, containerRtl.getParagraphDirection(hebrewStart))
        assertEquals(ResolvedTextDirection.Rtl, containerRtl.getParagraphDirection(rtlStart))
        assertStartMargin(containerRtl, defaultLatinStart, defaultLatinStart + defaultLatin.length, 1, ResolvedTextDirection.Rtl,
            "Invalid direction uses the RTL container despite LTR lexical content")
        compose.onNodeWithTag("entry-scroll").performScrollToNode(hasText("Wiktionary contributors"))
        compose.onNodeWithText("Media").assertDoesNotExist()
        compose.onNodeWithText("Tone", useUnmergedTree = true).assertDoesNotExist()
    }
}
