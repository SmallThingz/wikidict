package app.smallthingz.dict

import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.fonts.Font
import android.graphics.text.MeasuredText
import android.graphics.text.PositionedGlyphs
import android.graphics.text.TextRunShaper
import android.icu.text.Bidi
import android.text.Spanned
import android.text.SpannedString
import android.text.TextDirectionHeuristic
import android.text.TextPaint
import android.text.style.AbsoluteSizeSpan
import android.text.style.AlignmentSpan
import android.text.style.BackgroundColorSpan
import android.text.style.CharacterStyle
import android.text.style.ForegroundColorSpan
import android.text.style.MetricAffectingSpan
import android.text.style.LineHeightSpan
import android.text.style.ParagraphStyle
import android.text.style.RelativeSizeSpan
import android.text.style.ReplacementSpan
import android.text.style.ScaleXSpan
import android.text.style.StrikethroughSpan
import android.text.style.StyleSpan
import android.text.style.SubscriptSpan
import android.text.style.SuperscriptSpan
import android.text.style.TypefaceSpan
import android.text.style.UnderlineSpan
import kotlin.math.abs

/** The hard separator belongs to end, but is never a measured glyph. Empty hard
 * paragraphs and the paragraph after a terminal LF have no native bidi line. */
internal class NativeFloatRunParagraph internal constructor(
    val start: Int,
    val end: Int,
    val measuredEnd: Int,
    val rtl: Boolean,
    val measured: MeasuredText?,
    val bidi: Bidi?,
) {
    val isEmpty: Boolean get() = start == measuredEnd
}

internal data class NativeFloatRunMetric(
    val start: Int,
    val end: Int,
    val paint: TextPaint,
    val shift: Float,
    val image: NativeFloatInlineImage?,
    val column: NativeRubyColumn? = null,
    val atom: NativeInlineAtomicBox? = null,
)

internal data class NativeFloatRunPaintSlice(
    val start: Int,
    val end: Int,
    val underline: NativeAuthoredUnderline?,
    val mayUnderline: Boolean,
)

/** Glyph IDs, fonts and positions are produced once for a native metric/bidi
 * context. Drawing a color/background/decoration slice never reshapes that text. */
