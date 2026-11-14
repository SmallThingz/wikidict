package app.smallthingz.dict

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface
import android.text.Layout
import android.text.SpannableString
import android.text.Spanned
import android.text.StaticLayout
import android.text.TextDirectionHeuristics
import android.text.TextPaint
import android.text.style.MetricAffectingSpan
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.math.ceil

/** Source-only controls for the actual native kernel; no rendered-TH acceptance is implied. */
@RunWith(AndroidJUnit4::class)
class NativeInlineStyleDeviceTest {
    private class SnapshotPaint(val snapshot: TextPaint, val anchorState: (() -> Boolean)? = null) :
        MetricAffectingSpan(), NativeInlineSafePaintSpan, NativeMayUnderline {
        override val mayUnderline: Boolean get() = snapshot.isUnderlineText || anchorState != null
        override fun updateMeasureState(paint: TextPaint) { paint.set(snapshot) }
        override fun updateDrawState(paint: TextPaint) {
            paint.set(snapshot)
            anchorState?.let { paint.isUnderlineText = it() }
        }
    }

    private fun paint(size: Float) = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
        textSize = size; typeface = Typeface.MONOSPACE; color = Color.BLACK
    }

    private fun range(source: SpannableString, span: Any, start: Int = 0, end: Int = source.length) {
        source.setSpan(span, start, end, if (start == end) Spanned.SPAN_MARK_MARK else Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
    }

    private fun bounds(paint: TextPaint, height: Float, shift: Float = paint.baselineShift.toFloat()): Pair<Float, Float> {
        val fm = paint.fontMetrics
        val halfLeading = (height - (fm.descent - fm.ascent)) / 2f
        return fm.ascent - halfLeading + shift to fm.descent + halfLeading + shift
    }

    private fun refused(message: String, work: () -> Unit) {
        try { work(); fail("Expected explicit native refusal: $message") }
        catch (failure: UnsupportedFloatLayout) { assertEquals(message, failure.message) }
    }

    @Test fun everyWrapUsesIndependentDeclaringMetricsAndDistinctEmptyOwnersWithoutBorrowedText() {
        val root = paint(20f)
        val child = paint(40f)
        val declaring = paint(16f).apply { baselineShift = -12 }
        val source = SpannableString("AAAA AAAA AAAA")
        range(source, SnapshotPaint(child))
        val rootRun = NativeRunLineMetrics(NativePrimaryFontMetrics.from(root), NativeLineHeightPolicy.Pixels(20f), true)
        range(source, rootRun)
        range(source, NativeAuthoredInlineMetrics(NativePrimaryFontMetrics.from(child),
            NativeLineHeightPolicy.Pixels(4f), NativePrimaryFontMetrics.from(declaring)))
        val expected = listOf(bounds(root, 20f), bounds(child, 4f), bounds(declaring, 4f))
        val expectedHeight = expected.maxOf { it.second } - expected.minOf { it.first }
        val geometry = NativeFloatGeometry.build(source, root, 100, emptyList())
        assertTrue(geometry.shapedLineCount > 2)
        for (line in 0 until geometry.shapedLineCount) assertEquals(expectedHeight, geometry.usedLineHeight(line), .001f)
        assertTrue("The replaced child height must not retain its inherited 40px contribution", expectedHeight < 40f)
        assertEquals(source.toString(), geometry.text.toString())
        assertEquals(1, source.getSpans(0, source.length, NativeRunLineMetrics::class.java).size)

        source.removeSpan(rootRun)
        range(source, NativeRunLineMetrics(NativePrimaryFontMetrics.from(root), NativeLineHeightPolicy.Normal, true))
        refused("Authored inline height with mixed native normal owners is unavailable") {
            NativeFloatGeometry.build(source, root, 100, emptyList())
        }
        source.getSpans(0, source.length, NativeRunLineMetrics::class.java).forEach(source::removeSpan)
        range(source, rootRun)
        assertEquals(expectedHeight, NativeFloatGeometry.build(source, root, 100, emptyList()).usedLineHeight(0), .001f)

        val points = SpannableString("WW")
        range(points, NativeRunLineMetrics(NativePrimaryFontMetrics.from(root), NativeLineHeightPolicy.Pixels(10f), true))
        val owners = (0 until 7).map { index -> NativeAuthoredInlineMetrics(
            NativePrimaryFontMetrics.from(root).copy(baselineShift = -index.toFloat()), NativeLineHeightPolicy.Pixels(40f)) }
        owners.forEach { range(points, it, 1, 1) }
        val pointGeometry = NativeFloatGeometry.build(points, root, ceil(root.measureText("W")).toInt(), emptyList())
        assertEquals(2, pointGeometry.shapedLineCount)
        assertEquals(10f, pointGeometry.usedLineHeight(0), .001f)
        assertEquals(46f, pointGeometry.usedLineHeight(1), .001f)
        assertEquals(7, (pointGeometry.text as Spanned).getSpans(0, 2, NativeAuthoredInlineMetrics::class.java).size)
        assertEquals("WW", pointGeometry.text.toString())
        assertEquals(2, pointGeometry.text.length)

        val empty = SpannableString("")
        owners.forEach { range(empty, nativeInlineStyleSpanCopy(it)) }
        val emptyGeometry = NativeFloatGeometry.build(empty, paint(80f), 100, emptyList())
        assertEquals("", emptyGeometry.text.toString())
        assertTrue(emptyGeometry.nodes.isEmpty())
        assertTrue(emptyGeometry.rectsForRange(0, 0).isEmpty())
        assertEquals(46f, emptyGeometry.textBottom, .001f)
        assertEquals(46f, emptyGeometry.caretRect(0).height(), .001f)
        val retained = (emptyGeometry.text as Spanned).getSpans(0, 0, NativeAuthoredInlineMetrics::class.java)
        assertEquals(7, retained.size)
        retained.forEachIndexed { index, owner -> assertNotSame(owners[index], owner) }
    }

    @Test fun fractionalBaselineSharesActualPaintSelectionCharacterBoundsAndRefusesUnownedNormalOrBackground() {
        val root = paint(20f)
        val shifted = TextPaint(root).apply { baselineShift = -2 }
        fun source(shift: Float, policy: NativeLineHeightPolicy, background: Int = 0): SpannableString = SpannableString("ABCD").also {
            range(it, NativeRunLineMetrics(NativePrimaryFontMetrics.from(root), policy, true))
            range(it, SnapshotPaint(TextPaint(shifted).apply { baselineShift = shift.toInt(); bgColor = background }), 1, 3)
            range(it, NativeAuthoredInlineMetrics(NativePrimaryFontMetrics.from(shifted).copy(baselineShift = shift), policy), 1, 3)
            range(it, NativeAuthoredBaselineShift(shift), 1, 3)
        }
        val original = source(-2.25f, NativeLineHeightPolicy.Pixels(24f))
        var activations = 0
        val geometry = NativeFloatGeometry.build(original, root, 300, emptyList(), nodeFactory = { owner ->
            listOf(FloatInteractionNode(8, FloatInteractionKind.LINK, 1, 3, owner.rectsForRange(1, 3),
                "BC", null, { activations++ }))
        })
        val baseline = geometry.baselineForOffset(0)
        assertEquals(-2.25f, geometry.baselineForOffset(1) - baseline, .001f)
        val expectedTop = baseline + shifted.fontMetrics.ascent - 2.25f
        val expectedBottom = baseline + shifted.fontMetrics.descent - 2.25f
        geometry.characterRects(1, 2).forEach { rect ->
            assertNotNull(rect); assertEquals(expectedTop, rect!!.top, .001f); assertEquals(expectedBottom, rect.bottom, .001f)
        }
        assertEquals(expectedTop, geometry.caretRect(1).top, .001f)
        assertEquals(expectedBottom, geometry.caretRect(1).bottom, .001f)
        val hit = geometry.rectsForRange(1, 3).first()
        geometry.interactionNodeAt(hit.centerX(), hit.centerY())!!.onClick!!.invoke()
        assertEquals(1, activations)
        assertTrue(geometry.offsetForPosition(hit.centerX(), hit.centerY()) in 1..3)
        assertEquals("BC", geometry.text.subSequence(1, 3).toString())

        // An independent native glyph dispatch uses the unchanged metric-run context and
        // native advances; only the covered run's physical baseline has a fractional offset.
        val shaped = StaticLayout.Builder.obtain(original, 0, original.length, root, 300)
            .setIncludePad(true).setTextDirection(TextDirectionHeuristics.LTR)
            .setBreakStrategy(Layout.BREAK_STRATEGY_SIMPLE).setHyphenationFrequency(Layout.HYPHENATION_FREQUENCY_NONE).build()
        val expected = Bitmap.createBitmap(360, 160, Bitmap.Config.ARGB_8888)
        val actual = Bitmap.createBitmap(360, 160, Bitmap.Config.ARGB_8888)
        try {
            Canvas(expected).apply {
                translate(24f, 60f)
                drawTextRun("ABCD", 0, 1, 0, 1, shaped.getPrimaryHorizontal(0), baseline, false, root)
                drawTextRun("ABCD", 1, 3, 1, 3, shaped.getPrimaryHorizontal(1), baseline - 2.25f, false, shifted)
                drawTextRun("ABCD", 3, 4, 3, 4, shaped.getPrimaryHorizontal(3), baseline, false, root)
            }
            Canvas(actual).apply { translate(24f, 60f); geometry.paint(this) }
            val wanted = pixels(expected); val found = pixels(actual)
            assertTrue(wanted.count { Color.alpha(it) != 0 } > 20)
            assertArrayEquals(wanted, found)
            assertNotNull(geometry.extents.ink)
        } finally { expected.recycle(); actual.recycle() }

        refused("Fractional authored baseline with native normal line height is unavailable") {
            NativeFloatGeometry.build(source(-2.25f, NativeLineHeightPolicy.Normal), root, 300, emptyList())
        }
        assertEquals("ABCD", NativeFloatGeometry.build(source(-2f, NativeLineHeightPolicy.Normal), root, 300, emptyList()).text.toString())
        for (shift in listOf(-2f, -2.25f)) refused("Authored baseline with a character background is unavailable") {
            NativeFloatGeometry.build(source(shift, NativeLineHeightPolicy.Pixels(24f), Color.YELLOW), root, 300, emptyList())
        }
        val inherited = source(-2f, NativeLineHeightPolicy.Pixels(24f))
        inherited.getSpans(1, 3, SnapshotPaint::class.java).forEach { inherited.removeSpan(it) }
        refused("Authored baseline with a character background is unavailable") {
            NativeFloatGeometry.build(inherited, TextPaint(root).apply { bgColor = Color.YELLOW }, 300, emptyList())
        }
        assertEquals("ABCD", NativeFloatGeometry.build(source(0f, NativeLineHeightPolicy.Pixels(24f), Color.YELLOW), root, 300, emptyList()).text.toString())
        assertEquals(-2.25f, NativeFloatGeometry.build(original, root, 300, emptyList()).baselineForOffset(1) - baseline, .001f)
    }

    @Test fun dottedOwnerSurvivesAnchorUnderlineChangesAndAutoUsesNativeSmallFontWithoutInventingZeroInk() {
        val root = paint(22f)
        var anchorUnderline = false
        val source = SpannableString("Latin \u05d0\u05d1\u05d2 more words across wraps")
        range(source, SnapshotPaint(root) { anchorUnderline })
        range(source, NativeRunLineMetrics(NativePrimaryFontMetrics.from(root), NativeLineHeightPolicy.Pixels(28f), true))
        val decoration = NativeAuthoredUnderline(InlineUnderlineStyle.Dotted, Color.RED, .5f)
        range(source, decoration)
        val geometry = NativeFloatGeometry.build(source, root, 150, emptyList())
        assertTrue(geometry.shapedLineCount > 1)
        fun redInk(): IntArray {
            val bitmap = Bitmap.createBitmap(240, 240, Bitmap.Config.ARGB_8888)
            return try {
                Canvas(bitmap).apply { translate(20f, 40f); geometry.paint(this) }
                // Black anchor ink can change destination alpha. Compare the actual
                // premultiplied red contribution, allowing only 8-bit conversion error.
                pixels(bitmap).map { color -> (Color.red(color) * Color.alpha(color) + 127) / 255 }.toIntArray()
            } finally { bitmap.recycle() }
        }
        val unvisited = redInk()
        assertTrue(unvisited.any { it > 0 })
        anchorUnderline = true
        assertTrue(unvisited.zip(redInk()).all { (a, b) -> kotlin.math.abs(a - b) <= 1 })
        anchorUnderline = false
        assertArrayEquals(unvisited, redInk())
        assertEquals(source.toString(), geometry.text.toString())
        assertNotNull(geometry.extents.ink)

        fun underlineBounds(size: Float, thickness: Float?, authored: Boolean): NativeFloatBounds? {
            val p = paint(size)
            val s = SpannableString("MMMM")
            range(s, SnapshotPaint(TextPaint(p).apply { isUnderlineText = !authored }))
            if (authored) range(s, NativeAuthoredUnderline(InlineUnderlineStyle.Dotted, Color.RED, thickness))
            val native = StaticLayout.Builder.obtain(s, 0, s.length, p, 100).setIncludePad(true).build()
            return NativeLinePainter(native).decorationBounds(listOf(NativeLinePaintPlacement(0, 40f)))
        }
        val nativeAuto = underlineBounds(2f, null, false)!!
        val authoredAuto = underlineBounds(2f, null, true)!!
        assertEquals(nativeAuto.top, authoredAuto.top, .001f)
        assertEquals(nativeAuto.bottom, authoredAuto.bottom, .001f)
        val explicit = underlineBounds(2f, .25f, true)!!
        assertEquals(.25f, explicit.bottom - explicit.top, .001f)
        assertTrue(authoredAuto.bottom - authoredAuto.top > .25f)
        assertNull(underlineBounds(2f, 0f, true))
        assertNull(underlineBounds(0f, null, true))
        source.removeSpan(decoration)
        range(source, decoration.copy(thickness = 0f))
        val zero = NativeFloatGeometry.build(source, root, 150, emptyList())
        val bitmap = Bitmap.createBitmap(240, 240, Bitmap.Config.ARGB_8888)
        try {
            Canvas(bitmap).apply { translate(20f, 40f); zero.paint(this) }
            assertFalse(pixels(bitmap).any { Color.red(it) > Color.green(it) + 20 && Color.red(it) > Color.blue(it) + 20 })
        } finally { bitmap.recycle() }
    }

    private fun pixels(bitmap: Bitmap) = IntArray(bitmap.width * bitmap.height).also {
        bitmap.getPixels(it, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
    }
}
