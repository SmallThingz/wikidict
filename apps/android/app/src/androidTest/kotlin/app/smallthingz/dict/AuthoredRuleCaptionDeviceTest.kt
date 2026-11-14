package app.smallthingz.dict

import android.os.SystemClock
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.accessibility.AccessibilityNodeInfo
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.width
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.*
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.view.accessibility.AccessibilityNodeInfoCompat
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import kotlin.math.ceil
import kotlin.math.floor

/** Source-only controls through the real caption/anonymous/native input owners; all UNRUN. */
class AuthoredRuleCaptionDeviceTest {
    @get:Rule val compose = createPhysicalComposeRule()
    private fun px(value: Float) = StyleLength(StyleLengthUnit.Px, value)
    private fun edges(top: Float = 0f, right: Float = 0f, bottom: Float = 0f, left: Float = 0f) =
        StyleEdges(px(top), px(right), px(bottom), px(left))
    private val style = TextStyle(fontSize = 16.sp, lineHeight = 20.sp, fontFamily = FontFamily.Monospace)
    private val context = AnonymousFlowContext(BidiResolvedDirection.Ltr, "sr", null)
    private fun paragraph(text: String, top: Float, bottom: Float) = Block("paragraph", 0,
        listOf(Span("link", text, text)), style = BlockStyle(margins = edges(top = top, bottom = bottom)))
    private fun rule(height: StyleLength, fill: ContainerColor = ContainerColor.Rgb("#e40000"),
        horizontal: Float = 2.25f) = Block("rule", 0, emptyList(), ruleStyle = RuleStyle(height, fill,
        edges(top = 11f, right = 3.5f, bottom = 13f, left = horizontal)))
    private fun sequence(rule: Block, first: String = "Alpha") =
        listOf(paragraph(first, 0f, 7f), rule, paragraph("Beta", 17f, 0f))
    private fun textTop(geometry: FloatTextGeometry, text: String): Float {
        val start = geometry.text.toString().indexOf(text)
        check(start >= 0)
        return geometry.rectsForRange(start, start + text.length).minOf { it.top }
    }
    private fun figure(blocks: List<Block>) = Figure(
        FigureContent.Missing(Span("text", "media"), px(120f), px(20f)),
        FigureFormat.Framed, FigurePlacement.None, FigureClear.None, edges(), edges(), edges(),
        1f, px(20f), FigureColor.Transparent, FigureBorder.None, FigureColor.Transparent, FigureBorder.None,
        FigureColor.NativeTheme, FigureColor.Transparent, captionBlocks = blocks)

    private fun nativeViews(): List<NativeFloatTextView> {
        val result = mutableListOf<NativeFloatTextView>()
        compose.activityRule.scenario.onActivity { activity ->
            fun visit(view: View) {
                if (view is NativeFloatTextView && view.isShown) result += view
                if (view is ViewGroup) for (index in 0 until view.childCount) visit(view.getChildAt(index))
            }
            visit(activity.window.decorView)
        }
        return result
    }