internal class NativeFloatGlyphRun internal constructor(
    private val owner: NativeFloatRowRuns,
    val start: Int,
    val end: Int,
    val contextStart: Int,
    val contextEnd: Int,
    val rtl: Boolean,
    val visible: Boolean,
    private val metric: NativeFloatRunMetric,
    private val glyphs: PositionedGlyphs?,
    val image: NativeFloatInlineImage?,
    val advance: Float,
    val natural: NativeUsedLineMetrics,
    val paddedNatural: NativeUsedLineMetrics,
) {
    val column: NativeRubyColumn? get() = metric.column
    val atom: NativeInlineAtomicBox? get() = metric.atom
    private val slices = if (image == null && column == null && atom == null) owner.paintSlices(start, end) else emptyList()
    private val glyphBatches: List<GlyphBatch> = buildList {
        val value = glyphs ?: return@buildList
        var first = 0
        while (first < value.glyphCount()) {
            val font = value.getFont(first)
            var last = first + 1
            while (last < value.glyphCount() && value.getFont(last) == font) last++
            val ids = IntArray(last - first) { value.getGlyphId(first + it) }
            val positions = FloatArray((last - first) * 2) { index ->
                val glyph = first + index / 2
                if (index % 2 == 0) value.getGlyphX(glyph) - value.offsetX
                else value.getGlyphY(glyph) - value.offsetY
            }
            add(GlyphBatch(font, ids, positions))
            first = last
        }
    }

    private data class GlyphBatch(val font: Font, val ids: IntArray, val positions: FloatArray)

    init {
        // Paint boundaries may divide a ligature, but may not invent a cursor inside
        // a native grapheme. Its color is clipped at the native advance, not reshaped.
        if (image == null) for (cut in slices.flatMap { listOf(it.start, it.end) }.distinct()) {
            if (metric.paint.getTextRunCursor(owner.source, contextStart, contextEnd, rtl,
                    cut, Paint.CURSOR_AT_OR_AFTER) != cut)
                throw UnsupportedFloatLayout("Float row paint boundary is inside a native cluster")
        }
        slices.forEach { owner.livePaint(it.start, it.end, metric) }
    }

    /** Logical advance from start; the caller mirrors this for a physical RTL run. */
    fun advanceTo(offset: Int): Float {
        require(offset in start..end)
        if (image != null || column != null || atom != null) return if (offset == start) 0f else advance
        return floatRunCoordinate(metric.paint.getRunAdvance(owner.source, start, end,
            contextStart, contextEnd, rtl, offset).toDouble())
    }

    fun offsetForAdvance(value: Float): Int {
        require(value.isFinite())
        if (image != null || column != null || atom != null) return if (value <= advance / 2f) start else end
        return metric.paint.getOffsetForAdvance(owner.source, start, end, contextStart, contextEnd,
            rtl, value.coerceIn(0f, advance)).coerceIn(start, end)
    }

    /** Logical before/after, independent of physical run direction. */
    fun cursor(offset: Int, after: Boolean): Int {
        require(offset in start..end)
        if (image != null || column != null || atom != null) return if (after) end else start
        val next = metric.paint.getTextRunCursor(owner.source, contextStart, contextEnd, rtl, offset,
            if (after) Paint.CURSOR_AFTER else Paint.CURSOR_BEFORE)
        return if (next < 0) { if (after) end else start } else next.coerceIn(start, end)
    }

    private fun physical(offset: Int): Float = if (rtl) advance - advanceTo(offset) else advanceTo(offset)

    private fun sliceBounds(slice: NativeFloatRunPaintSlice): Pair<Float, Float> {
        val a = physical(slice.start)
        val b = physical(slice.end)
        return minOf(a, b) to maxOf(a, b)
    }

    /** naturalTop/naturalBottom are relative to the supplied flow baseline.
     * Android character backgrounds stay on that unshifted line band. */
    fun paintBackground(canvas: Canvas, x: Float, baseline: Float, naturalTop: Float, naturalBottom: Float) {
        if (!visible || image != null || column != null || atom != null) return
        data class Background(val left: Float, val right: Float, val color: Int, val antiAlias: Boolean, val dither: Boolean)
        val fragments = mutableListOf<Background>()
        for (slice in slices) {
            val paint = owner.livePaint(slice.start, slice.end, metric)
            if (paint.bgColor == 0) continue
            val (left, right) = sliceBounds(slice)
            if (right <= left || naturalBottom <= naturalTop) continue
            fragments += Background(left, right, paint.bgColor, paint.isAntiAlias, paint.isDither)
        }
        val joined = mutableListOf<Background>()
        for (fragment in fragments.sortedBy { it.left }) {
            val previous = joined.lastOrNull()
            if (previous != null && previous.right == fragment.left && previous.color == fragment.color &&
                previous.antiAlias == fragment.antiAlias && previous.dither == fragment.dither)
                joined[joined.lastIndex] = previous.copy(right = fragment.right)
            else joined += fragment
        }
        // A foreground-only cut must not add an antialiased seam to one background.
        for (fragment in joined) {
            canvas.drawRect(x + fragment.left, baseline + naturalTop, x + fragment.right, baseline + naturalBottom,
                Paint().apply { color = fragment.color; isAntiAlias = fragment.antiAlias; isDither = fragment.dither })
        }
    }

    fun paintGlyphs(canvas: Canvas, x: Float, baseline: Float) {
        if (!visible || image != null || column != null || atom != null) return
        for (slice in slices) {
            val paint = owner.livePaint(slice.start, slice.end, metric)
            val (left, right) = sliceBounds(slice)
            if (right <= left) continue
            paint.isUnderlineText = false
            paint.isStrikeThruText = false
            if (canvas is NativeRubyGlyphCanvas) {
                canvas.paintRubyGlyphRun(owner.source, slice.start, slice.end, contextStart, contextEnd,
                    x + left, baseline + metric.shift, rtl, paint) { target, a, b, shape, px, py ->
                    val save = target.save()
                    try {
                        // Keep only the original foreground-slice clips. Distribution
                        // boundaries retain each certified glyph's outside ink.
                        val clipLeft = (if (rtl) b == slice.end else a == slice.start) && left != 0f
                        val clipRight = (if (rtl) a == slice.start else b == slice.end) && right != advance
                        target.clipRect(if (clipLeft) px else -TablePixelLimit.toFloat(),
                            -TablePixelLimit.toFloat(),
                            if (clipRight) px + shape.advance else TablePixelLimit.toFloat(),
                            TablePixelLimit.toFloat())
                        target.translate(px, py)
                        var first = 0
                        while (first < shape.glyphs.size) {
                            val font = shape.glyphs[first].font as? Font
                                ?: throw UnsupportedFloatLayout("Ruby piece lost its actual native font")
                            var last = first + 1
                            while (last < shape.glyphs.size && shape.glyphs[last].font == font) last++
                            val ids = IntArray(last - first) { shape.glyphs[first + it].id }
                            val positions = FloatArray((last - first) * 2) { index ->
                                val glyph = shape.glyphs[first + index / 2]
                                if (index % 2 == 0) glyph.x else glyph.y
                            }
                            target.drawGlyphs(ids, 0, positions, 0, ids.size, font, paint)
                            first = last
                        }
                    } finally { target.restoreToCount(save) }
                }
                continue
            }
            // Do not clip the actual outside overhang of the first/last glyph.
            val clipLeft = if (left == 0f) -TablePixelLimit.toFloat() else x + left
            val clipRight = if (right == advance) TablePixelLimit.toFloat() else x + right
            val saved = canvas.save()
            try {
                canvas.clipRect(clipLeft, -TablePixelLimit.toFloat(), clipRight, TablePixelLimit.toFloat())
                canvas.translate(x, baseline + metric.shift)
                paint.isUnderlineText = false
                paint.isStrikeThruText = false
                for (batch in glyphBatches)
                    canvas.drawGlyphs(batch.ids, 0, batch.positions, 0, batch.ids.size, batch.font, paint)
            } finally { canvas.restoreToCount(saved) }
        }
    }

    fun paintDecorations(canvas: Canvas, x: Float, baseline: Float) {
        if (!visible || image != null || column != null || atom != null) return
        for (slice in slices) {
            val paint = owner.livePaint(slice.start, slice.end, metric)
            decorations(slice, paint, x, baseline, reserve = false).forEach { it.paint(canvas) }
        }
    }

    private fun decorations(slice: NativeFloatRunPaintSlice, paint: TextPaint, x: Float, baseline: Float,
        reserve: Boolean): List<NativeInlineDecorationFragment> = buildList {
        if (paint.textSize == 0f) return@buildList
        val (left, right) = sliceBounds(slice)
        if (right <= left) return@buildList
        fun addStroke(position: Float, thickness: Float, color: Int, style: InlineUnderlineStyle) {
            if (thickness <= 0f) return
            val top = floatRunCoordinate(baseline.toDouble() + metric.shift + position)
            add(NativeInlineDecorationFragment(NativeFloatBounds(x + left, top, x + right,
                floatRunCoordinate(top.toDouble() + thickness)), color, style))
        }
        if (paint.isUnderlineText || reserve && slice.mayUnderline)
            addStroke(paint.underlinePosition, maxOf(paint.underlineThickness, 1f), paint.color, InlineUnderlineStyle.Solid)
        if (paint.isStrikeThruText)
            addStroke(paint.strikeThruPosition, maxOf(paint.strikeThruThickness, 1f), paint.color, InlineUnderlineStyle.Solid)
        slice.underline?.let {
            addStroke(paint.underlinePosition, it.thickness ?: maxOf(paint.underlineThickness, 1f),
                it.color ?: paint.color, it.style)
        }
    }

    fun liveBackgroundContains(x: Float, baseline: Float, naturalTop: Float, naturalBottom: Float,
        hitX: Float, hitY: Float): Boolean {
        if (!visible || image != null || column != null || atom != null ||
            hitY < baseline + naturalTop || hitY >= baseline + naturalBottom) return false
        return slices.any { slice ->
            val paint = owner.livePaint(slice.start, slice.end, metric)
            val (left, right) = sliceBounds(slice)
            paint.bgColor ushr 24 != 0 && hitX >= x + left && hitX < x + right
        }
    }

    fun liveGlyphContains(x: Float, baseline: Float, hitX: Float, hitY: Float): Boolean {
        if (!visible || image != null || column != null || atom != null) return false
        for (slice in slices) {
            val paint = owner.livePaint(slice.start, slice.end, metric)
            if (paint.color ushr 24 == 0) continue
            val (left, right) = sliceBounds(slice)
            if (right <= left || left != 0f && hitX < x + left || right != advance && hitX >= x + right) continue
            for (batch in glyphBatches) for (i in batch.ids.indices) {
                val rect = RectF()
                batch.font.getGlyphBounds(batch.ids[i], paint, rect)
                rect.offset(x + batch.positions[i * 2], baseline + metric.shift + batch.positions[i * 2 + 1])
                if (rect.contains(hitX, hitY)) return true
            }
        }
        return false
    }

    fun liveDecorationContains(x: Float, baseline: Float, hitX: Float, hitY: Float): Boolean {
        if (!visible || image != null || column != null || atom != null) return false
        return slices.any { slice ->
            val paint = owner.livePaint(slice.start, slice.end, metric)
            decorations(slice, paint, x, baseline, reserve = false).any { fragment ->
                val b = fragment.bounds
                if (fragment.color ushr 24 == 0 || hitX < b.left || hitX >= b.right ||
                    hitY < b.top || hitY >= b.bottom) false
                else if (fragment.style == InlineUnderlineStyle.Solid) true
                else {
                    // The maintained dotted painter uses round zero-length dashes,
                    // a two-thickness period, and the same rectangular end clip.
                    val thickness = (b.bottom - b.top).toDouble()
                    val period = thickness * 2.0
                    val dx = hitX.toDouble() - b.left
                    val nearest = kotlin.math.round(dx / period) * period
                    val dy = hitY.toDouble() - (b.top.toDouble() + thickness / 2.0)
                    (dx - nearest) * (dx - nearest) + dy * dy <= thickness * thickness / 4.0
                }
            }
        }
    }

    /** Potential ordinary ink, including a live state's possible native underline.
     * The positioned image has a separate caller-owned phase and bounds. */
    fun paintBounds(x: Float, baseline: Float, naturalTop: Float, naturalBottom: Float): NativeFloatBounds? {
        if (!visible || image != null || column != null || atom != null) return null
        var result: NativeFloatBounds? = null
        fun include(rect: RectF) {
            if (rect.isEmpty) return
            floatRunCoordinates(rect.left, rect.top, rect.right, rect.bottom)
            result = enclosingBounds(result, NativeFloatBounds(rect.left, rect.top, rect.right, rect.bottom))
        }
        for (slice in slices) {
            val paint = owner.livePaint(slice.start, slice.end, metric)
            val (left, right) = sliceBounds(slice)
            if (right <= left) continue
            if (paint.bgColor != 0)
                include(RectF(x + left, baseline + naturalTop, x + right, baseline + naturalBottom))
            for (batch in glyphBatches) for (i in batch.ids.indices) {
                val rect = RectF()
                batch.font.getGlyphBounds(batch.ids[i], paint, rect)
                rect.offset(x + batch.positions[i * 2], baseline + metric.shift + batch.positions[i * 2 + 1])
                if (left != 0f) rect.left = maxOf(rect.left, x + left)
                if (right != advance) rect.right = minOf(rect.right, x + right)
                include(rect)
            }
            for (fragment in decorations(slice, paint, x, baseline, reserve = true)) {
                val b = fragment.bounds
                include(RectF(b.left, b.top, b.right, b.bottom))
            }
        }
        return result
    }
}

