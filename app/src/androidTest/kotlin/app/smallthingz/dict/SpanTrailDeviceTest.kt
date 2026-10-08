package app.smallthingz.dict

import androidx.activity.compose.setContent
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
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
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()
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
        show(listOf(Span("text", "code", trail = "d", bold = true, code = true), Span("text", "!")))
        val text = compose.onNodeWithText("coded!", useUnmergedTree = true)
            .fetchSemanticsNode().config[SemanticsProperties.Text].single()
        assertEquals("coded!", text.text)
        val style = text.spanStyles.single { it.item.fontWeight == FontWeight.Bold }
        assertEquals(FontFamily.Monospace, style.item.fontFamily)
        assertEquals(0, style.start)
        assertEquals(5, style.end)
        assertFalse(text.spanStyles.any { it.start <= 5 && it.end > 5 })
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

}
