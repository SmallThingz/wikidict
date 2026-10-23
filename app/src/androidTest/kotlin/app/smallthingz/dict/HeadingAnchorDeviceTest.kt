package app.smallthingz.dict

import androidx.activity.compose.setContent
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.*
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.test.platform.app.InstrumentationRegistry
import androidx.compose.ui.text.TextLayoutResult
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Synthetic compiled presentation; actual library/alias integration remains separate. */
class HeadingAnchorDeviceTest {
    @get:Rule val compose = createLegacyPhysicalComposeRule()

    private fun touchLink(label: String) {
        val node = compose.onNodeWithText(label, useUnmergedTree = true)
        val layouts = mutableListOf<TextLayoutResult>()
        node.performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(layouts) }
        node.performTouchInput { click(layouts.single().getBoundingBox(1).center) }
    }

    @Test fun compiledDuplicateAndStandaloneIdsOpenTheirFoldsAndLocalMissStaysLocal() {
        val entry = Entry("Heading ID fixture", emptyList(), "language", "English", "en", listOf(
            Section(3, "Noun", listOf(
                Block("definition", 1, listOf(Span("link", "Read second noun", target = "#Noun_2"))),
                Block("definition", 1, listOf(Span("link", "Read authored reference heading", target = "#reference-1"))),
                Block("definition", 1, listOf(Span("link", "Read missing destination", target = "#Missing"))),
                Block("definition", 1, listOf(Span("link", "Read legacy heading", target = "#.C3.A4"))),
                Block("heading", 0, listOf(Span("text", "Authored reference heading")), level = 4, anchor = "reference-1"),
                Block("paragraph", 0, listOf(Span("text", "STANDALONE HEADING BODY"))),
            ), anchor = "Noun"),
            Section(3, "Noun", listOf(Block("paragraph", 0, listOf(Span("text", "SECOND NOUN BODY")))), anchor = "Noun_2"),
            Section(3, "\u00e4", listOf(Block("paragraph", 0, listOf(Span("text", "LEGACY HEADING BODY")))),
                anchor = "\u00e4", anchorFallback = ".C3.A4"),
            Section(3, ".C3.A4", listOf(Block("paragraph", 0, listOf(Span("text", "LITERAL ESCAPE HEADING BODY")))),
                anchor = ".C3.A4_2"),
        ), listOf(Reference(1, 1, "", listOf(Span("text", "SYNTHETIC REFERENCE BODY")))))
        val forwarded = mutableListOf<String>()
        val request = mutableStateOf<EntryAnchorRequest?>(null)
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent { MaterialTheme {
                EntryView(entry, false, {}, onLink = { forwarded.add(it) },
                    settings = AppSettings(collapseOtherSections = true, collapseDetails = true),
                    anchorRequest = request.value, onAnchorConsumed = { if (request.value === it) request.value = null })
            } } }
            compose.onNodeWithText("SECOND NOUN BODY").assertDoesNotExist()
            compose.onNodeWithText("Authored reference heading").assertDoesNotExist()
            touchLink("Read second noun")
            compose.onNodeWithText("SECOND NOUN BODY").assertIsDisplayed()
            compose.onNodeWithTag("entry-scroll").performScrollToNode(hasText("Read authored reference heading"))
            touchLink("Read authored reference heading")
            compose.onNodeWithText("Authored reference heading").assertIsDisplayed()
            compose.onNodeWithText("SYNTHETIC REFERENCE BODY").assertDoesNotExist()
            captureOwnedHeading("heading-anchor-standalone.png")
            compose.onNodeWithTag("entry-scroll").performScrollToNode(hasText("Read missing destination"))
            touchLink("Read missing destination")
            compose.runOnIdle { assertTrue(forwarded.isEmpty()) }
            compose.onNodeWithTag("entry-scroll").performScrollToNode(hasText("Read legacy heading"))
            touchLink("Read legacy heading")
            compose.onNodeWithText("LEGACY HEADING BODY").assertIsDisplayed()
            compose.onNodeWithText("LITERAL ESCAPE HEADING BODY").assertDoesNotExist()
            captureOwnedHeading("heading-anchor-unicode.png")
            // Cross-entry and alias commits supply this same distinct request interface.
            // This assertion covers the renderer interface, not their library lookup routes.
            compose.runOnIdle { request.value = EntryAnchorRequest(entry.key, "#Noun_2") }
            compose.onNodeWithText("SECOND NOUN BODY").assertIsDisplayed()
            compose.runOnIdle { assertNull(request.value) }
        } finally {
            compose.activityRule.scenario.onActivity { it.setContent {} }
        }
    }

    private fun captureOwnedHeading(name: String) {
        val body = when (name) {
            "heading-anchor-standalone.png" -> "STANDALONE HEADING BODY"
            "heading-anchor-unicode.png" -> "LEGACY HEADING BODY"
            else -> error("Unexpected heading evidence name")
        }
        compose.onNodeWithText(body).assertIsDisplayed()
        // Capture only the owned Compose fixture root after its public body assertions.
        val bitmap = compose.onRoot().captureToImage().asAndroidBitmap()
        try {
            val files = InstrumentationRegistry.getInstrumentation().targetContext.filesDir
            val directory = java.io.File(files, "qa-copy-evidence")
            check(directory.mkdirs() || directory.isDirectory)
            check(directory.canonicalFile.parentFile == files.canonicalFile)
            val target = java.io.File(directory, name)
            check(target.canonicalFile.parentFile == directory.canonicalFile && !target.exists())
            target.outputStream().use {
                check(bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it))
            }
        } finally { bitmap.recycle() }
    }
}
