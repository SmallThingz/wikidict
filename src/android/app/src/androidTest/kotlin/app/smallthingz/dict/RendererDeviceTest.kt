package app.smallthingz.dict

import android.content.Intent
import android.content.pm.ActivityInfo
import android.net.Uri
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.text.style.BaselineShift
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import java.io.File

class RendererDeviceTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()

    @Before fun openBlobExport() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val file = File(instrumentation.targetContext.filesDir, "renderer-fixture.json")
        instrumentation.context.assets.open("renderer-fixture.json").use { input -> file.outputStream().use { input.copyTo(it) } }
        compose.activityRule.scenario.onActivity { activity ->
            val launchIntent = activity.intent
            instrumentation.callActivityOnNewIntent(activity, Intent(Intent.ACTION_VIEW, Uri.fromFile(file), activity, MainActivity::class.java))
            // ActivityScenario matches lifecycle events using the original launch intent.
            activity.intent = launchIntent
        }
        compose.waitUntil(10000) { compose.onAllNodesWithText("PREAMBLE: compiled presentation.").fetchSemanticsNodes().isNotEmpty() }
    }

    @Test fun compiledFeaturesRemainVisibleAndTablesRespectSpans() {
        compose.activityRule.scenario.onActivity { assertNull("Compose owns the only toolbar", it.actionBar) }
        val scroll = compose.onNodeWithTag("entry-scroll")
        scroll.performScrollToNode(hasText("After line break", substring = true))
        val styled = compose.onNodeWithText("After line break", substring = true).fetchSemanticsNode().config[SemanticsProperties.Text].first()
        assertTrue(styled.text.contains("\nAfter line break"))
        assertTrue(styled.spanStyles.any { it.item.baselineShift == BaselineShift.Superscript })
        assertTrue(styled.spanStyles.any { it.item.baselineShift == BaselineShift.Subscript })
        scroll.performScrollToNode(hasText("column A  column B", substring = true))
        compose.onNodeWithText("column A  column B\n  indented\tvalue").assertIsDisplayed()
        scroll.performScrollToNode(hasText("Inflection table"))
        compose.onNodeWithText("Case").assertIsDisplayed()
        // The rowspan keeps the next row's first cell out of column zero.
        val case = compose.onNodeWithText("Case").fetchSemanticsNode().boundsInRoot
        val singular = compose.onNodeWithText("Singular").fetchSemanticsNode().boundsInRoot
        assertTrue(singular.left > case.left)
        scroll.performScrollToNode(hasText("Reference content."))
        compose.onNodeWithText("Reference content.").assertIsDisplayed()
        scroll.performScrollToNode(hasText("Example pronunciation.ogg"))
        compose.onNodeWithText("Example pronunciation.ogg").assertIsDisplayed()
    }

    @Test fun searchThemeNavigationAndRecreationStayUsable() {
        compose.onNodeWithContentDescription("Dictionary").performClick()
        compose.onNode(hasSetTextAction()).performTextInput("not-in-dictionary")
        compose.onNodeWithText("No matching words in this dictionary.").assertIsDisplayed()
        compose.onNode(hasSetTextAction()).performTextClearance()
        compose.onNodeWithContentDescription("Close search").performClick()
        compose.onNodeWithContentDescription("Settings").performClick()
        compose.onNodeWithText("Dark").performClick()
        compose.onNodeWithText("Light").performClick()
        compose.onNodeWithContentDescription("Dictionary").performClick()
        compose.activityRule.scenario.recreate()
        compose.waitUntil(10000) { compose.onAllNodesWithText("PREAMBLE: compiled presentation.").fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithText("PREAMBLE: compiled presentation.").assertIsDisplayed()
        compose.activityRule.scenario.onActivity { it.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE }
        // Wait for configuration, not Espresso idleness across two activity instances.
        compose.waitUntil(10000) { compose.activity.resources.configuration.orientation == android.content.res.Configuration.ORIENTATION_LANDSCAPE }
        compose.activityRule.scenario.onActivity { it.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_PORTRAIT }
        compose.waitUntil(10000) { compose.activity.resources.configuration.orientation == android.content.res.Configuration.ORIENTATION_PORTRAIT }
        compose.onNodeWithTag("entry-scroll").assertExists()
    }

    @Test fun realCorpusBlobExportRenders() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        org.junit.Assume.assumeTrue(instrumentation.context.assets.list("")!!.contains("corpus-fixture.json"))
        val file = File(instrumentation.targetContext.filesDir, "corpus-fixture.json")
        instrumentation.context.assets.open("corpus-fixture.json").use { input -> file.outputStream().use { input.copyTo(it) } }
        val expected = ExportDocument.decode(file.readBytes()).entries.single()
        assertEquals("cat", expected.title)
        compose.activityRule.scenario.onActivity { activity ->
            val launchIntent = activity.intent
            instrumentation.callActivityOnNewIntent(activity, Intent(Intent.ACTION_VIEW, Uri.fromFile(file), activity, MainActivity::class.java))
            activity.intent = launchIntent
        }
        compose.waitUntil(10000) { compose.onAllNodesWithTag("entry-scroll").fetchSemanticsNodes().isNotEmpty() && compose.onAllNodesWithText("PREAMBLE: compiled presentation.").fetchSemanticsNodes().isEmpty() }
        compose.onNodeWithTag("entry-scroll").assertExists()
        compose.onAllNodesWithText("cat", useUnmergedTree = true).onFirst().assertExists()
        val screen = compose.onRoot().fetchSemanticsNode().boundsInRoot
        val reading = compose.onNodeWithTag("entry-scroll").fetchSemanticsNode().boundsInRoot
        assertTrue("Reading gets at least 85% of window height", reading.height / screen.height > 0.85f)
        compose.onNodeWithContentDescription("Sections").performClick()
        compose.onAllNodesWithText("Derived terms").onFirst().performScrollTo().performClick()
        compose.waitForIdle()
        compose.onNodeWithTag("entry-scroll").performScrollToNode(hasText("• a cat can look at a king", substring = true))
        assertTrue("Dense lists must have bounded text layouts", compose.onAllNodes(hasText("a cat can look at a king", substring = true)).fetchSemanticsNodes().all { node ->
            node.config[SemanticsProperties.Text].sumOf { it.text.length } < 500
        })
    }

    @Test fun parserRejectsDeferredInputsAndKeepsAllSemanticData() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val bytes = instrumentation.context.assets.open("renderer-fixture.json").use { it.readBytes() }
        val entry = ExportDocument.decode(bytes).entries.single()
        assertFalse(entry.preamble.isEmpty())
        assertEquals(2, entry.media.size)
        assertTrue(entry.sections.flatMap { it.blocks }.any { it.table != null })
        assertThrows(IllegalArgumentException::class.java) { ResultParser.parse("""{"schema":"dict.results.v1","source":"raw","entries":[]}""") }
    }
}
