package app.smallthingz.dict

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Typeface
import android.graphics.text.MeasuredText
import android.graphics.text.TextRunShaper
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

/** Native geometry/paint controls. Actual Compose lowering and View interaction are
 * exercised separately; these fixtures use explicitly chosen complete font snapshots. */
@RunWith(AndroidJUnit4::class)
class NativeInlineIntrinsicLinesDeviceTest {
    private class SourcePaint(private val snapshot: TextPaint) : MetricAffectingSpan(), NativeInlineSafePaintSpan {
        override fun updateMeasureState(paint: TextPaint) { paint.set(snapshot) }
        override fun updateDrawState(paint: TextPaint) { paint.set(snapshot) }
    }
    private val zero = NativeInlineBoxEdges(0f, 0f, 0f, 0f)
    private val noBorder = NativeInlineBoxBorder(0f, 0)
    private val noBorders = NativeInlineBoxBorders(noBorder, noBorder, noBorder, noBorder)
    private fun paint(size: Float, color: Int) = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
        typeface = Typeface.SANS_SERIF; textSize = size; textLocale = Locale.ENGLISH; this.color = color
    }
    private data class Fixture(val source: Spanned, val prepared: NativeRubyPreparedSource,
        val projection: RubyTextProjection, val owner: Span, val child: Span, val range: RubyTextRange,
        val box: NativeInlineBoxOwner, val rootPaint: TextPaint, val ownerPaint: TextPaint,
        val direction: TextDirectionHeuristic, val margin: Float, val align: Float) {
        fun shape(width: Float = 160.25f): NativeFloatGeometry = NativeFloatGeometry.build(source, rootPaint,
            floor(width).toInt(), emptyList(), textDirection = direction,
            includeFontPadding = false, exactAvailableWidth = width)
    }
    private fun fixture(scale: Float = .72f, density: Float = 1f, zoom: Float = 1f,
        heightFactor: Float? = 1f, marginEm: Float = -.3f, alignEm: Float = -.4f,
        digit: String = "2", prefix: String = "H", suffix: String = "O", noWrap: Boolean = true,
        direction: TextDirectionHeuristic = TextDirectionHeuristics.LTR,
        omitBreakMetadata: Boolean = false): Fixture {
        val rootPaint = paint(20f * density * zoom, Color.BLACK)
        val ownerPaint = paint(rootPaint.textSize * scale, Color.RED)
        val normalized = InlineTextStyle(fontNormalized = true)
        val snapshot = InlineFontSnapshot(fontScale = scale, fontScaleBasis = FontScaleBasis.NormalBody,
            fontNormalized = true, fontFamily = ContainerFontFamily.SansSerif)
        val height = heightFactor?.let { InlineLineHeight.FontRelative(it, snapshot) }
        val model = InlineBoxIntrinsicLinesLayout(
            marginBottom = InlineBoxSignedLength(StyleLengthUnit.Em, marginEm),
            verticalAlign = InlineBoxSignedLength(StyleLengthUnit.Em, alignEm),
            lineHeight = height, textAlign = InlineBoxOverlayTextAlign.Left, wrap = TextWrap.Normal,
            lines = listOf(InlineBoxIntrinsicLine(0, InlineBoxIntrinsicLineKind.Sup, true),
                InlineBoxIntrinsicLine(1, InlineBoxIntrinsicLineKind.Sub, false)))
        val child = Span("text", digit, fontScale = scale, fontScaleBasis = FontScaleBasis.NormalBody,
            fontFamily = ContainerFontFamily.SansSerif, inlineStyle = normalized, foreground = "#ff0000")
        fun px() = StyleLength(StyleLengthUnit.Px, 0f)
        val owner = Span("text", "", fontScale = scale, fontScaleBasis = FontScaleBasis.NormalBody,
            fontFamily = ContainerFontFamily.SansSerif, inlineStyle = normalized, foreground = "#ff0000",
            inlineBoxGroup = InlineBoxGroup(StyleEdges(px(), px(), px(), px()),
                InlineBoxBorderEdges(InlineBoxBorderEdge.None, InlineBoxBorderEdge.None,
                    InlineBoxBorderEdge.None, InlineBoxBorderEdge.None), spans = listOf(child), intrinsicLinesLayout = model))
        val original = rubyGraphicalProjection(listOf(Span("text", prefix), owner, Span("text", suffix)))
        val projection = if (omitBreakMetadata) original.copy(ranges = original.ranges.filter {
            it.role != RubyTextRole.IntrinsicLineBreak }) else original
        val range = projection.ranges.single { it.role == RubyTextRole.BoxGroup }
        val box = NativeInlineBoxOwner(owner, range.path)
        val margin = nativeInlineIntrinsicSignedLength(model.marginBottom, ownerPaint.textSize, density)
        val align = nativeInlineIntrinsicSignedLength(model.verticalAlign, ownerPaint.textSize, density)
        val policy = heightFactor?.let { NativeLineHeightPolicy.Pixels(ownerPaint.textSize * it) }
            ?: NativeLineHeightPolicy.Normal
        val format = NativeRubyGroupFormat(ownerPaint, direction, NativeLineHeightPolicy.Pixels(rootPaint.textSize * 2f),
            box = NativeInlineBoxFormat(box, zero, noBorders, emptyList(),
                intrinsicLinesLayout = NativeInlineIntrinsicLinesFormat(margin, align, InlineBoxOverlayTextAlign.Left, policy)))
        val source = SpannableString(projection.text)
        source.setSpan(NativeRunLineMetrics(NativePrimaryFontMetrics.from(rootPaint),
            NativeLineHeightPolicy.Pixels(rootPaint.textSize * 2f), strut = true), 0, source.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        if (noWrap) source.setSpan(NativeAuthoredTextWrap(TextWrap.NoWrap, inheritedOwner = true,
            sourceLineStarts = listOf(0)), 0, source.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        projection.ranges.filter { it.span != null && it.role != RubyTextRole.BoxGroup && it.start < it.end }.forEach {
            source.setSpan(SourcePaint(if (it.span === child) ownerPaint else rootPaint),
                it.start, it.end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
        val prepared = NativeRubyPreparedSource(projection, SpannedString(source), rootPaint, direction,
            mapOf(range.path to format))
        source.setSpan(prepared, 0, source.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        return Fixture(SpannedString(source), prepared, projection, owner, child, range, box,
            rootPaint, ownerPaint, direction, margin, align)
    }
    private fun atom(geometry: NativeFloatGeometry): NativeInlineAtomicBox = geometry.nativeRubyShapingSource
        .getSpans(0, geometry.nativeRubyShapingSource.length, NativeInlineAtomicBox::class.java).single()
    private fun measuredDigit(paint: TextPaint, digit: String): Float = MeasuredText.Builder(digit.toCharArray())
        .setComputeLayout(true).appendStyleRun(paint, 1, false).build().getWidth(0, 1)

    @Test fun originalBrAndMeasuredDigitKeepTwoOwnerBandsWithSignedOuterPlacement() {
        for ((scale, density, zoom) in listOf(Triple(.72f, 1f, 1f), Triple(1.13f, 1.5f, 1.25f))) {
            val value = fixture(scale, density, zoom)
            val geometry = value.shape()
            val owned = atom(geometry)
            val child = owned.child.geometry as NativeFloatGeometry
            val size = value.ownerPaint.textSize
            val width = measuredDigit(value.ownerPaint, "2")
            val fm = value.ownerPaint.fontMetrics
            val firstBaseline = -fm.ascent + (size - (fm.descent - fm.ascent)) / 2f
            val lastBaseline = firstBaseline + size
            assertEquals("H\n2O", geometry.text.toString())
            assertEquals("H\ufffcO", geometry.nativeRubyShapingSource.toString())
            assertEquals(1, geometry.shapedLineCount)
            assertEquals(2, child.shapedLineCount)
            assertEquals("\n2", child.text.toString())
            assertEquals(0 to 1, child.nativeRangeOfLine(0))
            assertEquals(1 to 2, child.nativeRangeOfLine(1))
            assertEquals(firstBaseline, checkNotNull(child.textBaselines?.first), .002f)
            assertEquals(lastBaseline, checkNotNull(child.textBaselines?.last), .002f)
            assertEquals(2f * size, owned.allocation.contentHeight, .002f)
            assertEquals(width, owned.advance, .001f)
            assertEquals(width, owned.allocation.contentWidth, .001f)
            assertEquals(1.7f * size, owned.allocation.marginHeight, .003f)
            assertEquals(-lastBaseline + .4f * size, owned.child.y, .003f)
            assertEquals(owned.child.y, owned.metrics.top, .002f)
            assertEquals(2f * size - .3f * size - lastBaseline + .4f * size, owned.metrics.bottom, .003f)
            val widths = nativeFloatRowIntrinsicWidths(value.source, value.rootPaint, value.direction, false)
            val full = value.rootPaint.measureText("H") + width + value.rootPaint.measureText("O")
            assertEquals(full, widths.minimum, .003f); assertEquals(full, widths.maximum, .003f)
            assertSame(value.owner, value.projection.ranges.single { it.role == RubyTextRole.BoxGroup }.span)
            val leaf = value.projection.ranges.single { it.span === value.child }
            assertEquals(2, leaf.start); assertEquals(3, leaf.end)
            assertEquals("2", value.child.text)
            val br = value.projection.ranges.single { it.role == RubyTextRole.IntrinsicLineBreak }
            assertNull(br.span); assertEquals(1, br.start); assertEquals(2, br.end)
            assertEquals(4, geometry.characterRects(0, 4).size)
            assertTrue(geometry.isHardLineBreak(1))
            assertFalse(geometry.isHardLineBreak(0)); assertFalse(geometry.isHardLineBreak(2))
            assertFalse(geometry.isHardLineBreak(3))
            val beforeDigit = geometry.caretRect(NativeTextCaret(2))
            val afterDigit = geometry.caretRect(NativeTextCaret(3, NativeTextAffinity.Upstream))
            assertEquals(width, afterDigit.left - beforeDigit.left, .003f)
            assertTrue(geometry.caretRect(NativeTextCaret(1)).top < beforeDigit.top)
            assertEquals(2, geometry.caretAt(beforeDigit.left, beforeDigit.centerY()).offset)
            assertEquals(3, geometry.caretAt(afterDigit.left, afterDigit.centerY()).offset)
            assertEquals("\n2", geometry.text.subSequence(1, 3).toString())
            assertTrue(geometry.nodes.isEmpty())
            assertFalse((owned as Any) is android.text.style.ReplacementSpan)
            val narrow = value.shape(width / 2f)
            assertEquals(1, narrow.shapedLineCount) // Original enclosing nowrap remains one outer line.
            assertEquals(width, atom(narrow).advance, .001f)
            assertSame(child, atom(narrow).child.geometry)
            assertEquals(owned.allocation, atom(value.shape(240.75f)).allocation)
        }
        val base = atom(fixture(marginEm = 0f, alignEm = 0f).shape())
        val raised = atom(fixture(marginEm = 0f, alignEm = .4f).shape())
        val lowered = atom(fixture(marginEm = 0f, alignEm = -.4f).shape())
        val shift = 20f * .72f * .4f
        assertEquals(base.child.y - shift, raised.child.y, .002f)
        assertEquals(base.child.y + shift, lowered.child.y, .002f)
        assertEquals(base.allocation.contentHeight, raised.allocation.contentHeight, 0f)
        assertEquals(base.advance, lowered.advance, 0f)
    }

    @Test fun innerBrDoesNotSplitParentDirectionAndExplicitSmallHeightKeepsVisibleInk() {
        // Hebrew after the atom must resolve its inherited paragraph direction;
        // the internal LF cannot end that parent paragraph before its first strong text.
        val value = fixture(prefix = "(", suffix = "\u05d0", noWrap = false,
            direction = TextDirectionHeuristics.FIRSTSTRONG_LTR)
        val geometry = value.shape()
        assertEquals(-1, (atom(geometry).child.geometry as NativeFloatGeometry).nativeRubyParagraphDirection)
        assertEquals("(\n2\u05d0", geometry.text.toString())
        assertEquals(1, geometry.shapedLineCount)
        val realBoundary = fixture(prefix = "A\n(", suffix = "\u05d0", noWrap = false,
            direction = TextDirectionHeuristics.FIRSTSTRONG_LTR).shape()
        assertEquals(2, realBoundary.shapedLineCount)
        assertEquals(-1, (atom(realBoundary).child.geometry as NativeFloatGeometry).nativeRubyParagraphDirection)
        val tiny = fixture(heightFactor = .2f, marginEm = 0f, alignEm = 0f)
        val painted = tiny.shape()
        val owned = atom(painted)
        val child = owned.child.geometry as NativeFloatGeometry
        val height = tiny.ownerPaint.textSize * .2f
        assertEquals(2f * height, owned.allocation.contentHeight, .002f)
        assertEquals(height, checkNotNull(child.textBaselines?.last) - checkNotNull(child.textBaselines?.first), .002f)
        val ink = checkNotNull(owned.paintBounds)
        assertTrue(ink.top < owned.contentBounds.top || ink.bottom > owned.contentBounds.bottom)
        val outerInk = checkNotNull(painted.extents.ink)
        val left = floor(minOf(0f, outerInk.left)).toInt() - 2
        val top = floor(minOf(0f, outerInk.top)).toInt() - 2
        val bitmap = Bitmap.createBitmap(ceil(maxOf(painted.width.toFloat(), outerInk.right)).toInt() - left + 2,
            ceil(maxOf(painted.height.toFloat(), outerInk.bottom)).toInt() - top + 2, Bitmap.Config.ARGB_8888)
        try {
            val canvas = Canvas(bitmap); canvas.translate(-left.toFloat(), -top.toFloat()); painted.paint(canvas)
            val border = checkNotNull(painted.inlineBoxGroupRects(tiny.box, tiny.range.start, tiny.range.end)).single()
            var redOutside = false
            for (y in 0 until bitmap.height) for (x in 0 until bitmap.width) {
                val pixel = bitmap.getPixel(x, y)
                if (Color.red(pixel) > 0 && Color.green(pixel) == 0 && Color.blue(pixel) == 0 &&
                    (y + top < border.top || y + top >= border.bottom)) redOutside = true
            }
            assertTrue("Negative leading retains actual digit glyph overflow", redOutside)
        } finally { bitmap.recycle() }
    }

    @Test fun normalRetainsNativeEnvelopesAndInvalidSignedOrSourceGeometryRecovers() {
        val value = fixture(heightFactor = null, marginEm = 0f, alignEm = 0f)
        val owned = atom(value.shape())
        val width = measuredDigit(value.ownerPaint, "2")
        // Public native font and actual shaped-digit envelopes independently own
        // Normal. The empty row has primary metrics; the digit may add fallback.
        val fm = value.ownerPaint.fontMetrics
        val shaped = TextRunShaper.shapeTextRun("2", 0, 1, 0, 1, 0f, 0f, false, value.ownerPaint)
        val secondTop = minOf(fm.ascent, shaped.ascent)
        val secondBottom = maxOf(fm.descent, shaped.descent)
        val firstHeight = fm.descent - fm.ascent
        val child = owned.child.geometry as NativeFloatGeometry
        assertEquals(firstHeight + secondBottom - secondTop, owned.allocation.contentHeight, .002f)
        assertEquals(-fm.ascent, checkNotNull(child.textBaselines?.first), .002f)
        assertEquals(firstHeight - secondTop, checkNotNull(child.textBaselines?.last), .002f)
        fun rejects(value: Fixture, expected: String) {
            try { value.shape(); fail("Invalid geometry must not drop the original source") }
            catch (failure: UnsupportedFloatLayout) { assertTrue(failure.message.orEmpty().contains(expected)) }
            assertEquals("H\n2O", value.source.toString())
        }
        rejects(fixture(marginEm = -3f), "reverses")
        rejects(fixture(omitBreakMetadata = true), "original BR")
        val recovered = fixture(marginEm = 0f, alignEm = 0f).shape()
        assertEquals("H\n2O", recovered.text.toString())
        assertEquals(2f * 20f * .72f, atom(recovered).allocation.contentHeight, .002f)
        assertEquals(width, atom(recovered).advance, .001f)
    }
}
