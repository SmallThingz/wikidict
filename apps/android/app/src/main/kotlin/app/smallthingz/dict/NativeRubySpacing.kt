package app.smallthingz.dict

import android.graphics.Canvas
import android.graphics.Bitmap
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Path
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.text.PositionedGlyphs
import android.graphics.text.TextRunShaper
import android.icu.text.BreakIterator
import android.text.TextPaint
import java.util.Locale
import kotlin.math.abs
import kotlin.math.ceil

/** A nested replacement translates once on the real canvas. Its own native children must
 * not pass through the enclosing row's distribution a second time. */
internal interface NativeRubyAtomicCanvas {
    fun paintRubyAtom(x: Float, y: Float, draw: (Canvas) -> Unit)
    fun paintRubyAtom(column: NativeRubyColumn, x: Float, y: Float, draw: (Canvas) -> Unit) =
        paintRubyAtom(x, y, draw)
}

internal interface NativeRubyPhysicalMap {
    val minimumShift: Float
    val maximumShift: Float
    fun shiftAt(x: Float): Float
    fun physical(x: Float, after: Boolean = true): Float
}

private val rubyCjkScripts = setOf(Character.UnicodeScript.HAN, Character.UnicodeScript.HIRAGANA,
    Character.UnicodeScript.KATAKANA, Character.UnicodeScript.HANGUL)
private val rubySymbolTypes = setOf(Character.CONNECTOR_PUNCTUATION.toInt(),
    Character.DASH_PUNCTUATION.toInt(), Character.START_PUNCTUATION.toInt(),
    Character.END_PUNCTUATION.toInt(), Character.INITIAL_QUOTE_PUNCTUATION.toInt(),
    Character.FINAL_QUOTE_PUNCTUATION.toInt(), Character.OTHER_PUNCTUATION.toInt(),
    Character.MATH_SYMBOL.toInt(), Character.CURRENCY_SYMBOL.toInt(),
    Character.MODIFIER_SYMBOL.toInt(), Character.OTHER_SYMBOL.toInt())

/** Finite UA policy for CSS ruby justification: intact CJK letters and same-script
 * punctuation/symbols, excluding separators, Bopomofo, cursive scripts and paired
 * dash/ellipsis traditions. Common resolves from the actual dominant script; a tie
 * needs an actual ja/zh/ko run language. These are candidates, never shaping proof. */
internal fun nativeRubySpacingCandidates(text: String, boundaries: List<Int>,
    languageAt: (Int) -> String): List<Int> = nativeRubySpacingEligibility(text, boundaries, languageAt).cuts

internal data class NativeRubySpacingEligibility(val units: List<Boolean>, val cuts: List<Int>)

/** These are source-policy candidates. The hierarchy also requires actual native
 * glyph proof for every retained interior boundary before admitting a profile. */
internal fun nativeRubySpacingEligibility(text: String, boundaries: List<Int>,
    languageAt: (Int) -> String): NativeRubySpacingEligibility {
    require(boundaries.firstOrNull() == 0 && boundaries.lastOrNull() == text.length &&
        boundaries.zipWithNext().all { (a, b) -> a < b })
    val scripts = mutableMapOf<Character.UnicodeScript, Int>()
    var at = 0
    while (at < text.length) {
        val cp = text.codePointAt(at)
        if (Character.isLetter(cp)) {
            val script = Character.UnicodeScript.of(cp)
            if (script != Character.UnicodeScript.COMMON && script != Character.UnicodeScript.INHERITED)
                scripts[script] = (scripts[script] ?: 0) + 1
        }
        at += Character.charCount(cp)
    }
    val maximum = scripts.values.maxOrNull()
    val dominant = scripts.filterValues { it == maximum }.keys
    fun commonIsCjk(offset: Int): Boolean {
        if (dominant.size == 1) return dominant.single() in rubyCjkScripts
        val language = languageAt(offset).lowercase(Locale.ROOT)
        val selected = when (language) {
            "ja" -> setOf(Character.UnicodeScript.HAN, Character.UnicodeScript.HIRAGANA, Character.UnicodeScript.KATAKANA)
            "zh" -> setOf(Character.UnicodeScript.HAN)
            "ko" -> setOf(Character.UnicodeScript.HAN, Character.UnicodeScript.HANGUL)
            else -> emptySet()
        }
        return selected.isNotEmpty() && (dominant.isEmpty() || dominant.any { it in selected })
    }
    fun eligible(start: Int, end: Int): Boolean {
        var substantive = false
        var index = start
        while (index < end) {
            val cp = text.codePointAt(index)
            val type = Character.getType(cp)
            if (cp == 0xfffc || Character.isWhitespace(cp) || Character.isSpaceChar(cp)) return false
            if (type == Character.NON_SPACING_MARK.toInt() || type == Character.COMBINING_SPACING_MARK.toInt() ||
                type == Character.ENCLOSING_MARK.toInt()) {
                index += Character.charCount(cp); continue
            }
            val script = Character.UnicodeScript.of(cp)
            val letter = Character.isLetter(cp) && script in rubyCjkScripts
            val symbol = type in rubySymbolTypes &&
                (script in rubyCjkScripts || script == Character.UnicodeScript.COMMON && commonIsCjk(index))
            if (!letter && !symbol) return false
            substantive = true
            index += Character.charCount(cp)
        }
        return substantive
    }
    val units = boundaries.zipWithNext().map { (start, end) -> eligible(start, end) }
    val cuts = (1 until boundaries.lastIndex).mapNotNull { index ->
        val cut = boundaries[index]
        cut.takeIf { units[index - 1] && units[index] && nativeRubySpacingEdgeAllowed(
            text.substring(boundaries[index - 1], cut), text.substring(cut, boundaries[index + 1])) }
    }
    return NativeRubySpacingEligibility(units, cuts)
}

/** Both endpoint units must already carry source eligibility. This preserves the
 * paired dash/ellipsis exclusion across independently shaped or nested owners. */
internal fun nativeRubySpacingEdgeAllowed(left: String, right: String): Boolean {
    require(left.isNotEmpty() && right.isNotEmpty())
    val a = left.codePointBefore(left.length)
    val b = right.codePointAt(0)
    val dash = Character.getType(a) == Character.DASH_PUNCTUATION.toInt() &&
        Character.getType(b) == Character.DASH_PUNCTUATION.toInt()
    return !dash && !(a in setOf(0x2026, 0x22ef) && b in setOf(0x2026, 0x22ef))
}

internal data class NativeRubyGlyph(val id: Int, val font: Any, val x: Float, val y: Float)
internal data class NativeRubyGlyphRun(val advance: Float, val glyphs: List<NativeRubyGlyph>)
// Public native glyph coordinates are floats. Allow only arithmetic rounding at that
// run's actual scale, not a fixed minimum gap which would erase a tiny authored advance.
private fun rubyClose(a: Float, b: Float, scale: Float = maxOf(abs(a), abs(b))): Boolean =
    a.isFinite() && b.isFinite() && scale.isFinite() &&
        abs(a - b) <= 4f * Math.ulp(maxOf(abs(a), abs(b), abs(scale)))

/** Compare actual native glyph/font/position output, including RTL physical order.
 * A shared glyph, lost cluster, font change or changed advance refuses that cut. */
internal fun nativeRubyEquivalentSplit(whole: NativeRubyGlyphRun, first: NativeRubyGlyphRun,
    second: NativeRubyGlyphRun, rtl: Boolean): Boolean {
    if (first.advance <= 0f || second.advance <= 0f ||
        !rubyClose(whole.advance, first.advance + second.advance)) return false
    val pieces = if (rtl) second.glyphs + first.glyphs.map { it.copy(x = it.x + second.advance) }
        else first.glyphs + second.glyphs.map { it.copy(x = it.x + first.advance) }
    return rubyGlyphsEqual(whole.glyphs, pieces, whole.advance)
}
private fun rubyGlyphsEqual(first: List<NativeRubyGlyph>, second: List<NativeRubyGlyph>, scale: Float): Boolean {
    if (first.size != second.size) return false
    val a = first.groupBy { it.id to it.font }
    val b = second.groupBy { it.id to it.font }
    if (a.keys != b.keys) return false
    val order = compareBy<NativeRubyGlyph>({ it.x }, { it.y })
    return a.all { (key, values) ->
        val other = b.getValue(key)
        values.size == other.size && values.sortedWith(order).zip(other.sortedWith(order)).all { (x, y) ->
            rubyClose(x.x, y.x, scale) && rubyClose(x.y, y.y, scale)
        }
    }
}

