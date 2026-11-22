package app.smallthingz.dict

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface
import android.os.Bundle
import android.os.SystemClock
import android.text.SpannableString
import android.text.Spanned
import android.text.SpannedString
import android.text.TextDirectionHeuristics
import android.text.TextPaint
import android.view.InputDevice
import android.view.MotionEvent
import android.view.View
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityNodeProvider
import androidx.activity.compose.setContent
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.SideEffect
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.sp
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.util.Locale
import kotlin.math.abs
import kotlin.math.ceil
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** Source-derived controls for the six MG shapes; execution does not imply genuine-page acceptance. */
@RunWith(AndroidJUnit4::class)
class NativeInlineBoxPitchDeviceTest {
    @get:Rule val compose = createPhysicalComposeRule()
    private val cases = listOf(
        listOf("ロ" to false, "ス" to true, "コ" to false),
        listOf("ヌ" to true, "エッ" to false, "チ" to true, "ケ" to false),
        listOf("ラリン" to false, "ピ" to true),
        listOf("エズ" to false, "ス" to true),
        listOf("た" to false, "く" to true, "ちい" to false),
        listOf("ス" to true, "カ" to false))
    private val zero = StyleLength(StyleLengthUnit.Px, 0f)
    private val one = StyleLength(StyleLengthUnit.Px, 1f)
    private val none = InlineBoxBorderEdge.None
    private fun leaf(value: String) = Span("text", value, language = "ja", classes = "Jpan")
    private fun owner(segments: List<Pair<String, Boolean>>): Span {
        val dot = InlineBoxBorderEdge.Dotted(one, InlineBoxColor.Rgb("#808080"))
        val solid = InlineBoxBorderEdge.Solid(one, InlineBoxColor.CurrentColor)
        return leaf("").copy(inlineBoxGroup = InlineBoxGroup(StyleEdges(one, one, one, one),
            InlineBoxBorderEdges(solid, none, none, none), listOf(InlineBoxOverlay(
                InlineBoxInsets(top = InlineBoxInset(StyleWidthUnit.Px, 0f),
                    right = InlineBoxInset(StyleWidthUnit.Percent, 0f), bottom = InlineBoxInset(StyleWidthUnit.Percent, 67f)),
                InlineBoxBorderEdges(none, solid, none, none))),
            segments.map { (text, circle) -> if (!circle) leaf(text) else leaf("").copy(inlineBoxGroup = InlineBoxGroup(
                StyleEdges(zero, zero, zero, zero), InlineBoxBorderEdges(dot, dot, dot, dot),
                spans = listOf(leaf(text)), radius = StyleWidth(StyleWidthUnit.Percent, 50f))) }))
    }
    private data class Fixture(val source: Spanned, val projection: RubyTextProjection, val owner: Span,
        val parent: RubyTextRange, val children: List<RubyTextRange>, val formats: Map<String, NativeRubyGroupFormat>,
        val paint: TextPaint, val direction: android.text.TextDirectionHeuristic) {
        fun key(range: RubyTextRange) = checkNotNull(formats.getValue(range.path).box).owner
    }
    private fun fixture(segments: List<Pair<String, Boolean>>, prefix: String = "前", childScale: Float = 1f,
        childHeight: NativeLineHeightPolicy? = null, rtl: Boolean = false): Fixture {
        val owner = owner(segments)
        val projection = rubyGraphicalProjection(listOf(leaf(prefix), owner, leaf("後")))
        val paint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            typeface = Typeface.MONOSPACE; textSize = 24f; textLocale = Locale.JAPANESE; color = Color.BLUE
        }
        val direction = if (rtl) TextDirectionHeuristics.RTL else TextDirectionHeuristics.LTR
        val ranges = projection.ranges.filter { it.role == RubyTextRole.BoxGroup }
        val parent = ranges.single { it.span === owner }
        val children = ranges.filter { it !== parent }
        val formats = ranges.associate { range ->
            val parentOwner = range === parent
            val noEdge = NativeInlineBoxBorder(0f, 0)
            val stroke = NativeInlineBoxBorder(1f, null)
            val dot = NativeInlineBoxBorder(1f, 0xff808080.toInt(), dotted = true)
            val border = if (parentOwner) NativeInlineBoxBorders(stroke, noEdge, noEdge, noEdge)
                else NativeInlineBoxBorders(dot, dot, dot, dot)
            val overlays = if (!parentOwner) emptyList() else listOf(NativeInlineBoxOverlay(
                NativeInlineBoxInsets(NativeInlineBoxInset(0f, false), NativeInlineBoxInset(0f, true),
                    NativeInlineBoxInset(67f, true), null), NativeInlineBoxBorders(noEdge, stroke, noEdge, noEdge)))
            range.path to NativeRubyGroupFormat(TextPaint(paint).apply { if (!parentOwner) textSize *= childScale },
                direction, if (parentOwner) NativeLineHeightPolicy.Normal else childHeight ?: NativeLineHeightPolicy.Normal,
                box = NativeInlineBoxFormat(NativeInlineBoxOwner(checkNotNull(range.span), range.path),
                    if (parentOwner) NativeInlineBoxEdges(1f, 1f, 1f, 1f) else NativeInlineBoxEdges(0f, 0f, 0f, 0f),
                    border, overlays, radius = if (parentOwner) null else 50f, radiusPercentage = !parentOwner))
        }
        val text = SpannableString(projection.text)
        text.setSpan(NativeRunLineMetrics(NativePrimaryFontMetrics.from(paint), NativeLineHeightPolicy.Normal, strut = true),
            0, text.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        text.setSpan(NativeRubyPreparedSource(projection, SpannedString(text), paint, direction, formats),
            0, text.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        return Fixture(SpannedString(text), projection, owner, parent, children, formats, paint, direction)
    }
    private fun build(value: Fixture, width: Int) = NativeFloatGeometry.build(value.source, value.paint,
        width, emptyList(), textDirection = value.direction)
    private fun rects(value: Fixture, geometry: FloatTextGeometry, range: RubyTextRange) =
        checkNotNull(geometry.inlineBoxGroupRects(value.key(range), range.start, range.end))
    private fun prefixWidth(value: Fixture, cut: Int): Int {
        val ranges = listOf(value.parent) + value.children
        val edges = ranges.sumOf { (if (it.start < cut) 1 else 0) + (if (it.end <= cut) 1 else 0) }
        return ceil(value.paint.measureText(value.projection.text.substring(0, cut)) + edges).toInt()
    }
    private fun assertAllocations(value: Fixture, geometry: NativeFloatGeometry) {
        assertEquals(value.projection.text, geometry.text.toString())
        assertTrue(geometry.nodes.isEmpty())
        val parents = rects(value, geometry, value.parent)
        assertEquals(parents.size, parents.map { it.top }.distinct().size)
        for (child in value.children) {
            val childRect = rects(value, geometry, child).single()
            val parent = parents.single { abs(it.top + 1f - childRect.top) < .02f }
            assertTrue(parent.left <= childRect.left && parent.right >= childRect.right)
            assertEquals(parent.bottom, childRect.bottom, .02f)
            if (child.start == value.parent.start) assertEquals(parent.left + 1f, childRect.left, .02f)
            if (child.end == value.parent.end) assertEquals(parent.right - 1f, childRect.right, .02f)
            val glyph = geometry.rectsForRange(child.start, child.end).single()
            assertEquals(childRect.left + 1f, glyph.left, .02f)
            assertEquals(childRect.right - 1f, glyph.right, .02f)
            val hit = checkNotNull(geometry.inlineBoxGroupHitTest(value.key(child), child.start, child.end))
            assertFalse(hit(childRect.left + .01f, childRect.top + .01f))
            assertTrue(hit(childRect.centerX(), childRect.centerY()))
            assertTrue(geometry.offsetForPosition(childRect.centerX(), childRect.centerY()) in child.start..child.end)
        }
        val lines = (0 until geometry.shapedLineCount).map { geometry.nativeRangeOfLine(it) }
        val expected = lines.sumOf { (a, b) -> value.paint.measureText(value.projection.text.substring(a, b)).toDouble() } +
            2.0 + value.children.size * 2.0
        assertEquals(expected, (0 until geometry.shapedLineCount).sumOf { geometry.nativeLineAdvance(it).toDouble() }, .03)
    }

    @Test fun sixPitchShapesPreserveEachEdgeOnceAcrossSharedEndpointsAndChildBoundaryWraps() {
        for (segments in cases) {
            val value = fixture(segments)
            val wide = build(value, 500)
            assertAllocations(value, wide)
            val plain = NativeFloatGeometry.build(SpannableString(value.projection.text), value.paint, 500,
                emptyList(), textDirection = TextDirectionHeuristics.LTR)
            assertEquals(plain.rectsForRange(0, 1), wide.rectsForRange(0, 1))
            for (cut in (listOf(value.parent.start, value.parent.end) + value.children.flatMap { listOf(it.start, it.end) }).distinct()) {
                val charge = (listOf(value.parent) + value.children).sumOf { (if (it.start == cut) 1 else 0) + (if (it.end == cut) 1 else 0) }
                assertEquals(charge.toFloat(), wide.caretRect(NativeTextCaret(cut, NativeTextAffinity.Downstream)).left -
                    wide.caretRect(NativeTextCaret(cut, NativeTextAffinity.Upstream)).left, .03f)
            }
            for (cut in value.children.flatMap { listOf(it.start, it.end) }.distinct()) {
                val narrow = build(value, prefixWidth(value, cut))
                assertAllocations(value, narrow)
                assertEquals(cut, narrow.lineRange(cut).first)
                assertEquals(cut, narrow.lineRange(cut - 1).second)
            }
        }
    }

    private fun raster(draw: (Canvas) -> Unit): IntArray {
        val bitmap = Bitmap.createBitmap(600, 400, Bitmap.Config.ARGB_8888)
        return try {
            val canvas = Canvas(bitmap); canvas.translate(20f, 80f); draw(canvas)
            IntArray(bitmap.width * bitmap.height).also { bitmap.getPixels(it, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height) }
        } finally { bitmap.recycle() }
    }
    private fun assertIndicator(value: Fixture, geometry: NativeFloatGeometry, crossed: Boolean = false) {
        val parent = rects(value, geometry, value.parent)
        val first = parent.first(); val last = parent.last()
        if (crossed) { assertTrue(parent.size > 1); assertTrue(first.left > last.right) }
        val right = maxOf(first.left, last.right)
        val top = first.top + 1f
        val bottom = (top.toDouble() + (last.bottom.toDouble() - top) * .33).toFloat()
        val expected = RectF(right - 1f, top, right, bottom)
        val noEdge = NativeInlineBoxBorder(0f, 0)
        val painter = NativeInlineBoxBorderPaint(expected,
            NativeInlineBoxBorders(noEdge, NativeInlineBoxBorder(1f, null), noEdge, noEdge))
        val pixels = raster { painter.paint(it) { Color.BLUE } }
        assertTrue(pixels.any { it != 0 })
        assertArrayEquals(pixels, raster { geometry.paintInlineBoxOverlays(it) })
        assertArrayEquals(raster { geometry.paint(it) }, raster { canvas ->
            geometry.paintInlineBoxContent(canvas); painter.paint(canvas) { Color.BLUE }
        })
        assertArrayEquals(raster { geometry.paint(it) }, raster { canvas ->
            for (line in 0 until geometry.shapedLineCount) geometry.paintRubyNativeLine(canvas, line)
        })
    }

    @Test fun wrappedPitchIndicatorUsesFirstLastPaddingIncludingCrossedInlineEdgesAndOriginalTouchText() {
        val normal = fixture(cases.first())
        assertIndicator(normal, build(normal, 500))
        val value = fixture(cases.last(), prefix = "前前前前")
        val geometry = build(value, prefixWidth(value, value.children.single().end))
        assertAllocations(value, geometry)
        assertIndicator(value, geometry, crossed = true)
        compose.runOnIdle {
            val view = NativeFloatTextView(compose.activityRule.activity())
            view.bind({ geometry }, 0x6633b5e5, 0xff1686c7.toInt())
            view.measure(View.MeasureSpec.makeMeasureSpec(geometry.width, View.MeasureSpec.EXACTLY),
                View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED))
            view.layout(0, 0, view.measuredWidth, view.measuredHeight)
            val child = value.children.single()
            val box = rects(value, geometry, child).single()
            val time = SystemClock.uptimeMillis()
            for (action in listOf(MotionEvent.ACTION_DOWN, MotionEvent.ACTION_UP)) {
                val event = MotionEvent.obtain(time, time + if (action == MotionEvent.ACTION_UP) 20 else 0,
                    action, box.centerX(), box.centerY(), 0)
                event.source = InputDevice.SOURCE_TOUCHSCREEN
                try { assertTrue(view.dispatchTouchEvent(event)) } finally { event.recycle() }
            }
            assertEquals(geometry.caretAt(box.centerX(), box.centerY()), view.selectionExtentCaret)
            val provider = view.accessibilityNodeProvider
            val host = checkNotNull(provider.createAccessibilityNodeInfo(AccessibilityNodeProvider.HOST_VIEW_ID))
            try { assertEquals(value.projection.text, host.text.toString()) } finally { host.recycle() }
            val arguments = Bundle().apply {
                putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, child.start)
                putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, child.end)
            }
            assertTrue(provider.performAction(AccessibilityNodeProvider.HOST_VIEW_ID, AccessibilityNodeInfo.ACTION_SET_SELECTION, arguments))
            assertEquals(child.start, view.selectionStart); assertEquals(child.end, view.selectionEnd)
        }
    }

    @Test fun nestedPitchRejectsRealizedMetricAndDirectionMismatchThenRecovers() {
        for (value in listOf(fixture(cases.first(), childScale = 1.25f),
                fixture(cases.first(), childHeight = NativeLineHeightPolicy.Pixels(36f)), fixture(cases.first(), rtl = true)))
            assertThrows(UnsupportedFloatLayout::class.java) { build(value, 500) }
        val recovery = fixture(cases[1])
        assertAllocations(recovery, build(recovery, 500))
    }

    @Test fun normalComposeLoweringKeepsBothSourceCirclesDensityAndEmptyOverlayWithoutInventingActions() {
        val sourceOwner = owner(cases[1])
        val spans = listOf(leaf("前"), sourceOwner, leaf("後"))
        val calls = mutableListOf<EntryLink>()
        var prepared: PreparedNativeFloatText? = null
        var primary: Throwable? = null
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                MaterialTheme {
                    CompositionLocalProvider(LocalDensity provides Density(1.25f, 1.2f)) {
                        val style = TextStyle(fontSize = 24.sp, fontFamily = FontFamily.SansSerif)
                        val annotation = styledTextAnnotation(spans, null, style) { calls += it }
                        val value = prepareNativeFloatText(spans, annotation, egyptianTextRuns(spans), style,
                            MaterialTheme.colorScheme.primary, emptyList(), AppSettings(), "", { calls += it },
                            nativeLineHeight = NativeLineHeightPolicy.Normal, ownerDirection = BidiResolvedDirection.Ltr)
                        SideEffect { prepared = value }
                    }
                }
            } }
            compose.waitForIdle()
            compose.runOnIdle {
                val value = checkNotNull(prepared)
                assertNull(value.stateDescription)
                assertEquals("前ヌエッチケ後", value.text.toString())
                val native = checkNotNull(value.native)
                val source = native.source(500)
                val marker = source.getSpans(0, source.length, NativeRubyPreparedSource::class.java).single()
                val ranges = marker.projection.ranges.filter { it.role == RubyTextRole.BoxGroup }
                assertEquals(3, ranges.size)
                val parent = ranges.single { it.span === sourceOwner }
                val format = marker.groups.getValue(parent.path)
                val box = checkNotNull(format.box)
                assertSame(sourceOwner, box.owner.span)
                assertEquals(1.25f, box.padding.left, .001f)
                assertEquals(1.25f, box.border.top.width, .001f)
                assertEquals(NativeInlineBoxInset(67f, true), box.overlays.single().insets.bottom)
                val geometry = checkNotNull(value.geometry)(500, emptyList(), false)
                assertEquals(value.text.toString(), geometry.text.toString())
                assertTrue(geometry.nodes.isEmpty())
                val parentRect = checkNotNull(geometry.inlineBoxGroupRects(box.owner, parent.start, parent.end)).single()
                for (child in ranges.filter { it !== parent }) {
                    val childBox = checkNotNull(marker.groups.getValue(child.path).box)
                    assertEquals(1.25f, childBox.border.left.width, .001f)
                    assertEquals(50f, childBox.radius!!, .001f)
                    val childRect = checkNotNull(geometry.inlineBoxGroupRects(childBox.owner, child.start, child.end)).single()
                    assertTrue(parentRect.left <= childRect.left && parentRect.right >= childRect.right)
                }
                assertTrue(calls.isEmpty())
            }
        } catch (failure: Throwable) { primary = failure; throw failure }
        finally {
            try { compose.activityRule.scenario.onActivity { it.setContent {} }; compose.waitForIdle() }
            catch (cleanup: Throwable) { if (primary == null) throw cleanup else primary.addSuppressed(cleanup) }
        }
    }
}
