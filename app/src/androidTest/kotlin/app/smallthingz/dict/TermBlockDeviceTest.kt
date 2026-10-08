package app.smallthingz.dict

import androidx.activity.compose.setContent
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.text.ExperimentalTextApi
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Existing compiler fixture, copied byte-for-byte from test/resources (SHA-256 8e0d146b...). */
@OptIn(ExperimentalTextApi::class)
class TermBlockDeviceTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()
    private fun fixtureBlocks(): List<Block> {
        val bytes = InstrumentationRegistry.getInstrumentation().context.assets
            .open("grammar-fixture-v2.dpr2").use { it.readBytes() }
        return BlobDecoder.decode(bytes, "Grammar fixture_猫", "language", "English", "en")
            .sections.flatMap { it.blocks }
    }
    private fun show(blocks: List<Block>, onLink: (String) -> Unit = {}) {
        val entry = Entry("Term fixture", emptyList(), "language", "English", "en",
            listOf(Section(3, "Grammar terms", blocks)), emptyList())
        compose.runOnUiThread {
            compose.activity.setContent {
                MaterialTheme {
                    EntryView(entry, false, {}, onLink = onLink,
                        settings = AppSettings(collapseOtherSections = false))
                }
            }
        }
    }
    @Test fun compiledTermLabelsAreBoldAndNestedLinksStayClickable() {
        val blocks = fixtureBlocks()
        val plain = blocks.single { it.kind == "term" && textOf(it.spans) == "HTML term" }
        val linked = blocks.single { it.kind == "term" && it.listPath == "*;" }
        assertTrue((plain.spans + linked.spans).all { !it.bold })
        var clicked: String? = null
        show(listOf(plain, linked)) { clicked = it }
        for (label in listOf("HTML term", "Nested term")) {
            val text = compose.onNodeWithText(label, useUnmergedTree = true)
                .fetchSemanticsNode().config[SemanticsProperties.Text].single()
            assertTrue(text.spanStyles.any {
                it.start == 0 && it.end == label.length && it.item.fontWeight == FontWeight.Bold
            })
        }
        val node = compose.onNodeWithText("Nested term", useUnmergedTree = true)
        val text = node.fetchSemanticsNode().config[SemanticsProperties.Text].single()
        assertEquals("HTTP:term", (text.getLinkAnnotations(0, text.length).single().item as LinkAnnotation.Clickable).tag)
        val layouts = mutableListOf<TextLayoutResult>()
        node.performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(layouts) }
        val linkedGlyph = layouts.single().getBoundingBox(1).center
        node.performTouchInput { click(linkedGlyph) }
        compose.runOnIdle { assertEquals("HTTP:term", clicked) }
    }
    @Test fun inheritedTermWeightKeepsInlineStyleAndDoesNotBoldTheDescription() {
        val blocks = fixtureBlocks()
        // Add one supported italic style to the retained linked term, retaining bold=false.
        val linked = blocks.single { it.kind == "term" && it.listPath == "*;" }
            .let { it.copy(spans = it.spans.map { span -> span.copy(italic = true) }) }
        val detail = blocks.single { it.kind == "list_detail" && it.listPath == "*:" }
        assertTrue(linked.spans.all { !it.bold && it.italic })
        show(listOf(linked, detail))
        val term = compose.onNodeWithText("Nested term", useUnmergedTree = true)
            .fetchSemanticsNode().config[SemanticsProperties.Text].single()
        assertTrue(term.spanStyles.any {
            it.start == 0 && it.end == term.length &&
                it.item.fontWeight == FontWeight.Bold && it.item.fontStyle == FontStyle.Italic
        })
        assertEquals("HTTP:term", (term.getLinkAnnotations(0, term.length).single().item as LinkAnnotation.Clickable).tag)
        val description = compose.onNodeWithText("nested descriptor", useUnmergedTree = true)
            .fetchSemanticsNode().config[SemanticsProperties.Text].single()
        assertFalse(description.spanStyles.any { it.item.fontWeight == FontWeight.Bold })
    }
}