internal data class NativeRubyPhysicalCut(val sourceOffset: Int, val x: Float)
internal class NativeRubySpacingMap(val origin: Float, advance: Float, allocation: Float,
    cuts: List<NativeRubyPhysicalCut>, parentIncrement: NativeRubySpacingIncrement? = null) : NativeRubyPhysicalMap {
    val cuts = cuts.sortedBy { it.x }
    private val intrinsic = nativeRubyAroundSpacing(advance, allocation, cuts.size)
    private val spacing = NativeRubyAroundSpacing(intrinsic.edge + (parentIncrement?.left ?: 0f),
        intrinsic.interior + (parentIncrement?.unit ?: 0f))
    override val minimumShift = spacing.edge - origin
    override val maximumShift = minimumShift + cuts.size * spacing.interior
    init {
        require(origin.isFinite() && this.cuts.all { it.x.isFinite() && it.x > origin && it.x < origin + advance })
        require(this.cuts.zipWithNext().all { (a, b) -> b.x > a.x })
        require(this.cuts.map { it.sourceOffset }.distinct().size == this.cuts.size)
    }
    private fun before(x: Float, after: Boolean): Int {
        var low = 0
        var high = cuts.size
        while (low < high) {
            val middle = (low + high) ushr 1
            if (if (after) x >= cuts[middle].x else x > cuts[middle].x) low = middle + 1 else high = middle
        }
        return low
    }
    override fun shiftAt(x: Float): Float = minimumShift + before(x, true) * spacing.interior
    override fun physical(x: Float, after: Boolean): Float = x + minimumShift +
        before(x, after) * spacing.interior
    fun original(x: Float): Float {
        var shift = minimumShift
        cuts.forEach { cut ->
            val before = cut.x + shift
            if (x < before) return x - shift
            if (x < before + spacing.interior) return cut.x
            shift += spacing.interior
        }
        return x - shift
    }
}

private data class RubyRun(val start: Int, val end: Int, val contextStart: Int, val contextEnd: Int,
    val x: Float, val rtl: Boolean, val paint: TextPaint, val shape: NativeRubyGlyphRun)
private data class RubyRunPiece(val start: Int, val end: Int, val left: Float, val advance: Float)
private data class RubyRunPlan(val run: RubyRun, val pieces: List<RubyRunPiece>)

private fun rubyShape(text: CharSequence, start: Int, end: Int, contextStart: Int, contextEnd: Int,
    rtl: Boolean, paint: Paint): NativeRubyGlyphRun = rubyGlyphs(TextRunShaper.shapeTextRun(text,
    start, end - start, contextStart, contextEnd - contextStart, 0f, 0f, rtl, paint))
private fun rubyGlyphs(value: PositionedGlyphs): NativeRubyGlyphRun {
    val glyphs = (0 until value.glyphCount()).map { index -> NativeRubyGlyph(value.getGlyphId(index), value.getFont(index),
        value.getGlyphX(index) - value.offsetX, value.getGlyphY(index) - value.offsetY) }
    if (!value.advance.isFinite() || value.advance < 0f || glyphs.any { !it.x.isFinite() || !it.y.isFinite() })
        throw UnsupportedFloatLayout("Ruby shaping returned non-finite native coordinates")
    return NativeRubyGlyphRun(value.advance, glyphs)
}

/** Translates existing full-context native dispatch. The probe validates every primitive
 * before this canvas is retained for painting; no display list or second painter is built. */
private class RubySpacingCanvas(private val source: CharSequence, private val lineStart: Int,
    private val target: Canvas? = null, private val map: NativeRubyPhysicalMap? = null,
    private val plans: List<RubyRunPlan> = emptyList(), private val top: Float = 0f,
    private val nested: List<RubyNestedReplay> = emptyList()) : Canvas(), NativeRubyAtomicCanvas {
    private data class State(val x: Float, val y: Float, val targetSave: Int?)
    private val saved = mutableListOf(State(0f, 0f, null))
    val runs = mutableListOf<RubyRun>()
    val atoms = mutableListOf<RubyNativeAtom>()
    override fun save(): Int = saved.size.also { saved += saved.last().copy(targetSave = target?.save()) }
    override fun getSaveCount(): Int = saved.size
    override fun restore() {
        check(saved.size > 1)
        val previous = saved.removeAt(saved.lastIndex)
        previous.targetSave?.let { target?.restoreToCount(it) }
    }
    override fun restoreToCount(saveCount: Int) {
        check(saveCount in 1..saved.size)
        while (saved.size > saveCount) restore()
    }
    override fun translate(dx: Float, dy: Float) {
        val previous = saved.last()
        saved[saved.lastIndex] = previous.copy(x = previous.x + dx, y = previous.y + dy)
    }
    override fun getClipBounds(bounds: Rect): Boolean {
        bounds.set(-TablePixelLimit, -TablePixelLimit, TablePixelLimit, TablePixelLimit)
        return true
    }
    private fun x(value: Float, after: Boolean = true): Float {
        val original = value + saved.last().x
        return map?.physical(original, after) ?: original
    }
    private fun y(value: Float) = value + saved.last().y - top
    override fun clipRect(left: Float, top: Float, right: Float, bottom: Float): Boolean =
        target?.clipRect(x(left), y(top), x(right, false), y(bottom)) ?: true
    override fun clipRect(rect: RectF): Boolean = clipRect(rect.left, rect.top, rect.right, rect.bottom)
    override fun clipRect(rect: Rect): Boolean = clipRect(rect.left.toFloat(), rect.top.toFloat(), rect.right.toFloat(), rect.bottom.toFloat())
    override fun drawRect(left: Float, top: Float, right: Float, bottom: Float, paint: Paint) {
        target?.drawRect(x(left), y(top), x(right, false), y(bottom), paint)
    }
    override fun drawRect(rect: RectF, paint: Paint) = drawRect(rect.left, rect.top, rect.right, rect.bottom, paint)
    override fun drawRect(rect: Rect, paint: Paint) = drawRect(rect.left.toFloat(), rect.top.toFloat(), rect.right.toFloat(), rect.bottom.toFloat(), paint)
    override fun drawLine(startX: Float, startY: Float, stopX: Float, stopY: Float, paint: Paint) {
        if (!rubyClose(startY, stopY)) unsupported()
        target?.drawLine(x(startX), y(startY), x(stopX, false), y(stopY), paint)
    }
    override fun paintRubyAtom(x: Float, y: Float, draw: (Canvas) -> Unit) {
        val output = target ?: return
        val save = output.save()
        try { output.translate(this.x(x), this.y(y)); draw(output) }
        finally { output.restoreToCount(save) }
    }
    override fun paintRubyAtom(column: NativeRubyColumn, x: Float, y: Float, draw: (Canvas) -> Unit) {
        val px = x + saved.last().x
        val py = y + saved.last().y
        if (target == null) { atoms += RubyNativeAtom(column, px, py); return }
        if (nested.isEmpty()) { paintRubyAtom(x, y, draw); return }
        val replacement = nested.singleOrNull { it.original === column && rubyClose(it.originalX, px) && rubyClose(it.baseline, py) }
            ?: throw UnsupportedFloatLayout("Ruby nested dispatch lost its measured occurrence")
        val output = target
        val save = output.save()
        try { output.translate(replacement.x, replacement.y); replacement.view.paint(output) }
        finally { output.restoreToCount(save) }
    }
    private fun run(start: Int, end: Int, contextStart: Int, contextEnd: Int,
        x: Float, y: Float, rtl: Boolean, paint: Paint, draw: (Int, Int, Float, Float) -> Unit) {
        if (start == end) return
        if (start < contextStart || end > contextEnd || contextStart < 0 || contextEnd > source.length ||
            paint.textAlign != Paint.Align.LEFT || (paint.startHyphenEdit != 0 || paint.endHyphenEdit != 0))
            unsupported()
        val physicalX = x + saved.last().x
        if (target == null) {
            val copy = TextPaint(paint)
            val shape = rubyShape(source, start, end, contextStart, contextEnd, rtl, copy)
            runs += RubyRun(start, end, contextStart, contextEnd, physicalX, rtl, copy, shape)
            return
        }
        val plan = plans.firstOrNull { candidate ->
            val value = candidate.run
            value.start == start && value.end == end && value.contextStart == contextStart && value.contextEnd == contextEnd &&
                value.rtl == rtl && rubyClose(value.x, physicalX) && value.paint.equalsForTextMeasurement(paint)
        } ?: throw UnsupportedFloatLayout("Ruby native paint no longer matches its measured spacing")
        plan.pieces.forEach { piece ->
            val left = physicalX + piece.left
            val shift = checkNotNull(map).shiftAt(left + piece.advance / 2f)
            draw(piece.start, piece.end, left + shift, this.y(y))
        }
    }
    override fun drawTextRun(text: CharSequence, start: Int, end: Int, contextStart: Int,
        contextEnd: Int, x: Float, y: Float, isRtl: Boolean, paint: Paint) {
        if (contextStart < 0 || contextEnd > text.length || contextEnd > source.length ||
            (contextStart until contextEnd).any { text[it] != source[it] }) unsupported()
        run(start, end, contextStart, contextEnd, x, y, isRtl, paint) { a, b, px, py ->
            target?.drawTextRun(text, a, b, contextStart, contextEnd, px, py, isRtl, paint)
        }
    }
    override fun drawTextRun(text: CharArray, index: Int, count: Int, contextIndex: Int,
        contextCount: Int, x: Float, y: Float, isRtl: Boolean, paint: Paint) {
        // Public Android TextLine.drawTextRun rebases its replacement buffer to the
        // selected line start; its CharSequence overload already uses absolute indices.
        if (contextIndex < 0 || contextIndex + contextCount > text.size ||
            contextIndex + contextCount + lineStart > source.length ||
            (contextIndex until contextIndex + contextCount).any { text[it] != source[lineStart + it] }) unsupported()
        run(lineStart + index, lineStart + index + count, lineStart + contextIndex,
            lineStart + contextIndex + contextCount, x, y, isRtl, paint) { a, b, px, py ->
            target?.drawTextRun(text, a - lineStart, b - a, contextIndex, contextCount, px, py, isRtl, paint)
        }
    }
    private fun unsupported(): Nothing = throw UnsupportedFloatLayout("Ruby spacing requires owned native run dispatch")
    override fun drawText(text: CharArray, index: Int, count: Int, x: Float, y: Float, paint: Paint) = unsupported()
    override fun drawText(text: String, x: Float, y: Float, paint: Paint) = unsupported()
    override fun drawText(text: String, start: Int, end: Int, x: Float, y: Float, paint: Paint) = unsupported()
    override fun drawText(text: CharSequence, start: Int, end: Int, x: Float, y: Float, paint: Paint) = unsupported()
    override fun drawPath(path: Path, paint: Paint) = unsupported()
    override fun drawCircle(cx: Float, cy: Float, radius: Float, paint: Paint) = unsupported()
    override fun drawOval(oval: RectF, paint: Paint) = unsupported()
    override fun drawRoundRect(rect: RectF, rx: Float, ry: Float, paint: Paint) = unsupported()
    override fun drawBitmap(bitmap: Bitmap, left: Float, top: Float, paint: Paint?) = unsupported()
    override fun drawBitmap(bitmap: Bitmap, src: Rect?, dst: RectF, paint: Paint?) = unsupported()
    override fun drawBitmap(bitmap: Bitmap, src: Rect?, dst: Rect, paint: Paint?) = unsupported()
    override fun scale(sx: Float, sy: Float) = unsupported()
    override fun rotate(degrees: Float) = unsupported()
    override fun skew(sx: Float, sy: Float) = unsupported()
    override fun concat(matrix: Matrix?) = unsupported()
    override fun setMatrix(matrix: Matrix?) = unsupported()
}