/** Native paragraph measurement and retained glyph runs only. LineBreaker owns
 * fitting; the Float row plan owns placement, selected line metrics and images. */
internal class NativeFloatRowRuns(source: Spanned, paint: TextPaint, private val direction: TextDirectionHeuristic) {
    val source: Spanned = SpannedString(source)
    val paint: TextPaint = floatRunPaintCopy(paint)
    private val metrics: List<NativeFloatRunMetric>
    val paragraphs: List<NativeFloatRunParagraph>

    init {
        validateNativeInlineStyle(this.source, this.paint)
        validatePaint(this.paint)
        if (this.source.any { it == '\t' })
            throw UnsupportedFloatLayout("Float row tab-stop allocation is unavailable")
        val lineEffects = nativeInlineRanges(this.source, NativeLineMinimum::class.java) +
            nativeInlineRanges(this.source, NativeLineGap::class.java)
        for (effect in this.source.getSpans(0, this.source.length, ParagraphStyle::class.java)) {
            if (effect.javaClass == AlignmentSpan.Standard::class.java) continue
            if (effect is LineHeightSpan && effect is NativeFloatRowMetricEffect && lineEffects.any {
                    it.start == this.source.getSpanStart(effect) && it.end == this.source.getSpanEnd(effect)
                }) continue
            throw UnsupportedFloatLayout("Float row custom paragraph effects are unavailable")
        }
        val replacements = nativeInlineRanges(this.source, ReplacementSpan::class.java)
        val atoms = nativeInlineRanges(this.source, NativeInlineAtomicBox::class.java)
        if (atoms.any { it.end != it.start + 1 || it.start !in this.source.indices || this.source[it.start] != '\uFFFC' } ||
            (replacements.map { it.start to it.end } + atoms.map { it.start to it.end }).sortedBy { it.first }
                .zipWithNext().any { (a, b) -> a.second > b.first })
            throw UnsupportedFloatLayout("Atomic inline box lost its owned private token")
        if (replacements.any { (it.value !is NativeFloatInlineImage && it.value !is NativeRubyColumn) || it.end != it.start + 1 ||
                it.start !in this.source.indices || this.source[it.start] != '\uFFFC' } ||
            replacements.sortedBy { it.start }.zipWithNext().any { (a, b) -> a.end > b.start })
            throw UnsupportedFloatLayout("Float row replacement is not an owned inline image")
        if (this.source.getSpans(0, this.source.length, CharacterStyle::class.java).any {
                it !is ReplacementSpan && it !is NativeInlineSafePaintSpan && it.javaClass !in knownStyles })
            throw UnsupportedFloatLayout("Float row paint requires known native style effects")
        val cuts = sortedSetOf(0, this.source.length)
        atoms.forEach { cuts += it.start; cuts += it.end }
        nativeInlineRanges(this.source, MetricAffectingSpan::class.java).forEach { cuts += it.start; cuts += it.end }
        nativeInlineRanges(this.source, NativeAuthoredBaselineShift::class.java).forEach { cuts += it.start; cuts += it.end }
        this.source.forEachIndexed { index, c -> if (c == '\n') { cuts += index; cuts += index + 1 } }
        val resolved = mutableListOf<NativeFloatRunMetric>()
        for ((start, end) in cuts.zipWithNext()) {
            if (start == end) continue
            val metricPaint = floatRunPaintCopy(this.paint)
            this.source.getSpans(start, end, MetricAffectingSpan::class.java)
                .filter { this.source.getSpanStart(it) < end && this.source.getSpanEnd(it) > start }
                .forEach { if (it !is ReplacementSpan) it.updateMeasureState(metricPaint) }
            validatePaint(metricPaint)
            val shift = authoredShift(start, end) ?: metricPaint.baselineShift.toFloat()
            val image = replacements.singleOrNull { it.start == start && it.end == end }?.value as? NativeFloatInlineImage
            val column = replacements.singleOrNull { it.start == start && it.end == end }?.value as? NativeRubyColumn
            val atom = atoms.singleOrNull { it.start == start && it.end == end }?.value
            val next = NativeFloatRunMetric(start, end, metricPaint, shift, image, column, atom)
            // Even equal paints retain an original metric-span boundary: it is a
            // native shaping-context cut. Only draw-only styles remain unsplit.
            resolved += next
        }
        metrics = resolved.toList()
        paragraphs = buildList {
            var start = 0
            while (true) {
                val newline = this@NativeFloatRowRuns.source.indexOf('\n', start)
                val measuredEnd = if (newline < 0) this@NativeFloatRowRuns.source.length else newline
                val end = if (newline < 0) measuredEnd else measuredEnd + 1
                add(paragraph(start, end, measuredEnd))
                if (newline < 0) break
                start = end
            }
        }
    }