    @Test fun zeroHeightAdjoinsThroughWhileFractionalPositiveRuleKeepsPaintSelectionHitAndSeparatorAx() {
        val height = mutableStateOf(0f)
        val fill = mutableStateOf<ContainerColor>(ContainerColor.Rgb("#e40000"))
        val horizontal = mutableStateOf(2.25f)
        var observed: NativeAnonymousFlowGeometry? = null
        val clicks = mutableListOf<EntryLink>()
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                MaterialTheme { CompositionLocalProvider(LocalDensity provides Density(1f, 1f)) {
                    val source = figure(sequence(rule(px(height.value), fill.value, horizontal.value)))
                    AnonymousBlockView(Block("paragraph", 0, emptyList(), figure = source),
                        Modifier.width(160.dp).background(Color.White).testTag("authored-caption"),
                        { clicks += it }, emptyList(), AppSettings(allowImages = false, allowAudio = false), "sr",
                        inherited = context, style = style, onFlowGeometry = { observed = it })
                } }
            } }
            compose.waitForIdle()
            var zeroBeta = 0f
            var firstBaseline = 0f
            compose.runOnIdle {
                val actual = checkNotNull(observed)
                zeroBeta = textTop(actual, "Beta")
                firstBaseline = textTop(actual, "Alpha")
                assertEquals(0f, actual.nodes.single { it.kind == FloatInteractionKind.SEPARATOR }.bounds.single().height(), 0f)
                assertEquals(2, actual.nodes.count { it.onClick != null })
                height.value = .25f
            }
            compose.waitForIdle()
            compose.runOnIdle {
                val actual = checkNotNull(observed)
                assertEquals(firstBaseline, textTop(actual, "Alpha"), .001f)
                // max(7,11,13,17) becomes max(7,11)+.25+max(13,17).
                assertEquals(zeroBeta + 11.25f, textTop(actual, "Beta"), .001f)
                val separator = actual.nodes.single { it.kind == FloatInteractionKind.SEPARATOR }
                assertEquals(.25f, separator.bounds.single().height(), .001f)
                assertNull(separator.onClick)
                assertTrue(actual.rectsForRange(actual.text.toString().indexOf("Beta"), actual.text.length).isNotEmpty())
                height.value = 1.25f
            }
            compose.waitForIdle()
            val image = compose.onNodeWithTag("authored-caption").captureToImage().asAndroidBitmap()
            try {
                val bounds = checkNotNull(observed).nodes.single { it.kind == FloatInteractionKind.SEPARATOR }.bounds.single()
                val x = floor(bounds.centerX()).toInt()
                assertTrue((floor(bounds.top).toInt() until ceil(bounds.bottom).toInt()).any { y ->
                    val color = image.getPixel(x, y)
                    android.graphics.Color.red(color) > android.graphics.Color.green(color) + 30 &&
                        android.graphics.Color.red(color) > android.graphics.Color.blue(color) + 30
                })
            } finally { image.recycle() }
            val view = nativeViews().single()
            compose.runOnIdle {
                val actual = checkNotNull(observed)
                val separator = actual.nodes.single { it.kind == FloatInteractionKind.SEPARATOR }
                val frame = actual.figures.single().bounds
                assertEquals(frame.left + 2.25f, separator.bounds.single().left, .001f)
                assertEquals(frame.right - 3.5f, separator.bounds.single().right, .001f)
                val provider = checkNotNull(view.accessibilityNodeProvider)
                val ax = checkNotNull(provider.createAccessibilityNodeInfo(separator.id))
                assertEquals(NativeRuleAccessibilityLabel, AccessibilityNodeInfoCompat.wrap(ax).roleDescription.toString())
                assertTrue(ax.text.isNullOrEmpty())
                assertFalse(ax.isClickable)
                assertFalse(provider.performAction(separator.id, AccessibilityNodeInfo.ACTION_CLICK, null))
                val link = actual.nodes.single { it.onClick != null && it.label.toString() == "Beta" }
                val bounds = link.bounds.first()
                assertEquals(link.id, actual.interactionNodeAt(bounds.centerX(), bounds.centerY())?.id)
                val now = SystemClock.uptimeMillis()
                for (action in listOf(MotionEvent.ACTION_DOWN, MotionEvent.ACTION_UP)) {
                    val event = MotionEvent.obtain(now, SystemClock.uptimeMillis(), action,
                        bounds.centerX() + view.paddingLeft, bounds.centerY() + view.paddingTop, 0)
                    try { assertTrue(view.dispatchTouchEvent(event)) } finally { event.recycle() }
                }
                assertEquals(listOf(EntryLink("Beta")), clicks)
                assertTrue(provider.performAction(link.id, AccessibilityNodeInfo.ACTION_CLICK, null))
                assertEquals(listOf(EntryLink("Beta"), EntryLink("Beta")), clicks)
                fill.value = ContainerColor.Rgb("#0000e4")
            }
            compose.waitForIdle()
            // A same-size source paint change must invalidate the actual rule Canvas.
            val blue = compose.onNodeWithTag("authored-caption").captureToImage().asAndroidBitmap()
            try {
                val bounds = checkNotNull(observed).nodes.single { it.kind == FloatInteractionKind.SEPARATOR }.bounds.single()
                assertEquals(1.25f, bounds.height(), .001f)
                val x = floor(bounds.centerX()).toInt()
                assertTrue((floor(bounds.top).toInt() until ceil(bounds.bottom).toInt()).any { y ->
                    val color = blue.getPixel(x, y)
                    android.graphics.Color.blue(color) > android.graphics.Color.green(color) + 30 &&
                        android.graphics.Color.blue(color) > android.graphics.Color.red(color) + 30
                })
            } finally { blue.recycle() }
            compose.runOnIdle {
                fill.value = ContainerColor.Transparent
                horizontal.value = 200f
            }
            compose.waitForIdle()
            compose.runOnIdle {
                val actual = checkNotNull(observed)
                val separator = actual.nodes.single { it.kind == FloatInteractionKind.SEPARATOR }
                assertEquals(0f, separator.bounds.single().width(), 0f)
                assertEquals(1.25f, separator.bounds.single().height(), .001f)
                assertEquals(zeroBeta + 12.25f, textTop(actual, "Beta"), .001f)
            }
            compose.onAllNodesWithText("Unable to display this layout.").assertCountEquals(0)
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} } }
    }

    @Test fun implicitAndPaddingOnlyParagraphsRefuseWithoutLosingEitherOriginalActionThenRecover() {
        val mode = mutableStateOf(0)
        var observed: FloatTextGeometry? = null
        val clicks = mutableListOf<EntryLink>()
        val reader = FigureReaderContext(emptyList(), AppSettings(allowImages = false, allowAudio = false),
            "sr", { clicks += it }, Any())
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                MaterialTheme { CompositionLocalProvider(LocalDensity provides Density(1f, 1f)) {
                    val first = paragraph("Alpha", 0f, 7f).let { block -> when (mode.value) {
                        0 -> block.copy(style = null)
                        1 -> block.copy(style = BlockStyle(padding = edges(left = 2f)))
                        else -> block
                    } }
                    Box(Modifier.width(180.dp)) {
                        FigureCaptionBlocks(listOf(first, rule(px(.5f)), paragraph("Beta", 17f, 0f)),
                            context, style, reader, { observed = it })
                    }
                } }
            } }
            for (selected in listOf(0, 1)) {
                compose.runOnIdle { mode.value = selected }
                compose.waitForIdle()
                compose.onAllNodesWithText("Unable to display this layout.").assertCountEquals(1)
                compose.runOnIdle { assertNull(observed) }
                compose.onNodeWithText("Alpha").performTouchInput { click() }
                compose.onNodeWithText("Beta").performTouchInput { click() }
                compose.runOnIdle { assertEquals(List(selected + 1) { listOf(EntryLink("Alpha"), EntryLink("Beta")) }.flatten(), clicks) }
            }
            compose.runOnIdle { mode.value = 2 }
            compose.waitForIdle()
            compose.onAllNodesWithText("Unable to display this layout.").assertCountEquals(0)
            compose.runOnIdle {
                assertEquals("Alpha\nBeta", checkNotNull(observed).text.toString())
                assertEquals(2, checkNotNull(observed).nodes.count { it.onClick != null })
            }
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} } }
    }

    @Test fun equalConstraintRemeasureRetainsPublicationAndEmUsesNormalBodyOnceAcrossSourceReplacement() {
        val first = mutableStateOf("Alpha")
        val fontScale = mutableStateOf(1f)
        val maximumHeight = mutableStateOf(4000)
        val captionExclusions = StaticCaptionInput()
        var observed: FloatTextGeometry? = null
        var publications = 0
        val clicks = mutableListOf<EntryLink>()
        val reader = FigureReaderContext(emptyList(), AppSettings(allowImages = false, allowAudio = false), "sr", { clicks += it }, Any())
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                MaterialTheme(typography = Typography(bodyLarge = style.copy(fontSize = 20.sp))) {
                    CompositionLocalProvider(LocalDensity provides Density(1f, fontScale.value),
                        LocalStaticCaptionInput provides captionExclusions) {
                        val blocks = sequence(rule(StyleLength(StyleLengthUnit.Em, .025f)), first.value)
                        Layout(content = {
                            FigureCaptionBlocks(blocks, context, style.copy(fontSize = 9.sp), reader,
                                { observed = it; publications++ })
                        }) { children, _ ->
                            val child = children.single().measure(Constraints(minWidth = 180, maxWidth = 180,
                                maxHeight = maximumHeight.value))
                            layout(180, child.height) { child.place(0, 0) }
                        }
                    }
                }
            } }
            compose.waitForIdle()
            var used = 0f
            var previousPublications = 0
            compose.runOnIdle {
                val actual = checkNotNull(observed)
                used = actual.extents.usedHeight
                assertEquals(.5f, actual.nodes.single { it.kind == FloatInteractionKind.SEPARATOR }.bounds.single().height(), .001f)
                previousPublications = publications
                // Re-enter the real column with a changed outer constraint. Its body
                // children still receive the same fixedWidth180 constraint and may cache.
                maximumHeight.value = 3999
            }
            compose.waitForIdle()
            compose.runOnIdle {
                assertEquals(used, checkNotNull(observed).extents.usedHeight, .001f)
                assertEquals("Alpha\nBeta", checkNotNull(observed).text.toString())
                assertTrue(publications > previousPublications)
                first.value = "Gamma"
                fontScale.value = 1.5f
            }
            compose.waitForIdle()
            compose.onAllNodesWithText("Unable to display this layout.").assertCountEquals(0)
            compose.runOnIdle {
                val actual = checkNotNull(observed)
                assertEquals("Gamma\nBeta", actual.text.toString())
                assertEquals(.75f, actual.nodes.single { it.kind == FloatInteractionKind.SEPARATOR }.bounds.single().height(), .001f)
                assertEquals(2, actual.nodes.count { it.onClick != null })
                maximumHeight.value = actual.height - 1
            }
            compose.waitForIdle()
            compose.onAllNodesWithText("Unable to display this layout.").assertCountEquals(1)
            compose.runOnIdle { assertNull(observed) }
            // The aggregate failed after measuring real children; local paint-free owners
            // keep their original callbacks usable without a second body composition.
            val retained = nativeViews()
            compose.runOnIdle {
                for (text in listOf("Gamma", "Beta")) {
                    val view = retained.single { candidate ->
                        candidate.accessibilityNodeProvider?.createAccessibilityNodeInfo(0)?.text?.toString() == text
                    }
                    assertTrue(checkNotNull(view.accessibilityNodeProvider).performAction(0,
                        AccessibilityNodeInfo.ACTION_CLICK, null))
                }
                assertEquals(listOf(EntryLink("Gamma"), EntryLink("Beta")), clicks)
                maximumHeight.value = Constraints.Infinity
            }
            compose.waitForIdle()
            compose.onAllNodesWithText("Unable to display this layout.").assertCountEquals(0)
            compose.runOnIdle {
                val actual = checkNotNull(observed)
                assertEquals("Gamma\nBeta", actual.text.toString())
                val separator = actual.nodes.single { it.kind == FloatInteractionKind.SEPARATOR }.bounds.single()
                captionExclusions.update(listOf(NativeFloatExclusion(TableFloatSide.Left,
                    NativeFloatBounds(0f, separator.top, 180f, separator.bottom))))
            }
            compose.waitForIdle()
            compose.onAllNodesWithText("Unable to display this layout.").assertCountEquals(1)
            compose.runOnIdle { assertNull(observed); captionExclusions.update(emptyList()) }
            compose.waitForIdle()
            compose.onAllNodesWithText("Unable to display this layout.").assertCountEquals(0)
            compose.runOnIdle { assertEquals("Gamma\nBeta", checkNotNull(observed).text.toString()) }
            assertTrue(nativeViews().isEmpty())
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} } }
    }
}