private fun rubyRunPlans(source: CharSequence,
    runs: List<RubyRun>, candidateCuts: List<Int>): Pair<List<NativeRubyPhysicalCut>, List<RubyRunPlan>> {
    // These are the actual shaped line's source/context/direction tuples. Do not run
    // a soft fragment through a new paragraph bidi pass: an isolate may begin earlier.
    val distinct = runs.fold(mutableListOf<RubyRun>()) { output, run ->
        if (output.none { it.start == run.start && it.end == run.end && it.contextStart == run.contextStart &&
            it.contextEnd == run.contextEnd && rubyClose(it.x, run.x) && it.rtl == run.rtl &&
            it.paint.equalsForTextMeasurement(run.paint) }) output += run
        output
    }
    val cuts = mutableListOf<NativeRubyPhysicalCut>()
    candidateCuts.forEach { offset ->
        val inside = distinct.singleOrNull { offset > it.start && offset < it.end }
        if (inside != null) {
            val first = rubyShape(source, inside.start, offset, inside.contextStart, inside.contextEnd, inside.rtl, inside.paint)
            val second = rubyShape(source, offset, inside.end, inside.contextStart, inside.contextEnd, inside.rtl, inside.paint)
            if (nativeRubyEquivalentSplit(inside.shape, first, second, inside.rtl))
                cuts += NativeRubyPhysicalCut(offset, inside.x + if (inside.rtl) second.advance else first.advance)
        } else {
            val before = distinct.singleOrNull { it.end == offset }
            val after = distinct.singleOrNull { it.start == offset }
            if (before != null && after != null && before.rtl == after.rtl) {
                val a = before.shape
                val b = after.shape
                val boundary = if (before.rtl) before.x else before.x + a.advance
                val adjacent = if (before.rtl) rubyClose(after.x + b.advance, boundary) else rubyClose(after.x, boundary)
                val sameMetrics = before.paint.equalsForTextMeasurement(after.paint)
                val safe = !sameMetrics || nativeRubyEquivalentSplit(rubyShape(source, before.start, after.end,
                    minOf(before.contextStart, after.contextStart), maxOf(before.contextEnd, after.contextEnd),
                    before.rtl, before.paint), a, b, before.rtl)
                if (adjacent && safe) cuts += NativeRubyPhysicalCut(offset, boundary)
            }
        }
    }
    val selected = cuts.sortedBy { it.x }
    if (selected.zipWithNext().any { (a, b) -> a.x == b.x })
        throw UnsupportedFloatLayout("Ruby opportunities have indistinguishable native coordinates")
    val plans = distinct.map { run ->
        val boundaries = listOf(run.start) + selected.map { it.sourceOffset }.filter { it > run.start && it < run.end }.sorted() + run.end
        val composed = mutableListOf<NativeRubyGlyph>()
        val pieces = boundaries.zipWithNext().map { (start, end) ->
            val shape = rubyShape(source, start, end, run.contextStart, run.contextEnd, run.rtl, run.paint)
            val prefix = if (start == run.start) 0f else rubyShape(source, run.start, start,
                run.contextStart, run.contextEnd, run.rtl, run.paint).advance
            val left = if (run.rtl) run.shape.advance - prefix - shape.advance else prefix
            composed += shape.glyphs.map { it.copy(x = it.x + left) }
            val physicalLeft = run.x + left
            val physicalRight = physicalLeft + shape.advance
            if (selected.any { it.x > physicalLeft && it.x < physicalRight &&
                    !rubyClose(it.x, physicalLeft) && !rubyClose(it.x, physicalRight) })
                throw UnsupportedFloatLayout("Ruby cut crosses an intact native run fragment")
            RubyRunPiece(start, end, left, shape.advance)
        }
        val whole = run.shape
        if (!rubyGlyphsEqual(whole.glyphs, composed, whole.advance))
            throw UnsupportedFloatLayout("Ruby distributed fragments changed native shaping")
        RubyRunPlan(run, pieces)
    }
    return selected to plans
}