    private fun paragraph(start: Int, end: Int, measuredEnd: Int): NativeFloatRunParagraph {
        val rtl = nativeClippedParagraphDirectionAt(source, start)?.let { it == BidiResolvedDirection.Rtl }
            ?: direction.isRtl(source, start, measuredEnd - start)
        if (start == measuredEnd) return NativeFloatRunParagraph(start, end, measuredEnd, rtl, null, null)
        val chars = CharArray(measuredEnd - start) { source[start + it] }
        val bidi = Bidi().apply { setPara(chars, (if (rtl) 1 else 0).toByte(), null) }
        if (bidi.countParagraphs() != 1)
            throw UnsupportedFloatLayout("Float row bidi paragraph separators are unavailable")
        val builder = MeasuredText.Builder(chars).setComputeLayout(true).setComputeHyphenation(false)
        var first = start
        while (first < measuredEnd) {
            val metric = metricAt(first)
            val level = bidi.getLevelAt(first - start)
            var last = minOf(measuredEnd, metric.end)
            var probe = first + 1
            while (probe < last) {
                if (bidi.getLevelAt(probe - start) != level) { last = probe; break }
                probe++
            }
            if (metric.atom != null) {
                if (first != metric.start || last != metric.end)
                    throw UnsupportedFloatLayout("Float row bidi split an atomic inline box")
                builder.appendReplacementRun(metric.paint, last - first, metric.atom.advance)
            } else if (metric.column != null) {
                if (first != metric.start || last != metric.end)
                    throw UnsupportedFloatLayout("Float row bidi split a ruby column")
                builder.appendReplacementRun(metric.paint, last - first, metric.column.advance)
            } else if (metric.image != null) {
                if (first != metric.start || last != metric.end)
                    throw UnsupportedFloatLayout("Float row bidi split an inline image")
                builder.appendReplacementRun(metric.paint, last - first, imageRow(metric.image).advance)
            } else builder.appendStyleRun(metric.paint, last - first, level.toInt() and 1 != 0)
            first = last
        }
        return NativeFloatRunParagraph(start, end, measuredEnd, rtl, builder.build(), bidi)
    }

