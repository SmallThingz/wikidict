package app.smallthingz.dict

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.Typeface
import android.os.Bundle
import android.text.SpannableString
import android.text.Spanned
import android.text.TextPaint
import android.view.View
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityNodeProvider
import androidx.activity.compose.setContent
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.sp
import androidx.test.ext.junit.runners.AndroidJUnit4
import kotlin.math.ceil
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** Actual source lowering and native View controls; no genuine-page or attached-window claim. */
@RunWith(AndroidJUnit4::class)
class NativeInlineBoxNbspDeviceTest {
    @get:Rule val compose = createPhysicalComposeRule()
    private val body = "\u00a0\u00a0\u00a0\u00a0"
    private val title = "Controlled swatch title"

    private fun owner(text: String = body, linked: Boolean = false): Span {
        val zero = StyleLength(StyleLengthUnit.Px, 0f)
        val edge = InlineBoxBorderEdge.Solid(StyleLength(StyleLengthUnit.Px, 1f), InlineBoxColor.Rgb("#000000"))
        return Span(if (linked) "link" else "text", "", if (linked) "original-target" else "",
            tooltip = title, background = "#cc2244", inlineBoxGroup = InlineBoxGroup(
                StyleEdges(zero, zero, zero, zero), InlineBoxBorderEdges(edge, edge, edge, edge),
                spans = listOf(Span("text", text))))
    }

