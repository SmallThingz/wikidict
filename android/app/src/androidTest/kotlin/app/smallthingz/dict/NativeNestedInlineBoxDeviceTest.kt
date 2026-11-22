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
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.util.Locale
import kotlin.math.abs
import kotlin.math.ceil
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

/** Native controls for MG134's exact source shape. This is not a rendered-page or attached-window grant. */
@RunWith(AndroidJUnit4::class)
class NativeNestedInlineBoxDeviceTest {
    private data class Fixture(val source: Spanned, val projection: RubyTextProjection,
        val parent: RubyTextRange, val child: RubyTextRange, val parentKey: NativeInlineBoxOwner,
        val childKey: NativeInlineBoxOwner, val paint: TextPaint, val direction: android.text.TextDirectionHeuristic)

    private fun fixture(parentColor: Int = Color.BLACK, childScale: Float = 1f,
        childPolicy: NativeLineHeightPolicy? = null, rtl: Boolean = false, overlapRows: Boolean = false, linkedAncestor: Boolean = false): Fixture {
        val paint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            typeface = Typeface.MONOSPACE
            textSize = 24f
            textLocale = Locale.JAPANESE
            color = if (overlapRows) Color.TRANSPARENT else Color.BLUE
        }
        val policy = if (overlapRows) NativeLineHeightPolicy.Pixels(0f) else NativeLineHeightPolicy.Normal
        val direction = if (rtl) TextDirectionHeuristics.RTL else TextDirectionHeuristics.LTR
        val zero = StyleLength(StyleLengthUnit.Px, 0f)
        val one = StyleLength(StyleLengthUnit.Px, 1f)
        val empty = StyleEdges(zero, zero, zero, zero)
        val none = InlineBoxBorderEdge.None
        val dot = InlineBoxBorderEdge.Dotted(one, InlineBoxColor.Rgb("#808080"))
        fun leaf(text: String) = Span("text", text, language = "ja")
        val child = Span("text", "", language = "ja", inlineBoxGroup = InlineBoxGroup(empty,
            InlineBoxBorderEdges(dot, dot, dot, dot), spans = listOf(leaf("ス")),
            radius = StyleWidth(StyleWidthUnit.Percent, 50f)))
        val parent = Span("text", "", language = "ja", inlineBoxGroup = InlineBoxGroup(empty,
            InlineBoxBorderEdges(InlineBoxBorderEdge.Solid(one, if (parentColor == Color.TRANSPARENT)
                InlineBoxColor.Transparent else InlineBoxColor.Rgb("#000000")), none, none, none),
            spans = listOf(leaf("ガ"), child, leaf("スざ"))))
        val later = Span("text", "", language = "ja", background = "#00ff00", inlineBoxGroup = InlineBoxGroup(
            StyleEdges(StyleLength(StyleLengthUnit.Px, 12f), zero, StyleLength(StyleLengthUnit.Px, 12f), zero),
            InlineBoxBorderEdges(none, none, none, none), spans = listOf(leaf("外外"))))
        val ancestor = Span("link", "", "outer-action", inlineActionGroup = InlineActionGroup(listOf(parent)))
        val projection = rubyGraphicalProjection(listOf(leaf("ペ"), if (linkedAncestor) ancestor else parent) +
            if (overlapRows) listOf(later) else emptyList())
        val parentRange = projection.ranges.single { it.role == RubyTextRole.BoxGroup && it.span === parent }
        val childRange = projection.ranges.single { it.role == RubyTextRole.BoxGroup && it.span === child }
        val parentKey = NativeInlineBoxOwner(parent, parentRange.path)
        val childKey = NativeInlineBoxOwner(child, childRange.path)
        val formats = projection.ranges.filter { it.role in setOf(RubyTextRole.BoxGroup, RubyTextRole.ActionGroup) }.associate { range ->
            val own = checkNotNull(range.span)
            val declaring = TextPaint(paint).apply {
                if (own === child) textSize *= childScale
                if (own === later) bgColor = Color.GREEN
            }
            val noEdge = NativeInlineBoxBorder(0f, 0)
            val border = when (own) {
                parent -> NativeInlineBoxBorders(NativeInlineBoxBorder(1f, parentColor), noEdge, noEdge, noEdge)
                child -> NativeInlineBoxBorder(1f, Color.GRAY, dotted = true).let { NativeInlineBoxBorders(it, it, it, it) }
                else -> NativeInlineBoxBorders(noEdge, noEdge, noEdge, noEdge)
            }
            val key = when (own) { parent -> parentKey; child -> childKey; else -> NativeInlineBoxOwner(own, range.path) }
            val padding = if (own === later) NativeInlineBoxEdges(12f, 0f, 12f, 0f) else NativeInlineBoxEdges(0f, 0f, 0f, 0f)
            range.path to NativeRubyGroupFormat(declaring, direction, if (own === child) childPolicy ?: policy else policy,
                actionOwner = if (own === ancestor) NativeInlineActionOwner(own, range.path) else null,
                box = if (own === ancestor) null else NativeInlineBoxFormat(key, padding, border, emptyList(),
                    radius = if (own === child) 50f else null, radiusPercentage = own === child))
        }
        val text = SpannableString(projection.text)
        text.setSpan(NativeRunLineMetrics(NativePrimaryFontMetrics.from(paint), policy, strut = true),
            0, text.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        val prepared = NativeRubyPreparedSource(projection, SpannedString(text), paint, direction, formats)
        text.setSpan(prepared, 0, text.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        return Fixture(SpannedString(text), projection, parentRange, childRange, parentKey, childKey, paint, direction)
    }

    private fun build(value: Fixture, width: Int) = NativeFloatGeometry.build(value.source,
        value.paint, width, emptyList(), textDirection = value.direction)
    private fun parentRects(value: Fixture, geometry: FloatTextGeometry) =
        checkNotNull(geometry.inlineBoxGroupRects(value.parentKey, value.parent.start, value.parent.end))
    private fun childRects(value: Fixture, geometry: FloatTextGeometry) =
        checkNotNull(geometry.inlineBoxGroupRects(value.childKey, value.child.start, value.child.end))

    @Test fun nestedPitchKeepsBothWrappedChildEdgesInsideItsOwnContinuousTopStroke() {
        val value = fixture()
        assertEquals("ペガススざ", value.projection.text)
        assertEquals(1 to 5, value.parent.start to value.parent.end)
        assertEquals(2 to 3, value.child.start to value.child.end)
        val beforeWidth = ceil(value.paint.measureText("ペガ")).toInt()
        val afterWidth = ceil(value.paint.measureText("ペガス") + 2f).toInt()
        val wide = build(value, 300)
        assertEquals(value.paint.measureText(value.projection.text) + 2f,
            wide.caretRect(5).left - wide.caretRect(0).left, .02f)
        val plain = NativeFloatGeometry.build(SpannableString(value.projection.text), value.paint, 300,
            emptyList(), textDirection = TextDirectionHeuristics.LTR)
        assertEquals(plain.rectsForRange(0, 1), wide.rectsForRange(0, 1))
        for (width in listOf(300, beforeWidth, afterWidth)) {
            val geometry = build(value, width)
            assertEquals(value.projection.text, geometry.text.toString())
            assertTrue(geometry.nodes.isEmpty())
            val child = childRects(value, geometry).single()
            val parent = parentRects(value, geometry).single { abs(it.top - child.top) < .01f }
            assertTrue(parent.left <= child.left && parent.right >= child.right)
            assertEquals(parent.top, child.top, .01f)
            val hit = checkNotNull(geometry.inlineBoxGroupHitTest(value.childKey, 2, 3))
            assertFalse(hit(child.left + .01f, child.top + .01f))
            assertTrue(hit(child.centerX(), child.centerY()))
            assertTrue(geometry.offsetForPosition(child.centerX(), child.centerY()) in 2..3)
            if (width == beforeWidth) {
                assertEquals(2, geometry.lineRange(2).first)
                assertEquals(child.left, parent.left, .01f)
            }
            if (width == afterWidth) {
                assertEquals(3, geometry.lineRange(2).second)
                assertEquals(child.right, parent.right, .01f)
            }
        }
        for (at in listOf(2, 3)) assertEquals(1f,
            wide.caretRect(NativeTextCaret(at, NativeTextAffinity.Downstream)).left -
                wide.caretRect(NativeTextCaret(at, NativeTextAffinity.Upstream)).left, .02f)
    }

    private fun raster(geometry: NativeFloatGeometry, before: ((Canvas) -> Unit)? = null,
        after: ((Canvas) -> Unit)? = null, lines: Boolean = false): IntArray {
        val bitmap = Bitmap.createBitmap(360, 300, Bitmap.Config.ARGB_8888)
        try {
            val canvas = Canvas(bitmap)
            canvas.translate(20f, 80f)
            before?.invoke(canvas)
            if (lines) for (line in 0 until geometry.shapedLineCount) geometry.paintRubyNativeLine(canvas, line)
            else geometry.paint(canvas)
            after?.invoke(canvas)
            return IntArray(bitmap.width * bitmap.height).also { bitmap.getPixels(it, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height) }
        } finally { bitmap.recycle() }
    }

    @Test fun nestedPitchPaintsAncestorFirstAndKeepsOriginalTouchAndAccessibilityText() {
        val value = fixture()
        val actual = build(value, 300)
        val noParent = build(fixture(parentColor = Color.TRANSPARENT), 300)
        val parent = parentRects(value, actual).single()
        val none = NativeInlineBoxBorder(0f, 0)
        val painter = NativeInlineBoxBorderPaint(parent, NativeInlineBoxBorders(NativeInlineBoxBorder(1f, Color.BLACK), none, none, none))
        val drawParent: (Canvas) -> Unit = { canvas -> painter.paint(canvas) { Color.BLACK } }
        val expected = raster(noParent, before = drawParent)
        assertArrayEquals(expected, raster(actual))
        assertFalse(expected.contentEquals(raster(noParent, after = drawParent)))
        val overlap = fixture(overlapRows = true)
        val narrow = build(overlap, ceil(overlap.paint.measureText("ペガ")).toInt())
        assertTrue(narrow.shapedLineCount > 1)
        assertArrayEquals(raster(narrow), raster(narrow, lines = true))
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        instrumentation.runOnMainSync {
            val view = NativeFloatTextView(instrumentation.targetContext)
            view.bind({ actual }, 0x6633b5e5, 0xff1686c7.toInt())
            view.measure(View.MeasureSpec.makeMeasureSpec(300, View.MeasureSpec.EXACTLY),
                View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED))
            view.layout(0, 0, view.measuredWidth, view.measuredHeight)
            val child = childRects(value, actual).single()
            val time = SystemClock.uptimeMillis()
            for (action in listOf(MotionEvent.ACTION_DOWN, MotionEvent.ACTION_UP)) {
                val event = MotionEvent.obtain(time, time + if (action == MotionEvent.ACTION_UP) 20 else 0,
                    action, child.centerX(), child.centerY(), 0)
                event.source = InputDevice.SOURCE_TOUCHSCREEN
                try { assertTrue(view.dispatchTouchEvent(event)) } finally { event.recycle() }
            }
            assertEquals(actual.caretAt(child.centerX(), child.centerY()), view.selectionExtentCaret)
            val provider = view.accessibilityNodeProvider
            val host = provider.createAccessibilityNodeInfo(AccessibilityNodeProvider.HOST_VIEW_ID)!!
            try { assertEquals("ペガススざ", host.text.toString()) } finally { host.recycle() }
            val arguments = Bundle().apply {
                putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, 2)
                putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, 3)
            }
            assertTrue(provider.performAction(AccessibilityNodeProvider.HOST_VIEW_ID, AccessibilityNodeInfo.ACTION_SET_SELECTION, arguments))
            assertEquals(2, view.selectionStart)
            assertEquals(3, view.selectionEnd)
        }
    }

    @Test fun nestedPitchRefusesUnselectedRealizedMetricsAndDirectionThenRecovers() {
        for (value in listOf(fixture(childScale = 1.25f), fixture(childPolicy = NativeLineHeightPolicy.Pixels(36f)), fixture(rtl = true), fixture(linkedAncestor = true))) {
            assertThrows(UnsupportedFloatLayout::class.java) { build(value, 300) }
        }
        val value = fixture()
        assertEquals("ペガススざ", build(value, 300).text.toString())
    }
}
