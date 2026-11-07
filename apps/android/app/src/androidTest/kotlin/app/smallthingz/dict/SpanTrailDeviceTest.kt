package app.smallthingz.dict

import androidx.activity.compose.setContent
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.*
import androidx.compose.ui.text.ExperimentalTextApi
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Supported DPR2 field contract; synthetic presentation fixture, not a corpus loss claim. */
@OptIn(ExperimentalTextApi::class)
class SpanTrailDeviceTest {
    @get:Rule val compose = createLegacyPhysicalComposeRule()
    private fun show(spans: List<Span>) {
        val entry = Entry("Trail fixture", emptyList(), "language", "English", "en",
            listOf(Section(3, "Noun", listOf(Block("definition", 1, spans)))), emptyList())
        compose.runOnUiThread {
            compose.activity.setContent { MaterialTheme { EntryView(entry, false, {}, settings = AppSettings()) } }
        }
    }
    @Test fun linkedSuffixSharesTheActualRenderedAnnotation() {
        show(listOf(Span("link", "cat", target = "cat", trail = "s"), Span("text", "!")))
        val text = compose.onNodeWithText("cats!", useUnmergedTree = true)
            .fetchSemanticsNode().config[SemanticsProperties.Text].single()
        assertEquals("cats!", text.text)
        val links = text.getLinkAnnotations(3, 4)
        assertEquals(1, links.size)
        assertEquals("cat", (links.single().item as LinkAnnotation.Clickable).tag)
        assertEquals(0, links.single().start)
        assertEquals(4, links.single().end)
        assertTrue(text.getLinkAnnotations(4, 5).isEmpty())
    }
    @Test fun styledSuffixSharesStyleWithoutStylingFollowingPlainText() {
        show(listOf(Span("text", "code", trail = "d", bold = true, code = true, background = "#ffffe0"), Span("text", "!")))
        val text = compose.onNodeWithText("coded!", useUnmergedTree = true)
            .fetchSemanticsNode().config[SemanticsProperties.Text].single()
        assertEquals("coded!", text.text)
        val style = text.spanStyles.single { it.item.fontWeight == FontWeight.Bold }
        assertEquals(FontFamily.Monospace, style.item.fontFamily)
        assertEquals(0, style.start)
        assertEquals(5, style.end)
        assertFalse(text.spanStyles.any { it.start <= 5 && it.end > 5 })
        val painted = text.spanStyles.single { it.item.background == androidx.compose.ui.graphics.Color(0xffffffe0.toInt()) }
        assertEquals(0, painted.start)
        assertEquals(5, painted.end)
        show(listOf(Span("text", "a\nb", trail = "c", code = true, background = "#ffffe0")))
        val multiline = compose.onNodeWithText("a\nbc", useUnmergedTree = true)
            .fetchSemanticsNode().config[SemanticsProperties.Text].single()
        val paints = multiline.spanStyles.filter { it.item.background != androidx.compose.ui.graphics.Color.Unspecified }
        assertEquals(listOf(0 to 1, 2 to 4), paints.map { it.start to it.end })
        assertTrue(paints.all { it.item.background == androidx.compose.ui.graphics.Color(0xffffffe0.toInt()) })
    }
    @Test fun rtlSuffixRemainsInsideTheDirectionIsolate() {
        show(listOf(Span("link", "אב", target = "אב", trail = "ג", direction = "rtl"), Span("text", "!")))
        val expected = "\u2067אבג\u2069!"
        val text = compose.onNodeWithText(expected, useUnmergedTree = true)
            .fetchSemanticsNode().config[SemanticsProperties.Text].single()
        assertEquals(expected, text.text)
        assertEquals('ג', text.text[3])
        assertEquals('\u2069', text.text[4])
        val links = text.getLinkAnnotations(3, 4)
        assertEquals(1, links.size)
        assertEquals("אב", (links.single().item as LinkAnnotation.Clickable).tag)
        assertEquals(0, links.single().start)
        assertEquals(5, links.single().end)
        assertTrue(text.getLinkAnnotations(5, 6).isEmpty())
    }

    @Test fun automaticAndExplicitDirectionKeepTheCompleteLinkedSuffixIsolated() {
        val before = "LTR before "
        val after = " after"
        for ((direction, opener) in listOf(
            "auto" to "\u2068", "rtl" to "\u2067", "ltr" to "\u2066", "" to "", "unknown" to ""
        )) {
            show(listOf(Span("text", before), Span("link", "אב", target = "אב", trail = "ג", direction = direction), Span("text", after)))
            val isolated = opener + "אבג" + if (opener.isEmpty()) "" else "\u2069"
            val expected = before + isolated + after
            val text = compose.onNodeWithText(before, substring = true, useUnmergedTree = true)
                .fetchSemanticsNode().config[SemanticsProperties.Text].single()
            assertEquals("direction=$direction", expected, text.text)
            val link = text.getLinkAnnotations(0, text.length).single()
            assertEquals("direction=$direction", "אב", (link.item as LinkAnnotation.Clickable).tag)
            assertEquals("direction=$direction", before.length, link.start)
            assertEquals("direction=$direction", before.length + isolated.length, link.end)
            val trailOffset = before.length + opener.length + 2
            assertEquals("direction=$direction", 'ג', text.text[trailOffset])
            assertEquals(listOf(link), text.getLinkAnnotations(trailOffset, trailOffset + 1))
            assertTrue("direction=$direction", text.getLinkAnnotations(0, before.length).isEmpty())
            assertTrue("direction=$direction", text.getLinkAnnotations(link.end, text.length).isEmpty())
        }
    }