/** One selected native row, with original public UTF-16 ranges and one physical spacing map.
 * Native shaping, bidi and styles remain the original owner's; only proved gaps are added. */
internal fun nativeRubyDistribute(geometry: NativeFloatGeometry, advance: Float, allocation: Float,
    line: Int = 0, parentIncrement: NativeRubySpacingIncrement? = null): FloatTextGeometry {
    require(geometry.nodes.isEmpty() && allocation.isFinite() && allocation >= advance && advance >= 0f)
    if (geometry.hasPreciseClips || geometry.positionedGroups.isNotEmpty())
        throw UnsupportedFloatLayout("Ruby row requires its original text-only paint owner")
    if (allocation > TablePixelLimit) throw UnsupportedFloatLayout("Ruby spacing exceeds native coordinates")
    val source = geometry.nativeRubyRaw.nativeRubyShapingSource
    val lineStart = geometry.nativeRubyLineSourceStart(line)
    val lineEnd = geometry.nativeRubyRaw.nativeRangeOfLine(line).second
    val owned = geometry.nativeRubyLineRanges(line).filter { it.first < it.second }
    require(owned.all { it.first >= 0 && it.second <= geometry.text.length } &&
        owned.zipWithNext().all { (a, b) -> a.second <= b.first })
    val bounds = geometry.nativeRubyLineAdvanceBounds(line)
    val origin = bounds?.left ?: 0f
    val top = geometry.nativeRubyLineTop(line)
    val baseline = geometry.nativeRubyLineBaseline(line)
    val height = geometry.nativeRubyRaw.nativeUsedLineMetrics(line).height
    fun result(cuts: List<NativeRubyPhysicalCut>, plans: List<RubyRunPlan>): FloatTextGeometry {
        val width = allocation.toDouble() + (parentIncrement?.left ?: 0f) + (parentIncrement?.right ?: 0f) +
            cuts.size.toDouble() * (parentIncrement?.unit ?: 0f)
        if (!width.isFinite() || width > TablePixelLimit)
            throw UnsupportedFloatLayout("Ruby spacing exceeds native coordinates")
        return NativeRubyDistributedLine(geometry, line, owned,
            NativeRubySpacingMap(origin, advance, allocation, cuts, parentIncrement),
            plans, width.toFloat(), height, top, baseline)
    }
    if (allocation == advance && (parentIncrement == null || parentIncrement.isZero)) return result(emptyList(), emptyList())
    if (source.getSpans(lineStart, lineEnd, NativeRubyColumn::class.java).any {
            source.getSpanStart(it) in lineStart until lineEnd } || geometry.nativeRubyCollapsedText.any { gap ->
            owned.any { it.first < gap.end && it.second > gap.start } }) {
        val hierarchy = rubyHierarchySource(geometry, line)
        if (hierarchy.profile.zeroOpportunities && (parentIncrement == null || parentIncrement.isZero))
            return result(emptyList(), emptyList())
        return rubyHierarchyDistribute(geometry, line, advance, allocation, hierarchy, parentIncrement)
    }
    val text = source.subSequence(lineStart, lineEnd).toString()
    val breaker = BreakIterator.getCharacterInstance(geometry.nativeRubyRaw.nativeRubyShapingPaint.textLocale)
    breaker.setText(text)
    val boundaries = mutableListOf<Int>()
    var boundary = breaker.first()
    while (boundary != BreakIterator.DONE) { boundaries += boundary; boundary = breaker.next() }
    // If even the permissive CJK-language candidate pass has no opportunity, preserve
    // native painting intact. A Latin/cursive row needs no shaping API or canvas adapter.
    if (text.isEmpty() || listOf("ja", "zh", "ko").all { language ->
            nativeRubySpacingCandidates(text, boundaries) { language }.isEmpty() })
        return result(emptyList(), emptyList())
    val probe = RubySpacingCanvas(source, lineStart)
    geometry.paintRubyNativeLine(probe, line)
    val candidates = if (text.isEmpty()) emptyList() else nativeRubySpacingCandidates(text, boundaries) { offset ->
        probe.runs.firstOrNull { lineStart + offset in it.start until it.end }?.paint?.textLocale?.language
            ?: geometry.nativeRubyRaw.nativeRubyShapingPaint.textLocale.language
    }.map { it + lineStart }
    val (cuts, plans) = if (candidates.isEmpty()) emptyList<NativeRubyPhysicalCut>() to emptyList<RubyRunPlan>()
        else rubyRunPlans(source, probe.runs, candidates)
    if (parentIncrement != null && cuts.size != candidates.size)
        throw UnsupportedFloatLayout("Ruby parent increment lost its complete native opportunity proof")
    return result(cuts, plans)
}