    /** The full selected row fixes bidi; visibleEnd only divides its trailing
     * whitespace into retained source pieces which the painter can omit. */
    fun visualRuns(paragraph: NativeFloatRunParagraph, start: Int, end: Int,
        visibleEnd: Int = end): List<NativeFloatGlyphRun> {
        require(paragraphs.any { it === paragraph })
        require(start in paragraph.start..paragraph.measuredEnd && end in start..paragraph.measuredEnd &&
            visibleEnd in start..end)
        if (start == end) return emptyList()
        if ((visibleEnd until end).any { !nativeFloatRowLineEndSpace(source[it]) })
            throw UnsupportedFloatLayout("Float row omitted trailing source is not native space")
        val line = checkNotNull(paragraph.bidi).setLine(start - paragraph.start, end - paragraph.start)
        return buildList {
            for (index in 0 until line.countRuns()) {
                val bidiRun = line.getVisualRun(index)
                val first = start + bidiRun.start
                val last = start + bidiRun.limit
                val rtl = bidiRun.isOddRun
                val pieces = mutableListOf<Triple<Int, Int, NativeFloatRunMetric>>()
                var next = first
                while (next < last) {
                    val metric = metricAt(next)
                    val limit = minOf(last, metric.end)
                    if (visibleEnd > next && visibleEnd < limit) {
                        pieces += Triple(next, visibleEnd, metric)
                        pieces += Triple(visibleEnd, limit, metric)
                    } else pieces += Triple(next, limit, metric)
                    next = limit
                }
                for ((pieceStart, pieceEnd, metric) in if (rtl) pieces.asReversed() else pieces) {
                    val contextStart = maxOf(first, metric.start)
                    val contextEnd = minOf(last, metric.end)
                    add(shape(pieceStart, pieceEnd, contextStart, contextEnd, rtl, pieceStart < visibleEnd, metric))
                }
            }
        }
    }

