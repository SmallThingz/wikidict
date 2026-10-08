package app.smallthingz.dict

import androidx.activity.compose.setContent
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.text.TextLayoutResult
import org.junit.Assert.assertTrue
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
}