private class NativeRubyDistributedLine(private val owner: NativeFloatGeometry, private val line: Int,
    private val owned: List<Pair<Int, Int>>, private val map: NativeRubySpacingMap,
    private val plans: List<RubyRunPlan>, allocation: Float, lineHeight: Float,
    private val top: Float, baseline: Float) : FloatTextGeometry {
    override val text: CharSequence get() = owner.text
    override val width = ceil(allocation.toDouble()).toInt()
    override val height = ceil(lineHeight.toDouble()).toInt()
    override val nodes = emptyList<FloatInteractionNode>()
    override val textBaselines = NativeTextBaselines(baseline - top, baseline - top)
    override val hasPreciseClips get() = owner.hasPreciseClips
    private fun owns(offset: Int) = owned.any { offset >= it.first && offset < it.second }
    private fun affinity(offset: Int): Int? = if (owns(offset)) offset else
        owned.lastOrNull { it.second == offset }?.let { it.second - 1 }
    private fun shift(offset: Int): Float {
        if (map.cuts.isEmpty()) return map.minimumShift
        val raw = owner.nativeRubyRawOffset(offset)
        plans.firstNotNullOfOrNull { plan -> plan.pieces.firstOrNull { raw >= it.start && raw < it.end }?.let {
            map.shiftAt(plan.run.x + it.left + it.advance / 2f)
        } }?.let { return it }
        val native = owner.nativeRubyRaw
        val source = native.nativeRubyShapingSource
        val atom = raw < source.length && source.getSpans(raw, raw + 1, NativeRubyColumn::class.java).any {
            source.getSpanStart(it) <= raw && source.getSpanEnd(it) > raw
        }
        val x = if (atom) native.nativeReplacementOrigin(raw).first else native.caretRect(raw).left
        return map.shiftAt(x)
    }
    private fun translated(rect: RectF, shift: Float): RectF = RectF(rect).apply { offset(shift, -top) }
    private fun parts(start: Int, end: Int): List<Triple<Int, Int, Float>> {
        require(start in 0..text.length && end in start..text.length)
        val result = mutableListOf<Triple<Int, Int, Float>>()
        owned.forEach { range ->
            var at = maxOf(start, range.first)
            val limit = minOf(end, range.second)
            while (at < limit) {
                val begin = at
                val value = shift(at++)
                while (at < limit && shift(at) == value) at++
                result += Triple(begin, at, value)
            }
        }
        return result
    }
    override fun rectsForRange(start: Int, end: Int): List<RectF> = parts(start, end).flatMap { (a, b, shift) ->
        owner.nativeRubyLineRects(line, a, b).map { translated(it, shift) }
    }
    override fun inlinePaddingGroupRects(owner: Span, start: Int, end: Int): List<RectF>? {
        val fragments = parts(start, end)
        if (fragments.isEmpty()) return null
        val bounds = this.owner.inlinePaddingGroupRects(owner, start, end) ?: return null
        val fragment = fragments.singleOrNull()
        if (fragment == null || fragment.first != start || fragment.second != end)
            throw UnsupportedFloatLayout("Inline padding group crosses a Ruby spacing fragment")
        return bounds.map { translated(it, fragment.third) }
    }
    override fun characterRects(start: Int, length: Int): List<RectF?> {
        require(start in 0..text.length && length >= 0 && length <= text.length - start)
        return (start until start + length).map { offset ->
            if (!owns(offset)) null else {
                val begin = if (offset > 0 && Character.isLowSurrogate(text[offset]) &&
                    Character.isHighSurrogate(text[offset - 1])) offset - 1 else offset
                val end = if (Character.isHighSurrogate(text[begin]) && begin + 1 < text.length &&
                    Character.isLowSurrogate(text[begin + 1])) begin + 2 else begin + 1
                rectsForRange(begin, end).reduceOrNull { a, b -> a.apply { union(b) } }
            }
        }
    }
    override fun caretRect(offset: Int): RectF {
        require(offset in 0..text.length)
        val caret = owner.nativeRubyLineCaret(line, offset) ?: return RectF()
        return translated(caret, shift(affinity(offset) ?: return RectF()))
    }
    override fun clipForOffset(offset: Int): RectF? {
        val source = affinity(offset) ?: return RectF()
        return owner.clipForOffset(source)?.let { translated(it, shift(source)) }
    }
    override fun preciseClipForOffset(offset: Int): NativeTextClip? {
        val source = affinity(offset) ?: return NativeTextClip.rectangle(RectF())
        return owner.preciseClipForOffset(source)?.translated(shift(source), -top)
    }
    override fun containsInteraction(x: Float, y: Float): Boolean = rectsForRange(0, text.length).any { it.contains(x, y) }
    override fun offsetForPosition(x: Float, y: Float): Int {
        val fragments = parts(0, text.length)
        fragments.forEach { (a, b, shift) ->
            if (owner.nativeRubyLineRects(line, a, b).any { translated(it, shift).contains(x, y) })
                return owner.nativeRubyLineOffsetForPosition(line, x - shift, y + top).coerceIn(a, b)
        }
        val offset = owner.nativeRubyLineOffsetForPosition(line, map.original(x), y + top)
        return owned.firstOrNull { offset in it.first..it.second }?.let { offset }
            ?: owned.flatMap { listOf(it.first, it.second) }.minByOrNull { abs(it - offset) } ?: 0
    }
    override fun lineRange(offset: Int): Pair<Int, Int> = owner.lineRange(offset)
    override fun isHardLineBreak(offset: Int): Boolean = owner.isHardLineBreak(offset)
    override fun visualLineRanges(offset: Int): List<Pair<Int, Int>> = if (affinity(offset) == null) emptyList() else owned
    override fun visualOffset(offset: Int, direction: Int): Int {
        require(offset in 0..text.length && direction in listOf(-1, 1))
        if (affinity(offset) == null) return offset
        val next = owner.visualOffset(offset, direction)
        // Crossing this selected row belongs to the enclosing Ruby/paragraph owner.
        return if (affinity(next) != null) next else offset
    }
    override fun cursorAt(x: Float, y: Float): InlineCursor? {
        if (!containsInteraction(x, y)) return null
        val offset = offsetForPosition(x, y)
        return if (owns(offset)) owner.nativeRubyLineCursorAt(line, x - shift(offset), y + top) else null
    }
    override fun paintSelection(canvas: Canvas, start: Int, end: Int, paint: Paint) {
        // Ruby children are text/Ruby only. Ancestor clips remain outside this owner;
        // using the selected native line avoids Layout's cross-line highlight filler.
        rectsForRange(start, end).forEach { canvas.drawRect(it, paint) }
    }
    override fun paint(canvas: Canvas) {
        if (map.cuts.isEmpty()) {
            val save = canvas.save()
            try { canvas.translate(map.minimumShift, -top); owner.paintRubyNativeLine(canvas, line) }
            finally { canvas.restoreToCount(save) }
        } else {
            val save = canvas.save()
            try { owner.paintRubyNativeLine(RubySpacingCanvas(owner.nativeRubyRaw.nativeRubyShapingSource,
                owner.nativeRubyLineSourceStart(line), canvas, map, plans, top), line) }
            finally { canvas.restoreToCount(save) }
        }
    }
    override val ordinaryPaintBounds: List<NativeFloatBounds> get() = owner.nativeRubyLinePaintBounds(line).map {
        NativeFloatBounds(it.left + map.minimumShift, it.top - top, it.right + map.maximumShift, it.bottom - top)
    }
    override val extents: NativeGeometryExtents get() = NativeGeometryExtents(width, height.toFloat(),
        ordinaryPaintBounds.reduceOrNull { a, b -> a.enclosing(b) }, nativeBoundsOf(rectsForRange(0, text.length)))
}


private data class RubyNativeAtom(val column: NativeRubyColumn, val x: Float, val baseline: Float)
private data class RubyHierarchyRegion(val text: String, val native: List<Int>, val sourceOffsets: List<Int>,
    val boundaries: List<Int>, val language: (Int) -> String, val policy: NativeRubySpacingEligibility)
private data class RubyHierarchySlot(val nativeStart: Int, val start: Int, val end: Int,
    val left: Float, val right: Float, val profile: NativeRubySpacingProfile,
    val column: NativeRubyColumn? = null, val baseline: Float = 0f,
    val view: FloatTextGeometry? = null, val ranges: List<Pair<Int, Int>> = listOf(start to end),
    val nativeOffsets: List<Int> = emptyList())
private data class RubyHierarchySource(val profile: NativeRubySpacingProfile,
    val slots: List<RubyHierarchySlot>, val plans: List<RubyRunPlan>, val silent: List<Pair<Int, Int>>)
private data class RubyNestedReplay(val original: NativeRubyColumn, val nativeStart: Int, val originalX: Float,
    val baseline: Float, val x: Float, val y: Float, val view: FloatTextGeometry,
    val ranges: List<Pair<Int, Int>>)

/** A complete base-row certificate, including eligible opportunities inside nested
 * Ruby. Complete all-ineligible rows keep native intact centering; an exception or
 * private U+FFFC is never evidence that a row has zero opportunities. */
internal fun nativeRubySpacingProfile(geometry: NativeFloatGeometry, line: Int = 0): NativeRubySpacingProfile =
    rubyHierarchySource(geometry, line).profile

