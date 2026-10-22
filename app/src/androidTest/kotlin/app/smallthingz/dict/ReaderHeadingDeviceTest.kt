package app.smallthingz.dict

import androidx.activity.compose.setContent
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.*
import org.junit.Rule
import org.junit.Test

/** Synthetic compiled presentation shapes; no corpus or TalkBack run is claimed. */
class ReaderHeadingDeviceTest {
    @get:Rule val compose = createLegacyPhysicalComposeRule()

    @Test fun ordinarySectionAndSupportingHeadingsExposeHeadingNavigationAndKeepFolds() {
        val entry = Entry("Heading accessibility fixture", emptyList(), "language", "English", "en",
            listOf(
                Section(3, "Noun", listOf(Block("definition", 1, listOf(Span("text", "Dictionary meaning"))))),
                Section(3, "Usage notes", listOf(Block("paragraph", 0, listOf(Span("text", "Ordinary usage body"))))),
            ),
            listOf(Reference(1, 1, "", listOf(Span("text", "Supporting reference")))),
            preamble = listOf(Span("text", "Compiled preamble")),
            media = listOf(Media("Heading-fixture.jpg", "image", "Supporting image")),
        )
        try {
            compose.activityRule.scenario.onActivity { activity ->
                activity.setContent { MaterialTheme {
                    EntryView(entry, false, {}, settings = AppSettings(collapseOtherSections = true,
                        allowImages = false, allowAudio = false))
                } }
            }
            for (label in listOf("About this entry", "Noun", "Usage notes", "References", "Media")) {
                compose.onNodeWithTag("entry-scroll").performScrollToNode(hasText(label))
                // The merged accessible control must expose both its heading and fold action.
                compose.onNodeWithText(label)
                    .assert(SemanticsMatcher.keyIsDefined(SemanticsProperties.Heading))
                    .assertHasClickAction()
                    .assertIsDisplayed()
            }
            compose.onNodeWithTag("entry-scroll").performScrollToNode(hasText("Usage notes"))
            compose.onNodeWithText("Ordinary usage body").assertDoesNotExist()
            compose.onNodeWithText("Usage notes").performTouchInput { click(center) }
            compose.onNodeWithText("Ordinary usage body").assertIsDisplayed()
            compose.onNodeWithText("Usage notes")
                .assert(SemanticsMatcher.keyIsDefined(SemanticsProperties.Heading))
                .performTouchInput { click(center) }
            compose.onNodeWithText("Ordinary usage body").assertDoesNotExist()
        } finally {
            compose.activityRule.scenario.onActivity { it.setContent {} }
        }
    }
}