    private fun shape(start: Int, end: Int, contextStart: Int, contextEnd: Int, rtl: Boolean,
        visible: Boolean, metric: NativeFloatRunMetric): NativeFloatGlyphRun {
        if (metric.atom != null) {
            if (start != metric.start || end != metric.end)
                throw UnsupportedFloatLayout("Float row cut an atomic inline box")
            return NativeFloatGlyphRun(this, start, end, contextStart, contextEnd, rtl, visible, metric,
                null, null, metric.atom.advance, metric.atom.metrics, metric.atom.metrics)
        }
        if (metric.column != null) {
            if (start != metric.start || end != metric.end)
                throw UnsupportedFloatLayout("Float row cut a ruby column")
            val natural = metric.column.base
            return NativeFloatGlyphRun(this, start, end, contextStart, contextEnd, rtl, visible, metric,
                null, null, metric.column.advance, natural, natural)
        }
        val image = metric.image
        if (image != null) {
            val fm = metric.paint.fontMetrics
            val natural = NativeUsedLineMetrics(fm.ascent, fm.descent).including(image.nativeUsedMetrics)
            return NativeFloatGlyphRun(this, start, end, start, end, rtl, visible, metric, null, image,
                imageRow(image).advance, natural, natural)
        }
        val shaped = TextRunShaper.shapeTextRun(source, start, end - start, contextStart,
            contextEnd - contextStart, 0f, 0f, rtl, metric.paint)
        floatRunCoordinates(shaped.advance, shaped.ascent, shaped.descent)
        if (shaped.advance < 0f) throw UnsupportedFloatLayout("Float row native advance is negative")
        val fm = metric.paint.fontMetrics
        var top = if (shaped.glyphCount() == 0) fm.top else Float.POSITIVE_INFINITY
        var bottom = if (shaped.glyphCount() == 0) fm.bottom else Float.NEGATIVE_INFINITY
        val fonts = mutableSetOf<Font>()
        for (index in 0 until shaped.glyphCount()) {
            floatRunCoordinates(shaped.getGlyphX(index), shaped.getGlyphY(index))
            if (fonts.add(shaped.getFont(index))) {
                val fallback = Paint.FontMetrics()
                shaped.getFont(index).getMetrics(metric.paint, fallback)
                top = minOf(top, fallback.top)
                bottom = maxOf(bottom, fallback.bottom)
            }
        }
        val ascent = if (shaped.glyphCount() == 0) fm.ascent else shaped.ascent
        val descent = if (shaped.glyphCount() == 0) fm.descent else shaped.descent
        val natural = NativeUsedLineMetrics(floatRunCoordinate(ascent.toDouble() + metric.shift),
            floatRunCoordinate(descent.toDouble() + metric.shift))
        val padded = NativeUsedLineMetrics(floatRunCoordinate(top.toDouble() + metric.shift),
            floatRunCoordinate(bottom.toDouble() + metric.shift)).including(natural)
        return NativeFloatGlyphRun(this, start, end, contextStart, contextEnd, rtl, visible, metric,
            shaped, null, shaped.advance, natural, padded)
    }