private fun rubyHierarchySource(owner: NativeFloatGeometry, line: Int): RubyHierarchySource {
    if (owner.nodes.isNotEmpty() || owner.hasPreciseClips || owner.positionedGroups.isNotEmpty())
        throw UnsupportedFloatLayout("Ruby hierarchy requires its original native text owner")
    val raw = owner.nativeRubyRaw
    val source = raw.nativeRubyShapingSource
    val lineStart = owner.nativeRubyLineSourceStart(line)
    val lineEnd = raw.nativeRangeOfLine(line).second
    val owned = owner.nativeRubyLineRanges(line).filter { it.first < it.second }
    val probe = RubySpacingCanvas(source, lineStart)
    owner.paintRubyNativeLine(probe, line)
    val columns = source.getSpans(lineStart, lineEnd, NativeRubyColumn::class.java).filter {
        source.getSpanStart(it) in lineStart until lineEnd
    }.sortedBy(source::getSpanStart)
    val nested = columns.map { column ->
        val at = source.getSpanStart(column)
        if (source.getSpanEnd(column) != at + 1 || source[at] != '\ufffc')
            throw UnsupportedFloatLayout("Ruby hierarchy requires exact retained replacement occurrences")
        val origin = raw.nativeReplacementOrigin(at)
        val observed = probe.atoms.filter { it.column === column }
        if (observed.isEmpty() || observed.any { !rubyClose(it.x, origin.first) || !rubyClose(it.baseline, origin.second) })
            throw UnsupportedFloatLayout("Ruby hierarchy lacks actual replacement draw coordinates")
        val view = owner.nativeRubyColumnView(at, column)
        val profile = column.spacingProfile()
        val anchors = column.children.flatMap { it.ranges }
        val ranges = anchors.filter { it.first < it.second }.sortedBy { it.first }
        if (ranges.isEmpty() && (!profile.sourceEmpty || anchors.isEmpty()))
            throw UnsupportedFloatLayout("Ruby hierarchy lacks its original empty source identity")
        val start = ranges.firstOrNull()?.first ?: anchors.minOf { it.first }
        val end = ranges.lastOrNull()?.second ?: start
        RubyHierarchySlot(at, start, end, origin.first,
            origin.first + column.reserved, profile, column, origin.second, view, ranges)
    }
    if (probe.atoms.any { atom -> columns.none { it === atom.column } })
        throw UnsupportedFloatLayout("Ruby hierarchy acquired an unowned nested draw")
    // This metadata is the compiler's actual contextual/line-edge decision. Raw
    // CR/LF/HT bytes alone never grant a retained spacing item or a native line.
    val gaps = owner.nativeRubyCollapsedText.filter { gap ->
        owned.any { it.first < gap.end && it.second > gap.start }
    }
    if (gaps.any { gap -> !owned.any { it.first <= gap.start && it.second >= gap.end } })
        throw UnsupportedFloatLayout("Ruby gap lost its selected-line source ownership")
    val retained = gaps.filter { !it.trimmed && it.nativeEnd > it.nativeStart }
    val silent = gaps.filter { it.trimmed || it.nativeEnd == it.nativeStart }.map { it.start to it.end }
    val publicAt = mutableMapOf<Int, Int>()
    owned.forEach { (first, last) -> for (offset in first until last) {
        if (nested.any { slot -> slot.ranges.any { offset in it.first until it.second } } ||
            gaps.any { offset in it.start until it.end }) continue
        val native = owner.nativeRubyRawOffset(offset)
        if (native !in lineStart until lineEnd || source[native] != owner.text[offset] || publicAt.put(native, offset) != null)
            throw UnsupportedFloatLayout("Ruby hierarchy retains an unowned source map")
    } }
    val regions = mutableListOf<RubyHierarchyRegion>()
    val native = mutableListOf<Int>()
    fun flush() {
        if (native.isEmpty()) return
        val positions = native.toList(); native.clear()
        val offsets = positions.map { publicAt.getValue(it) }
        if (offsets.zipWithNext().any { (a, b) -> b != a + 1 })
            throw UnsupportedFloatLayout("Ruby ordinary profile is not a complete source fragment")
        val text = positions.map { source[it] }.joinToString("")
        val breaker = BreakIterator.getCharacterInstance(raw.nativeRubyShapingPaint.textLocale)
        breaker.setText(text)
        val boundaries = mutableListOf<Int>()
        var at = breaker.first()
        while (at != BreakIterator.DONE) { boundaries += at; at = breaker.next() }
        val language: (Int) -> String = { offset ->
            probe.runs.firstOrNull { positions[offset] in it.start until it.end }?.paint?.textLocale?.language
                ?: raw.nativeRubyShapingPaint.textLocale.language
        }
        regions += RubyHierarchyRegion(text, positions, offsets, boundaries, language,
            nativeRubySpacingEligibility(text, boundaries, language))
    }
    for (at in lineStart until lineEnd) {
        if (gaps.any { it.nativeStart == at }) flush()
        when {
            nested.any { it.nativeStart == at } -> flush()
            gaps.any { at in it.nativeStart until it.nativeEnd } -> Unit
            at in publicAt -> native += at
            source[at] in '\u2066'..'\u2069' -> Unit
            at == lineEnd - 1 && source[at] == '\n' -> Unit
            else -> throw UnsupportedFloatLayout("Ruby hierarchy contains an unowned native source unit")
        }
    }
    flush()
    if (nested.isEmpty() && regions.isEmpty() && retained.isEmpty())
        throw UnsupportedFloatLayout("Ruby hierarchy has no complete visible base source")
    val eligibleCuts = regions.flatMap { region -> region.policy.cuts.map { region.native[it] } }
    val gapDispatchCuts = gaps.flatMap { listOf(it.nativeStart, it.nativeEnd) }.filter { at ->
        probe.runs.any { at > it.start && at < it.end }
    }
    val dispatchCuts = (eligibleCuts + gapDispatchCuts).distinct()
    val proof = rubyRunPlans(source, probe.runs, dispatchCuts)
    if (proof.first.map { it.sourceOffset }.sorted() != dispatchCuts.sorted())
        throw UnsupportedFloatLayout("Ruby hierarchy lacks every native dispatch-cut proof")
    val plans = proof.second
    val ownedNative = publicAt.keys + retained.flatMap { (it.nativeStart until it.nativeEnd).toList() }
    fun fragments(positions: List<Int>): List<Pair<RubyRunPlan, RubyRunPiece>> = plans.flatMap { plan ->
        plan.pieces.mapNotNull { piece ->
            if (positions.none { it in piece.start until piece.end }) return@mapNotNull null
            if (ownedNative.any { it in piece.start until piece.end && it !in positions })
                throw UnsupportedFloatLayout("Ruby glyph dispatch crosses an unproved source piece")
            if (piece.advance <= 0f) null else plan to piece
        }
    }
    fun left(fragment: Pair<RubyRunPlan, RubyRunPiece>) = fragment.first.run.x + fragment.second.left
    fun right(fragment: Pair<RubyRunPlan, RubyRunPiece>) = left(fragment) + fragment.second.advance
    val ordinary = regions.flatMap { region ->
        val pieces = NativeRubySpacingProfile.sourcePieces(region.text, region.boundaries, region.language,
            region.policy.cuts, complete = true)
        pieces.map { piece ->
            val positions = region.native.subList(piece.start, piece.end)
            val draws = fragments(positions)
            if (draws.isEmpty()) throw UnsupportedFloatLayout("Ruby source piece has no distinguishable native advance")
            fun edge(draw: Pair<RubyRunPlan, RubyRunPiece>, physicalFirst: Boolean): NativeRubySpacingEdge {
                val present = positions.filter { it in draw.second.start until draw.second.end }
                val at = if (physicalFirst != draw.first.run.rtl) present.first() else present.last()
                val offset = region.native.indexOf(at)
                val found = region.boundaries.binarySearch(offset)
                val index = if (found >= 0) found else -found - 2
                return NativeRubySpacingEdge(region.text.substring(region.boundaries[index], region.boundaries[index + 1]),
                    region.policy.units[index])
            }
            val first = draws.minBy(::left); val last = draws.maxBy(::right)
            val profile = piece.profile.withPhysicalEdges(edge(first, true), edge(last, false))
            RubyHierarchySlot(positions.first(), region.sourceOffsets[piece.start], region.sourceOffsets[piece.end - 1] + 1,
                left(first), right(last), profile, nativeOffsets = positions)
        }
    }
    val gapSlots = retained.map { gap ->
        val positions = (gap.nativeStart until gap.nativeEnd).toList()
        val draws = fragments(positions)
        if (draws.isEmpty()) {
            if (raw.nativeRubyMeasuredAdvance(gap.nativeStart, gap.nativeEnd) != 0f)
                throw UnsupportedFloatLayout("Retained Ruby gap lacks its actual native advance")
            val caret = raw.nativeRubyLineCaret(line, gap.nativeStart)
                ?: throw UnsupportedFloatLayout("Zero-advance Ruby gap lacks its native caret origin")
            RubyHierarchySlot(gap.nativeStart, gap.start, gap.end, caret.left, caret.left,
                NativeRubySpacingProfile.retainedGap(), nativeOffsets = positions)
        } else RubyHierarchySlot(gap.nativeStart, gap.start, gap.end, draws.minOf(::left), draws.maxOf(::right),
            NativeRubySpacingProfile.retainedGap(), nativeOffsets = positions)
    }
    val logical = (nested + ordinary + gapSlots).sortedBy { it.nativeStart }
    // A real zero-advance separator precedes a positive slot at the same physical
    // left edge, independently of the logical order chosen by paragraph bidi.
    val physical = logical.sortedWith(compareBy<RubyHierarchySlot>({ it.left }, { it.right }))
    if (physical.any { !it.left.isFinite() || !it.right.isFinite() || it.right < it.left ||
            it.right == it.left && !it.profile.retainedGap && !it.profile.sourceEmpty ||
            it.profile.physicalEdges == null && !it.profile.sourceEmpty } ||
        physical.zipWithNext().any { (a, b) -> a.right > b.left && !rubyClose(a.right, b.left) })
        throw UnsupportedFloatLayout("Ruby hierarchy lacks distinct physical source edges")
    val profile = NativeRubySpacingProfile.compose(logical.map { it.profile },
        physical.map { logical.indexOf(it) }, complete = true)
    return RubyHierarchySource(profile, physical, plans, silent)
}

