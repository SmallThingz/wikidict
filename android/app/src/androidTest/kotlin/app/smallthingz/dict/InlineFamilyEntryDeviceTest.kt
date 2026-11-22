package app.smallthingz.dict

import android.graphics.Typeface
import android.os.Bundle
import android.os.SystemClock
import android.view.MotionEvent
import android.view.View
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.*
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** Typed synthetic API05 data through the real StyledText and Entry owners; all font presence is injected. */
@RunWith(AndroidJUnit4::class)
class InlineFamilyEntryDeviceTest {
    @get:Rule val compose = createPhysicalComposeRule()
    private val settings = AppSettings(allowImages = false, allowAudio = false,
        collapseOtherSections = true, collapseDetails = false)
    private fun px(value: Float) = StyleLength(StyleLengthUnit.Px, value)
    private fun edges() = StyleEdges(px(0f), px(0f), px(0f), px(0f))
    private fun views(): List<NativeFloatTextView> {
        val result = mutableListOf<NativeFloatTextView>()
        compose.activityRule.scenario.onActivity { activity ->
            fun collect(view: View) {
                if (view is NativeFloatTextView) result += view
                if (view is android.view.ViewGroup) for (index in 0 until view.childCount) collect(view.getChildAt(index))
            }
            collect(activity.window.decorView)
        }
        return result
    }
    private fun textOwner(text: String) = views().single { it.logicalText.toString() == text }
    private fun tap(view: NativeFloatTextView, label: String) {
        compose.runOnIdle {
            val geometry = checkNotNull(view.currentMeasuredGeometry)
            val node = geometry.nodes.single { it.kind == FloatInteractionKind.LINK && it.label == label }
            val box = node.bounds.single()
            assertEquals(node.id, geometry.interactionNodeAt(box.centerX(), box.centerY())?.id)
            val now = SystemClock.uptimeMillis()
            val down = MotionEvent.obtain(now, now, MotionEvent.ACTION_DOWN, box.centerX(), box.centerY(), 0)
            val up = MotionEvent.obtain(now, now + 1, MotionEvent.ACTION_UP, box.centerX(), box.centerY(), 0)
            try { view.dispatchTouchEvent(down); view.dispatchTouchEvent(up) }
            finally { down.recycle(); up.recycle() }
        }
        compose.waitForIdle()
    }
    private fun tapRetained(label: String) {
        val native = views().filter { it.currentMeasuredGeometry?.nodes?.any { node ->
            node.kind == FloatInteractionKind.LINK && node.label == label
        } == true }
        if (native.isNotEmpty()) tap(native.single(), label) else {
            val node = compose.onNodeWithText(label, substring = true, useUnmergedTree = true)
            val layouts = mutableListOf<TextLayoutResult>()
            node.performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(layouts) }
            val layout = layouts.single()
            val offset = layout.layoutInput.text.text.indexOf(label).also { check(it >= 0) }
            node.performTouchInput { click(layout.getBoundingBox(offset).center) }
        }
    }
    private fun keyboardMenu(label: String) {
        compose.onNodeWithContentDescription("Sections").performClick()
        val item = compose.onNode(hasText(label) and hasAnyAncestor(isPopup()))
        item.performSemanticsAction(SemanticsActions.RequestFocus) { assertTrue(it()) }
        item.assertIsFocused().performKeyInput { pressKey(androidx.compose.ui.input.key.Key.Enter) }
        compose.waitForIdle()
    }
    private fun copied(view: NativeFloatTextView, expected: String) {
        compose.runOnIdle {
            assertEquals(expected, view.logicalText.toString())
            view.setSelection(0, view.logicalText.length)
            assertEquals(expected, view.selectedTextForCopy())
            view.setSelection(0, 0)
        }
    }
    private fun control(name: String, body: () -> Unit) {
        try { body() }
        catch (failure: Throwable) {
            runCatching {
                val root = compose.onNodeWithTag("inline-family-root")
                val report = renderedLayoutFailureEvidence(name, null, null, root, name, root.captureToImage().asAndroidBitmap())
                InstrumentationRegistry.getInstrumentation().sendStatus(0, Bundle().apply {
                    putString(android.app.Instrumentation.REPORT_KEY_STREAMRESULT, "\n$report\n")
                })
            }
            throw failure
        } finally {
            compose.activityRule.scenario.onActivity { it.setContent {} }
            compose.waitForIdle()
        }
    }

    @Test fun standaloneFamilyKeepsNullNeighboursTrailsAndActionsAcrossPresenceFailureAndRecovery() =
        control("inline-family-source-recovery.png") {
            val state = mutableStateOf(0)
            val actions = mutableListOf<EntryLink>()
            val queries = mutableListOf<Pair<String, FontWeight>>()
            val failures = mutableListOf<String>()
            val expected = "  chosen  \u00a0  "
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                val phase = state.value
                val family = ContainerFontFamily.Stack(listOf(if (phase == 2) "Absent B" else "Absent A"), GenericFontFamily.Serif)
                val spans = listOf(Span("text", "  "), Span("link", "chosen", "chosen-target", trail = "  ",
                    code = true, bold = true, fontFamily = family), Span("text", "\u00a0  "))
                MaterialTheme {
                    CompositionLocalProvider(LocalDensity provides Density(1.25f, 1.1f),
                        LocalNativeNamedFontProbe provides NativeNamedFontProbe { _, name, weight, _ ->
                            queries += name to weight
                            if (phase == 1) Typeface.SERIF else null
                        }, LocalNativeFloatContextFailureObserver provides { failures += it }) {
                        Box(Modifier.size(300.dp, 180.dp).background(Color.White).testTag("inline-family-root")) {
                            StyledText(spans, style = MaterialTheme.typography.bodyLarge.copy(fontSize = 20.sp),
                                onLink = { actions += it })
                        }
                    }
                }
            } }
            compose.waitForIdle()
            copied(textOwner(expected), expected)
            assertTrue(queries.any { it.first == "Absent A" && it.second == FontWeight.Bold })
            tap(textOwner(expected), "chosen  ")
            compose.runOnIdle { state.value = 1 }
            compose.waitForIdle()
            compose.onNodeWithText("Unable to display this layout.").assertIsDisplayed()
            assertTrue(failures.contains(NativeNamedFamilyUnavailable))
            tapRetained("chosen")
            compose.runOnIdle { queries.clear(); state.value = 2 }
            compose.waitForIdle()
            compose.onAllNodesWithText("Unable to display this layout.").assertCountEquals(0)
            copied(textOwner(expected), expected)
            assertTrue(queries.any { it.first == "Absent B" })
            assertFalse(queries.any { it.first == "Absent A" })
            tap(textOwner(expected), "chosen  ")
            assertEquals(listOf("chosen-target", "chosen-target", "chosen-target"), actions.map { it.target })
        }

    @Test fun explicitFamilyReplacementRefusalKeepsTheOriginalOwnerAndRecoversWithoutTextMutation() =
        control("inline-family-egyptian-refusal.png") {
            val replacement = mutableStateOf(true)
            val actions = mutableListOf<EntryLink>()
            val failures = mutableListOf<String>()
            val expected = "  \ud80c\udc00 action  "
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                val spans = listOf(Span("text", "  "), Span("text", "\ud80c\udc00",
                    classes = if (replacement.value) "Egyp" else "", fontFamily = ContainerFontFamily.SansSerif),
                    Span("link", " action", "kept", trail = "  "))
                MaterialTheme {
                    CompositionLocalProvider(LocalNativeFloatContextFailureObserver provides { failures += it }) {
                        Box(Modifier.size(300.dp, 180.dp).testTag("inline-family-root")) {
                            StyledText(spans, onLink = { actions += it })
                        }
                    }
                }
            } }
            compose.waitForIdle()
            compose.onNodeWithText("Unable to display this layout.").assertIsDisplayed()
            assertTrue(failures.contains(NativeInlineFamilyReplacementUnavailable))
            tapRetained("action")
            compose.runOnIdle { replacement.value = false }
            compose.waitForIdle()
            copied(textOwner(expected), expected)
            compose.onAllNodesWithText("Unable to display this layout.").assertCountEquals(0)
            tap(textOwner(expected), " action  ")
            assertEquals(listOf("kept", "kept"), actions.map { it.target })
        }

    @Test fun headingOnlyPrefixSharesFirstRealBlockAndWhitespaceTitleFoldsThroughTheKeyboardMenu() =
        control("inline-family-heading-prefix.png") {
            val actions = mutableListOf<EntryLink>()
            val failures = mutableListOf<String>()
            val ordinary = mutableStateOf(false)
            val reading = EntryReadingState()
            val prefix = Block("paragraph", 0, listOf(Span("link", "prefix", "prefix")), style = BlockStyle(margins = edges()))
            val float = Block("table", 0, emptyList(), table = Table(emptyList(),
                listOf(listOf(Cell(listOf(Span("text", "float")), false, 1, 1, style = CellStyle(padding = edges())))),
                style = TableStyle(floatSide = TableFloatSide.Left, width = StyleWidth(StyleWidthUnit.Px, 60f), margins = edges())))
            val box = ContainerStyle(margins = edges(), padding = edges(), border = ContainerBorder.None,
                ownerFontScale = 1f, lineHeight = ContainerLineHeight.Length(px(20f)), clear = FigureClear.Both,
                fontFamily = ContainerFontFamily.SansSerif)
            val style = SectionHeadingStyle(box, InlineFontSnapshot(fontScale = 1f,
                fontScaleBasis = FontScaleBasis.NormalBody, language = "th"), BidiResolvedDirection.Ltr)
            val title = Section(2, " ", listOf(Block("heading", 0, listOf(Span("text", " ")), level = 2),
                Block("paragraph", 0, listOf(Span("link", "body", "body")), style = BlockStyle(margins = edges()))),
                headingStyle = style)
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                MaterialTheme {
                    CompositionLocalProvider(LocalNativeFloatContextFailureObserver provides { failures += it }) {
                        Box(Modifier.size(320.dp, 560.dp).testTag("inline-family-root")) {
                            EntryView(Entry("Prefix control", emptyList(), "language", "Japanese", "ja",
                                listOf(Section(0, "", listOf(prefix, float)), title), emptyList(),
                                bodyAdjoining = if (ordinary.value) BodyAdjoiningPolicy.Ordinary else null),
                                false, {}, settings = settings, readingState = reading, onLink = { actions += it })
                        }
                    }
                }
            } }
            compose.waitForIdle()
            fun owner() = views().single { view -> view.currentMeasuredGeometry?.nodes?.any {
                it.kind == FloatInteractionKind.HEADING && it.label == " "
            } == true }
            copied(owner(), "prefix\n\ufffc\n ")
            assertFalse(owner().logicalText.contains("body"))
            keyboardMenu("Expand  ")
            copied(owner(), "prefix\n\ufffc\n \nbody")
            tap(owner(), "prefix"); tap(owner(), "body")
            keyboardMenu("Collapse  ")
            copied(owner(), "prefix\n\ufffc\n ")
            keyboardMenu("Expand  ")
            compose.runOnIdle { ordinary.value = true }
            compose.waitForIdle()
            copied(owner(), "prefix\n\ufffc\n \nbody")
            assertTrue(failures.isEmpty())
            assertEquals(listOf("prefix", "body"), actions.map { it.target })
        }
}
