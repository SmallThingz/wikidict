package app.smallthingz.dict

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.Typeface
import android.os.SystemClock
import android.text.Layout
import android.text.SpannableString
import android.text.Spanned
import android.text.TextDirectionHeuristics
import android.text.TextPaint
import android.view.MotionEvent
import android.view.View
import android.view.accessibility.AccessibilityNodeInfo
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.util.Locale
import kotlin.math.ceil

/** Synthetic source policies through the maintained native owner, not genuine page qualification. */
@RunWith(AndroidJUnit4::class)
class NativeTextWrapDeviceTest {
    private fun paint(locale: Locale = Locale.US) = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
        textSize = 24f; typeface = Typeface.MONOSPACE; color = Color.BLACK; textLocale = locale
    }
    private fun policy(source: SpannableString, wrap: TextWrap, start: Int = 0, end: Int = source.length,
        owner: Boolean = false): NativeAuthoredTextWrap = NativeAuthoredTextWrap(wrap, owner).also {
        source.setSpan(it, start, end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
    }
    private fun refused(source: SpannableString, paint: TextPaint, width: Int) {
        assertTrue(runCatching { NativeFloatGeometry.build(source, paint, width, emptyList()) }
            .exceptionOrNull() is UnsupportedFloatLayout)
    }
    private fun pixels(bitmap: Bitmap) = IntArray(bitmap.width * bitmap.height).also {
        bitmap.getPixels(it, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
    }

    @Test fun oneAuthoredActionWrapsWithoutLoweringWordMinimumOrChangingItsNormalNeighbour() {
        val root = paint()
        val first = "MMMMMMMMMMMMMMMM"
        val second = "WWWWWWWWWWWWWWWWWWWW"
        val raw = "left $first right $second tail"
        val source = SpannableString(raw)
        val a = raw.indexOf(first); val b = raw.indexOf(second)
        policy(source, TextWrap.Normal, owner = true)
        policy(source, TextWrap.Normal, a, a + first.length)
        policy(source, TextWrap.BreakWord, b, b + second.length)
        val ordinary = nativeTextWidthRange(SpannableString(raw), root)
        assertEquals(ordinary, nativeTextWidthRange(source, root))
        assertTrue(ordinary.minimum > 100)
        var opened = 0
        fun geometry(width: Int) = NativeFloatGeometry.build(source, root, width, emptyList(), nodeFactory = { owner ->
            listOf(FloatInteractionNode(71, FloatInteractionKind.LINK, b, b + second.length,
                owner.rectsForRange(b, b + second.length), second, null, { opened++ }))
        })
        val narrow = geometry(100)
        assertEquals(raw, narrow.text.toString())
        val firstBaselines = (a until a + first.length).map(narrow::baselineForOffset).distinct()
        assertEquals(1, firstBaselines.size)
        assertTrue(narrow.rectsForRange(a, a + first.length).single().width() > 100f)
        assertTrue((b until b + second.length).map(narrow::baselineForOffset).distinct().size > 1)
        assertTrue(narrow.rectsForRange(b, b + second.length).all { it.width() <= 101f })
        assertEquals(listOf(71), narrow.nodes.map { it.id })
        assertEquals(b, narrow.nodes.single().start); assertEquals(b + second.length, narrow.nodes.single().end)
        val wide = geometry(900)
        assertEquals(raw, wide.text.toString()); assertEquals(narrow.nodes.single().label, wide.nodes.single().label)
        assertEquals(ordinary, nativeTextWidthRange(source, root))

        // The complementary inheritance direction uses the same actual source/action owner:
        // explicit Normal overrides inherited BreakWord, while the unmarked second word inherits it.
        val oldPolicies = source.getSpans(0, source.length, NativeAuthoredTextWrap::class.java)
        source.removeSpan(oldPolicies.single { it.inheritedOwner })
        source.removeSpan(oldPolicies.single { !it.inheritedOwner && it.wrap == TextWrap.BreakWord })
        policy(source, TextWrap.BreakWord, owner = true)
        val retainedPolicies = source.getSpans(0, source.length, NativeAuthoredTextWrap::class.java)
        assertEquals(2, retainedPolicies.size)
        assertEquals(TextWrap.BreakWord, retainedPolicies.single { it.inheritedOwner }.wrap)
        val explicitNormal = retainedPolicies.single { !it.inheritedOwner }
        assertEquals(TextWrap.Normal, explicitNormal.wrap)
        assertEquals(a, source.getSpanStart(explicitNormal)); assertEquals(a + first.length, source.getSpanEnd(explicitNormal))
        val inherited = geometry(100)
        assertEquals(raw, inherited.text.toString())
        assertEquals(1, (a until a + first.length).map(inherited::baselineForOffset).distinct().size)
        assertTrue(inherited.rectsForRange(a, a + first.length).single().width() > 100f)
        assertTrue((b until b + second.length).map(inherited::baselineForOffset).distinct().size > 1)
        assertTrue(inherited.rectsForRange(b, b + second.length).all { it.width() <= 101f })
        assertEquals(narrow.nodes.map { Triple(it.id, it.start, it.end) }, inherited.nodes.map { Triple(it.id, it.start, it.end) })
        assertEquals(ordinary, nativeTextWidthRange(source, root))

        val instrumentation = InstrumentationRegistry.getInstrumentation()
        instrumentation.runOnMainSync {
            val view = NativeFloatTextView(instrumentation.targetContext)
            view.bind(::geometry, Color.BLUE, Color.RED)
            view.measure(View.MeasureSpec.makeMeasureSpec(100, View.MeasureSpec.EXACTLY),
                View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED))
            view.layout(0, 0, view.measuredWidth, view.measuredHeight)
            val actual = checkNotNull(view.currentMeasuredGeometry)
            val provider = checkNotNull(view.accessibilityNodeProvider)
            val node = checkNotNull(provider.createAccessibilityNodeInfo(71))
            try {
                assertEquals(second, node.text.toString()); assertTrue(node.isClickable)
                val bounds = Rect(); node.getBoundsInParent(bounds)
                assertFalse(bounds.isEmpty)
                assertEquals(71, actual.nodes.single().id)
                view.setSelection(b, b + second.length)
                assertEquals(second, view.selectedTextForCopy())
                view.setSelection(0, 0)
                val hit = actual.rectsForRange(b, b + second.length).first()
                val now = SystemClock.uptimeMillis()
                val down = MotionEvent.obtain(now, now, MotionEvent.ACTION_DOWN, hit.centerX(), hit.centerY(), 0)
                val up = MotionEvent.obtain(now, now + 20, MotionEvent.ACTION_UP, hit.centerX(), hit.centerY(), 0)
                try { assertTrue(view.onTouchEvent(down)); assertTrue(view.onTouchEvent(up)) }
                finally { down.recycle(); up.recycle() }
                assertEquals(1, opened)
                assertTrue(provider.performAction(71, AccessibilityNodeInfo.ACTION_CLICK, null))
                assertEquals(2, opened)
            } finally { node.recycle() }
        }
    }

    @Test fun normalOverflowKeepsFullContextNativeRasterCaretAndSelectionForEveryAlignmentAndDirection() {
        for ((text, locale) in listOf("MMMMMMMMMMMMMMMM" to Locale.US, "مرحبابكممرحبابكم" to Locale("ar"))) {
            val root = paint(locale)
            val source = SpannableString(text); policy(source, TextWrap.Normal)
            val wideWidth = ceil(Layout.getDesiredWidth(source, root).toDouble()).toInt() + 32
            for (ltr in listOf(true, false)) for (alignment in listOf(Layout.Alignment.ALIGN_NORMAL,
                Layout.Alignment.ALIGN_OPPOSITE, Layout.Alignment.ALIGN_CENTER)) {
                val direction = if (ltr) TextDirectionHeuristics.LTR else TextDirectionHeuristics.RTL
                val actual = NativeFloatGeometry.build(source, root, 80, emptyList(), alignment, direction)
                val reference = NativeFloatGeometry.build(SpannableString(text), root, wideWidth, emptyList(), alignment, direction)
                assertEquals(1, actual.shapedLineCount); assertEquals(1, reference.shapedLineCount)
                assertEquals(text, actual.text.toString())
                val dx = actual.caretRect(0).left - reference.caretRect(0).left
                val dy = actual.baselineForOffset(0) - reference.baselineForOffset(0)
                for (offset in text.indices) {
                    val a = checkNotNull(actual.characterRects(offset, 1).single())
                    val r = checkNotNull(reference.characterRects(offset, 1).single())
                    assertEquals(r.left + dx, a.left, .01f); assertEquals(r.right + dx, a.right, .01f)
                    assertEquals(r.top + dy, a.top, .01f); assertEquals(r.bottom + dy, a.bottom, .01f)
                }
                val first = Bitmap.createBitmap(1200, 160, Bitmap.Config.ARGB_8888)
                val second = Bitmap.createBitmap(1200, 160, Bitmap.Config.ARGB_8888)
                try {
                    Canvas(first).apply { translate(500f, 20f); actual.paint(this) }
                    Canvas(second).apply { translate(500f + dx, 20f + dy); reference.paint(this) }
                    assertArrayEquals("Actual fitted paint must coincide with its native caret/selection transform", pixels(second), pixels(first))
                    assertTrue(pixels(first).any { Color.alpha(it) != 0 })
                } finally { first.recycle(); second.recycle() }
            }
        }
    }

    @Test fun emergencyFittingKeepsGraphemesAndOrdinaryMinimumIncludingLegacyAnywhereContext() {
        val root = paint()
        val text = "e\u0301".repeat(18) + "👩\u200d🔬".repeat(4)
        val source = SpannableString(text); policy(source, TextWrap.BreakWord)
        val ordinary = nativeTextWidthRange(SpannableString(text), root)
        assertEquals(ordinary.minimum, nativeTextWidthRange(source, root, breakWordMinimum = true).minimum)
        for (width in listOf(0, 30, 70, 800)) {
            val actual = NativeFloatGeometry.build(source, root, width, emptyList())
            assertEquals(text, actual.text.toString())
            val breaks = android.icu.text.BreakIterator.getCharacterInstance(root.textLocale).apply { setText(text) }
            for (offset in 1 until text.length) if (actual.baselineForOffset(offset) != actual.baselineForOffset(offset - 1))
                assertTrue("Native line change must retain a complete grapheme at $offset", breaks.isBoundary(offset))
        }
        val partial = SpannableString("abcdefgh")
        policy(partial, TextWrap.BreakWord, 2, 6)
        assertTrue(runCatching { nativeTextWidthRange(partial, root, breakWordMinimum = true) }
            .exceptionOrNull() is UnsupportedFloatLayout)
        assertEquals(nativeTextWidthRange(SpannableString("abcdefgh"), root), nativeTextWidthRange(partial, root))
    }

    @Test fun unsupportedMixedWordAndActiveFloatRetainSourceAndRecoverWithSupportedPolicy() {
        val root = paint()
        val source = SpannableString("MMMMMMMMMMMMMMMM")
        val partial = policy(source, TextWrap.Normal, 2, source.length - 2)
        refused(source, root, 80)
        assertEquals("MMMMMMMMMMMMMMMM", source.toString())
        source.removeSpan(partial); val normal = policy(source, TextWrap.Normal)
        assertEquals(1, NativeFloatGeometry.build(source, root, 80, emptyList()).shapedLineCount)
        assertTrue(runCatching {
            NativeFloatGeometry.build(source, root, 80, emptyList(), carriedExclusions = listOf(
                NativeFloatExclusion(TableFloatSide.Left, NativeFloatBounds(0f, 0f, 30f, 200f))))
        }.exceptionOrNull() is UnsupportedFloatLayout)
        source.removeSpan(normal); policy(source, TextWrap.BreakWord)
        val recovered = NativeFloatGeometry.build(source, root, 80, emptyList(), carriedExclusions = listOf(
            NativeFloatExclusion(TableFloatSide.Left, NativeFloatBounds(0f, 0f, 30f, 200f))))
        assertEquals(source.toString(), recovered.text.toString())
        assertTrue(recovered.shapedLineCount > 1)
        assertEquals(1, source.getSpans(0, source.length, NativeAuthoredTextWrap::class.java).size)
    }

    @Test fun emergencyPolicyFiltersActualNativeEndpointsWithoutChangingOriginalOffsets() {
        val root = paint()
        val raw = "e\u0301".repeat(4) + "\ud83d\udc69\u200d\ud83d\udd2c".repeat(2) + "abcdefghij"
        val source = SpannableString(raw)
        val authored = policy(source, TextWrap.BreakWord)
        val plan = checkNotNull(NativeTextWrapPlan.create(source, root))
        fun endpoints(geometry: NativeFloatGeometry): Set<Int> = (1 until raw.length).filter {
            geometry.baselineForOffset(it) != geometry.baselineForOffset(it - 1)
        }.toSet()
        val narrow = NativeFloatGeometry.build(source, root, 0, emptyList())
        val actual = endpoints(narrow)
        val admitted = actual.filter { plan.permitsEmergencyBreak(it) }.toSet()
        assertTrue(admitted.isNotEmpty())
        assertTrue(2 in admitted)
        assertTrue(raw.indexOf("abcdefghij") + 1 in admitted)
        val graphemes = android.icu.text.BreakIterator.getCharacterInstance(root.textLocale).apply { setText(raw) }
        assertTrue(actual.all(graphemes::isBoundary))
        for (offset in 1 until raw.length) if (!graphemes.isBoundary(offset))
            assertFalse(plan.permitsEmergencyBreak(offset))
        assertFalse(plan.permitsEmergencyBreak(0))
        assertFalse(plan.permitsEmergencyBreak(raw.length))
        assertFalse(plan.permitsEmergencyBreak(1)) // Inside the first combining sequence.
        assertTrue(runCatching { plan.permitsEmergencyBreak(-1) }.exceptionOrNull() is IllegalArgumentException)
        assertTrue(runCatching { plan.permitsEmergencyBreak(raw.length + 1) }.exceptionOrNull() is IllegalArgumentException)
        val wide = NativeFloatGeometry.build(source, root, 2000, emptyList())
        assertEquals(1, wide.shapedLineCount)
        assertTrue(endpoints(wide).filter { plan.permitsEmergencyBreak(it) }.isEmpty())
        assertEquals(raw, narrow.text.toString()); assertEquals(raw, wide.text.toString())
        assertSame(authored, source.getSpans(0, source.length, NativeAuthoredTextWrap::class.java).single())
        assertEquals(0, source.getSpanStart(authored)); assertEquals(raw.length, source.getSpanEnd(authored))

        val normal = SpannableString(raw); policy(normal, TextWrap.Normal)
        val normalPlan = checkNotNull(NativeTextWrapPlan.create(normal, root))
        assertTrue(actual.none { normalPlan.permitsEmergencyBreak(it) })
        val nowrap = SpannableString(raw)
        nowrap.setSpan(NativeAuthoredTextWrap(TextWrap.NoWrap, inheritedOwner = true, sourceLineStarts = listOf(0)),
            0, nowrap.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        assertFalse(checkNotNull(NativeTextWrapPlan.create(nowrap, root)).permitsEmergencyBreak(2))
        assertNull(NativeTextWrapPlan.create(SpannableString("legacy"), root))

        // Policy-only replacement guard; this atom is never measured or painted.
        val atomic = SpannableString("abcdef")
        atomic.setSpan(NativeRubyBreaks(listOf(0, atomic.length)), 0, atomic.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        atomic.setSpan(object : android.text.style.ReplacementSpan() {
            override fun getSize(paint: Paint, text: CharSequence, start: Int, end: Int,
                fm: Paint.FontMetricsInt?): Int = error("Boundary fixture must not be measured")
            override fun draw(canvas: Canvas, text: CharSequence, start: Int, end: Int,
                x: Float, top: Int, y: Int, bottom: Int, paint: Paint) {
                error("Boundary fixture must not be painted")
            }
        }, 2, 4, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        val atomicPlan = checkNotNull(NativeTextWrapPlan.create(atomic, root))
        assertTrue(atomicPlan.permitsEmergencyBreak(1))
        assertFalse(atomicPlan.permitsEmergencyBreak(3))
        assertTrue(atomicPlan.permitsEmergencyBreak(5))
        assertEquals("abcdef", atomic.toString())
    }

    @Test fun emergencyPolicyKeepsAuthoredMinimumAndOnlyAdmitsTheLegacyMinimumRequest() {
        val root = paint()
        val raw = "ab abcdefghij"
        val source = SpannableString(raw)
        val authored = policy(source, TextWrap.BreakWord, 0, 2)
        val plan = checkNotNull(NativeTextWrapPlan.create(source, root))
        assertTrue(plan.permitsEmergencyBreak(1))
        assertFalse(plan.permitsEmergencyBreak(1, forLegacyIntrinsicMinimum = true))
        assertTrue(plan.permitsEmergencyBreak(4))
        assertTrue(plan.permitsEmergencyBreak(4, forLegacyIntrinsicMinimum = true))
        assertFalse(plan.permitsEmergencyBreak(3)) // Ordinary word start is not an emergency cut.
        val ordinary = nativeTextWidthRange(source, root)
        val emergency = nativeTextWidthRange(source, root, breakWordMinimum = true)
        assertEquals(nativeTextWidthRange(SpannableString(raw), root), ordinary)
        assertTrue(emergency.minimum < ordinary.minimum)
        assertEquals(nativeTextWidthRange(SpannableString("ab"), root).minimum, emergency.minimum)
        assertEquals(ordinary.maximum, emergency.maximum)
        assertEquals(raw, source.toString()); assertSame(authored,
            source.getSpans(0, source.length, NativeAuthoredTextWrap::class.java).single())

        val partial = SpannableString("abcdefgh")
        val partialPolicy = policy(partial, TextWrap.BreakWord, 2, 6)
        val partialPlan = checkNotNull(NativeTextWrapPlan.create(partial, root))
        assertTrue(partialPlan.permitsEmergencyBreak(3))
        assertTrue(runCatching { partialPlan.permitsEmergencyBreak(3, forLegacyIntrinsicMinimum = true) }
            .exceptionOrNull() is UnsupportedFloatLayout)
        partial.removeSpan(partialPolicy); policy(partial, TextWrap.BreakWord)
        val recovered = checkNotNull(NativeTextWrapPlan.create(partial, root))
        assertTrue(recovered.permitsEmergencyBreak(3))
        assertFalse(recovered.permitsEmergencyBreak(3, forLegacyIntrinsicMinimum = true))
        assertEquals("abcdefgh", partial.toString())
    }
}