    @Test fun fourNbspShapeMinWidthFontBandCopyAdviceAndOneOriginalLinkSurviveReflow() {
        val density = 1.25f
        val zoom = 1.2f
        val plain = owner()
        val linked = owner(linked = true)
        val current = mutableStateOf(plain)
        val calls = mutableListOf<EntryLink>()
        var prepared: PreparedNativeFloatText? = null
        var primary: Throwable? = null
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                MaterialTheme(typography = Typography(bodyLarge = TextStyle(fontSize = 24.sp))) {
                    CompositionLocalProvider(LocalDensity provides Density(density, zoom)) {
                        val spans = listOf(current.value)
                        val style = TextStyle(fontSize = 24.sp, fontFamily = FontFamily.Monospace)
                        val annotation = styledTextAnnotation(spans, null, style) { calls += it }
                        val value = prepareNativeFloatText(spans, annotation, egyptianTextRuns(spans), style,
                            MaterialTheme.colorScheme.primary, emptyList(), AppSettings(), "", { calls += it },
                            nativeLineHeight = NativeLineHeightPolicy.Normal, ownerDirection = BidiResolvedDirection.Ltr)
                        SideEffect { prepared = value }
                    }
                }
            } }
            val reference = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
                typeface = Typeface.MONOSPACE
                textSize = 24f * density * zoom
            }
            val advance = reference.measureText(body)
            val ink = Rect().also { reference.getTextBounds(body, 0, body.length, it) }
            assertTrue(advance > 0f)
            assertTrue("NBSP has advance without glyph ink", ink.isEmpty)
            val expectedWidth = advance + 2f * density
            val fitWidth = ceil(expectedWidth).toInt()
            for ((selected, width) in listOf(plain to 300, plain to fitWidth, linked to 300, plain to 300)) {
                compose.runOnIdle { current.value = selected }
                compose.waitForIdle()
                compose.runOnIdle {
                    val value = checkNotNull(prepared)
                    assertNull(value.stateDescription)
                    assertFalse(value.emptyInlineOwner)
                    assertEquals(body, value.text.toString())
                    val native = checkNotNull(value.native)
                    val source = native.source(width)
                    val marker = source.getSpans(0, source.length, NativeRubyPreparedSource::class.java).single()
                    val range = marker.projection.ranges.single { it.role == RubyTextRole.BoxGroup }
                    assertSame(selected, range.span)
                    assertEquals(0 to 4, range.start to range.end)
                    assertSame(selected.inlineBoxGroup!!.spans.single(),
                        marker.projection.ranges.single { it.span === selected.inlineBoxGroup!!.spans.single() }.span)
                    val format = marker.groups.getValue(range.path)
                    val box = checkNotNull(format.box)
                    if (selected === plain && width == fitWidth) {
                        // Exercise the literal boundary contract directly: source collapse is not this test's oracle.
                        for (text in listOf(" " + body, body + " ", "\u2009" + body, body + "\u3000")) {
                            val edgeSource = SpannableString(text).apply {
                                setSpan(NativeInlineBoxSpan(format, 0f, false), 0, length,
                                    Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                            }
                            assertThrows(UnsupportedFloatLayout::class.java) {
                                NativeInlineBoxWidths(edgeSource, format.paint, native.direction)
                            }
                        }
                    }
                    assertEquals(reference.textSize, format.paint.textSize, .01f)
                    assertEquals(density, box.border.left.width, .001f)
                    val widths = nativeTextWidthRange(source, native.paint, textDirection = native.direction)
                    assertEquals(fitWidth, widths.minimum)
                    assertEquals(fitWidth, widths.maximum)
                    val geometry = checkNotNull(value.geometry)(width, emptyList(), false)
                    assertEquals(body, geometry.text.toString())
                    assertEquals(1, geometry.shapedLineCount)
                    val border = checkNotNull(geometry.inlineBoxGroupRects(box.owner, 0, 4)).single()
                    assertEquals(expectedWidth, border.width(), .05f)
                    val fm = reference.fontMetrics
                    val baseline = geometry.baselineForOffset(0)!!
                    assertEquals(baseline + fm.ascent - density, border.top, .05f)
                    assertEquals(baseline + fm.descent + density, border.bottom, .05f)
                    val chars = geometry.characterRects(0, 4)
                    assertEquals(4, chars.size)
                    assertTrue(chars.all { it != null && it.width() > 0f })
                    for (offset in 0..4) {
                        val caret = geometry.caretRect(NativeTextCaret(offset,
                            if (offset == 4) NativeTextAffinity.Upstream else NativeTextAffinity.Downstream))
                        assertEquals(border.left + density + reference.measureText(body.substring(0, offset)), caret.left, .05f)
                    }
                    val bitmap = Bitmap.createBitmap(400, 200, Bitmap.Config.ARGB_8888)
                    try {
                        val canvas = Canvas(bitmap)
                        canvas.translate(20f, 40f)
                        geometry.paint(canvas)
                        assertEquals(0xffcc2244.toInt(), bitmap.getPixel((border.centerX() + 20f).toInt(),
                            (border.centerY() + 40f).toInt()))
                        assertEquals(android.graphics.Color.TRANSPARENT,
                            bitmap.getPixel((border.right + 24f).toInt(), (border.centerY() + 40f).toInt()))
                    } finally { bitmap.recycle() }
                    val node = geometry.nodes.single()
                    assertEquals(if (selected === linked) FloatInteractionKind.LINK else FloatInteractionKind.ADVISORY, node.kind)
                    assertEquals(0 to 4, node.start to node.end)
                    assertEquals(body, node.label.toString())
                    assertEquals(title, node.tooltip.toString())
                    assertTrue(node.contains(border.centerX(), border.centerY()))
                    val view = NativeFloatTextView(compose.activityRule.activity())
                    view.bind({ geometry }, 0x6633b5e5, 0xff1686c7.toInt())
                    view.measure(View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.EXACTLY),
                        View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED))
                    view.layout(0, 0, view.measuredWidth, view.measuredHeight)
                    val provider = view.accessibilityNodeProvider
                    val host = provider.createAccessibilityNodeInfo(AccessibilityNodeProvider.HOST_VIEW_ID)!!
                    try { assertEquals(body, host.text.toString()) } finally { host.recycle() }
                    val advice = provider.createAccessibilityNodeInfo(node.id)!!
                    try {
                        assertEquals(body, advice.text.toString())
                        assertEquals(title, advice.tooltipText.toString())
                    } finally { advice.recycle() }
                    val args = Bundle().apply {
                        putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, 0)
                        putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, 4)
                    }
                    assertTrue(provider.performAction(AccessibilityNodeProvider.HOST_VIEW_ID,
                        AccessibilityNodeInfo.ACTION_SET_SELECTION, args))
                    assertEquals(body, view.selectedTextForCopy())
                    if (selected === linked) {
                        assertTrue(provider.performAction(node.id, AccessibilityNodeInfo.ACTION_CLICK, null))
                        assertEquals(listOf(EntryLink("original-target")), calls)
                    } else assertNull(node.onClick)
                }
            }
            compose.runOnIdle { current.value = plain }
            compose.waitForIdle()
            compose.runOnIdle {
                val value = checkNotNull(prepared)
                assertEquals(body, checkNotNull(value.geometry)(fitWidth, emptyList(), false).text.toString())
                assertEquals(listOf(EntryLink("original-target")), calls)
            }
        } catch (failure: Throwable) { primary = failure; throw failure }
        finally {
            try { compose.activityRule.scenario.onActivity { it.setContent {} }; compose.waitForIdle() }
            catch (cleanup: Throwable) {
                val failure = primary
                if (failure == null) throw cleanup
                if (failure !== cleanup) failure.addSuppressed(cleanup)
            }
        }
    }
}
