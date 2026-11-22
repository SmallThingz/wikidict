package app.smallthingz.dict

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface
import android.graphics.text.LineBreaker
import android.graphics.text.MeasuredText
import android.icu.text.BreakIterator
import android.text.SpannableString
import android.text.Spanned
import android.text.SpannedString
import android.text.TextDirectionHeuristic
import android.text.TextDirectionHeuristics
import android.text.TextPaint
import android.text.style.MetricAffectingSpan
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.util.Locale
import kotlin.math.ceil
import kotlin.math.floor

/** Direct native controls; actual Compose source lowering is covered by its own suite. */
@RunWith(AndroidJUnit4::class)
class NativeInlineAtomicAutoBoxDeviceTest {
    private val padding = NativeInlineBoxEdges(.75f, .5f, .25f, .5f)
    private val margins = NativeInlineBoxEdges(1.25f, .375f, .5f, .125f)
    private val edge = NativeInlineBoxBorder(1f, Color.BLACK)
    private val borders = NativeInlineBoxBorders(edge, edge, edge, edge)
    private val lineHeight = 19.5f
    private fun paint(scale: Float = 1f) = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
        typeface = Typeface.SANS_SERIF; textSize = 20f * scale
        textLocale = Locale.ENGLISH; color = Color.BLUE
    }
    private class SourcePaint(private val snapshot: TextPaint) : MetricAffectingSpan(), NativeInlineSafePaintSpan {
        override fun updateMeasureState(paint: TextPaint) { paint.set(snapshot) }
        override fun updateDrawState(paint: TextPaint) { paint.set(snapshot) }
    }
    private data class Fixture(val source: Spanned, val prepared: NativeRubyPreparedSource,
        val projection: RubyTextProjection, val owner: Span, val child: Span, val range: RubyTextRange,
        val key: NativeInlineBoxOwner, val rootPaint: TextPaint, val childPaint: TextPaint,
        val direction: TextDirectionHeuristic) {
        fun shape(width: Float, gutter: Float = 0f): NativeFloatGeometry = NativeFloatGeometry.build(
            source, rootPaint, floor(width).toInt(), emptyList(), textDirection = direction,
            insets = NativeTextInsets(left = gutter), includeFontPadding = false, exactAvailableWidth = width)
    }
    private fun fixture(body: String, intrinsic: InlineBoxIntrinsicWrap = InlineBoxIntrinsicWrap.Anywhere,
        wrap: TextWrap = TextWrap.BreakWord, maximum: Float = 90.5f, prefix: String = "", suffix: String = "",
        boxSizing: ContainerBoxSizing = ContainerBoxSizing.ContentBox, rtl: Boolean = false,
        childBackground: Boolean = false): Fixture {
        val rootPaint = paint()
        val declaring = paint(.81f).apply { bgColor = Color.GREEN }
        val childPaint = paint(.81f).apply { bgColor = if (childBackground) Color.YELLOW else 0 }
        val direction = if (rtl) TextDirectionHeuristics.RTL else TextDirectionHeuristics.LTR
        val normalized = InlineTextStyle(fontNormalized = true)
        val child = Span("text", body, fontScale = .81f, fontScaleBasis = FontScaleBasis.NormalBody,
            fontFamily = ContainerFontFamily.SansSerif, inlineStyle = normalized,
            background = "#ffff00".takeIf { childBackground })
        fun px(value: Float) = StyleLength(StyleLengthUnit.Px, value)
        fun edges(value: NativeInlineBoxEdges) = StyleEdges(px(value.top), px(value.right), px(value.bottom), px(value.left))
        val solid = InlineBoxBorderEdge.Solid(px(1f), InlineBoxColor.Rgb("#000000"))
        val policy = InlineBoxAtomicAutoLayout(px(maximum), edges(margins), boxSizing,
            InlineBoxOverlayTextAlign.Start, wrap, intrinsic,
            InlineLineHeight.Computed(InlineComputedLength(lineHeight, FontScaleBasis.CssPx)))
        val owner = Span("text", "", fontScale = .81f, fontScaleBasis = FontScaleBasis.NormalBody,
            fontFamily = ContainerFontFamily.SansSerif, inlineStyle = normalized, background = "#00ff00",
            inlineBoxGroup = InlineBoxGroup(edges(padding), InlineBoxBorderEdges(solid, solid, solid, solid),
                spans = listOf(child), atomicAutoLayout = policy))
        val spans = listOf(Span("text", prefix), owner, Span("text", suffix))
        val projection = rubyGraphicalProjection(spans)
        val range = projection.ranges.single { it.role == RubyTextRole.BoxGroup }
        val key = NativeInlineBoxOwner(owner, range.path)
        val auto = NativeInlineAtomicAutoBoxFormat(maximum, margins, boxSizing,
            InlineBoxOverlayTextAlign.Start, wrap, intrinsic, NativeLineHeightPolicy.Pixels(lineHeight))
        val format = NativeRubyGroupFormat(declaring, direction, NativeLineHeightPolicy.Pixels(40f),
            box = NativeInlineBoxFormat(key, padding, borders, emptyList(), atomicAutoLayout = auto))
        val source = SpannableString(projection.text)
        source.setSpan(NativeRunLineMetrics(NativePrimaryFontMetrics.from(rootPaint),
            NativeLineHeightPolicy.Pixels(40f), strut = true), 0, source.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        projection.ranges.filter { it.span != null && it.role != RubyTextRole.BoxGroup && it.start < it.end }.forEach {
            source.setSpan(SourcePaint(if (it.span === child) childPaint else rootPaint),
                it.start, it.end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
        val prepared = NativeRubyPreparedSource(projection, SpannedString(source), rootPaint, direction,
            mapOf(range.path to format))
        source.setSpan(prepared, 0, source.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        return Fixture(SpannedString(source), prepared, projection, owner, child, range, key, rootPaint, childPaint, direction)
    }
    private fun atom(value: NativeFloatGeometry): NativeInlineAtomicBox = value.nativeRubyShapingSource
        .getSpans(0, value.nativeRubyShapingSource.length, NativeInlineAtomicBox::class.java).single()
    private fun measured(body: String, paint: TextPaint, rtl: Boolean = false) = MeasuredText.Builder(body.toCharArray())
        .setComputeLayout(true).appendStyleRun(paint, body.length, rtl).build()
    private fun lines(measured: MeasuredText, width: Float) = LineBreaker.Builder()
        .setBreakStrategy(LineBreaker.BREAK_STRATEGY_SIMPLE)
        .setHyphenationFrequency(LineBreaker.HYPHENATION_FREQUENCY_NONE).build()
        .computeLineBreaks(measured, LineBreaker.ParagraphConstraints().apply { setWidth(width) }, 0)

    @Test fun autoAtomUsesExplicitMinMaxFullContainingWidthAndFreshResizeGeometry() {
        // Combining and supplementary units must remain whole, measured in their
        // original full shaping context rather than summing isolated UTF-16 chars.
        val body = "A\u0301B\ud83d\ude00CDEFGHIJKLMNO"
        val value = fixture(body)
        val native = measured(body, value.childPaint)
        val clusters = BreakIterator.getCharacterInstance(Locale.ENGLISH).apply { setText(body) }
        val ends = mutableListOf<Int>()
        var end = clusters.first()
        while (end != BreakIterator.DONE) { if (end > 0) ends += end; end = clusters.next() }
        var first = 0
        val clusterMinimum = ends.maxOf { last -> native.getWidth(first, last).also { first = last } }
        assertFalse(ends.contains(1)); assertFalse(ends.contains(4))
        val maximum = native.getWidth(0, body.length)
        assertTrue(maximum > 90.5f)
        // Horizontal padding+border=3 and margins=.5, independently known here.
        val intrinsic = nativeFloatRowIntrinsicWidths(value.source, value.rootPaint, value.direction, false)
        assertEquals(clusterMinimum + 3.5f, intrinsic.minimum, .001f)
        assertEquals(94f, intrinsic.maximum, .001f)
        val normal = fixture(body, intrinsic = InlineBoxIntrinsicWrap.Normal)
        val normalIntrinsic = nativeFloatRowIntrinsicWidths(normal.source, normal.rootPaint, normal.direction, false)
        assertEquals(94f, normalIntrinsic.minimum, .001f)
        assertEquals(intrinsic.maximum, normalIntrinsic.maximum, .001f)
        try {
            nativeRubyLayout(value.source, value.rootPaint, value.direction, exactAdvances = true)
            fail("A layout call without actual containing C must not borrow an intrinsic width")
        } catch (expected: UnsupportedFloatLayout) { assertTrue(expected.message.orEmpty().contains("containing content width")) }

        val narrow = value.shape(80f)
        assertEquals(76.5f, atom(narrow).allocation.contentWidth, .001f)
        val withGutter = value.shape(80f, 12.25f)
        assertEquals(76.5f, atom(withGutter).allocation.contentWidth, .001f)
        assertSame(atom(narrow).child.geometry, atom(withGutter).child.geometry)
        val wide = value.shape(240.25f)
        assertEquals(90.5f, atom(wide).allocation.contentWidth, 0f)
        assertNotSame(atom(narrow).child.geometry, atom(wide).child.geometry)
        assertSame(atom(wide).child.geometry, atom(value.shape(260.5f)).child.geometry)
        val recovered = value.shape(80f)
        assertEquals(atom(narrow).allocation, atom(recovered).allocation)
        assertEquals(body, recovered.text.toString())
        assertSame(value.child, value.projection.ranges.single { it.span === value.child }.span)
        assertTrue(recovered.nodes.isEmpty())
        assertFalse((atom(recovered) as Any) is android.text.style.ReplacementSpan)

        val child = atom(recovered).child.geometry as NativeFloatGeometry
        val expectedLines = lines(native, 76.5f)
        assertTrue(expectedLines.lineCount > 1)
        assertEquals(expectedLines.lineCount, child.shapedLineCount)
        assertEquals(expectedLines.lineCount * lineHeight, atom(recovered).allocation.contentHeight, .01f)
        val fm = value.childPaint.fontMetrics
        val firstBaseline = -fm.ascent + (lineHeight - (fm.descent - fm.ascent)) / 2f
        val lastBaseline = firstBaseline + (expectedLines.lineCount - 1) * lineHeight
        assertEquals(lastBaseline, checkNotNull(child.textBaselines?.last), .01f)
        assertEquals(-lastBaseline - 3f, atom(recovered).metrics.top, .01f)
        first = 0
        for (line in 0 until expectedLines.lineCount) {
            val last = expectedLines.getLineBreakOffset(line)
            assertTrue(ends.contains(last))
            assertEquals(first to last, child.nativeRangeOfLine(line))
            if (line + 1 < expectedLines.lineCount) {
                val up = NativeTextCaret(last, NativeTextAffinity.Upstream)
                val down = NativeTextCaret(last)
                assertTrue(recovered.caretRect(up).top < recovered.caretRect(down).top)
                assertEquals(listOf(first to last), recovered.visualLineRanges(up))
            }
            first = last
        }
        assertEquals(body.length, recovered.characterRects(0, body.length).size)
        val trailing = NativeTextCaret(body.length, NativeTextAffinity.Upstream)
        val trailingRect = recovered.caretRect(trailing)
        assertEquals(body.length, recovered.caretAt(trailingRect.left, trailingRect.centerY()).offset)

        // Prior inline text consumes the row, never the atom's containing width.
        val prefixed = fixture(body, prefix = "P ".repeat(8), suffix = " Z")
        val moved = prefixed.shape(200f)
        assertEquals(90.5f, atom(moved).allocation.contentWidth, 0f)
        assertTrue(moved.nativeRubyRaw.nativeLineAt(moved.nativeRubyRawOffset(prefixed.range.start)) > 0)
        assertEquals(prefixed.projection.text, moved.text.toString())
        val rtl = fixture(body, rtl = true).shape(80f)
        assertEquals(-1, (atom(rtl).child.geometry as NativeFloatGeometry).nativeRubyParagraphDirection)
        assertEquals(76.5f, atom(rtl).allocation.contentWidth, .001f)
    }

    @Test fun normalWrapAndZeroContentBorderBoxKeepRealOverflowAndAutoLineHeight() {
        val body = "ABCDEFGHIJKLMNO"
        val normal = fixture(body, intrinsic = InlineBoxIntrinsicWrap.Normal, wrap = TextWrap.Normal,
            maximum = 30.25f, childBackground = true)
        val geometry = normal.shape(140.5f)
        val owned = atom(geometry)
        val child = owned.child.geometry as NativeFloatGeometry
        assertEquals(30.25f, owned.allocation.contentWidth, 0f)
        assertEquals(1, child.shapedLineCount)
        assertEquals(lineHeight, owned.allocation.contentHeight, .01f)
        assertEquals(0 to body.length, child.nativeRangeOfLine(0))
        assertTrue(normal.childPaint.measureText(body) > owned.allocation.contentWidth)
        val ownerBox = checkNotNull(geometry.inlineBoxGroupRects(normal.key, normal.range.start, normal.range.end)).single()
        val ink = checkNotNull(geometry.extents.ink)
        assertTrue(ink.right > ownerBox.right)
        val left = floor(minOf(0f, ink.left)).toInt() - 2
        val top = floor(minOf(0f, ink.top)).toInt() - 2
        val bitmap = Bitmap.createBitmap(ceil(maxOf(geometry.width.toFloat(), ink.right)).toInt() - left + 2,
            ceil(maxOf(geometry.height.toFloat(), ink.bottom)).toInt() - top + 2, Bitmap.Config.ARGB_8888)
        try {
            val canvas = Canvas(bitmap); canvas.translate(-left.toFloat(), -top.toFloat()); geometry.paint(canvas)
            var blueOutside = false; var yellowOutside = false
            for (y in 0 until bitmap.height) for (x in 0 until bitmap.width) if (x + left > ownerBox.right + 1f) {
                val pixel = bitmap.getPixel(x, y)
                // The only paint here is the real blue glyph over its yellow child
                // background. Fractional antialiasing need not produce an opaque blue pixel.
                blueOutside = blueOutside || Color.blue(pixel) > 0
                yellowOutside = yellowOutside || pixel == Color.YELLOW
            }
            assertTrue("Real child glyph overflow stays painted", blueOutside)
            assertTrue("Real child background overflow stays painted", yellowOutside)
        } finally { bitmap.recycle() }
        val emergency = fixture(body, intrinsic = InlineBoxIntrinsicWrap.Normal, wrap = TextWrap.BreakWord,
            maximum = 30.25f).shape(140.5f)
        val expected = lines(measured(body, normal.childPaint), 30.25f)
        assertTrue(expected.lineCount > 1)
        assertEquals(expected.lineCount, (atom(emergency).child.geometry as NativeFloatGeometry).shapedLineCount)
        assertEquals(expected.lineCount * lineHeight, atom(emergency).allocation.contentHeight, .01f)

        // Positive border-box maximum below the real edges floors content to zero.
        // Normal's genuine unbreakable word still supplies its real line and ink.
        val zeroSource = fixture("A", intrinsic = InlineBoxIntrinsicWrap.Normal, wrap = TextWrap.Normal,
            maximum = 1f, boxSizing = ContainerBoxSizing.BorderBox)
        val zero = zeroSource.shape(80f)
        assertEquals(0f, atom(zero).allocation.contentWidth, 0f)
        assertEquals(3f, atom(zero).allocation.borderWidth, 0f)
        assertEquals(3.5f, atom(zero).advance, 0f)
        assertEquals(lineHeight, atom(zero).allocation.contentHeight, .01f)
        assertEquals("A", zero.text.toString())
        assertNotNull(zero.characterRects(0, 1).single())
        assertTrue(checkNotNull(atom(zero).child.geometry.extents.ink).right > 0f)
        val whitespace = fixture("  \u00a0 A  ", intrinsic = InlineBoxIntrinsicWrap.Normal,
            wrap = TextWrap.Normal, maximum = 200f)
        val whitespaceGeometry = whitespace.shape(240f)
        assertEquals("  \u00a0 A  ", whitespaceGeometry.text.toString())
        assertEquals(whitespace.childPaint.measureText("\u00a0 A"), atom(whitespaceGeometry).allocation.contentWidth, .001f)
        assertEquals(whitespace.projection.text.length,
            whitespaceGeometry.characterRects(0, whitespace.projection.text.length).size)
        assertTrue(atom(whitespaceGeometry).allocation.contentWidth > whitespace.childPaint.measureText(" A"))
        val recovered = normal.shape(140.5f)
        assertEquals(owned.allocation, atom(recovered).allocation)
        assertEquals(body, recovered.text.toString())
    }
}