    private fun metricAt(offset: Int): NativeFloatRunMetric = metrics.firstOrNull {
        it.start <= offset && offset < it.end
    } ?: throw UnsupportedFloatLayout("Float row has no source metric owner")

    private fun authoredShift(start: Int, end: Int): Float? =
        source.getSpans(start, end, NativeAuthoredBaselineShift::class.java)
            .singleOrNull { source.getSpanStart(it) < end && source.getSpanEnd(it) > start }?.shift

    internal fun paintSlices(start: Int, end: Int): List<NativeFloatRunPaintSlice> {
        val cuts = sortedSetOf(start, end)
        source.getSpans(start, end, CharacterStyle::class.java).forEach {
            cuts += source.getSpanStart(it).coerceIn(start, end)
            cuts += source.getSpanEnd(it).coerceIn(start, end)
        }
        source.getSpans(start, end, NativeAuthoredUnderline::class.java).forEach {
            cuts += source.getSpanStart(it).coerceIn(start, end)
            cuts += source.getSpanEnd(it).coerceIn(start, end)
        }
        return cuts.zipWithNext().map { (first, last) ->
            val styles = source.getSpans(first, last, CharacterStyle::class.java).filter {
                source.getSpanStart(it) < last && source.getSpanEnd(it) > first
            }
            val underline = source.getSpans(first, last, NativeAuthoredUnderline::class.java).singleOrNull {
                source.getSpanStart(it) < last && source.getSpanEnd(it) > first
            }
            NativeFloatRunPaintSlice(first, last, underline, styles.any { it is NativeMayUnderline && it.mayUnderline })
        }
    }