    @Test fun languageTagsStyleCompleteSpansAndLinkedTrailsWithoutChangingText() {
        val before = "plain before "
        val separator = " / "
        val plainLocalized = "abc"
        val after = " plain after"
        for ((language, expectedTag) in listOf(
            "ja" to "ja", "zh-Hant-TW" to "zh-Hant-TW", "de-DE-x-goethe" to "de-DE-x-goethe",
            "und" to "und", "und-Latn" to "und-Latn", "x-private" to "x-private",
            "" to null, "en_US" to null
        )) {
            show(listOf(
                Span("text", before),
                Span("link", "字", target = "語", trail = "形", language = language, direction = "auto", bold = true, italic = true),
                Span("text", separator),
                Span("text", plainLocalized, language = "sr-Latn-RS"),
                Span("text", after)
            ))
            val isolated = "\u2068字形\u2069"
            val expected = before + isolated + separator + plainLocalized + after
            val text = compose.onNodeWithText(before, substring = true, useUnmergedTree = true)
                .fetchSemanticsNode().config[SemanticsProperties.Text].single()
            assertEquals("language=$language", expected, text.text)
            val linkStart = before.length
            val linkEnd = linkStart + isolated.length
            val link = text.getLinkAnnotations(0, text.length).single()
            assertEquals("語", (link.item as LinkAnnotation.Clickable).tag)
            assertEquals(linkStart, link.start)
            assertEquals(linkEnd, link.end)
            assertEquals(listOf(link), text.getLinkAnnotations(linkStart + 2, linkStart + 3))
            assertTrue(text.getLinkAnnotations(0, linkStart).isEmpty())
            assertTrue(text.getLinkAnnotations(linkEnd, text.length).isEmpty())
            val linkedStyle = text.spanStyles.single { it.start == linkStart && it.end == linkEnd && it.item.fontWeight == FontWeight.Bold }
            assertEquals(androidx.compose.ui.text.font.FontStyle.Italic, linkedStyle.item.fontStyle)
            assertEquals("language=$language", expectedTag, linkedStyle.item.localeList?.get(0)?.toLanguageTag())
            val localStart = linkEnd + separator.length
            val localEnd = localStart + plainLocalized.length
            val localizedStyles = text.spanStyles.filter { it.item.localeList != null }
            assertEquals(if (expectedTag == null) 1 else 2, localizedStyles.size)
            val standaloneStyle = localizedStyles.single { it.start == localStart && it.end == localEnd }
            assertEquals("sr-Latn-RS", standaloneStyle.item.localeList!![0].toLanguageTag())
            assertNull(standaloneStyle.item.fontWeight)
            assertNull(standaloneStyle.item.fontStyle)
            assertTrue(localizedStyles.none { it.start < linkStart || it.end > localEnd })
            assertTrue(localizedStyles.none { it.start < localStart && it.end > linkEnd })
        }
    }

    @Test fun embeddedMediaCaptionKeepsStyleLinkAndPreformattedWhitespace() {
        val before = "  "
        val isolated = "\u2066字形\u2069"
        val after = "\n\n tail  "
        val spans = listOf(
            Span("text", before),
            Span("link", "字", target = "File:Cat.jpg", trail = "形", language = "ja", classes = "wikidict-media", direction = "ltr", bold = true, italic = true, code = true),
            Span("line_break", ""), Span("line_break", ""), Span("text", " tail  ")
        )
        val entry = Entry("Caption fixture", emptyList(), "language", "English", "en",
            listOf(Section(3, "Noun", listOf(Block("preformatted", 0, spans)))), emptyList(),
            media = listOf(Media("Cat.jpg", "image", "字形")))
        val clicked = mutableListOf<String>()
        compose.runOnUiThread {
            compose.activity.setContent { MaterialTheme {
                EntryView(entry, false, {}, onLink = { clicked.add(it.target) }, settings = AppSettings(collapseOtherSections = false, allowImages = false, allowAudio = false))
            } }
        }
        val node = compose.onNodeWithText(before + isolated + after, useUnmergedTree = true)
        val text = node.fetchSemanticsNode().config[SemanticsProperties.Text].single()
        assertEquals(before + isolated + after, text.text)
        compose.onAllNodesWithText("字形", useUnmergedTree = true).assertCountEquals(0)
        compose.onAllNodesWithContentDescription("Image source").assertCountEquals(1)
        val start = before.length
        val end = start + isolated.length
        val style = text.spanStyles.single { it.start == start && it.end == end && it.item.fontWeight == FontWeight.Bold }
        assertEquals(androidx.compose.ui.text.font.FontStyle.Italic, style.item.fontStyle)
        assertEquals(FontFamily.Monospace, style.item.fontFamily)
        assertEquals("ja", style.item.localeList!![0].toLanguageTag())
        assertFalse(text.spanStyles.any { it.start < start || it.end > end })
        val link = text.getLinkAnnotations(0, text.length).single()
        assertEquals("File:Cat.jpg", (link.item as LinkAnnotation.Clickable).tag)
        assertEquals(start, link.start)
        assertEquals(end, link.end)
        assertEquals(listOf(link), text.getLinkAnnotations(start + 2, start + 3))
        assertTrue(text.getLinkAnnotations(0, start).isEmpty())
        assertTrue(text.getLinkAnnotations(end, text.length).isEmpty())
        val layouts = mutableListOf<androidx.compose.ui.text.TextLayoutResult>()
        node.performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.GetTextLayoutResult) { it(layouts) }
        node.performTouchInput { click(layouts.single().getBoundingBox(start + 2).center) }
        compose.runOnIdle { assertEquals(listOf("File:Cat.jpg"), clicked) }
    }

}