private class RubyHierarchyMap(private val slots: List<RubyHierarchySlot>,
    private val plan: NativeRubyHierarchyPlan, private val origin: Float) : NativeRubyPhysicalMap {
    override val minimumShift = plan.leadingIncrement - origin
    override val maximumShift = plan.placements.last().let { it.prefixIncrement + it.widthIncrement - origin }
    override fun shiftAt(x: Float): Float {
        val index = slots.indexOfLast { x >= it.left }
        return if (index < 0) minimumShift else plan.placements[index].prefixIncrement - origin
    }
    override fun physical(x: Float, after: Boolean): Float {
        var shift = minimumShift
        slots.forEachIndexed { index, slot ->
            if (x < slot.left || !after && x == slot.left) return x + shift
            val placed = plan.placements[index]
            if (x < slot.right || !after && x == slot.right) {
                val growth = if (slot.column == null || placed.widthIncrement == 0f) 0f
                    else placed.widthIncrement * (x - slot.left) / (slot.right - slot.left)
                return x + placed.prefixIncrement - origin + growth
            }
            shift = placed.prefixIncrement + placed.widthIncrement - origin
        }
        return x + shift
    }
}

private fun rubyHierarchyDistribute(owner: NativeFloatGeometry, line: Int, advance: Float,
    allocation: Float, source: RubyHierarchySource, parentIncrement: NativeRubySpacingIncrement?): FloatTextGeometry {
    val origin = owner.nativeRubyLineAdvanceBounds(line)?.left ?: 0f
    val top = owner.nativeRubyLineTop(line)
    if (source.slots.first().left < origin && !rubyClose(source.slots.first().left, origin) ||
        source.slots.last().right > origin + advance && !rubyClose(source.slots.last().right, origin + advance))
        throw UnsupportedFloatLayout("Ruby hierarchy exceeds its retained native advance")
    val input = source.slots.map { slot -> NativeRubyHierarchyItem(slot, slot.profile,
        slot.column?.advance ?: (slot.right - slot.left), slot.column != null, reversedEdges = false) }
    val plan = nativeRubyHierarchyPlan(input, allocation - advance, parentIncrement)
    val finalWidth = allocation.toDouble() + (parentIncrement?.width(source.profile) ?: 0f)
    if (!finalWidth.isFinite() || finalWidth > TablePixelLimit)
        throw UnsupportedFloatLayout("Ruby hierarchy exceeds native coordinates")
    val map = RubyHierarchyMap(source.slots, plan, origin)
    val nested = source.slots.mapIndexedNotNull { index, slot ->
        val original = slot.column ?: return@mapIndexedNotNull null
        // A source-empty base supplies no opportunity and receives no growth. Keep
        // that exact owner, including its reading, background/cursor and metrics.
        val grown = if (slot.profile.sourceEmpty) original else original.reallocated(plan.placements[index].increment)
        if (!rubyClose(grown.advance, plan.placements[index].newWidth) || grown.base != original.base || grown.container != original.container)
            throw UnsupportedFloatLayout("Ruby horizontal reallocation changed its retained line metrics")
        val view = owner.nativeRubyColumnView(slot.nativeStart, grown)
        RubyNestedReplay(original, slot.nativeStart, slot.left, slot.baseline,
            slot.left + plan.placements[index].prefixIncrement - origin, slot.baseline - top, view, slot.ranges)
    }.sortedBy { it.nativeStart } // Preserve the retained projection's source-owner hit priority.
    return NativeRubyHierarchyLine(owner, line, source, plan, map, nested, finalWidth.toFloat(), top)
}

