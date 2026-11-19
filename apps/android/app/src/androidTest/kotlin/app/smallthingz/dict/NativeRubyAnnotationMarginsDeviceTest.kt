package app.smallthingz.dict

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface
import android.text.SpannableString
import android.text.Spanned
import android.text.SpannedString
import android.text.TextDirectionHeuristics
import android.text.TextPaint
import android.text.style.MetricAffectingSpan
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.util.Locale
import kotlin.math.ceil
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

/** Controlled native fonts and source owners; actual Compose lowering has its own control. */
@RunWith(AndroidJUnit4::class)
class NativeRubyAnnotationMarginsDeviceTest {
    private fun style() = InlineTextStyle(fontNormalized = true)
    private fun owner(scale: Float = 1f) = RubyOwner(InlineFontSnapshot(fontScale = scale,
        fontScaleBasis = FontScaleBasis.NormalBody, fontNormalized = true, language = "ja"),
        direction = "ltr", inlineStyle = style())
    private fun leaf(text: String, scale: Float = 1f, color: String = "#0000ff", target: String = "") =
        Span(if (target.isEmpty()) "text" else "link", text, target, fontScale = scale,
            fontScaleBasis = FontScaleBasis.NormalBody, language = "ja", foreground = color, inlineStyle = style())
    private fun base(span: Span) = RubyBase(owner(), emptyList(), listOf(span))
    private fun annotation(spans: List<Span>, scale: Float = .6f, level: Long = 0,
        start: Long = 0, margins: RubyAnnotationMargins? = null, gap: List<Span> = emptyList()) =
        RubyAnnotation(start, 1, level, owner(scale), gap, spans, emptyList(), emptyList(), false, margins)
    private fun ruby(bases: List<RubyBase>, annotations: List<RubyAnnotation>) = Span("text", "",
        direction = "ltr", fontScale = 1f, fontScaleBasis = FontScaleBasis.NormalBody,
        language = "ja", inlineStyle = style(), ruby = Ruby(listOf(RubySegment(emptyList(), bases, annotations))))
    private fun margins(top: Float, bottom: Float, unit: StyleLengthUnit = StyleLengthUnit.Em) =
        RubyAnnotationMargins(StyleLength(unit = unit, value = top), StyleLength(unit = unit, value = bottom))
    private fun paint(scale: Float = 1f, color: Int = Color.BLUE) = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
        typeface = Typeface.MONOSPACE; textSize = 24f * scale; textLocale = Locale.JAPANESE; this.color = color
    }
    private class SourcePaint(private val value: TextPaint) : MetricAffectingSpan(), NativeInlineSafePaintSpan {
        override fun updateMeasureState(paint: TextPaint) { paint.set(value) }
        override fun updateDrawState(paint: TextPaint) { paint.set(value) }
    }
    private class Fixture(val source: Spanned, val projection: RubyTextProjection, val body: TextPaint,
        val actions: List<Pair<RubyTextRange, () -> Unit>>) {
        fun range(span: Span) = projection.ranges.single { it.span === span && it.role != RubyTextRole.Owner }
        fun build(width: Int = 900): NativeFloatGeometry = NativeFloatGeometry.build(source, body, width,
            emptyList(), textDirection = TextDirectionHeuristics.LTR, nodeFactory = { geometry ->
                actions.mapIndexed { index, (range, click) -> FloatInteractionNode(index, FloatInteractionKind.LINK,
                    range.start, range.end, geometry.rectsForRange(range.start, range.end),
                    checkNotNull(range.span).text, null, click) }
            })
    }
    private fun prepare(spans: List<Span>, density: Float = 1f, clicked: (Span) -> Unit = {}): Fixture {
        val projection = rubyGraphicalProjection(spans)
        val root = paint()
        val groups = projection.ranges.filter { it.role in setOf(RubyTextRole.Owner, RubyTextRole.Base, RubyTextRole.Annotation) }
            .associate { range ->
                val declared = range.base?.owner ?: range.annotation?.owner ?: owner()
                val ownPaint = paint(checkNotNull(declared.font.fontScale))
                range.path to NativeRubyGroupFormat(ownPaint, TextDirectionHeuristics.LTR, NativeLineHeightPolicy.Normal,
                    sourceDirection = declared.direction, annotationMargins = range.annotation?.margins?.let {
                        nativeRubyAnnotationMargins(it, ownPaint.textSize, density)
                    })
            }
        val source = SpannableString(projection.text)
        source.setSpan(NativeRunLineMetrics(NativePrimaryFontMetrics.from(root), NativeLineHeightPolicy.Normal, strut = true),
            0, source.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        val actions = mutableListOf<Pair<RubyTextRange, () -> Unit>>()
        projection.ranges.filter { it.span != null && it.role != RubyTextRole.Owner && it.start < it.end }.forEach { range ->
            val span = checkNotNull(range.span)
            val ownPaint = paint(checkNotNull(span.fontScale), Color.parseColor(checkNotNull(span.foreground)))
            source.setSpan(SourcePaint(ownPaint), range.start, range.end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            source.setSpan(NativeRunLineMetrics(NativePrimaryFontMetrics.from(ownPaint), NativeLineHeightPolicy.Normal),
                range.start, range.end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            if (span.kind == "link") actions += range to { clicked(span) }
        }
        val prepared = NativeRubyPreparedSource(projection, SpannedString(source), root, TextDirectionHeuristics.LTR, groups)
        source.setSpan(prepared, 0, source.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        return Fixture(SpannedString(source), projection, root, actions)
    }
    private fun columns(geometry: NativeFloatGeometry): List<NativeRubyColumn> {
        val source = geometry.nativeRubyRaw.nativeRubyShapingSource
        return nativeInlineRanges(source, NativeRubyColumn::class.java).sortedBy { it.start }.map { it.value }
    }
    private fun bounds(geometry: FloatTextGeometry, range: RubyTextRange) =
        geometry.rectsForRange(range.start, range.end).map(::RectF).reduce { a, b -> a.apply { union(b) } }
    private fun relative(rect: RectF, baseline: Float) = RectF(rect).apply { offset(0f, -baseline) }
    private fun sameRect(expected: RectF, actual: RectF, dy: Float = 0f) {
        assertEquals(expected.left, actual.left, .02f); assertEquals(expected.right, actual.right, .02f)
        assertEquals(expected.top + dy, actual.top, .02f); assertEquals(expected.bottom + dy, actual.bottom, .02f)
    }
    private fun redInk(geometry: NativeFloatGeometry): RectF {
        val box = NativeSurfaceBox.from(geometry.extents)
        val bitmap = Bitmap.createBitmap(box.width + 8, box.height + 8, Bitmap.Config.ARGB_8888)
        try {
            val canvas = Canvas(bitmap); canvas.translate(4f - box.left, 4f - box.top); geometry.paint(canvas)
            var result: RectF? = null
            for (y in 0 until bitmap.height) for (x in 0 until bitmap.width) {
                val pixel = bitmap.getPixel(x, y)
                if (Color.red(pixel) > 0 && Color.green(pixel) == 0 && Color.blue(pixel) == 0) {
                    val next = RectF(x + box.left - 4f, y + box.top - 4f, x + box.left - 3f, y + box.top - 3f)
                    result?.union(next) ?: run { result = next }
                }
            }
            return checkNotNull(result)
        } finally { bitmap.recycle() }
    }

    @Test fun readingMarginsUseOwnFontAndTranslateRealPaintCaretsAndActionsWithoutExpandingThem() {
        for (scale in listOf(.6f, .35f)) for (density in listOf(1f, 1.75f)) {
            val main = leaf("\u7d05\u5dee")
            // The reading action is an explicitly synthetic interaction contrast.
            val read = leaf("\u3079\u306b\u3055", scale, "#ff0000", "original-reading")
            val middle = leaf("\u3057", color = "#00ff00")
            val other = ruby(listOf(base(leaf("\u6307"))), listOf(annotation(listOf(leaf("\u3086\u3073", .6f)), .6f)))
            fun fixture(pair: RubyAnnotationMargins?, clicked: (Span) -> Unit = {}) = prepare(listOf(
                ruby(listOf(base(main)), listOf(annotation(listOf(read), scale, margins = pair))), middle, other), density, clicked)
            val plain = fixture(null); val absent = plain.build()
            val zero = fixture(margins(0f, 0f)).build()
            val clicks = mutableListOf<Span>()
            val changed = fixture(margins(.25f, .25f)) { clicks += it }; val actual = changed.build()
            val baseRange = changed.range(main); val readingRange = changed.range(read)
            assertSame(read, readingRange.span); assertSame(middle, changed.range(middle).span)
            assertEquals(plain.projection.text, actual.text.toString())
            val oldBase = absent.baselineForOffset(baseRange.start)
            val newBase = actual.baselineForOffset(baseRange.start)
            val zeroBase = zero.baselineForOffset(baseRange.start)
            val edge = paint(scale).textSize * .25f
            val oldColumn = columns(absent).first(); val newColumn = columns(actual).first()
            assertEquals(oldColumn.advance, newColumn.advance, 0f)
            assertEquals(oldColumn.base, newColumn.base)
            assertEquals(oldColumn.container.top - edge * 2f, newColumn.container.top, .02f)
            assertEquals(oldColumn.container.bottom, newColumn.container.bottom, .02f)
            assertEquals(oldColumn.container, columns(zero).first().container)
            val oldBox = relative(bounds(absent, readingRange), oldBase)
            val actualBox = relative(bounds(actual, readingRange), newBase)
            sameRect(oldBox, actualBox, -edge)
            sameRect(oldBox, relative(bounds(zero, readingRange), zeroBase))
            for (offset in readingRange.start..readingRange.end) {
                val affinity = if (offset == readingRange.end) NativeTextAffinity.Upstream else NativeTextAffinity.Downstream
                val caret = NativeTextCaret(offset, affinity)
                sameRect(relative(absent.caretRect(caret), oldBase), relative(actual.caretRect(caret), newBase), -edge)
            }
            val originalInk = relative(redInk(absent), oldBase); val actualInk = relative(redInk(actual), newBase)
            assertEquals(originalInk.top - edge, actualInk.top, 1.1f)
            assertEquals(originalInk.bottom - edge, actualInk.bottom, 1.1f)
            val node = actual.nodes.single()
            assertEquals(readingRange.start, node.start); assertEquals(readingRange.end, node.end)
            assertTrue(node.contains(bounds(actual, readingRange).centerX(), bounds(actual, readingRange).centerY()))
            val child = newColumn.children.single { readingRange.start >= it.start && readingRange.end <= it.end }
            val childContentTop = child.geometry.extents.ink?.top ?: 0f
            // The reserved top margin lies outside the real reading selection/action band.
            val outsideY = minOf(bounds(actual, readingRange).top, newBase + child.y + childContentTop) - edge / 2f
            assertFalse(node.contains(bounds(actual, readingRange).centerX(), outsideY))
            checkNotNull(node.onClick).invoke(); assertEquals(1, clicks.size); assertSame(read, clicks.single())
            val recovered = plain.build()
            assertEquals(columns(absent).first().container, columns(recovered).first().container)
            sameRect(bounds(absent, readingRange), bounds(recovered, readingRange))
        }
    }

    @Test fun eachVisibleFragmentGetsOnePairRegardlessOfChildRunCount() {
        val main = leaf("\u6f22\u5b57\u4eee\u540d\u6f22\u5b57\u4eee\u540d\u6f22\u5b57\u4eee\u540d", target = "base")
        val text = "\u304b\u3093\u3058\u304b\u306a\u304b\u3093\u3058\u304b\u306a\u304b\u3093\u3058\u304b\u306a"
        val one = listOf(leaf(text, .6f, "#ff0000"))
        val many = text.chunked(3).map { leaf(it, .6f, "#ff0000") }
        fun fixture(runs: List<Span>, pair: RubyAnnotationMargins?) = prepare(listOf(ruby(listOf(base(main)),
            listOf(annotation(runs, margins = pair)))))
        val plain = fixture(one, null)
        val margined = fixture(one, margins(2.25f, 3.5f, StyleLengthUnit.Px))
        val split = fixture(many, margins(2.25f, 3.5f, StyleLengthUnit.Px))
        val width = ceil(paint().measureText("\u6f22\u5b57\u4eee\u540d").toDouble()).toInt().coerceAtLeast(64)
        val old = plain.build(width); val next = margined.build(width); val divided = split.build(width)
        assertTrue(next.shapedLineCount > 1)
        assertEquals(old.shapedLineCount, next.shapedLineCount)
        assertEquals(next.shapedLineCount, divided.shapedLineCount)
        val oldColumns = columns(old); val newColumns = columns(next); val splitColumns = columns(divided)
        assertTrue(newColumns.size > 1)
        assertEquals(oldColumns.size, newColumns.size); assertEquals(newColumns.size, splitColumns.size)
        oldColumns.zip(newColumns).forEach { (a, b) ->
            assertEquals(a.advance, b.advance, .02f)
            assertEquals(a.container.top - 5.75f, b.container.top, .02f)
            assertEquals(a.container.bottom, b.container.bottom, .02f)
        }
        newColumns.zip(splitColumns).forEach { (a, b) ->
            assertEquals(a.advance, b.advance, .02f); assertEquals(a.container, b.container)
        }
        assertEquals(plain.projection.text, next.text.toString()); assertEquals(next.text.toString(), divided.text.toString())
        val counts = IntArray(next.text.length)
        for (line in 0 until next.shapedLineCount) next.nativeRubyLineRanges(line).forEach { (a, b) ->
            for (offset in a until b) counts[offset]++
            assertTrue(next.nativeRubyLineRects(line, a, b).isNotEmpty())
        }
        assertTrue(counts.all { it == 1 })
        assertEquals(next.text.length, next.characterRects(0, next.text.length).size)
        assertEquals(1, margined.build(900).shapedLineCount)
        assertEquals(newColumns.map { it.container }, columns(margined.build(width)).map { it.container })
    }

    @Test fun independentLevelsAndGapContentKeepTheirOwnersAndHiddenReadingReservesNothing() {
        val main = leaf("M")
        val over = leaf("over", .6f, "#ff0000")
        val under = leaf("under", .4f, "#00ff00")
        val upper = leaf("outer", .3f)
        fun stacked(pair: Boolean) = prepare(listOf(ruby(listOf(base(main)), listOf(
            annotation(listOf(over), .6f, 0, margins = if (pair) margins(2f, 3f, StyleLengthUnit.Px) else null),
            annotation(listOf(under), .4f, 1, margins = if (pair) margins(5f, 7f, StyleLengthUnit.Px) else null),
            annotation(listOf(upper), .3f, 2, margins = if (pair) margins(11f, 13f, StyleLengthUnit.Px) else null)))))
        val oldFixture = stacked(false); val newFixture = stacked(true)
        val old = oldFixture.build(); val next = newFixture.build()
        val oldBase = old.baselineForOffset(oldFixture.range(main).start)
        val nextBase = next.baselineForOffset(newFixture.range(main).start)
        for ((span, delta) in listOf(over to -3f, under to 5f, upper to -18f)) {
            val range = newFixture.range(span)
            assertEquals(old.baselineForOffset(range.start) - oldBase + delta,
                next.baselineForOffset(range.start) - nextBase, .02f)
            sameRect(relative(bounds(old, range), oldBase), relative(bounds(next, range), nextBase), delta)
        }
        assertEquals(columns(old).single().container.top - 29f, columns(next).single().container.top, .02f)
        assertEquals(columns(old).single().container.bottom + 12f, columns(next).single().container.bottom, .02f)
        val duplicate = leaf("M", .6f, "#ff0000")
        fun hidden(pair: RubyAnnotationMargins?) = prepare(listOf(ruby(listOf(base(main)),
            listOf(annotation(listOf(duplicate), margins = pair)))))
        val plainHidden = hidden(null); val hugeHidden = hidden(margins(1000f, 1000f))
        assertFalse(hugeHidden.projection.ranges.any { it.annotation != null })
        assertEquals("M", hugeHidden.projection.text)
        assertEquals(columns(plainHidden.build()).single().container, columns(hugeHidden.build()).single().container)
        fun emptyReading(pair: RubyAnnotationMargins?) = prepare(listOf(ruby(listOf(base(main)),
            listOf(annotation(emptyList(), margins = pair)))))
        val emptyPlain = emptyReading(null)
        val emptyMargins = emptyReading(margins(2f, 3f, StyleLengthUnit.Px))
        assertEquals(1, emptyMargins.projection.ranges.count { it.annotation != null })
        assertEquals("M", emptyMargins.projection.text)
        val emptyOld = columns(emptyPlain.build()).single()
        val emptyNew = columns(emptyMargins.build()).single()
        assertEquals(emptyOld.advance, emptyNew.advance, 0f)
        assertEquals(emptyOld.container.top - 5f, emptyNew.container.top, .02f)
        assertEquals(emptyOld.container.bottom, emptyNew.container.bottom, .02f)
        val nestedBase = leaf("I")
        val nestedReading = leaf("nested", .4f)
        val nested = ruby(listOf(base(nestedBase)), listOf(annotation(listOf(nestedReading), .4f,
            margins = margins(1f, 2f, StyleLengthUnit.Px))))
        fun nestedFixture(pair: RubyAnnotationMargins?) = prepare(listOf(ruby(listOf(base(main)),
            listOf(annotation(listOf(nested), margins = pair)))))
        val nestedPlain = nestedFixture(null); val nestedMargins = nestedFixture(margins(4f, 6f, StyleLengthUnit.Px))
        val nestedOld = nestedPlain.build(); val nestedNew = nestedMargins.build()
        val nestedRange = nestedMargins.range(nestedReading)
        val nestedBaseRange = nestedMargins.range(main)
        assertEquals(nestedPlain.projection.text, nestedNew.text.toString())
        assertSame(nestedReading, nestedRange.span)
        assertEquals(nestedOld.baselineForOffset(nestedRange.start) - nestedOld.baselineForOffset(nestedBaseRange.start) - 6f,
            nestedNew.baselineForOffset(nestedRange.start) - nestedNew.baselineForOffset(nestedBaseRange.start), .02f)
        assertEquals(columns(nestedOld).single().container.top - 10f, columns(nestedNew).single().container.top, .02f)
        val first = leaf("A"); val second = leaf("B")
        val firstRead = leaf("one", .6f); val secondRead = leaf("two", .6f)
        val gap = leaf(" ", 2f, "#00ff00")
        fun gaps(pair: RubyAnnotationMargins?) = prepare(listOf(ruby(listOf(base(first), base(second)), listOf(
            annotation(listOf(firstRead)), annotation(listOf(secondRead), start = 1, margins = pair, gap = listOf(gap))))))
        val beforeGap = gaps(null); val withGap = gaps(margins(2f, 3f, StyleLengthUnit.Px))
        val beforeGeometry = beforeGap.build(); val withGeometry = withGap.build()
        val gapRange = withGap.range(gap)
        assertSame(gap, gapRange.span)
        val oldGap = bounds(beforeGeometry, gapRange); val newGap = bounds(withGeometry, gapRange)
        assertEquals(oldGap.width(), newGap.width(), .02f); assertEquals(oldGap.height(), newGap.height(), .02f)
        assertEquals(beforeGap.projection.text, withGeometry.text.toString())
        val gapChild = columns(withGeometry).flatMap { it.children }.single { it.start == gapRange.start && it.end == gapRange.end }
        assertEquals(gap.text, gapChild.geometry.text.toString())
        val gapAdvance = gapChild.geometry.caretRect(gapChild.geometry.text.length).left -
            gapChild.geometry.caretRect(0).left
        assertEquals(paint(2f).measureText(" "), gapAdvance, .02f)
        // This real gap's own band dominates the margined reading. Giving the gap
        // the RT pair would enlarge the column and fail this independent contrast.
        val gapMetrics = paint(2f).fontMetrics
        val readingMetrics = paint(.6f).fontMetrics
        assertTrue(gapMetrics.ascent < readingMetrics.ascent - 2f)
        assertTrue(gapMetrics.descent > readingMetrics.descent + 3f)
        assertEquals(columns(beforeGeometry).map { it.container }, columns(withGeometry).map { it.container })
    }
}