    internal fun livePaint(start: Int, end: Int, metric: NativeFloatRunMetric): TextPaint {
        val value = floatRunPaintCopy(paint)
        source.getSpans(start, end, CharacterStyle::class.java)
            .filter { source.getSpanStart(it) < end && source.getSpanEnd(it) > start }
            .forEach { if (it !is ReplacementSpan) it.updateDrawState(value) }
        validatePaint(value)
        if (!sameMetric(value, metric.paint) || (authoredShift(start, end) ?: value.baselineShift.toFloat()) != metric.shift)
            throw UnsupportedFloatLayout("Float row live paint changed native measurement")
        return value
    }

    private fun imageRow(image: NativeFloatInlineImage): NativeFloatRowImage {
        val occurrence = image.nativeImageOccurrence
        val used = image.nativeUsedMetrics
        val ink = image.nativeImageInkBounds
        floatRunCoordinates(image.nativeImageWidth, image.nativeImageHeight, used.top, used.bottom,
            ink.left, ink.top, ink.right, ink.bottom, occurrence?.paddingLeft ?: 0f,
            occurrence?.paddingRight ?: 0f, occurrence?.translationX ?: 0f, occurrence?.translationY ?: 0f)
        if (image.nativeImageWidth < 0f || image.nativeImageHeight < 0f ||
            ink.right < ink.left || ink.bottom < ink.top ||
            (occurrence?.paddingLeft ?: 0f) < 0f || (occurrence?.paddingRight ?: 0f) < 0f)
            throw UnsupportedFloatLayout("Float row image dimensions are invalid")
        floatRunCoordinate((occurrence?.paddingLeft ?: 0f).toDouble() + image.nativeImageWidth +
            (occurrence?.paddingRight ?: 0f))
        return NativeFloatRowImage(image.nativeImageWidth, image.nativeImageHeight, image.nativeUsedMetrics.top,
            occurrence?.paddingLeft ?: 0f, occurrence?.paddingRight ?: 0f,
            occurrence?.translationX ?: 0f, occurrence?.translationY ?: 0f, occurrence != null)
    }

    private fun sameMetric(a: TextPaint, b: TextPaint): Boolean =
        a.equalsForTextMeasurement(b) && a.baselineShift == b.baselineShift

    private fun validatePaint(value: TextPaint) {
        if (value.textSize < 0f || value.textScaleX < 0f ||
            value.textAlign != Paint.Align.LEFT || value.style != Paint.Style.FILL || value.shadowLayerRadius != 0f ||
            value.shader != null || value.pathEffect != null || value.colorFilter != null ||
            value.maskFilter != null || value.xfermode != null || value.startHyphenEdit != 0 || value.endHyphenEdit != 0)
            throw UnsupportedFloatLayout("Float row paint has an unowned drawing effect")
        floatRunCoordinates(value.textSize, value.textScaleX, value.textSkewX, value.letterSpacing)
    }

    private companion object {
        val knownStyles: Set<Class<out CharacterStyle>> = setOf(
            AbsoluteSizeSpan::class.java, BackgroundColorSpan::class.java, ForegroundColorSpan::class.java,
            RelativeSizeSpan::class.java, ScaleXSpan::class.java, StrikethroughSpan::class.java,
            StyleSpan::class.java, SubscriptSpan::class.java, SuperscriptSpan::class.java,
            TypefaceSpan::class.java, UnderlineSpan::class.java,
        )
    }
}

private fun floatRunCoordinate(value: Double): Float {
    if (!value.isFinite() || abs(value) > TablePixelLimit)
        throw UnsupportedFloatLayout("Float row glyph geometry exceeds native coordinates")
    return value.toFloat()
}

private fun floatRunPaintCopy(paint: TextPaint): TextPaint = TextPaint().apply { set(paint) }

/** Native line-end trimming deliberately excludes NBSP, NNBSP and figure space. */
internal fun nativeFloatRowLineEndSpace(char: Char): Boolean = char == ' ' || char == '\t' ||
    char == '\u1680' || char in '\u2000'..'\u200A' && char != '\u2007' ||
    char == '\u205F' || char == '\u3000'

private fun floatRunCoordinates(vararg values: Float) {
    if (values.any { !it.isFinite() || abs(it) > TablePixelLimit })
        throw UnsupportedFloatLayout("Float row glyph geometry exceeds native coordinates")
}