private class NativeRubyHierarchyLine(private val owner: NativeFloatGeometry, private val line: Int,
    private val source: RubyHierarchySource, private val plan: NativeRubyHierarchyPlan,
    private val map: RubyHierarchyMap, private val nested: List<RubyNestedReplay>,
    allocation: Float, private val top: Float) : FloatTextGeometry {
    override val text: CharSequence get() = owner.text
    override val width = ceil(allocation.toDouble()).toInt()
    override val height = ceil(owner.nativeRubyRaw.nativeUsedLineMetrics(line).height.toDouble()).toInt()
    override val nodes = emptyList<FloatInteractionNode>()
    override val textBaselines = NativeTextBaselines(owner.nativeRubyLineBaseline(line) - top, owner.nativeRubyLineBaseline(line) - top)
    private val ordinary = source.slots.mapIndexedNotNull { index, slot ->
        if (slot.column == null) slot to (plan.placements[index].prefixIncrement - mapOrigin()) else null
    }
    private fun mapOrigin() = owner.nativeRubyLineAdvanceBounds(line)?.left ?: 0f
    private val owned = owner.nativeRubyLineRanges(line).filter { it.first < it.second }
    private fun owns(offset: Int) = owned.any { offset in it.first until it.second }
    private fun affinity(offset: Int) = owns(offset) || owned.any { offset == it.second }
    private fun shifted(rect: RectF, dx: Float, dy: Float) = RectF(rect).apply { offset(dx, dy) }
    override fun rectsForRange(start: Int, end: Int): List<RectF> {
        require(start in 0..text.length && end in start..text.length)
        return ordinary.flatMap { (slot, dx) ->
            val first = maxOf(start, slot.start); val last = minOf(end, slot.end)
            if (first < last) owner.nativeRubyLineRects(line, first, last).map { shifted(it, dx, -top) } else emptyList()
        } + nested.flatMap { own -> own.view.rectsForRange(start, end).map { shifted(it, own.x, own.y) } }
    }
    override fun inlinePaddingGroupRects(owner: Span, start: Int, end: Int): List<RectF>? {
        require(start in 0..text.length && end in start..text.length)
        if (start == end) return null
        nested.forEach { own ->
            if (own.ranges.any { start >= it.first && end <= it.second }) {
                own.view.inlinePaddingGroupRects(owner, start, end)?.let { bounds ->
                    return bounds.map { shifted(it, own.x, own.y) }
                }
            }
        }
        ordinary.forEach { (slot, dx) ->
            if (start >= slot.start && end <= slot.end) {
                this.owner.inlinePaddingGroupRects(owner, start, end)?.let { bounds ->
                    return bounds.map { shifted(it, dx, -top) }
                }
            }
        }
        return null
    }
    override fun characterRects(start: Int, length: Int): List<RectF?> {
        require(start in 0..text.length && length >= 0 && length <= text.length - start)
        return (start until start + length).map { offset ->
            if (!owns(offset)) null else {
                val first = if (offset > 0 && Character.isLowSurrogate(text[offset]) && Character.isHighSurrogate(text[offset - 1])) offset - 1 else offset
                val last = if (Character.isHighSurrogate(text[first]) && first + 1 < text.length && Character.isLowSurrogate(text[first + 1])) first + 2 else first + 1
                rectsForRange(first, last).reduceOrNull { a, b -> a.apply { union(b) } }
            }
        }
    }
    override fun caretRect(offset: Int): RectF {
        require(offset in 0..text.length)
        if (source.silent.any { offset in it.first until it.second }) {
            val original = owner.nativeRubyLineCaret(line, offset) ?: return RectF()
            return shifted(original, map.physical(original.left) - original.left, -top)
        }
        val ordinaryOwner = ordinary.firstOrNull { offset in it.first.start until it.first.end }
        val nestedOwner = nested.firstOrNull { own -> own.ranges.any { offset in it.first until it.second } }
        if (nestedOwner != null) return shifted(nestedOwner.view.caretRect(offset), nestedOwner.x, nestedOwner.y)
        val selected = ordinaryOwner ?: ordinary.lastOrNull { it.first.end == offset }
        if (selected != null) return owner.nativeRubyLineCaret(line, offset)?.let { shifted(it, selected.second, -top) } ?: RectF()
        val ending = nested.lastOrNull { own -> own.ranges.any { offset == it.second } } ?: return RectF()
        return shifted(ending.view.caretRect(offset), ending.x, ending.y)
    }
    private fun ordinaryOffset(slot: RubyHierarchySlot, dx: Float, x: Float, y: Float): Int {
        if (slot.profile.retainedGap)
            return owner.nativeRubyLineOffsetForPosition(line, x - dx, y + top).coerceIn(slot.start, slot.end)
        val raw = owner.nativeRubyRaw.nativeRubyLineOffsetForPosition(line, x - dx, y + top)
        val index = slot.nativeOffsets.indexOf(raw)
        if (index >= 0) return slot.start + index
        if (raw >= slot.nativeOffsets.last() + 1) return slot.end
        // A zero-width private isolate has no public offset. Keep the original
        // source cluster boundary without manufacturing a caret inside its UTF-16.
        val a = owner.nativeRubyLineCaret(line, slot.start)?.left ?: slot.left
        val b = owner.nativeRubyLineCaret(line, slot.end)?.left ?: slot.right
        return if (abs(x - dx - a) <= abs(x - dx - b)) slot.start else slot.end
    }
    override fun containsInteraction(x: Float, y: Float): Boolean = rectsForRange(0, text.length).any { it.contains(x, y) }
    override fun offsetForPosition(x: Float, y: Float): Int {
        nested.asReversed().firstOrNull { it.view.containsInteraction(x - it.x, y - it.y) }?.let {
            return it.view.offsetForPosition(x - it.x, y - it.y)
        }
        ordinary.firstOrNull { (slot, dx) -> owner.nativeRubyLineRects(line, slot.start, slot.end)
            .any { shifted(it, dx, -top).contains(x, y) } }?.let { return ordinaryOffset(it.first, it.second, x, y) }
        data class Target(val distance: Double, val query: () -> Int)
        fun distance(rect: RectF): Double {
            val dx = maxOf(rect.left - x, 0f, x - rect.right).toDouble()
            val dy = maxOf(rect.top - y, 0f, y - rect.bottom).toDouble()
            return dx * dx + dy * dy
        }
        val candidates = ordinary.map { (slot, dx) -> Target(owner.nativeRubyLineRects(line, slot.start, slot.end)
            .minOfOrNull { distance(shifted(it, dx, -top)) } ?: Double.POSITIVE_INFINITY) { ordinaryOffset(slot, dx, x, y) } } +
            nested.map { own -> Target(own.view.rectsForRange(0, text.length)
                .minOfOrNull { distance(shifted(it, own.x, own.y)) } ?: Double.POSITIVE_INFINITY) {
                own.view.offsetForPosition(x - own.x, y - own.y)
            } }
        return candidates.minByOrNull { it.distance }?.query?.invoke() ?: 0
    }
    override fun cursorAt(x: Float, y: Float): InlineCursor? {
        nested.asReversed().forEach { own -> own.view.cursorAt(x - own.x, y - own.y)?.let { return it } }
        ordinary.forEach { (slot, dx) ->
            if (owner.nativeRubyLineRects(line, slot.start, slot.end).any { shifted(it, dx, -top).contains(x, y) }) {
                val cursor = if (slot.profile.retainedGap) owner.nativeRubyLineCursorAt(line, x - dx, y + top)
                    else owner.nativeRubyRaw.nativeRubyLineCursorAt(line, x - dx, y + top)
                cursor?.let { return it }
            }
        }
        return null
    }
    override fun lineRange(offset: Int) = owner.lineRange(offset)
    override fun visualLineRanges(offset: Int): List<Pair<Int, Int>> = if (affinity(offset)) owned else emptyList()
    override fun isHardLineBreak(offset: Int) = owner.isHardLineBreak(offset)
    override fun visualOffset(offset: Int, direction: Int): Int {
        require(offset in 0..text.length && direction in listOf(-1, 1))
        if (!affinity(offset)) return offset
        fun nestedOwns(own: RubyNestedReplay, at: Int) = own.ranges.any { at in it.first until it.second }
        val ordinaryOwner = ordinary.firstOrNull { offset in it.first.start until it.first.end }
        val nestedOwner = nested.firstOrNull { nestedOwns(it, offset) }
            ?: if (ordinaryOwner == null) nested.lastOrNull { own -> own.ranges.any { offset == it.second } } else null
        if (nestedOwner != null) {
            val next = nestedOwner.view.visualOffset(offset, direction)
            if (next != offset && nestedOwns(nestedOwner, next)) return next
        } else {
            // Inside ordinary source, keep the platform's full-context grapheme/bidi
            // transition. Entering a resized column is resolved below from current edges.
            val next = owner.visualOffset(offset, direction)
            if (next != offset && affinity(next) && nested.none { nestedOwns(it, next) } &&
                ordinary.any { next in it.first.start..it.first.end }) return next
        }
        val ordinaryRanges = ordinary.map { it.first.start to it.first.end }.sortedBy { it.first }
            .fold(mutableListOf<Pair<Int, Int>>()) { ranges, range ->
                val previous = ranges.lastOrNull()
                if (previous != null && previous.second == range.first)
                    ranges[ranges.lastIndex] = previous.first to range.second
                else ranges += range
                ranges
            }
        // Rank actual owner-local boundary carets, retaining endpoint affinity even
        // when the same logical offset belongs to following ordinary text. Entering
        // through such an endpoint asks that child's native cursor for the first stop;
        // it must not skip directly to a farther source-range edge.
        data class Boundary(val offset: Int, val caret: RectF, val nested: RubyNestedReplay?)
        val current = caretRect(offset)
        fun inDirection(rect: RectF) = if (direction < 0) rect.left < current.left else rect.left > current.left
        val edges = ordinaryRanges.flatMap { listOf(it.first, it.second) }.distinct()
            .filter { it != offset && affinity(it) }
            .map { Boundary(it, caretRect(it), null) } + nested.flatMap { own ->
                own.ranges.flatMap { listOf(it.first, it.second) }.distinct().filter(::affinity).map { at ->
                    Boundary(at, shifted(own.view.caretRect(at), own.x, own.y), own)
                }
            }
        val ordered = edges.filter { inDirection(it.caret) || it.nested != null && it.caret.left == current.left }
            .sortedWith(compareBy<Boundary>({ abs(it.caret.left - current.left) },
                { abs(it.caret.top - current.top) }))
        for (edge in ordered) {
            val target = edge.nested
            if (target != null && target !== nestedOwner &&
                (!nestedOwns(target, edge.offset) || edge.offset == offset)) {
                val next = target.view.visualOffset(edge.offset, direction)
                if (next != edge.offset && nestedOwns(target, next) && affinity(next) && inDirection(caretRect(next)))
                    return next
                // An endpoint belonging to another owner is not a substitute for
                // that target's native interior cursor stop.
                if (!nestedOwns(target, edge.offset)) continue
            }
            if (edge.offset != offset && inDirection(caretRect(edge.offset))) return edge.offset
        }
        return offset
    }
    override fun clipForOffset(offset: Int): RectF? = if (affinity(offset)) null else RectF()
    override fun preciseClipForOffset(offset: Int): NativeTextClip? = if (affinity(offset)) null else NativeTextClip.rectangle(RectF())
    override fun paintSelection(canvas: Canvas, start: Int, end: Int, paint: Paint) {
        rectsForRange(start, end).forEach { canvas.drawRect(it, paint) }
    }
    override fun paint(canvas: Canvas) {
        val save = canvas.save()
        try { owner.paintRubyNativeLine(RubySpacingCanvas(owner.nativeRubyRaw.nativeRubyShapingSource,
            owner.nativeRubyLineSourceStart(line), canvas, map, source.plans, top, nested), line) }
        finally { canvas.restoreToCount(save) }
    }
    override val ordinaryPaintBounds: List<NativeFloatBounds> get() =
        owner.nativeRubyLinePaintBounds(line).map { NativeFloatBounds(it.left + map.minimumShift, it.top - top,
            it.right + map.maximumShift, it.bottom - top) } + nested.flatMap { own ->
            own.view.ordinaryPaintBounds.map { it.translated(own.x, own.y) }
        }
    override val extents get() = NativeGeometryExtents(width, height.toFloat(),
        ordinaryPaintBounds.reduceOrNull { a, b -> a.enclosing(b) }, nativeBoundsOf(rectsForRange(0, text.length)))
}
