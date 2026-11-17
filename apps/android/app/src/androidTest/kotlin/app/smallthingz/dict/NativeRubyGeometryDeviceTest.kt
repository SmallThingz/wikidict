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
import android.text.style.SuperscriptSpan
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.util.IdentityHashMap
import java.util.Locale
import kotlin.math.ceil
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

/** Direct native geometry and raster controls. Entry/View routing and OS actions are
 * separate controls; this donor never creates a View or changes input/focus state. */
@RunWith(AndroidJUnit4::class)
class NativeRubyGeometryDeviceTest {
    private val bodyPixels = 24f
    private fun policy(zero: Boolean, numeric: Float? = null) = InlineTextStyle(
        fontNormalized = true,
        lineHeight = if (zero) InlineLineHeight.Computed(InlineComputedLength(0f, FontScaleBasis.CssPx)) else null,
        baselineShift = numeric?.let { InlineComputedLength(it, FontScaleBasis.CssPx) })
    private fun font(scale: Float = 1f, script: Boolean = false) = InlineFontSnapshot(
        fontScale = scale, fontScaleBasis = FontScaleBasis.NormalBody, fontNormalized = true,
        superscript = script, language = "ja")
    private fun context(scale: Float = 1f, zero: Boolean = false, script: Boolean = false,
        numeric: Float? = null) = RubyOwner(font(scale, script), direction = "ltr", inlineStyle = policy(zero, numeric))
    private fun leaf(text: String, target: String = "", scale: Float = 1f, color: String = "#0000ff",
        zero: Boolean = false, script: Boolean = false) = Span(if (target.isEmpty()) "text" else "link", text,
        target, fontScale = scale, fontScaleBasis = FontScaleBasis.NormalBody, language = "ja",
        superscript = script, foreground = color, inlineStyle = policy(zero))
    private fun base(spans: List<Span>, owner: RubyOwner = context(), gap: List<Span> = emptyList()) =
        RubyBase(owner, gap, spans)
    private fun reading(spans: List<Span>, level: Long = 0, start: Long = 0, count: Long = 1,
        owner: RubyOwner = context(.5f), gap: List<Span> = emptyList()) =
        RubyAnnotation(start, count, level, owner, gap, spans, emptyList(), emptyList(), false)
    private fun ruby(bases: List<RubyBase>, readings: List<RubyAnnotation>, zero: Boolean = false,
        script: Boolean = false, numeric: Float? = null) = Span("text", "", fontScale = 1f,
        fontScaleBasis = FontScaleBasis.NormalBody, language = "ja", superscript = script,
        inlineStyle = policy(zero, numeric), direction = "ltr",
        ruby = Ruby(listOf(RubySegment(emptyList(), bases, readings))))

    private fun paint(scale: Float = 1f, color: Int = Color.BLUE) = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
        typeface = Typeface.MONOSPACE
        textSize = bodyPixels * scale
        textLocale = Locale.JAPANESE
        this.color = color
    }
    private fun scriptShift(value: TextPaint): Float = TextPaint(value).apply {
        SuperscriptSpan().updateMeasureState(this)
    }.baselineShift.toFloat()
    private fun snapshot(span: Span) = InlineFontSnapshot(span.fontScale, span.fontScaleBasis,
        small = span.small, superscript = span.superscript, subscript = span.subscript,
        fontNormalized = span.inlineStyle?.fontNormalized == true, bold = span.bold, italic = span.italic,
        code = span.code, language = span.language, classes = span.classes, role = span.role,
        fontFeatures = span.fontFeatures, fontFamily = span.fontFamily)
    private fun nativePolicy(style: InlineTextStyle?, fallback: NativeLineHeightPolicy): NativeLineHeightPolicy =
        (style?.lineHeight as? InlineLineHeight.Computed)?.let { NativeLineHeightPolicy.Pixels(it.value.value) } ?: fallback
    private class SourcePaint(private val snapshot: TextPaint) : MetricAffectingSpan(), NativeInlineSafePaintSpan {
        override fun updateMeasureState(paint: TextPaint) { paint.set(snapshot) }
        override fun updateDrawState(paint: TextPaint) { paint.set(snapshot) }
    }
    private data class Action(val range: RubyTextRange, val source: Span, val invoke: () -> Unit)
    private class Fixture(val spans: List<Span>, val source: Spanned, val projection: RubyTextProjection,
        val body: TextPaint, val actions: List<Action>, val rtl: Boolean = false) {
        fun range(span: Span): RubyTextRange = projection.ranges.single { it.span === span && it.role != RubyTextRole.Owner }
        fun build(width: Int, exclusions: List<NativeFloatExclusion> = emptyList()): NativeFloatGeometry =
            NativeFloatGeometry.build(source, body, width, emptyList(),
                textDirection = if (rtl) TextDirectionHeuristics.RTL else TextDirectionHeuristics.LTR,
                carriedExclusions = exclusions, nodeFactory = { geometry -> actions.mapIndexed { id, action ->
                    FloatInteractionNode(id, FloatInteractionKind.LINK, action.range.start, action.range.end,
                        geometry.rectsForRange(action.range.start, action.range.end), action.source.text + action.source.trail,
                        null, action.invoke)
                } })
    }

    /** This is the stable prepared API, not a duplicate reader lowerer. All inputs are
     * explicit synthetic resolved paints: normalized 24px body, 12px readings, source
     * colors and public SuperscriptSpan's actual displacement where requested. */
    private fun prepare(spans: List<Span>, zero: Boolean = false,
        onAction: (Span) -> Unit = {}, scriptFromOwnFont: Boolean = false, rtl: Boolean = false): Fixture {
        val projection = rubyGraphicalProjection(spans)
        val root = paint()
        val inheritedScript = scriptShift(root)
        val rootPolicy = if (zero) NativeLineHeightPolicy.Pixels(0f) else NativeLineHeightPolicy.Normal
        val groups = projection.ranges.filter { it.role in setOf(RubyTextRole.Owner, RubyTextRole.Base, RubyTextRole.Annotation) }
            .associate { range ->
                val owner = when (range.role) {
                    RubyTextRole.Owner -> checkNotNull(range.span).let { RubyOwner(snapshot(it), it.direction, it.inlineStyle, it.foreground, it.background) }
                    RubyTextRole.Base -> checkNotNull(range.base).owner
                    RubyTextRole.Annotation -> checkNotNull(range.annotation).owner
                    else -> error("Not a declaring group")
                }
                val resolved = paint(owner.font.fontScale ?: 1f,
                    owner.foreground?.let(Color::parseColor) ?: Color.BLUE)
                range.path to NativeRubyGroupFormat(resolved,
                    if (owner.direction == "rtl") TextDirectionHeuristics.RTL else TextDirectionHeuristics.LTR,
                    nativePolicy(owner.inlineStyle, rootPolicy),
                    baselineShift = if (owner.font.superscript)
                        (if (scriptFromOwnFont) scriptShift(resolved) else inheritedScript) else 0f,
                    sourceDirection = owner.direction,
                    localBaselineShift = owner.inlineStyle?.baselineShift?.value)
            }
        val source = SpannableString(projection.text)
        source.setSpan(NativeRunLineMetrics(NativePrimaryFontMetrics.from(root), rootPolicy, strut = true),
            0, source.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        val callbacks = IdentityHashMap<Span, () -> Unit>()
        val actions = mutableListOf<Action>()
        projection.ranges.filter { it.span != null && it.role != RubyTextRole.Owner && it.start < it.end }.forEach { range ->
            val span = checkNotNull(range.span)
            val resolved = paint(span.fontScale ?: 1f, span.foreground?.let(Color::parseColor) ?: Color.BLUE)
            // Existing fixtures retain their declaring owner's inherited default.
            // Mode contrasts opt into distinct actual font-dependent defaults, so
            // source mode identity, not equal float values, must govern reuse.
            if (span.superscript) resolved.baselineShift =
                (if (scriptFromOwnFont) scriptShift(resolved) else inheritedScript).toInt()
            source.setSpan(SourcePaint(resolved), range.start, range.end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            span.inlineStyle?.baselineShift?.let {
                source.setSpan(NativeAuthoredBaselineShift(it.value), range.start, range.end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            }
            source.setSpan(NativeRunLineMetrics(NativePrimaryFontMetrics.from(resolved), nativePolicy(span.inlineStyle, rootPolicy)),
                range.start, range.end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            if (span.kind == "link") actions += Action(range, span, callbacks.getOrPut(span) { { onAction(span) } })
        }
        val prepared = NativeRubyPreparedSource(projection, SpannedString(source), root,
            if (rtl) TextDirectionHeuristics.RTL else TextDirectionHeuristics.LTR, groups)
        val measured = SpannableString(source).apply {
            setSpan(prepared, 0, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
        return Fixture(spans, SpannedString(measured), projection, root, actions, rtl)
    }

    private fun box(geometry: FloatTextGeometry, range: RubyTextRange): RectF =
        geometry.rectsForRange(range.start, range.end).map(::RectF).reduce { a, b -> a.apply { union(b) } }
    private fun sameRect(expected: RectF, actual: RectF, tolerance: Float = .01f) {
        assertEquals(expected.left, actual.left, tolerance); assertEquals(expected.top, actual.top, tolerance)
        assertEquals(expected.right, actual.right, tolerance); assertEquals(expected.bottom, actual.bottom, tolerance)
    }
    private fun assertActions(fixture: Fixture, geometry: NativeFloatGeometry) {
        assertEquals(fixture.actions.size, geometry.nodes.size)
        fixture.actions.zip(geometry.nodes).forEach { (action, node) ->
            assertSame(action.source, action.range.span)
            assertEquals(action.range.start, node.start); assertEquals(action.range.end, node.end)
            assertEquals(action.source.text + action.source.trail, geometry.text.subSequence(node.start, node.end).toString())
            assertSame(action.invoke, node.onClick)
            assertTrue(node.bounds.isNotEmpty())
        }
    }
    private data class Ink(val count: Int, val bounds: RectF?)
    private fun raster(geometry: FloatTextGeometry): Map<Int, Ink> {
        val surface = NativeSurfaceBox.from(geometry.extents)
        assertTrue(surface.width in 1..4096 && surface.height in 1..4096)
        val margin = 8
        val bitmap = Bitmap.createBitmap(surface.width + margin * 2, surface.height + margin * 2, Bitmap.Config.ARGB_8888)
        var failure: Throwable? = null
        try {
            val canvas = Canvas(bitmap)
            canvas.translate(margin - surface.left.toFloat(), margin - surface.top.toFloat())
            geometry.paint(canvas)
            val counts = mutableMapOf(Color.RED to 0, Color.GREEN to 0, Color.BLUE to 0)
            val bounds = mutableMapOf<Int, RectF>()
            for (y in 0 until bitmap.height) for (x in 0 until bitmap.width) {
                val pixel = bitmap.getPixel(x, y)
                if (Color.alpha(pixel) == 0) continue
                val red = Color.red(pixel); val green = Color.green(pixel); val blue = Color.blue(pixel)
                val key = when {
                    red > 0 && green == 0 && blue == 0 -> Color.RED
                    green > 0 && red == 0 && blue == 0 -> Color.GREEN
                    blue > 0 && red == 0 && green == 0 -> Color.BLUE
                    else -> continue
                }
                counts[key] = counts.getValue(key) + 1
                val rect = RectF(x + surface.left - margin.toFloat(), y + surface.top - margin.toFloat(),
                    x + 1 + surface.left - margin.toFloat(), y + 1 + surface.top - margin.toFloat())
                bounds[key]?.union(rect) ?: run { bounds[key] = rect }
            }
            return counts.mapValues { (color, count) -> Ink(count, bounds[color]) }
        } catch (caught: Throwable) { failure = caught; throw caught }
        finally {
            try { bitmap.recycle() }
            catch (cleanup: Throwable) {
                val primary = failure
                if (primary != null) { if (primary !== cleanup) primary.addSuppressed(cleanup) } else throw cleanup
            }
        }
    }

    @Test fun originalUtf16ActionsAndGapLfSurviveAdjacentRubyAndTheNextOrdinaryWrappedRow() {
        val before = leaf("e\u0301 \u05d0 ", "before")
        val baseA = leaf("A\ud840\udc00", "base-a")
        val readA = leaf("read", "reading-a", .5f, "#ff0000")
        val baseB = leaf("B", "base-b")
        val readB = leaf("bee", "reading-b", .5f, "#ff0000")
        val after = leaf("WIDE ordinary sibling", "after")
        val first = ruby(listOf(base(listOf(baseA))), listOf(reading(listOf(readA))))
        val second = ruby(listOf(base(listOf(baseB))), listOf(reading(listOf(readB))))
        val calls = mutableListOf<Span>()
        val fixture = prepare(listOf(before, first, second, leaf(" "), after), onAction = { calls += it })
        val expected = "e\u0301 \u05d0 A\ud840\udc00readBbee WIDE ordinary sibling"
        assertEquals(expected, fixture.projection.text)
        val wide = fixture.build(1200)
        assertEquals(expected, wide.text.toString())
        assertActions(fixture, wide)
        val a = fixture.range(baseA)
        val supplementary = a.start + 1
        val characters = wide.characterRects(supplementary, 2)
        sameRect(checkNotNull(characters[0]), checkNotNull(characters[1]))
        for (offset in 0..wide.text.length) for (direction in listOf(-1, 1)) {
            if (offset > 0 && offset < wide.text.length && Character.isLowSurrogate(wide.text[offset]) &&
                Character.isHighSurrogate(wide.text[offset - 1])) continue
            val moved = wide.visualOffset(offset, direction)
            assertTrue(moved in 0..wide.text.length)
            assertFalse(moved > 0 && moved < wide.text.length && Character.isLowSurrogate(wide.text[moved]) &&
                Character.isHighSurrogate(wide.text[moved - 1]))
        }
        assertNotEquals(1, wide.visualOffset(0, 1)) // The combining mark is not a separate caret stop.
        val coreReading = fixture.range(readB)
        val standaloneCoreReading = prepare(listOf(readB)).build(1200)
        assertEquals(readB.text, standaloneCoreReading.text.toString())
        assertEquals(1, standaloneCoreReading.shapedLineCount)
        val corePrevious = standaloneCoreReading.visualOffset(standaloneCoreReading.text.length, -1)
        assertTrue(corePrevious in 0 until standaloneCoreReading.text.length)
        assertEquals(' ', wide.text[coreReading.end]) // Original ordinary sibling immediately follows Ruby.
        val enteringCore = wide.visualOffset(coreReading.end, -1)
        assertEquals(coreReading.start + corePrevious, enteringCore)
        assertTrue(wide.caretRect(enteringCore).left < wide.caretRect(coreReading.end).left)
        val next = fixture.range(after)
        val width = ceil(wide.caretRect(next.start).left.toDouble()).toInt().coerceAtLeast(64)
        val narrow = fixture.build(width)
        assertEquals(expected, narrow.text.toString())
        assertActions(fixture, narrow)
        val previous = fixture.range(baseB)
        assertTrue(narrow.baselineForOffset(next.start) > narrow.baselineForOffset(previous.start))
        val row = narrow.visualLineRanges(next.start)
        val previousReading = fixture.range(readB)
        assertFalse(row.any { it.first < previousReading.end && it.second > previousReading.start })
        val rawNext = narrow.nativeRubyRawOffset(next.start)
        sameRect(narrow.nativeRubyRaw.caretRect(rawNext), narrow.caretRect(next.start))
        assertEquals(narrow.nativeRubyRaw.baselineForOffset(rawNext), narrow.baselineForOffset(next.start), .01f)
        assertTrue(narrow.caretRect(next.start).top >= 0f)
        narrow.nodes.forEach { checkNotNull(it.onClick).invoke() }
        assertEquals(fixture.actions.map { it.source }, calls)
        assertTrue(fixture.actions.zip(wide.nodes).all { (action, node) -> action.invoke === node.onClick })
        val ink = raster(narrow)
        assertTrue(ink.getValue(Color.RED).count > 0)
        assertTrue(ink.getValue(Color.BLUE).count > 0)

        val gap = leaf("\n")
        val tail = ruby(listOf(base(listOf(leaf("M"))), base(emptyList(), gap = listOf(gap))), emptyList())
        val gapFixture = prepare(listOf(tail))
        val gapGeometry = gapFixture.build(300)
        assertEquals("M\n", gapGeometry.text.toString())
        assertFalse(gapGeometry.isHardLineBreak(1))
        assertEquals(2, gapGeometry.visualLineEnd(0))
        assertEquals(1, gapGeometry.shapedLineCount)
        assertEquals("M\n", gapGeometry.text.subSequence(0, gapGeometry.visualLineEnd(0)).toString())
    }

    @Test fun nestedOverAndUnderReadingsPaintAndSupplyLeadingWithoutMovingBaseAlignment() {
        val innerBase = leaf("N", color = "#0000ff", zero = true)
        val innerRead = leaf("en", scale = .5f, color = "#ff0000", zero = true)
        val inner = ruby(listOf(base(listOf(innerBase), context(zero = true))),
            listOf(reading(listOf(innerRead), owner = context(.5f, zero = true))), zero = true)
        val main = leaf("M", color = "#0000ff", zero = true)
        val over = leaf("over", scale = .5f, color = "#ff0000", zero = true)
        val under = leaf("under", scale = .5f, color = "#00ff00", zero = true)
        val owner = ruby(listOf(base(listOf(main, inner), context(zero = true))), listOf(
            reading(listOf(over), owner = context(.5f, zero = true)),
            reading(listOf(under), level = 1, owner = context(.5f, zero = true))), zero = true)
        val fixture = prepare(listOf(owner), zero = true)
        val geometry = fixture.build(600)
        val baseline = checkNotNull(geometry.textBaselines?.first)
        assertEquals(baseline, geometry.baselineForOffset(fixture.range(main).start), .01f)
        assertEquals(baseline, geometry.baselineForOffset(fixture.range(innerBase).start), .01f)
        assertTrue(geometry.baselineForOffset(fixture.range(innerRead).start) < baseline)
        assertTrue(geometry.baselineForOffset(fixture.range(over).start) <
            geometry.baselineForOffset(fixture.range(innerRead).start))
        assertTrue(geometry.baselineForOffset(fixture.range(under).start) > baseline)
        val ink = raster(geometry)
        for (color in listOf(Color.RED, Color.GREEN, Color.BLUE)) assertTrue(ink.getValue(color).count > 0)
        assertTrue(checkNotNull(ink.getValue(Color.RED).bounds).centerY() < checkNotNull(ink.getValue(Color.BLUE).bounds).centerY())
        assertTrue(checkNotNull(ink.getValue(Color.GREEN).bounds).centerY() > checkNotNull(ink.getValue(Color.BLUE).bounds).centerY())

        val bare = prepare(listOf(ruby(listOf(base(listOf(leaf("MN", zero = true)), context(zero = true))),
            emptyList(), zero = true)), zero = true).build(600)
        assertTrue(geometry.usedLineHeight(0) > bare.usedLineHeight(0))
        val repeated = prepare(listOf(owner, Span("line_break", ""), owner, Span("line_break", ""), owner), zero = true)
        val three = repeated.build(600)
        assertEquals(3, three.shapedLineCount)
        val ranges = repeated.projection.ranges.filter { it.role == RubyTextRole.Owner && it.span === owner }
        assertEquals(3, ranges.size)
        val boxes = ranges.map { box(three, it) }
        for ((a, b) in boxes.zipWithNext()) assertTrue("Ruby containers must separate on successive native rows", a.bottom <= b.top + 1f)
        assertTrue(three.usedLineHeight(0) > 0f)
        assertTrue(raster(three).getValue(Color.GREEN).count > 0)

        data class GapReserve(val height: Float, val readingAboveBase: Float)
        fun gapReserve(scale: Float): GapReserve {
            val m = leaf("M", zero = true)
            val n = leaf("N", zero = true)
            val first = leaf("r", scale = .5f, color = "#ff0000", zero = true)
            val second = leaf("s", scale = .5f, color = "#00ff00", zero = true)
            val gap = leaf(" ", scale = scale, zero = true)
            val value = ruby(listOf(base(listOf(m), context(zero = true)), base(listOf(n), context(zero = true))), listOf(
                reading(listOf(first), owner = context(.5f, zero = true)),
                reading(listOf(second), start = 1, owner = context(.5f, zero = true), gap = listOf(gap))), zero = true)
            val fixture = prepare(listOf(value), zero = true)
            val result = fixture.build(500)
            assertEquals("MNr s", result.text.toString())
            assertSame(gap, fixture.range(gap).span)
            val level = result.baselineForOffset(fixture.range(first).start)
            assertEquals(level, result.baselineForOffset(fixture.range(gap).start), .01f)
            val ink = raster(result)
            for (color in listOf(Color.RED, Color.GREEN, Color.BLUE)) assertTrue(ink.getValue(color).count > 0)
            return GapReserve(result.usedLineHeight(0), level - result.baselineForOffset(fixture.range(m).start))
        }
        val halfGap = gapReserve(.5f)
        val fullGap = gapReserve(1f)
        assertTrue(paint().fontMetrics.descent > paint(.5f).fontMetrics.descent)
        assertTrue(fullGap.height > halfGap.height)
        assertTrue(fullGap.readingAboveBase < halfGap.readingAboveBase)

        fun emptyReading(scale: Float): NativeFloatGeometry {
            val m = leaf("M", zero = true)
            val value = ruby(listOf(base(listOf(m), context(zero = true))),
                listOf(reading(emptyList(), owner = context(scale, zero = true))), zero = true)
            val fixture = prepare(listOf(value), zero = true)
            val result = fixture.build(500)
            val declared = fixture.projection.ranges.single { it.role == RubyTextRole.Annotation }
            assertEquals(declared.start, declared.end)
            assertEquals("M", result.text.toString())
            assertEquals(listOf(0 to 1), result.visualLineRanges(0))
            assertEquals(1, result.characterRects(0, result.text.length).count { it != null })
            assertEquals(checkNotNull(result.textBaselines?.first), result.baselineForOffset(0), .01f)
            val ink = raster(result)
            assertTrue(ink.getValue(Color.BLUE).count > 0)
            assertEquals(0, ink.getValue(Color.RED).count); assertEquals(0, ink.getValue(Color.GREEN).count)
            return result
        }
        val halfEmpty = emptyReading(.5f)
        val fullEmpty = emptyReading(1f)
        assertTrue(halfEmpty.usedLineHeight(0) > bare.usedLineHeight(0))
        assertTrue(fullEmpty.usedLineHeight(0) > halfEmpty.usedLineHeight(0))
        val halfPrimary = paint(.5f).fontMetrics
        val fullPrimary = paint().fontMetrics
        val naturalDifference = (fullPrimary.descent - fullPrimary.ascent) - (halfPrimary.descent - halfPrimary.ascent)
        assertEquals(naturalDifference, fullEmpty.usedLineHeight(0) - halfEmpty.usedLineHeight(0), 1.1f)
    }

    @Test fun numericLocalShiftsPreserveAncestorPlacementAndScriptDisplacementIsAppliedOnce() {
        fun observed(script: Boolean, ownerNumeric: Float?, baseNumeric: Float?): Pair<Float, Float> {
            val value = leaf("M", zero = true, script = script)
            val annotation = leaf("r", scale = .5f, color = "#ff0000", zero = true, script = script)
            val owner = ruby(listOf(base(listOf(value), context(zero = true, script = script, numeric = baseNumeric))),
                listOf(reading(listOf(annotation), owner = context(.5f, zero = true, script = script))),
                zero = true, script = script, numeric = ownerNumeric)
            val fixture = prepare(listOf(owner), zero = true)
            val geometry = fixture.build(500)
            val baseline = checkNotNull(geometry.textBaselines?.first)
            val shift = geometry.baselineForOffset(fixture.range(value).start) - baseline
            val nativeScript = scriptShift(paint())
            assertTrue(raster(geometry).getValue(Color.BLUE).count > 0)
            return shift to nativeScript
        }
        assertEquals(.25f, observed(false, .25f, null).first, .01f)
        assertEquals(.25f, observed(false, .25f, 0f).first, .01f)
        assertEquals(1f, observed(false, .25f, .75f).first, .01f)
        val script = observed(true, null, null)
        assertTrue(script.second < 0f)
        assertEquals(script.second, script.first, .01f)
        assertEquals(.25f, observed(true, .25f, null).first, .01f)
        assertEquals(0f, observed(true, 0f, null).first, .01f)

        // Distinct actual default offsets must not turn inherited SUP mode into a
        // fresh script operation. Conversely a normal reset removes only a default
        // that was actually applied, preserving all numeric ancestor placement.
        val parentDefault = scriptShift(paint())
        val childDefault = scriptShift(paint(1.5f))
        assertTrue(parentDefault < 0f && childDefault < 0f && parentDefault != childDefault)
        fun modePosition(parentSuper: Boolean, parentNumeric: Float?, childSuper: Boolean): Float {
            val value = leaf("M", scale = 1.5f, zero = true, script = childSuper)
            val owner = ruby(listOf(base(listOf(value),
                context(1.5f, zero = true, script = childSuper))), emptyList(),
                zero = true, script = parentSuper, numeric = parentNumeric)
            val fixture = prepare(listOf(owner), zero = true, scriptFromOwnFont = true)
            val geometry = fixture.build(500)
            assertEquals("M", geometry.text.toString())
            assertSame(value, fixture.range(value).span)
            assertTrue(raster(geometry).getValue(Color.BLUE).count > 0)
            return geometry.baselineForOffset(fixture.range(value).start) -
                checkNotNull(geometry.textBaselines?.first)
        }
        assertEquals(parentDefault, modePosition(true, null, true), .01f)
        assertEquals(0f, modePosition(true, null, false), .01f)
        assertEquals(-5f, modePosition(true, -5f, true), .01f)
        assertEquals(-5f, modePosition(true, -5f, false), .01f)
        assertEquals(-5f + childDefault, modePosition(false, -5f, true), .01f)
        assertEquals(-5f, modePosition(false, -5f, false), .01f)

        val main = leaf("M", zero = true)
        val above = leaf("over", scale = .5f, color = "#ff0000", zero = true)
        val below = leaf("under", scale = .5f, color = "#00ff00", zero = true)
        data class AnnotationPosition(val baseline: Float, val caret: RectF, val selection: RectF, val ink: RectF)
        fun annotations(upperShift: Float?, lowerShift: Float?,
            ancestorShift: Float? = null): Pair<AnnotationPosition, AnnotationPosition> {
            val owner = ruby(listOf(base(listOf(main), context(zero = true))), listOf(
                reading(listOf(above), owner = context(.5f, zero = true, numeric = upperShift)),
                reading(listOf(below), level = 1, owner = context(.5f, zero = true, numeric = lowerShift))),
                zero = true, numeric = ancestorShift)
            val fixture = prepare(listOf(owner), zero = true)
            val geometry = fixture.build(500)
            assertEquals("Moverunder", geometry.text.toString())
            assertSame(above, fixture.range(above).span); assertSame(below, fixture.range(below).span)
            val baseBaseline = geometry.baselineForOffset(fixture.range(main).start)
            assertEquals(ancestorShift ?: 0f, baseBaseline - checkNotNull(geometry.textBaselines?.first), .01f)
            val pixels = raster(geometry)
            fun position(span: Span, color: Int): AnnotationPosition {
                val range = fixture.range(span)
                assertTrue(pixels.getValue(color).count > 0)
                fun relative(value: RectF) = RectF(value).apply { offset(0f, -baseBaseline) }
                return AnnotationPosition(geometry.baselineForOffset(range.start) - baseBaseline,
                    relative(geometry.caretRect(range.start)), relative(box(geometry, range)),
                    relative(checkNotNull(pixels.getValue(color).bounds)))
            }
            return position(above, Color.RED) to position(below, Color.GREEN)
        }
        val absent = annotations(null, null)
        val zero = annotations(0f, 0f)
        val movedAbove = annotations(3.25f, 0f)
        val movedBelow = annotations(0f, -3.5f)
        fun shifted(expected: AnnotationPosition, actual: AnnotationPosition, delta: Float) {
            assertEquals(expected.baseline + delta, actual.baseline, .01f)
            sameRect(RectF(expected.caret).apply { offset(0f, delta) }, actual.caret)
            sameRect(RectF(expected.selection).apply { offset(0f, delta) }, actual.selection)
            // Native raster bounds lie on integer pixels; the source displacement is
            // fractional and larger than that quantization tolerance.
            assertEquals(expected.ink.top + delta, actual.ink.top, 1.1f)
            assertEquals(expected.ink.bottom + delta, actual.ink.bottom, 1.1f)
        }
        shifted(absent.first, zero.first, 0f); shifted(absent.second, zero.second, 0f)
        shifted(zero.first, movedAbove.first, 3.25f); shifted(zero.second, movedAbove.second, 0f)
        shifted(zero.first, movedBelow.first, 0f); shifted(zero.second, movedBelow.second, -3.5f)
        // The common owner already displaces the base and the reading stack. A
        // reading-local numeric shift remains local; the common shift is not added twice.
        val displaced = annotations(0f, 0f, ancestorShift = -7.25f)
        val displacedAbove = annotations(3.25f, 0f, ancestorShift = -7.25f)
        val displacedBelow = annotations(0f, -3.5f, ancestorShift = -7.25f)
        shifted(zero.first, displaced.first, 0f); shifted(zero.second, displaced.second, 0f)
        shifted(movedAbove.first, displacedAbove.first, 0f); shifted(movedAbove.second, displacedAbove.second, 0f)
        shifted(movedBelow.first, displacedBelow.first, 0f); shifted(movedBelow.second, displacedBelow.second, 0f)

        // A gap precedes the second annotation and is outside that annotation's
        // group. The first Normal annotation gives an independently measured common
        // level baseline; the gap keeps its own complete source script/numeric policy.
        fun gapPosition(superGap: Boolean, gapNumeric: Float?, annotationNumeric: Float?): Float {
            val first = leaf("aa", scale = .5f, color = "#ff0000", zero = true)
            val second = leaf("bb", scale = .5f, color = "#00ff00", zero = true, script = true)
            val gap = leaf(" ", scale = .5f, zero = true, script = superGap).copy(inlineStyle = policy(true, gapNumeric))
            val owner = ruby(listOf(base(listOf(leaf("M", zero = true)), context(zero = true)),
                base(listOf(leaf("N", zero = true)), context(zero = true))), listOf(
                reading(listOf(first), owner = context(.5f, zero = true)),
                reading(listOf(second), start = 1, owner = context(.5f, zero = true, script = true,
                    numeric = annotationNumeric), gap = listOf(gap))), zero = true)
            val fixture = prepare(listOf(owner), zero = true, scriptFromOwnFont = true)
            val geometry = fixture.build(500)
            assertEquals("MNaa bb", geometry.text.toString())
            assertSame(gap, fixture.range(gap).span)
            val levelBaseline = geometry.baselineForOffset(fixture.range(first).start)
            val gapRange = fixture.range(gap)
            val pixels = raster(geometry)
            assertTrue(pixels.getValue(Color.RED).count > 0 && pixels.getValue(Color.GREEN).count > 0)
            return geometry.baselineForOffset(gapRange.start) - levelBaseline
        }
        val normalGap = gapPosition(false, null, null)
        val superGap = gapPosition(true, null, null)
        val numericGap = gapPosition(true, 2.25f, null)
        val changedAnnotation = gapPosition(true, 2.25f, -3.5f)
        val gapDefault = scriptShift(paint(.5f))
        assertEquals(0f, normalGap, .01f)
        assertEquals(gapDefault, superGap, .01f)
        assertEquals(2.25f, numericGap, .01f)
        assertEquals(2.25f, changedAnnotation, .01f)
        assertEquals(gapDefault, gapPosition(true, null, -3.5f), .01f)
        assertEquals(0f, gapPosition(false, null, -3.5f), .01f)
    }

    /** The joint-fragment oracle stays provisional until the selected planner/actual-band
     * source tuple is frozen. This method deliberately checks source and geometry, not a
     * preselected font-dependent line count or a ratio-derived reading split. */
    @Test fun jointNativeFragmentsKeepIndependentSourceRangesInsideTheActualFloatBand() {
        val baseText = leaf("\u6f22\u5b57\u4eee\u540d\u6f22\u5b57\u4eee\u540d\u6f22\u5b57\u4eee\u540d", "base-long")
        val readText = leaf("\u304b\u3093\u3058\u304b\u306a\u304b\u3093\u3058\u304b\u306a\u304b\u3093\u3058\u304b\u306a", "reading-long", .5f, "#ff0000")
        val owner = ruby(listOf(base(listOf(baseText))), listOf(reading(listOf(readText))))
        val calls = mutableListOf<Span>()
        val fixture = prepare(listOf(owner), onAction = { calls += it })
        val wide = fixture.build(900)
        assertEquals(1, wide.shapedLineCount)
        val width = ceil(paint().measureText("\u6f22\u5b57\u4eee\u540d").toDouble()).toInt().coerceAtLeast(64)
        val bandWidth = width / 3f
        val bandHeight = paint().fontSpacing * 4f
        val band = NativeFloatBounds(0f, 0f, bandWidth, bandHeight)
        val narrow = fixture.build(width, listOf(NativeFloatExclusion(TableFloatSide.Left, band)))
        assertEquals(fixture.projection.text, narrow.text.toString())
        assertTrue(narrow.shapedLineCount > 1)
        assertActions(fixture, wide); assertActions(fixture, narrow)
        val base = fixture.range(baseText); val reading = fixture.range(readText)
        val rows = (0 until narrow.shapedLineCount).map { narrow.nativeRubyLineRanges(it) }
        assertTrue(rows.all { it.isNotEmpty() && it.zipWithNext().all { (a, b) -> a.second <= b.first } })
        assertTrue(rows.any { fragments ->
            fragments.any { it.first < base.end && it.second > base.start } &&
                fragments.any { it.first < reading.end && it.second > reading.start }
        })
        assertTrue(rows.count { fragments -> fragments.any { it.first < base.end && it.second > base.start } } > 1)
        assertTrue(rows.count { fragments -> fragments.any { it.first < reading.end && it.second > reading.start } } > 1)
        val counts = IntArray(narrow.text.length)
        rows.flatten().forEach { (start, end) -> for (offset in start until end) counts[offset]++ }
        assertTrue(counts.all { it == 1 })
        assertTrue(narrow.nativeRubyLineTop(0) < band.bottom)
        val first = narrow.nativeRubyLineRanges(0).flatMap { (start, end) -> narrow.nativeRubyLineRects(0, start, end) }
        assertTrue(first.isNotEmpty())
        assertTrue(first.all { it.left >= band.right - 1f })
        rows.forEachIndexed { line, fragments -> fragments.forEach { (start, end) ->
            assertEquals(fragments, narrow.visualLineRanges(start))
            assertEquals(narrow.text.subSequence(start, end).toString(), fixture.projection.text.substring(start, end))
            assertTrue(narrow.nativeRubyLineRects(line, start, end).isNotEmpty())
        } }
        wide.nodes.zip(narrow.nodes).forEach { (a, b) ->
            assertEquals(a.id, b.id); assertEquals(a.start, b.start); assertEquals(a.end, b.end)
            assertSame(a.onClick, b.onClick)
        }
        narrow.nodes.forEach { checkNotNull(it.onClick).invoke() }
        assertEquals(listOf(baseText, readText), calls)
        val ink = raster(narrow)
        assertTrue(ink.getValue(Color.BLUE).count > 0)
        assertTrue(ink.getValue(Color.RED).count > 0)
    }

    @Test fun actualNestedHierarchyAddsOnlyIncrementalGapsAndKeepsZeroOpportunityRecoveryIntact() {
        val before = leaf("\u7532", "before")
        val firstBase = leaf("\u4e59\u4e19", "first-base")
        val firstReading = leaf("\u3042\u3044\u3046\u3048\u304a\u304b", "first-reading", .5f, "#ff0000")
        val secondBase = leaf("\u4e01\u620a", "second-base")
        val secondReading = leaf("\u304d\u304f\u3051", "second-reading", .5f, "#00ff00")
        val after = leaf("\u5df1", "after")
        val first = ruby(listOf(base(listOf(firstBase))), listOf(reading(listOf(firstReading))))
        val second = ruby(listOf(base(listOf(secondBase))), listOf(reading(listOf(secondReading))))
        val shared = base(listOf(before, first, second, after))
        val outerReading = leaf("\u3042\u3044\u3046\u3048\u304a\u304b\u304d\u304f\u3051\u3053\u3055\u3057\u3059\u305b\u305d\u305f\u3061\u3064\u3066\u3068",
            "outer-reading", .5f, "#ff0000")
        val naturalFixture = prepare(listOf(ruby(listOf(shared), emptyList())))
        val calls = mutableListOf<Span>()
        val expandedFixture = prepare(listOf(ruby(listOf(shared), listOf(reading(listOf(outerReading))))),
            onAction = { calls += it })
        val natural = naturalFixture.build(1000)
        val expanded = expandedFixture.build(1000)
        assertEquals(1, natural.shapedLineCount); assertEquals(1, expanded.shapedLineCount)
        assertActions(naturalFixture, natural); assertActions(expandedFixture, expanded)
        assertEquals(natural.text.toString() + outerReading.text, expanded.text.toString())
        naturalFixture.actions.zip(expandedFixture.actions).forEach { (a, b) ->
            assertSame(a.source, b.source); assertEquals(a.range.start, b.range.start); assertEquals(a.range.end, b.range.end)
        }
        fun glyph(fixture: Fixture, geometry: NativeFloatGeometry, span: Span, at: Int = 0): RectF =
            checkNotNull(geometry.characterRects(fixture.range(span).start + at, 1).single())
        fun gaps(fixture: Fixture, geometry: NativeFloatGeometry): List<Float> {
            val a = glyph(fixture, geometry, before)
            val b = glyph(fixture, geometry, firstBase)
            val c = glyph(fixture, geometry, firstBase, 1)
            val d = glyph(fixture, geometry, secondBase)
            val e = glyph(fixture, geometry, secondBase, 1)
            val f = glyph(fixture, geometry, after)
            return listOf(b.left - a.right, c.left - b.right, d.left - c.right, e.left - d.right, f.left - e.right)
        }
        val originalGaps = gaps(naturalFixture, natural)
        val expandedGaps = gaps(expandedFixture, expanded)
        assertTrue(originalGaps[1] > originalGaps[3]) // Unequal existing annotation-induced inner slack.
        val naturalLeft = glyph(naturalFixture, natural, before).left
        val naturalRight = glyph(naturalFixture, natural, after).right
        val readingBox = box(expanded, expandedFixture.range(outerReading))
        val extra = readingBox.width() - (naturalRight - naturalLeft)
        val unit = extra / 6f // Six explicit original base graphemes, including both nested pairs.
        assertTrue(unit > 4f)
        for (index in originalGaps.indices)
            assertEquals(unit, expandedGaps[index] - originalGaps[index], 1.1f)
        assertEquals(originalGaps[1] - originalGaps[3], expandedGaps[1] - expandedGaps[3], 1.1f)
        assertEquals(unit / 2f, glyph(expandedFixture, expanded, before).left - readingBox.left, 1.1f)
        assertEquals(unit / 2f, readingBox.right - glyph(expandedFixture, expanded, after).right, 1.1f)

        val readingStart = expandedFixture.range(firstReading).start
        assertEquals(readingStart + 1, expanded.visualOffset(readingStart, 1))
        assertTrue(expanded.caretRect(readingStart + 1).left > expanded.caretRect(readingStart).left)
        val baseLast = expandedFixture.range(secondBase).end - 1
        val leaving = expanded.visualOffset(baseLast, 1)
        assertNotEquals(baseLast, leaving)
        assertTrue(expanded.caretRect(leaving).left > expanded.caretRect(baseLast).left)
        val ordinaryStart = expandedFixture.range(after).start
        val entering = expanded.visualOffset(ordinaryStart, -1)
        assertNotEquals(ordinaryStart, entering)
        // The logical terminal boundary is also the following ordinary owner's
        // start. Native entry must reach the reading's previous grapheme, not skip
        // to its far range edge. Shape that same source reading independently.
        val standaloneReading = prepare(listOf(secondReading)).build(1000)
        assertEquals(secondReading.text, standaloneReading.text.toString())
        assertEquals(1, standaloneReading.shapedLineCount)
        val previousReadingStop = standaloneReading.visualOffset(standaloneReading.text.length, -1)
        assertTrue(previousReadingStop in 0 until standaloneReading.text.length)
        assertEquals(expandedFixture.range(secondReading).start + previousReadingStop, entering)
        assertTrue(expanded.caretRect(entering).left < expanded.caretRect(ordinaryStart).left)
        assertTrue(entering in expandedFixture.range(secondBase).start..expandedFixture.range(secondReading).end)
        expanded.nodes.forEach { checkNotNull(it.onClick).invoke() }
        assertEquals(expandedFixture.actions.map { it.source }, calls)
        val expandedInk = raster(expanded)
        for (color in listOf(Color.RED, Color.GREEN, Color.BLUE)) assertTrue(expandedInk.getValue(color).count > 0)

        // The mixed join has no spacing opportunity. Nested base interiors still
        // receive the parent's unit; their old annotation-induced slack is retained.
        val mixedBefore = leaf("L", "mixed-before")
        val mixedBase = base(listOf(mixedBefore, first))
        val mixedNaturalFixture = prepare(listOf(ruby(listOf(mixedBase), emptyList())))
        val mixedCalls = mutableListOf<Span>()
        val mixed = prepare(listOf(ruby(listOf(mixedBase), listOf(reading(listOf(outerReading))))),
            onAction = { mixedCalls += it })
        val mixedNatural = mixedNaturalFixture.build(1000)
        val mixedExpanded = mixed.build(1000)
        assertEquals(1, mixedExpanded.shapedLineCount)
        assertActions(mixed, mixedExpanded)
        assertEquals(mixedNatural.text.toString() + outerReading.text, mixedExpanded.text.toString())
        val mixedRow = prepare(listOf(mixedBefore, first)).build(1000)
        val mixedReadingBox = box(mixedExpanded, mixed.range(outerReading))
        val mixedUnit = (mixedReadingBox.width() - mixedRow.nativeSingleLineAdvance()) / 2f
        assertTrue(mixedUnit > 4f) // One nested base interior plus the whole-row edge budget.
        fun firstGap(f: Fixture, g: NativeFloatGeometry) = glyph(f, g, firstBase, 1).left - glyph(f, g, firstBase).right
        assertEquals(mixedUnit, firstGap(mixed, mixedExpanded) - firstGap(mixedNaturalFixture, mixedNatural), 1.1f)
        val oldJoin = glyph(mixedNaturalFixture, mixedNatural, firstBase).left -
            box(mixedNatural, mixedNaturalFixture.range(mixedBefore)).right
        val newJoin = glyph(mixed, mixedExpanded, firstBase).left - box(mixedExpanded, mixed.range(mixedBefore)).right
        assertEquals(oldJoin, newJoin, 1.1f)
        assertEquals(mixedUnit / 2f, box(mixedExpanded, mixed.range(mixedBefore)).left - mixedReadingBox.left, 1.1f)
        for (span in listOf(firstBase, firstReading)) {
            val occupied = box(mixedExpanded, mixed.range(span))
            assertTrue(occupied.left >= box(mixedExpanded, mixed.range(mixedBefore)).right - 1.1f)
            assertTrue(occupied.right <= mixedReadingBox.right + 1.1f)
        }
        mixedExpanded.nodes.forEach { checkNotNull(it.onClick).invoke() }
        assertEquals(mixed.actions.map { it.source }, mixedCalls)

        // Parallel readings have independent opportunity counts. A long Latin
        // reading stays intact while CJK annotation gaps use its own added budget.
        val parallelBase = leaf("\u6f22\u5b57", "parallel-base")
        val parallelAbove = leaf("\u3042\u3044\u3046\u3048\u304a\u304b", "parallel-above", .5f, "#ff0000")
        val parallelBelow = leaf("unbreakable", "parallel-below", .5f, "#00ff00")
        val parallel = ruby(listOf(base(listOf(parallelBase))), listOf(reading(listOf(parallelAbove)),
            reading(listOf(parallelBelow), level = 1)))
        val parallelBefore = leaf("L", "parallel-before")
        val parallelOuter = leaf(outerReading.text, "parallel-outer", .5f, "#000000")
        val parallelBody = base(listOf(parallelBefore, parallel))
        val parallelNaturalFixture = prepare(listOf(ruby(listOf(parallelBody), emptyList())))
        val parallelCalls = mutableListOf<Span>()
        val parallelFixture = prepare(listOf(ruby(listOf(parallelBody), listOf(reading(listOf(parallelOuter))))),
            onAction = { parallelCalls += it })
        val parallelNatural = parallelNaturalFixture.build(1000)
        val parallelExpanded = parallelFixture.build(1000)
        val parallelRow = prepare(listOf(parallelBefore, parallel)).build(1000)
        val parallelOuterBox = box(parallelExpanded, parallelFixture.range(parallelOuter))
        val parallelUnit = (parallelOuterBox.width() - parallelRow.nativeSingleLineAdvance()) / 2f
        assertTrue(parallelUnit > 4f)
        val nestedGrowth = parallelUnit * 1.5f // One interior, no left join, one physical outer half.
        val intrinsicWidth = listOf(parallelBase, parallelAbove, parallelBelow).maxOf {
            prepare(listOf(it)).build(1000).nativeSingleLineAdvance()
        }
        val nestedLeft = box(parallelExpanded, parallelFixture.range(parallelBefore)).left +
            prepare(listOf(parallelBefore)).build(1000).nativeSingleLineAdvance()
        val nestedRight = nestedLeft + intrinsicWidth + nestedGrowth
        for (span in listOf(parallelBase, parallelAbove, parallelBelow)) {
            val occupied = box(parallelExpanded, parallelFixture.range(span))
            assertTrue(occupied.left >= nestedLeft - 1.1f)
            assertTrue(occupied.right <= nestedRight + 1.1f)
        }
        fun spanGap(f: Fixture, g: NativeFloatGeometry, span: Span) = glyph(f, g, span, 1).left - glyph(f, g, span).right
        assertEquals(parallelUnit, spanGap(parallelFixture, parallelExpanded, parallelBase) -
            spanGap(parallelNaturalFixture, parallelNatural, parallelBase), 1.1f)
        assertEquals(nestedGrowth / parallelAbove.text.length,
            spanGap(parallelFixture, parallelExpanded, parallelAbove) -
                spanGap(parallelNaturalFixture, parallelNatural, parallelAbove), 1.1f)
        val oldBelow = box(parallelNatural, parallelNaturalFixture.range(parallelBelow))
        val newBelow = box(parallelExpanded, parallelFixture.range(parallelBelow))
        assertEquals(oldBelow.width(), newBelow.width(), .01f)
        for (offset in parallelBelow.text.indices)
            assertEquals(glyph(parallelNaturalFixture, parallelNatural, parallelBelow, offset).left - oldBelow.left,
                glyph(parallelFixture, parallelExpanded, parallelBelow, offset).left - newBelow.left, .01f)
        assertActions(parallelFixture, parallelExpanded)
        parallelExpanded.nodes.forEach { checkNotNull(it.onClick).invoke() }
        assertEquals(parallelFixture.actions.map { it.source }, parallelCalls)
        val parallelInk = raster(parallelExpanded)
        assertTrue(parallelInk.getValue(Color.RED).count > 0) // Only the above reading owns red.
        assertTrue(parallelInk.getValue(Color.GREEN).count > 0) // Only the intact below reading owns green.
        assertTrue(parallelInk.getValue(Color.BLUE).count > 0)

        // A genuinely empty BASE has no source edge. Its visible reading and
        // allocated owner still exist between the two source-bearing neighbors.
        val emptyLeft = leaf("\u6f22", "empty-left", color = "#000000")
        val emptyRight = leaf("\u5b57", "empty-right", color = "#000000")
        val emptyBase = base(emptyList())
        val emptyReading = leaf("empty", "empty-reading", .5f, "#ff0000")
        val emptyRuby = ruby(listOf(emptyBase), listOf(reading(listOf(emptyReading))))
            .copy(background = "#00ff00", inlineStyle = policy(false).copy(cursor = InlineCursor.Help,
                decoration = InlineUnderline(InlineUnderlineStyle.Solid, "#0000ff", StyleLength(StyleLengthUnit.Px, 1f))))
        fun withEmptyOwner(spans: List<Span>, onAction: (Span) -> Unit = {}): Fixture {
            val original = prepare(spans, onAction = onAction)
            val retained = original.source.getSpans(0, original.source.length, NativeRubyPreparedSource::class.java).single()
            val declaring = retained.projection.ranges.single { it.role == RubyTextRole.Owner && it.span === emptyRuby }
            val format = retained.groups.getValue(declaring.path)
            val decorated = NativeRubyGroupFormat(TextPaint(format.paint).apply { bgColor = Color.GREEN },
                format.direction, format.lineHeight, format.baselineShift, wrap = format.wrap,
                underline = NativeAuthoredUnderline(InlineUnderlineStyle.Solid, Color.BLUE, 1f),
                cursor = InlineCursor.Help, sourceDirection = format.sourceDirection,
                localBaselineShift = format.localBaselineShift)
            val prepared = NativeRubyPreparedSource(retained.projection, retained.source, retained.paint,
                retained.direction, retained.groups + (declaring.path to decorated), parentScript = retained.parentScript)
            val value = SpannableString(retained.source).apply { setSpan(prepared, 0, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE) }
            return Fixture(original.spans, SpannedString(value), original.projection, original.body, original.actions, original.rtl)
        }
        val emptyOriginal = withEmptyOwner(listOf(emptyLeft, emptyRuby, emptyRight))
        val emptyRow = emptyOriginal.build(1000)
        val emptyOuterReading = leaf(outerReading.text, "empty-outer", .5f, "#000000")
        val emptyCalls = mutableListOf<Span>()
        val emptyExpandedFixture = withEmptyOwner(listOf(ruby(listOf(base(listOf(emptyLeft, emptyRuby, emptyRight))),
            listOf(reading(listOf(emptyOuterReading))))), onAction = { emptyCalls += it })
        val emptyExpanded = emptyExpandedFixture.build(1000)
        assertEquals(1, emptyRow.shapedLineCount); assertEquals(1, emptyExpanded.shapedLineCount)
        val emptyBaseRange = emptyExpandedFixture.projection.ranges.single { it.base === emptyBase && it.role == RubyTextRole.Base }
        assertEquals(emptyBaseRange.start, emptyBaseRange.end)
        assertSame(emptyBase, emptyBaseRange.base)
        assertTrue(emptyExpanded.rectsForRange(emptyBaseRange.start, emptyBaseRange.end).isEmpty())
        assertEquals(emptyRow.text.toString() + emptyOuterReading.text, emptyExpanded.text.toString())
        val oldEmptyReading = box(emptyRow, emptyOriginal.range(emptyReading))
        val newEmptyReading = box(emptyExpanded, emptyExpandedFixture.range(emptyReading))
        val emptyCoverage = box(emptyExpanded, emptyExpandedFixture.range(emptyOuterReading))
        val emptyUnit = (emptyCoverage.width() - emptyRow.nativeSingleLineAdvance()) / 2f
        assertTrue(emptyUnit > 4f) // One nearest-source join; the empty owner contributes zero units.
        assertEquals(oldEmptyReading.width(), newEmptyReading.width(), .01f)
        for (offset in emptyReading.text.indices)
            assertEquals(glyph(emptyOriginal, emptyRow, emptyReading, offset).left - oldEmptyReading.left,
                glyph(emptyExpandedFixture, emptyExpanded, emptyReading, offset).left - newEmptyReading.left, .01f)
        assertEquals(emptyUnit, newEmptyReading.left - oldEmptyReading.left - emptyCoverage.left, 1.1f)
        assertEquals(emptyUnit / 2f, glyph(emptyExpandedFixture, emptyExpanded, emptyLeft).left - emptyCoverage.left, 1.1f)
        assertEquals(emptyUnit / 2f, emptyCoverage.right - glyph(emptyExpandedFixture, emptyExpanded, emptyRight).right, 1.1f)
        assertEquals(oldEmptyReading.height(), newEmptyReading.height(), .01f)
        assertEquals(emptyRow.baselineForOffset(emptyOriginal.range(emptyReading).start) -
            emptyRow.baselineForOffset(emptyOriginal.range(emptyLeft).start),
            emptyExpanded.baselineForOffset(emptyExpandedFixture.range(emptyReading).start) -
                emptyExpanded.baselineForOffset(emptyExpandedFixture.range(emptyLeft).start), .01f)
        assertEquals(InlineCursor.Help, emptyExpanded.cursorAt(newEmptyReading.centerX(), newEmptyReading.centerY()))
        val emptyInk = raster(emptyExpanded)
        for (color in listOf(Color.RED, Color.GREEN, Color.BLUE)) assertTrue(emptyInk.getValue(color).count > 0)
        assertActions(emptyExpandedFixture, emptyExpanded)
        emptyExpanded.nodes.forEach { checkNotNull(it.onClick).invoke() }
        assertEquals(emptyExpandedFixture.actions.map { it.source }, emptyCalls)
        val emptyAgain = emptyOriginal.build(1000)
        sameRect(oldEmptyReading, box(emptyAgain, emptyOriginal.range(emptyReading)))
        assertEquals(emptyOriginal.projection.text, emptyAgain.text.toString())
        assertActions(emptyOriginal, emptyAgain)

        val latinBefore = leaf("L", "latin-before")
        val latinBase = leaf("M", "latin-base")
        val latinReading = leaf("many", "latin-reading", .5f, "#ff0000")
        val latinAfter = leaf("N", "latin-after")
        val latinInner = ruby(listOf(base(listOf(latinBase))), listOf(reading(listOf(latinReading))))
        val latinShared = base(listOf(latinBefore, latinInner, latinAfter))
        val latinNaturalFixture = prepare(listOf(ruby(listOf(latinShared), emptyList())))
        val latinExpandedFixture = prepare(listOf(ruby(listOf(latinShared),
            listOf(reading(listOf(leaf("verylongreading", scale = .5f, color = "#ff0000")))))))
        val latinNatural = latinNaturalFixture.build(1000)
        val latinExpanded = latinExpandedFixture.build(1000)
        fun latinGap(fixture: Fixture, geometry: NativeFloatGeometry) =
            glyph(fixture, geometry, latinBase).left - glyph(fixture, geometry, latinBefore).right
        assertEquals(latinGap(latinNaturalFixture, latinNatural), latinGap(latinExpandedFixture, latinExpanded), 1.1f)
        assertActions(latinExpandedFixture, latinExpanded)
        val latinInk = raster(latinExpanded)
        assertTrue(latinInk.getValue(Color.BLUE).count > 0 && latinInk.getValue(Color.RED).count > 0)
    }

    @Test fun recursiveBaseAndReadingKeepAnEmptyAssociationAtomicAcrossFloatBandsAndRtlReflow() {
        val prefix = leaf("\u7532\u4e59", "prefix")
        val locked = leaf("\u6f22\u5b57", "locked")
        val flexible = leaf("\u4eee\u540d\u6f22\u5b57\u4eee\u540d\u6f22\u5b57\u4eee\u540d\u6f22\u5b57", "flexible")
        val flexibleReading = leaf("\u3042\u3044\u3046\u3048\u304a\u304b\u304d\u304f\u3051\u3053\u3055\u3057",
            "flexible-reading", .5f, "#ff0000")
        val readingBase = leaf("\u3042\u3044\u3046\u3048\u304a\u304b\u304d\u304f\u3051\u3053\u3055\u3057".repeat(2),
            "nested-reading-base", .5f, "#00ff00")
        val readingAnnotation = leaf("\u30a2\u30a4\u30a6\u30a8\u30aa\u30ab\u30ad\u30af\u30b1\u30b3\u30b5\u30b7".repeat(2),
            "nested-reading-annotation", .25f, "#ff0000")
        val probeLeaf = leaf(prefix.text + locked.text)
        val probe = prepare(listOf(probeLeaf)).build(1000)
        val width = ceil(probe.nativeSingleLineAdvance().toDouble()).toInt()
        val glyphAdvance = prepare(listOf(leaf(locked.text.take(1)))).build(1000).nativeSingleLineAdvance()
        val plainLocked = prepare(listOf(locked)).build(ceil(glyphAdvance.toDouble()).toInt())
        assertEquals(2, plainLocked.shapedLineCount) // Its ordinary native interior cut exists.
        val bandWidth = glyphAdvance
        val available = width - bandWidth
        val prefixAdvance = prepare(listOf(prefix)).build(1000).nativeSingleLineAdvance()
        assertTrue(available >= prefixAdvance + glyphAdvance - .01f)
        assertTrue(available < probe.nativeSingleLineAdvance())

        for (rtl in listOf(false, true)) {
            val direction = if (rtl) "rtl" else "ltr"
            fun owner(scale: Float = 1f) = context(scale).copy(direction = direction)
            val emptyReading = reading(emptyList(), owner = owner(.5f))
            val innerBase = ruby(listOf(base(listOf(locked), owner()), base(listOf(flexible), owner())),
                listOf(emptyReading, reading(listOf(flexibleReading), start = 1, owner = owner(.5f))))
                .copy(direction = direction)
            val innerReading = ruby(listOf(base(listOf(readingBase), owner(.5f))),
                listOf(reading(listOf(readingAnnotation), owner = owner(.25f))))
                .copy(direction = direction, fontScale = .5f)
            val outerBase = base(listOf(prefix, innerBase), owner())
            val outerReading = reading(listOf(innerReading), owner = owner(.5f))
            val source = ruby(listOf(outerBase), listOf(outerReading)).copy(direction = direction)
            val calls = mutableListOf<Span>()
            val fixture = prepare(listOf(source), onAction = { calls += it }, rtl = rtl)
            val expected = prefix.text + locked.text + flexible.text + flexibleReading.text +
                readingBase.text + readingAnnotation.text
            assertEquals(expected, fixture.projection.text)
            val emptyRange = fixture.projection.ranges.single {
                it.role == RubyTextRole.Annotation && it.annotation === emptyReading
            }
            assertEquals(emptyRange.start, emptyRange.end)
            val outerBaseRange = fixture.projection.ranges.single { it.role == RubyTextRole.Base && it.base === outerBase }
            val outerReadingRange = fixture.projection.ranges.single {
                it.role == RubyTextRole.Annotation && it.annotation === outerReading
            }
            val wide = fixture.build(1000)
            assertEquals(1, wide.shapedLineCount)
            val bandHeight = wide.nativeUsedLineMetrics(0).height * if (rtl) 2.25f else 1.25f
            val band = if (rtl) NativeFloatBounds(width - bandWidth, 0f, width.toFloat(), bandHeight)
                else NativeFloatBounds(0f, 0f, bandWidth, bandHeight)
            val narrow = fixture.build(width, listOf(NativeFloatExclusion(
                if (rtl) TableFloatSide.Right else TableFloatSide.Left, band)))
            assertTrue(narrow.shapedLineCount > 1)
            assertEquals(expected, narrow.text.toString())
            val rows = (0 until narrow.shapedLineCount).map(narrow::nativeRubyLineRanges)
            fun intersects(ranges: List<Pair<Int, Int>>, range: RubyTextRange) =
                ranges.any { it.first < range.end && it.second > range.start }
            val prefixRange = fixture.range(prefix)
            val lockedRange = fixture.range(locked)
            val flexibleRange = fixture.range(flexible)
            assertTrue(rows.first().any { it.first <= prefixRange.start && it.second >= prefixRange.end })
            assertFalse(intersects(rows.first(), lockedRange))
            assertEquals(1, rows.count { intersects(it, lockedRange) })
            assertTrue(rows.count { intersects(it, flexibleRange) } > 1)
            assertTrue(rows.count { intersects(it, fixture.range(readingBase)) } > 1)
            val coverage = IntArray(expected.length)
            rows.forEachIndexed { line, ranges ->
                assertTrue(ranges.isNotEmpty())
                assertTrue(ranges.zipWithNext().all { (a, b) -> a.second <= b.first })
                // Neither parallel side may be exhausted and replaced by empty continuations.
                assertTrue(intersects(ranges, outerBaseRange))
                assertTrue(intersects(ranges, outerReadingRange))
                ranges.forEach { (start, end) ->
                    assertEquals(ranges, narrow.visualLineRanges(start))
                    for (offset in start until end) {
                        coverage[offset]++
                        val character = checkNotNull(narrow.characterRects(offset, 1).single())
                        assertFalse(character.isEmpty)
                        val actualRowRects = narrow.nativeRubyLineRects(line, offset, offset + 1)
                        assertTrue(actualRowRects.isNotEmpty())
                        sameRect(character, actualRowRects.map(::RectF).reduce { a, b -> a.apply { union(b) } })
                    }
                }
            }
            assertTrue(coverage.all { it == 1 })
            val firstRects = rows.first().flatMap { (start, end) -> narrow.nativeRubyLineRects(0, start, end) }
            assertTrue(firstRects.isNotEmpty())
            if (rtl) assertTrue(firstRects.all { it.right <= band.left + 1f })
            else assertTrue(firstRects.all { it.left >= band.right - 1f })
            rows.forEachIndexed { line, ranges ->
                val rowTop = narrow.nativeRubyLineTop(line)
                val rowBottom = rowTop + narrow.nativeUsedLineMetrics(line).height
                if (rowTop < band.bottom && rowBottom > band.top) {
                    val rowRects = ranges.flatMap { (start, end) -> narrow.nativeRubyLineRects(line, start, end) }
                    assertTrue(rowRects.isNotEmpty())
                    if (rtl) assertTrue(rowRects.all { it.right <= band.left + 1f })
                    else assertTrue(rowRects.all { it.left >= band.right - 1f })
                }
            }
            assertTrue(narrow.nativeRubyLineTop(0) < band.bottom)
            assertTrue(narrow.nativeRubyLineTop(narrow.shapedLineCount - 1) >= band.bottom)

            // Whole-owner inheritance must suppress cuts in both nested sides. The
            // existing NoWrap float refusal is separate, so compare at this same
            // narrow width without carried exclusions, then recover the normal source.
            val normalAtWidth = fixture.build(width)
            assertTrue(normalAtWidth.shapedLineCount > 1)
            val originalPrepared = fixture.source.getSpans(0, fixture.source.length,
                NativeRubyPreparedSource::class.java).single()
            val noWrapLogical = SpannableString(originalPrepared.source).apply {
                setSpan(NativeAuthoredTextWrap(TextWrap.NoWrap, inheritedOwner = true,
                    sourceLineStarts = listOf(0)), 0, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            }
            val noWrapPrepared = NativeRubyPreparedSource(originalPrepared.projection,
                SpannedString(noWrapLogical), originalPrepared.paint, originalPrepared.direction,
                originalPrepared.groups, parentScript = originalPrepared.parentScript)
            val noWrapSource = SpannableString(noWrapLogical).apply {
                setSpan(noWrapPrepared, 0, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            }
            val noWrapFixture = Fixture(fixture.spans, SpannedString(noWrapSource), fixture.projection,
                fixture.body, fixture.actions, rtl)
            val noWrap = noWrapFixture.build(width)
            assertEquals(expected, noWrap.text.toString())
            assertEquals(1, noWrap.shapedLineCount)
            assertTrue(noWrap.nativeSingleLineAdvance() > width)
            val noWrapBase = box(noWrap, outerBaseRange)
            assertTrue(noWrapBase.left < 0f || noWrapBase.right > width)
            assertActions(noWrapFixture, noWrap)
            fixture.actions.zip(noWrap.nodes).forEach { (action, node) -> assertSame(action.invoke, node.onClick) }
            val normalAgain = fixture.build(width)
            assertEquals(expected, normalAgain.text.toString())
            assertEquals(normalAtWidth.shapedLineCount, normalAgain.shapedLineCount)
            for (line in 0 until normalAgain.shapedLineCount)
                assertEquals(normalAtWidth.nativeRubyLineRanges(line), normalAgain.nativeRubyLineRanges(line))
            normalAtWidth.characterRects(0, expected.length).zip(normalAgain.characterRects(0, expected.length))
                .forEach { (a, b) -> sameRect(checkNotNull(a), checkNotNull(b)) }
            assertActions(fixture, normalAgain)
            val recovered = fixture.build(1000)
            assertEquals(1, recovered.shapedLineCount)
            for (geometry in listOf(wide, narrow, recovered)) {
                assertEquals(expected, geometry.text.toString())
                assertActions(fixture, geometry)
            }
            wide.nodes.zip(narrow.nodes).forEach { (a, b) ->
                assertEquals(a.id, b.id); assertEquals(a.start, b.start); assertEquals(a.end, b.end)
                assertSame(a.onClick, b.onClick)
            }
            wide.nodes.zip(recovered.nodes).forEach { (a, b) ->
                assertEquals(a.id, b.id); assertSame(a.onClick, b.onClick)
                assertEquals(a.bounds.size, b.bounds.size)
                a.bounds.zip(b.bounds).forEach { (x, y) -> sameRect(x, y) }
            }
            narrow.nodes.forEach { checkNotNull(it.onClick).invoke() }
            assertEquals(fixture.actions.map { it.source }, calls)
            val ink = raster(narrow)
            for (color in listOf(Color.BLUE, Color.GREEN, Color.RED)) assertTrue(ink.getValue(color).count > 0)
        }
    }


    @Test fun contextualRawGapsKeepTheirPaintAndOwnerCursorThenTrimAndRecoverAtNativeEdges() {
        fun underline(value: InlineUnderline?): NativeAuthoredUnderline? = value?.let {
            val thickness = it.thickness?.let { length ->
                when (length.unit) {
                    StyleLengthUnit.Px -> length.value
                    else -> error("This explicit fixture only authors pixel underlines")
                }
            }
            NativeAuthoredUnderline(it.style, it.color?.let(Color::parseColor), thickness)
        }
        // Add existing source-owned paint/decoration/cursor metadata locally. The
        // shared fixture helper and the preceding six controls keep their semantics.
        fun styled(spans: List<Span>, onAction: (Span) -> Unit = {}, rtl: Boolean = false): Fixture {
            val plain = prepare(spans, onAction = onAction, rtl = rtl)
            val original = plain.source.getSpans(0, plain.source.length, NativeRubyPreparedSource::class.java).single()
            val logical = SpannableString(original.source)
            original.projection.ranges.filter { it.span != null && it.role != RubyTextRole.Owner && it.start < it.end }
                .forEach { range ->
                    val span = checkNotNull(range.span)
                    val resolved = TextPaint(original.paint)
                    val old = logical.getSpans(range.start, range.end, SourcePaint::class.java)
                    old.forEach { it.updateMeasureState(resolved); logical.removeSpan(it) }
                    resolved.bgColor = span.background?.let(Color::parseColor) ?: 0
                    logical.setSpan(SourcePaint(resolved), range.start, range.end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                    underline(span.inlineStyle?.decoration)?.let {
                        logical.setSpan(it, range.start, range.end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                    }
                    span.inlineStyle?.cursor?.let {
                        logical.setSpan(NativeAuthoredCursor(it), range.start, range.end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                    }
                }
            val groups = original.groups.mapValues { (path, format) ->
                val range = original.projection.ranges.single { it.path == path }
                val declaring = when (range.role) {
                    RubyTextRole.Owner -> checkNotNull(range.span).let {
                        RubyOwner(snapshot(it), it.direction, it.inlineStyle, it.foreground, it.background)
                    }
                    RubyTextRole.Base -> checkNotNull(range.base).owner
                    RubyTextRole.Annotation -> checkNotNull(range.annotation).owner
                    else -> error("Not a declaring group")
                }
                val resolved = TextPaint(format.paint).apply { bgColor = declaring.background?.let(Color::parseColor) ?: 0 }
                NativeRubyGroupFormat(resolved, format.direction, format.lineHeight, format.baselineShift,
                    wrap = format.wrap, underline = underline(declaring.inlineStyle?.decoration),
                    cursor = declaring.inlineStyle?.cursor, sourceDirection = format.sourceDirection,
                    localBaselineShift = format.localBaselineShift)
            }
            val prepared = NativeRubyPreparedSource(original.projection, SpannedString(logical), original.paint,
                original.direction, groups, parentScript = original.parentScript)
            val source = SpannableString(logical).apply {
                setSpan(prepared, 0, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            }
            return Fixture(plain.spans, SpannedString(source), plain.projection, plain.body, plain.actions, plain.rtl)
        }
        val first = leaf("word", "word")
        val next = leaf("next\u6f22\u5b57", "next")
        val gap = leaf("\r\n\t", scale = .5f).copy(background = "#00ff00",
            inlineStyle = policy(false).copy(decoration = InlineUnderline(InlineUnderlineStyle.Solid,
                "#ff0000", StyleLength(StyleLengthUnit.Px, 1f))))
        fun inner(space: Span) = ruby(listOf(base(listOf(first)), base(listOf(next), gap = listOf(space))), emptyList())
            .copy(inlineStyle = policy(false).copy(cursor = InlineCursor.Help))
        val source = inner(gap)
        val calls = mutableListOf<Span>()
        val fixture = styled(listOf(source), onAction = { calls += it })
        val expected = first.text + gap.text + next.text
        assertEquals("word\r\n\tnext\u6f22\u5b57", expected)
        assertEquals(expected, fixture.projection.text)
        val gapRange = fixture.range(gap)
        assertNull(gap.inlineStyle?.cursor)
        val wide = fixture.build(1200)
        assertEquals(1, wide.shapedLineCount)
        assertEquals(expected, wide.text.toString())
        val retained = wide.nativeRubyCollapsedText.single { it.start == gapRange.start && it.end == gapRange.end }
        assertFalse(retained.trimmed)
        assertEquals(" ", wide.nativeRubyRaw.nativeRubyShapingSource.subSequence(retained.nativeStart, retained.nativeEnd).toString())
        assertEquals(3, retained.end - retained.start)
        assertTrue(wide.nativeRubyRaw.nativeRubyShapingSource.any { it in '\u2066'..'\u2069' })
        for (offset in gapRange.start until gapRange.end) assertFalse(wide.isHardLineBreak(offset))
        val halfSpace = paint(.5f).measureText(" ")
        val actualHalf = wide.nativeRubyRaw.nativeRubyMeasuredAdvance(retained.nativeStart, retained.nativeEnd)
        assertEquals(halfSpace, actualHalf, .01f)
        val gapBox = box(wide, gapRange)
        assertEquals(halfSpace, gapBox.width(), 1.1f)
        wide.characterRects(gapRange.start, gapRange.end - gapRange.start).forEach { sameRect(gapBox, checkNotNull(it)) }
        for (offset in gapRange.start + 1 until gapRange.end) sameRect(wide.caretRect(gapRange.start), wide.caretRect(offset))
        val resolvedGap = TextPaint(wide.nativeRubyRaw.nativeRubyShapingPaint)
        val native = wide.nativeRubyRaw.nativeRubyShapingSource
        native.getSpans(retained.nativeStart, retained.nativeEnd, MetricAffectingSpan::class.java)
            .forEach { it.updateMeasureState(resolvedGap) }
        assertEquals(bodyPixels * .5f, resolvedGap.textSize, 0f)
        assertEquals(paint(.5f).fontMetrics.ascent, resolvedGap.fontMetrics.ascent, .01f)
        assertEquals(paint(.5f).fontMetrics.descent, resolvedGap.fontMetrics.descent, .01f)
        assertNull(wide.nativeRubyRaw.nativeRubyLineCursorAt(0, gapBox.centerX(), gapBox.centerY()))
        assertEquals(InlineCursor.Help, wide.cursorAt(gapBox.centerX(), gapBox.centerY()))
        val wideInk = raster(wide)
        assertTrue(wideInk.getValue(Color.GREEN).count > 0)
        assertTrue(wideInk.getValue(Color.RED).count > 0)

        val fullGap = gap.copy(fontScale = 1f)
        val fullFixture = styled(listOf(inner(fullGap)))
        val full = fullFixture.build(1200)
        val fullRange = fullFixture.range(fullGap)
        val fullPiece = full.nativeRubyCollapsedText.single { it.start == fullRange.start && it.end == fullRange.end }
        assertEquals(paint().measureText(" "), full.nativeRubyRaw.nativeRubyMeasuredAdvance(fullPiece.nativeStart, fullPiece.nativeEnd), .01f)
        assertTrue(box(full, fullRange).width() > gapBox.width())

        // With no LF in a cross-owner whitespace chain, the first body's SP is
        // the surviving separator. Its full-size paint must not become the later
        // half-size gap's paint, nor be trimmed during standalone base measuring.
        val keeperWord = leaf("word", "keeper-word", color = "#000000")
        val keeperSpace = leaf(" ", color = "#000000").copy(background = "#00ff00",
            inlineStyle = policy(false).copy(decoration = InlineUnderline(InlineUnderlineStyle.Solid,
                "#ff0000", StyleLength(StyleLengthUnit.Px, 1f))))
        val laterGap = leaf("\t", scale = .5f, color = "#000000").copy(background = "#0000ff")
        val keeperNext = leaf("next\u6f22\u5b57", "keeper-next", color = "#000000")
        val keeperSource = ruby(listOf(base(listOf(keeperWord, keeperSpace)),
            base(listOf(keeperNext), gap = listOf(laterGap))), emptyList())
        val keeperCalls = mutableListOf<Span>()
        val keeperFixture = styled(listOf(keeperSource), onAction = { keeperCalls += it })
        val keeperExpected = "word \tnext\u6f22\u5b57"
        assertEquals(keeperExpected, keeperFixture.projection.text)
        val keeperRange = keeperFixture.range(keeperSpace)
        val laterRange = keeperFixture.range(laterGap)
        val keeperWide = keeperFixture.build(1200)
        assertEquals(1, keeperWide.shapedLineCount)
        assertEquals(keeperExpected, keeperWide.text.toString())
        val keeperBox = box(keeperWide, keeperRange)
        val bodySpaceAdvance = paint().measureText(" ")
        assertEquals(bodySpaceAdvance, keeperBox.width(), 1.1f)
        assertTrue(keeperBox.width() > halfSpace + 1.1f)
        sameRect(keeperBox, checkNotNull(keeperWide.characterRects(keeperRange.start, 1).single()))
        assertTrue(keeperWide.rectsForRange(laterRange.start, laterRange.end).all { it.isEmpty })
        assertTrue(keeperWide.characterRects(laterRange.start, 1).all { it == null || it.isEmpty })
        val keeperWideInk = raster(keeperWide)
        assertTrue(keeperWideInk.getValue(Color.GREEN).count > 0)
        assertTrue(keeperWideInk.getValue(Color.RED).count > 0)
        assertEquals(0, keeperWideInk.getValue(Color.BLUE).count)
        val keeperWordAdvance = prepare(listOf(keeperWord)).build(1200).nativeSingleLineAdvance()
        val keeperWidth = ceil(keeperWordAdvance.toDouble()).toInt() + ceil((bodySpaceAdvance / 2f).toDouble()).toInt()
        val keeperNarrow = keeperFixture.build(keeperWidth)
        assertTrue(keeperNarrow.shapedLineCount > 1)
        assertEquals(keeperExpected, keeperNarrow.text.toString())
        assertTrue(keeperNarrow.rectsForRange(keeperRange.start, keeperRange.end).all { it.isEmpty })
        assertTrue(keeperNarrow.characterRects(keeperRange.start, 1).all { it == null || it.isEmpty })
        assertTrue(keeperNarrow.rectsForRange(laterRange.start, laterRange.end).all { it.isEmpty })
        assertEquals(keeperNarrow.visualLineRanges(keeperFixture.range(keeperWord).start),
            keeperNarrow.visualLineRanges(keeperRange.start))
        assertTrue(keeperNarrow.baselineForOffset(keeperFixture.range(keeperNext).start) >
            keeperNarrow.baselineForOffset(keeperFixture.range(keeperWord).start))
        val keeperNarrowInk = raster(keeperNarrow)
        for (color in listOf(Color.RED, Color.GREEN, Color.BLUE)) assertEquals(0, keeperNarrowInk.getValue(color).count)
        val keeperAgain = keeperFixture.build(1200)
        sameRect(keeperBox, box(keeperAgain, keeperRange))
        val keeperAgainInk = raster(keeperAgain)
        assertTrue(keeperAgainInk.getValue(Color.GREEN).count > 0 && keeperAgainInk.getValue(Color.RED).count > 0)
        assertEquals(0, keeperAgainInk.getValue(Color.BLUE).count)
        for (geometry in listOf(keeperWide, keeperNarrow, keeperAgain)) {
            assertEquals(keeperExpected, geometry.text.toString())
            assertSame(keeperSpace, keeperFixture.range(keeperSpace).span)
            assertSame(laterGap, keeperFixture.range(laterGap).span)
            assertActions(keeperFixture, geometry)
        }
        keeperNarrow.nodes.forEach { checkNotNull(it.onClick).invoke() }
        assertEquals(keeperFixture.actions.map { it.source }, keeperCalls)

        // Actual Bidi_Control characters are ignored by same-level whitespace
        // collapse; WORD JOINER is not. Both remain exact original public source.
        for ((controlText, retainedGap) in listOf("\u200e" to false, "\u2060" to true)) {
            val control = leaf(controlText, color = "#000000")
            val controlSource = ruby(listOf(base(listOf(keeperWord, keeperSpace, control)),
                base(listOf(keeperNext), gap = listOf(laterGap))), emptyList())
            val controlFixture = styled(listOf(controlSource))
            val controlWide = controlFixture.build(1200)
            val controlExpected = keeperWord.text + keeperSpace.text + controlText + laterGap.text + keeperNext.text
            assertEquals(controlExpected, controlFixture.projection.text)
            assertEquals(controlExpected, controlWide.text.toString())
            assertEquals(1, controlWide.shapedLineCount)
            assertSame(control, controlFixture.range(control).span)
            assertEquals(bodySpaceAdvance, box(controlWide, controlFixture.range(keeperSpace)).width(), 1.1f)
            val controlledGap = controlFixture.range(laterGap)
            val controlledInk = raster(controlWide)
            if (retainedGap) {
                val bounds = box(controlWide, controlledGap)
                assertEquals(halfSpace, bounds.width(), 1.1f)
                sameRect(bounds, checkNotNull(controlWide.characterRects(controlledGap.start, 1).single()))
                assertTrue(controlledInk.getValue(Color.BLUE).count > 0)
            } else {
                assertTrue(controlWide.rectsForRange(controlledGap.start, controlledGap.end).all { it.isEmpty })
                assertTrue(controlWide.characterRects(controlledGap.start, 1).all { it == null || it.isEmpty })
                assertEquals(0, controlledInk.getValue(Color.BLUE).count)
            }
            assertTrue(controlledInk.getValue(Color.GREEN).count > 0 && controlledInk.getValue(Color.RED).count > 0)
            assertActions(controlFixture, controlWide)
        }

        val firstAdvance = prepare(listOf(first)).build(1200).nativeSingleLineAdvance()
        val width = ceil(firstAdvance.toDouble()).toInt() + ceil((halfSpace / 2f).toDouble()).toInt()
        val narrow = fixture.build(width)
        assertTrue(narrow.shapedLineCount > 1)
        assertEquals(expected, narrow.text.toString())
        val trimmed = narrow.nativeRubyCollapsedText.single { it.start == gapRange.start && it.end == gapRange.end }
        assertTrue(trimmed.trimmed)
        assertTrue(trimmed.nativeEnd > trimmed.nativeStart) // Private shaping separator remains.
        assertEquals(0f, narrow.nativeRubyRaw.nativeRubyMeasuredAdvance(trimmed.nativeStart, trimmed.nativeEnd), 0f)
        assertTrue(narrow.characterRects(gapRange.start, gapRange.end - gapRange.start).all { it == null || it.isEmpty })
        val gapLine = (0 until narrow.shapedLineCount).single { line ->
            narrow.nativeRubyLineRanges(line).any { gapRange.start in it.first until it.second }
        }
        assertTrue(narrow.nativeRubyLineRanges(gapLine).any { it.first <= gapRange.start && it.second >= gapRange.end })
        assertEquals(narrow.nativeRubyRaw.nativeLineAt(trimmed.nativeStart), gapLine)
        for (offset in gapRange.start until gapRange.end)
            assertEquals(narrow.nativeRubyLineRanges(gapLine), narrow.visualLineRanges(offset))
        assertEquals(ceil(firstAdvance.toDouble()).toFloat(), narrow.nativeRubyRaw.nativeLineAdvance(0), .01f)
        val firstRect = checkNotNull(narrow.characterRects(fixture.range(first).start, 1).single())
        val nextRect = checkNotNull(narrow.characterRects(fixture.range(next).start, 1).single())
        assertEquals(firstRect.left, nextRect.left, .01f)
        assertTrue(narrow.baselineForOffset(fixture.range(next).start) > narrow.baselineForOffset(fixture.range(first).start))
        val narrowInk = raster(narrow)
        assertEquals(0, narrowInk.getValue(Color.GREEN).count)
        assertEquals(0, narrowInk.getValue(Color.RED).count)
        val recovered = fixture.build(1200)
        sameRect(gapBox, box(recovered, gapRange))
        assertEquals(InlineCursor.Help, recovered.cursorAt(gapBox.centerX(), gapBox.centerY()))
        for (geometry in listOf(wide, narrow, recovered)) assertActions(fixture, geometry)
        narrow.nodes.forEach { checkNotNull(it.onClick).invoke() }
        assertEquals(fixture.actions.map { it.source }, calls)

        // This actual parent allocation enters the hierarchical spacing helper;
        // the declaring gap-owner cursor must survive its inverse translation.
        val longReading = leaf("\u3042\u3044\u3046\u3048\u304a\u304b\u304d\u304f\u3051\u3053\u3055\u3057".repeat(3),
            "gap-outer-reading", .5f, "#000000")
        val expandedFixture = styled(listOf(ruby(listOf(base(listOf(source))), listOf(reading(listOf(longReading))))))
        val expanded = expandedFixture.build(1200)
        val expandedGap = box(expanded, expandedFixture.range(gap))
        assertEquals(gapBox.width(), expandedGap.width(), .01f)
        assertEquals(InlineCursor.Help, expanded.cursorAt(expandedGap.centerX(), expandedGap.centerY()))
        assertActions(expandedFixture, expanded)
        val expandedInk = raster(expanded)
        assertTrue(expandedInk.getValue(Color.GREEN).count > 0 && expandedInk.getValue(Color.RED).count > 0)

        // A retained, zero-font separator still owns source affinity and blocks
        // justification across that gap; it never acquires a fabricated hit area.
        val zeroGap = gap.copy(fontScale = 0f)
        for (rtl in listOf(false, true)) {
            val direction = if (rtl) "rtl" else "ltr"
            val zeroInner = inner(zeroGap).copy(direction = direction)
            val zeroPlainFixture = styled(listOf(zeroInner), rtl = rtl)
            val zeroPlain = zeroPlainFixture.build(1200)
            val zeroPlainRange = zeroPlainFixture.range(zeroGap)
            val zeroPiece = zeroPlain.nativeRubyCollapsedText.single {
            it.start == zeroPlainRange.start && it.end == zeroPlainRange.end
            }
            assertFalse(zeroPiece.trimmed)
            assertTrue(zeroPiece.nativeEnd > zeroPiece.nativeStart)
            assertEquals(0f, zeroPlain.nativeRubyRaw.nativeRubyMeasuredAdvance(zeroPiece.nativeStart, zeroPiece.nativeEnd), 0f)
            val zeroOuter = ruby(listOf(base(listOf(zeroInner))), listOf(reading(listOf(longReading)))).copy(direction = direction)
            val zeroExpandedFixture = styled(listOf(zeroOuter), rtl = rtl)
            val zeroExpanded = zeroExpandedFixture.build(1200)
            val zeroRange = zeroExpandedFixture.range(zeroGap)
            assertEquals(zeroExpandedFixture.projection.text, zeroExpanded.text.toString())
            assertTrue(zeroExpanded.rectsForRange(zeroRange.start, zeroRange.end).all { it.isEmpty })
            assertTrue(zeroExpanded.characterRects(zeroRange.start, zeroRange.end - zeroRange.start).all { it == null || it.isEmpty })
            val zeroInk = raster(zeroExpanded)
            assertEquals(0, zeroInk.getValue(Color.GREEN).count)
            assertEquals(0, zeroInk.getValue(Color.RED).count)
            assertActions(zeroExpandedFixture, zeroExpanded)
        }

        // Same-level annotations can be separate columns on one actual row. Their
        // gap is retained there, then trimmed only when the second column wraps.
        val componentA = leaf("\u6f22", "component-a")
        val componentB = leaf("\u5b57", "component-b")
        val readingA = leaf("one", "component-reading-a", .5f)
        val readingB = leaf("two", "component-reading-b", .5f)
        val annotationOwner = context(.5f).copy(inlineStyle = policy(false).copy(cursor = InlineCursor.Help))
        val componentsSource = ruby(listOf(base(listOf(componentA)), base(listOf(componentB))),
            listOf(reading(listOf(readingA), owner = annotationOwner),
                reading(listOf(readingB), start = 1, owner = annotationOwner, gap = listOf(gap))))
        val componentCalls = mutableListOf<Span>()
        val components = styled(listOf(componentsSource), onAction = { componentCalls += it })
        val componentExpected = componentA.text + componentB.text + readingA.text + gap.text + readingB.text
        val componentGap = components.range(gap)
        val componentsWide = components.build(1200)
        assertEquals(1, componentsWide.shapedLineCount)
        assertEquals(componentExpected, componentsWide.text.toString())
        val componentBox = box(componentsWide, componentGap)
        assertEquals(halfSpace, componentBox.width(), 1.1f)
        assertNull(componentsWide.cursorAt(componentBox.centerX(), componentBox.centerY()))
        val declaredReadingBox = box(componentsWide, components.range(readingB))
        assertEquals(InlineCursor.Help, componentsWide.cursorAt(declaredReadingBox.centerX(), declaredReadingBox.centerY()))
        val componentWidth = ceil(maxOf(prepare(listOf(componentA)).build(1200).nativeSingleLineAdvance(),
            prepare(listOf(readingB)).build(1200).nativeSingleLineAdvance() + halfSpace).toDouble()).toInt()
        val componentsNarrow = components.build(componentWidth)
        assertEquals(2, componentsNarrow.shapedLineCount)
        assertEquals(componentExpected, componentsNarrow.text.toString())
        val firstReadingLine = componentsNarrow.nativeRubyRaw.nativeLineAt(
            componentsNarrow.nativeRubyRawOffset(components.range(readingA).start))
        val secondReadingLine = componentsNarrow.nativeRubyRaw.nativeLineAt(
            componentsNarrow.nativeRubyRawOffset(components.range(readingB).start))
        assertTrue(secondReadingLine > firstReadingLine)
        val actualComponentGapLine = componentsNarrow.nativeRubyRaw.nativeLineAt(
            componentsNarrow.nativeRubyRawOffset(componentGap.start))
        assertEquals(secondReadingLine, actualComponentGapLine)
        for (offset in componentGap.start until componentGap.end)
            assertEquals(componentsNarrow.nativeRubyLineRanges(actualComponentGapLine), componentsNarrow.visualLineRanges(offset))
        assertTrue(componentsNarrow.rectsForRange(componentGap.start, componentGap.end).all { it.isEmpty })
        assertTrue(componentsNarrow.characterRects(componentGap.start, componentGap.end - componentGap.start).all { it == null || it.isEmpty })
        val componentsNarrowInk = raster(componentsNarrow)
        assertEquals(0, componentsNarrowInk.getValue(Color.GREEN).count)
        assertEquals(0, componentsNarrowInk.getValue(Color.RED).count)
        val componentsAgain = components.build(1200)
        sameRect(componentBox, box(componentsAgain, componentGap))
        assertNull(componentsAgain.cursorAt(componentBox.centerX(), componentBox.centerY()))
        val recoveredReadingBox = box(componentsAgain, components.range(readingB))
        assertEquals(InlineCursor.Help, componentsAgain.cursorAt(recoveredReadingBox.centerX(), recoveredReadingBox.centerY()))
        for (geometry in listOf(componentsWide, componentsNarrow, componentsAgain)) assertActions(components, geometry)
        componentsNarrow.nodes.forEach { checkNotNull(it.onClick).invoke() }
        assertEquals(components.actions.map { it.source }, componentCalls)

        // A stored but graphically hidden previous annotation is a real barrier;
        // the raw gap stays in source while contributing no glyph, box or paint.
        val hidden = leaf("A", "hidden-reading", .5f)
        val visible = leaf("bee", "visible-reading", .5f)
        val barrierSource = ruby(listOf(base(listOf(leaf("A"))), base(listOf(leaf("B")))),
            listOf(reading(listOf(hidden)), reading(listOf(visible), start = 1, gap = listOf(gap))))
        val barrierFixture = styled(listOf(barrierSource))
        assertSame(hidden, checkNotNull(barrierSource.ruby).segments.single().annotations.first().spans.single())
        assertFalse(barrierFixture.projection.ranges.any { it.span === hidden })
        assertEquals("AB" + gap.text + visible.text, barrierFixture.projection.text)
        val barrier = barrierFixture.build(1200)
        val barrierGap = barrierFixture.range(gap)
        assertEquals(barrierFixture.projection.text, barrier.text.toString())
        assertTrue(barrier.rectsForRange(barrierGap.start, barrierGap.end).isEmpty())
        assertTrue(barrier.characterRects(barrierGap.start, barrierGap.end - barrierGap.start).all { it == null || it.isEmpty })
        assertTrue(barrier.caretRect(barrierGap.start).isEmpty)
        val barrierInk = raster(barrier)
        assertEquals(0, barrierInk.getValue(Color.GREEN).count)
        assertEquals(0, barrierInk.getValue(Color.RED).count)
        assertActions(barrierFixture, barrier)
    }

    @Test fun rubyBreakWordRetriesOnlyAfterOrdinaryJointOverflowAndKeepsIntrinsicWidths() {
        fun authored(span: Span, wrap: TextWrap?) = span.copy(inlineStyle = checkNotNull(span.inlineStyle).copy(wrap = wrap))
        fun declaring(scale: Float, wrap: TextWrap?) = context(scale).copy(inlineStyle = policy(false).copy(wrap = wrap))
        fun wrapped(spans: List<Span>, onAction: (Span) -> Unit = {}): Fixture {
            val original = prepare(spans, onAction = onAction)
            val retained = original.source.getSpans(0, original.source.length, NativeRubyPreparedSource::class.java).single()
            val logical = SpannableString(retained.source)
            retained.projection.ranges.filter { it.span != null && it.role != RubyTextRole.Owner && it.start < it.end }
                .forEach { range -> checkNotNull(range.span).inlineStyle?.wrap?.let {
                    logical.setSpan(NativeAuthoredTextWrap(it), range.start, range.end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                } }
            val groups = retained.groups.mapValues { (path, format) ->
                val range = retained.projection.ranges.single { it.path == path }
                val style = when (range.role) {
                    RubyTextRole.Owner -> checkNotNull(range.span).inlineStyle
                    RubyTextRole.Base -> checkNotNull(range.base).owner.inlineStyle
                    RubyTextRole.Annotation -> checkNotNull(range.annotation).owner.inlineStyle
                    else -> error("Not a declaring group")
                }
                NativeRubyGroupFormat(format.paint, format.direction, format.lineHeight, format.baselineShift,
                    wrap = style?.wrap, underline = format.underline, cursor = format.cursor,
                    sourceDirection = format.sourceDirection, localBaselineShift = format.localBaselineShift)
            }
            val prepared = NativeRubyPreparedSource(retained.projection, SpannedString(logical), retained.paint,
                retained.direction, groups, parentScript = retained.parentScript)
            val value = SpannableString(logical).apply { setSpan(prepared, 0, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE) }
            return Fixture(original.spans, SpannedString(value), original.projection, original.body, original.actions, original.rtl)
        }
        data class Case(val fixture: Fixture, val base: Span, val reading: Span)
        fun single(baseWrap: TextWrap?, readingWrap: TextWrap?, parallel: TextWrap? = null,
            emptyParallel: Boolean = false, onAction: (Span) -> Unit = {}): Case {
            val body = authored(leaf("abcdefghijklmnop", "break-base"), baseWrap)
            val label = authored(leaf("abcdefghijklmnopqrstuvwx", "break-reading", .5f, "#ff0000"), readingWrap)
            val readings = mutableListOf(reading(listOf(label), owner = declaring(.5f, readingWrap)))
            if (parallel != null || emptyParallel) readings += reading(
                if (emptyParallel) emptyList() else listOf(authored(leaf("parallelunbreakable", "parallel-track", .5f), parallel)),
                level = 1, owner = declaring(.5f, parallel))
            return Case(wrapped(listOf(ruby(listOf(base(listOf(body), owner = declaring(1f, baseWrap))), readings)), onAction), body, label)
        }
        fun widths(fixture: Fixture, legacy: Boolean = false) = nativeTextWidthRange(fixture.source, fixture.body,
            breakWordMinimum = legacy, textDirection = TextDirectionHeuristics.LTR)
        fun rows(geometry: NativeFloatGeometry) = (0 until geometry.shapedLineCount).map(geometry::nativeRubyLineRanges)
        fun covered(fixture: Fixture, geometry: NativeFloatGeometry) {
            assertEquals(fixture.projection.text, geometry.text.toString())
            val coverage = IntArray(geometry.text.length)
            rows(geometry).forEach { fragments ->
                assertTrue(fragments.isNotEmpty())
                fragments.forEach { (start, end) ->
                    assertEquals(fragments, geometry.visualLineRanges(start))
                    for (offset in start until end) coverage[offset]++
                }
            }
            assertTrue(coverage.all { it == 1 })
            assertActions(fixture, geometry)
        }
        val defaults = single(null, null)
        val normal = single(TextWrap.Normal, TextWrap.Normal)
        val calls = mutableListOf<Span>()
        val emergency = single(TextWrap.BreakWord, TextWrap.BreakWord, onAction = { calls += it })
        val width = ceil(paint().measureText("abcd").toDouble()).toInt()
        val normalWidths = widths(normal.fixture)
        assertTrue(normalWidths.minimum > width)
        for (fixture in listOf(defaults.fixture, emergency.fixture)) {
            assertEquals(normalWidths.minimum, widths(fixture).minimum)
            assertEquals(normalWidths.maximum, widths(fixture).maximum)
        }
        assertEquals(normalWidths.minimum, widths(emergency.fixture, legacy = true).minimum)
        assertEquals(normalWidths.maximum, widths(emergency.fixture, legacy = true).maximum)
        val ordinaryNarrow = normal.fixture.build(width)
        val defaultNarrow = defaults.fixture.build(width)
        assertEquals(1, ordinaryNarrow.shapedLineCount)
        assertEquals(rows(ordinaryNarrow), rows(defaultNarrow))
        assertTrue(ordinaryNarrow.nativeSingleLineAdvance() > width)
        val broken = emergency.fixture.build(width)
        assertTrue(broken.shapedLineCount > 1)
        val baseRange = emergency.fixture.range(emergency.base)
        val readingRange = emergency.fixture.range(emergency.reading)
        rows(broken).forEach { fragments ->
            assertTrue(fragments.any { it.first < baseRange.end && it.second > baseRange.start })
            assertTrue(fragments.any { it.first < readingRange.end && it.second > readingRange.start })
        }
        // These independent same-source native paragraphs witness actual endpoint
        // stops; no ratio or UTF-16 enumeration supplies Ruby's emergency cuts.
        for ((span, range) in listOf(emergency.base to baseRange, emergency.reading to readingRange)) {
            val plain = wrapped(listOf(span)).build(0)
            val ends = rows(plain).flatten().map { it.second }.toSet()
            rows(broken).flatten().forEach { (start, end) ->
                val selectedEnd = minOf(end, range.end)
                if (start < range.end && end > range.start && selectedEnd < range.end)
                    assertTrue(selectedEnd - range.start in ends)
            }
        }
        for (geometry in listOf(ordinaryNarrow, defaultNarrow))
            assertEquals(normal.fixture.projection.text, geometry.text.toString())
        covered(normal.fixture, ordinaryNarrow); covered(defaults.fixture, defaultNarrow)
        val wide = emergency.fixture.build(1000)
        assertEquals(1, wide.shapedLineCount)
        val narrowAgain = emergency.fixture.build(width)
        assertEquals(rows(broken), rows(narrowAgain))
        for (geometry in listOf(wide, broken, narrowAgain)) covered(emergency.fixture, geometry)
        wide.nodes.zip(broken.nodes).forEach { (a, b) -> assertEquals(a.id, b.id); assertSame(a.onClick, b.onClick) }
        broken.nodes.forEach { checkNotNull(it.onClick).invoke() }
        assertEquals(emergency.fixture.actions.map { it.source }, calls)
        val ink = raster(broken)
        assertTrue(ink.getValue(Color.BLUE).count > 0 && ink.getValue(Color.RED).count > 0)

        // There is a jointly fitting ordinary space cut. Emergency packing could
        // fit more letters, but must not replace that first-stage native cut.
        val spacedBody = authored(leaf("ab cdefghijklmnop", "ordinary-base"), TextWrap.BreakWord)
        val spacedReading = authored(leaf("xy zabcdefghijklmnop", "ordinary-reading", .5f), TextWrap.BreakWord)
        val spaced = wrapped(listOf(ruby(listOf(base(listOf(spacedBody), owner = declaring(1f, TextWrap.BreakWord))),
            listOf(reading(listOf(spacedReading), owner = declaring(.5f, TextWrap.BreakWord))))))
        val prefix = maxOf(paint().measureText("ab "), paint(.5f).measureText("xy "))
        val ordinaryWidth = ceil((prefix + paint().measureText("cd")).toDouble()).toInt()
        assertTrue(ordinaryWidth > prefix + paint().measureText("c"))
        val staged = spaced.build(ordinaryWidth)
        assertTrue(staged.shapedLineCount > 1)
        val firstRow = staged.nativeRubyLineRanges(0)
        for (span in listOf(spacedBody, spacedReading)) {
            val range = spaced.range(span)
            val last = firstRow.filter { it.first < range.end && it.second > range.start }.maxOf { minOf(it.second, range.end) }
            assertEquals(range.start + 3, last)
        }
        covered(spaced, staged)

        // Every parallel association participates: an authored Normal reading or
        // a real visible-empty reading blocks an invented emergency continuation.
        val normalTrack = single(TextWrap.BreakWord, TextWrap.BreakWord, parallel = TextWrap.Normal)
        val emptyTrack = single(TextWrap.BreakWord, TextWrap.BreakWord,
            parallel = TextWrap.BreakWord, emptyParallel = true)
        for (blocked in listOf(normalTrack, emptyTrack)) {
            val geometry = blocked.fixture.build(width)
            assertEquals(1, geometry.shapedLineCount)
            assertTrue(geometry.nativeSingleLineAdvance() > width)
            covered(blocked.fixture, geometry)
            assertEquals(1, blocked.fixture.build(1000).shapedLineCount)
        }

        // Independently declared Latin boxes have no ordinary between-base cut.
        // Only both real neighboring edge policies may authorize that boundary;
        // each associated Normal reading must finish with its own intact box.
        data class Boxes(val fixture: Fixture, val bodies: List<Span>, val labels: List<Span>, val standalone: List<Fixture>)
        fun boxes(leftWrap: TextWrap?, rightWrap: TextWrap?, onAction: (Span) -> Unit = {}): Boxes {
            val policies = listOf(leftWrap, rightWrap)
            val bodies = listOf("abcdefgh", "ijklmnop").mapIndexed { index, text ->
                authored(leaf(text, "box-base-$index"), policies[index])
            }
            val labels = listOf("first", "second").mapIndexed { index, text ->
                authored(leaf(text, "box-reading-$index", .5f, "#ff0000"), TextWrap.Normal)
            }
            val bases = bodies.mapIndexed { index, span -> base(listOf(span), owner = declaring(1f, policies[index])) }
            val annotations = labels.mapIndexed { index, span ->
                reading(listOf(span), start = index.toLong(), owner = declaring(.5f, TextWrap.Normal))
            }
            val standalone = bases.indices.map { index -> wrapped(listOf(ruby(listOf(bases[index]),
                listOf(reading(listOf(labels[index]), owner = declaring(.5f, TextWrap.Normal)))))) }
            return Boxes(wrapped(listOf(ruby(bases, annotations)), onAction), bodies, labels, standalone)
        }
        val boxCalls = mutableListOf<Span>()
        val permitted = boxes(TextWrap.BreakWord, TextWrap.BreakWord, onAction = { boxCalls += it })
        val originalBoxes = permitted.standalone.map { it.build(1000) }
        assertTrue(originalBoxes.all { it.shapedLineCount == 1 })
        val boxWidth = ceil(originalBoxes.maxOf { it.nativeSingleLineAdvance() }.toDouble()).toInt()
        val boxesWide = permitted.fixture.build(1000)
        assertEquals(1, boxesWide.shapedLineCount)
        assertTrue(boxesWide.nativeSingleLineAdvance() > boxWidth)
        val boxesNarrow = permitted.fixture.build(boxWidth)
        assertEquals(2, boxesNarrow.shapedLineCount)
        for (index in permitted.bodies.indices) {
            val actualRow = boxesNarrow.nativeRubyLineRanges(index)
            val bodyRange = permitted.fixture.range(permitted.bodies[index])
            val labelRange = permitted.fixture.range(permitted.labels[index])
            val expectedOffsets = (bodyRange.start until bodyRange.end).toList() + (labelRange.start until labelRange.end).toList()
            assertEquals(expectedOffsets, actualRow.flatMap { (start, end) -> (start until end).toList() })
            val independent = originalBoxes[index]
            val independentFixture = permitted.standalone[index]
            for (span in listOf(permitted.bodies[index], permitted.labels[index])) {
                val expectedRange = independentFixture.range(span)
                val actualRange = permitted.fixture.range(span)
                val expectedBox = box(independent, expectedRange)
                val actualBox = box(boxesNarrow, actualRange)
                assertEquals(expectedBox.width(), actualBox.width(), .01f)
                assertEquals(expectedBox.height(), actualBox.height(), .01f)
                for (offset in span.text.indices) {
                    val expectedCharacter = checkNotNull(independent.characterRects(expectedRange.start + offset, 1).single())
                    val actualCharacter = checkNotNull(boxesNarrow.characterRects(actualRange.start + offset, 1).single())
                    assertEquals(expectedCharacter.left - expectedBox.left, actualCharacter.left - actualBox.left, .01f)
                    assertEquals(expectedCharacter.width(), actualCharacter.width(), .01f)
                }
            }
            assertEquals(independent.baselineForOffset(independentFixture.range(permitted.labels[index]).start) -
                independent.baselineForOffset(independentFixture.range(permitted.bodies[index]).start),
                boxesNarrow.baselineForOffset(labelRange.start) - boxesNarrow.baselineForOffset(bodyRange.start), .01f)
        }
        val boxesAgain = permitted.fixture.build(1000)
        for (geometry in listOf(boxesWide, boxesNarrow, boxesAgain)) covered(permitted.fixture, geometry)
        for (span in permitted.bodies + permitted.labels)
            sameRect(box(boxesWide, permitted.fixture.range(span)), box(boxesAgain, permitted.fixture.range(span)))
        boxesWide.nodes.zip(boxesNarrow.nodes).forEach { (a, b) -> assertEquals(a.id, b.id); assertSame(a.onClick, b.onClick) }
        boxesNarrow.nodes.forEach { checkNotNull(it.onClick).invoke() }
        assertEquals(permitted.fixture.actions.map { it.source }, boxCalls)
        for (blockedPolicy in listOf<TextWrap?>(TextWrap.Normal, null)) for (side in listOf(0, 1)) {
            val denied = boxes(if (side == 0) blockedPolicy else TextWrap.BreakWord,
                if (side == 1) blockedPolicy else TextWrap.BreakWord)
            assertEquals(permitted.fixture.projection.text, denied.fixture.projection.text)
            val intact = denied.fixture.build(boxWidth)
            assertEquals(1, intact.shapedLineCount)
            assertTrue(intact.nativeSingleLineAdvance() > boxWidth)
            covered(denied.fixture, intact)
            assertEquals(widths(permitted.fixture).minimum, widths(denied.fixture).minimum)
            assertEquals(widths(permitted.fixture).maximum, widths(denied.fixture).maximum)
        }
        // Per-base model NoWrap is not admitted. The sixth control carries the
        // actual complete inherited-NoWrap context without inventing that field.

        // A Normal URL elsewhere in the same full child source must not be fitted
        // at zero width merely to discover another word's emergency endpoints.
        fun urlCase(wordWrap: TextWrap): Fixture {
            val url = authored(leaf("https://example.test/AAAA", "normal-url"), TextWrap.Normal)
            val word = authored(leaf("abcdefghijklmnop", "separate-word"), wordWrap)
            val label = authored(leaf("pronunciation", "url-reading", .5f), TextWrap.BreakWord)
            return wrapped(listOf(ruby(listOf(base(listOf(url, leaf(" "), word))),
                listOf(reading(listOf(label), owner = declaring(.5f, TextWrap.BreakWord))))))
        }
        val mixed = urlCase(TextWrap.BreakWord)
        val reference = urlCase(TextWrap.Normal)
        assertEquals(widths(reference).minimum, widths(mixed).minimum)
        assertEquals(widths(reference).maximum, widths(mixed).maximum)
        assertEquals(widths(mixed).minimum, widths(mixed, legacy = true).minimum)
        val fitted = mixed.build(1000)
        assertEquals(1, fitted.shapedLineCount)
        assertEquals(reference.build(1000).nativeSingleLineAdvance(), fitted.nativeSingleLineAdvance(), .01f)
        covered(mixed, fitted)
    }

    @Test fun emptyRubyAndMetricOwnersKeepTheirUsedBandThroughBoxColumnsAndAnonymousFlow() {
        val usedHeight = 48f
        val root = paint()
        val primary = NativePrimaryFontMetrics.from(root)
        val zero = NativeLineHeightPolicy.Pixels(0f)
        val positive = NativeLineHeightPolicy.Pixels(usedHeight)
        val originalBase = base(emptyList(), owner = context().copy(inlineStyle = policy(false).copy(
            lineHeight = InlineLineHeight.Computed(InlineComputedLength(usedHeight, FontScaleBasis.CssPx)))))
        val originalRuby = ruby(listOf(originalBase), emptyList(), zero = true)
        val originalSpans = listOf(originalRuby)
        val projection = rubyGraphicalProjection(originalSpans)
        assertEquals("", projection.text)
        val ownerRange = projection.ranges.single { it.role == RubyTextRole.Owner }
        val baseRange = projection.ranges.single { it.role == RubyTextRole.Base }
        assertSame(originalRuby, ownerRange.span)
        assertSame(originalBase, baseRange.base)
        assertTrue(projection.ranges.none { it.role == RubyTextRole.Annotation })
        assertTrue(projection.ranges.all { it.start == 0 && it.end == 0 })
        val groups = mapOf(
            ownerRange.path to NativeRubyGroupFormat(root, TextDirectionHeuristics.LTR, zero,
                sourceDirection = "ltr"),
            baseRange.path to NativeRubyGroupFormat(root, TextDirectionHeuristics.LTR, positive,
                sourceDirection = "ltr"))
        // The ordinary all-empty source has no synthetic root metric span. Its real
        // Ruby marker is a point; native replacement measurement rounds the declared
        // base box, independently of the exact authored height retained by the column.
        val midpoint = (primary.ascent + primary.descent) / 2f
        val declaredTop = midpoint - usedHeight / 2f
        val declaredBottom = midpoint + usedHeight / 2f
        val roundedTop = kotlin.math.floor(declaredTop.toDouble()).toFloat()
        val roundedBottom = ceil(declaredBottom.toDouble()).toFloat()
        val nativeFont = root.fontMetricsInt
        // The independently resolved parent font fits inside this source's 48px box,
        // so include-font-padding cannot add a larger outer band in either route.
        assertTrue(roundedTop <= nativeFont.top && roundedBottom >= nativeFont.bottom)
        val rubyHeight = roundedBottom - roundedTop
        val raw = SpannableString("")
        val prepared = NativeRubyPreparedSource(projection, SpannedString(raw), root,
            TextDirectionHeuristics.LTR, groups)
        val rubySource = SpannedString(SpannableString(raw).apply {
            setSpan(prepared, 0, 0, Spanned.SPAN_MARK_MARK)
        })
        val point = NativeAuthoredInlineMetrics(primary, positive)
        val metricSource = SpannedString(SpannableString("").apply {
            setSpan(point, 0, 0, Spanned.SPAN_MARK_MARK)
        })
        val plainSource = SpannedString("")
        assertFalse(hasNativeAuthoredInlineMetrics(rubySource))
        assertTrue(hasNativeInlineLayoutOwner(rubySource))
        assertTrue(hasNativeAuthoredInlineMetrics(metricSource))
        assertTrue(hasNativeInlineLayoutOwner(metricSource))
        assertFalse(hasNativeInlineLayoutOwner(plainSource))
        assertSame(prepared, rubySource.getSpans(0, 0, NativeRubyPreparedSource::class.java).single())
        assertSame(point, metricSource.getSpans(0, 0, NativeAuthoredInlineMetrics::class.java).single())
        fun shape(source: Spanned, width: Int = 160, exclusions: List<NativeFloatExclusion> = emptyList()) =
            NativeFloatGeometry.build(source, root, width, emptyList(),
                textDirection = TextDirectionHeuristics.LTR, carriedExclusions = exclusions)
        fun emptyPublicGeometry(geometry: FloatTextGeometry) {
            assertEquals("", geometry.text.toString())
            assertTrue(geometry.nodes.isEmpty())
            assertTrue(geometry.rectsForRange(0, 0).isEmpty())
            assertTrue(geometry.characterRects(0, 0).isEmpty())
        }
        val emptyBox = ParagraphBox(ParagraphEdges(), ParagraphEdges(), 0f, 0f)
        for (source in listOf(rubySource, metricSource)) {
            val expectedHeight = if (source === rubySource) rubyHeight else usedHeight
            val direct = shape(source)
            if (source === rubySource) {
                val declared = direct.nativeRubyColumns.single().column.base
                assertEquals(usedHeight, declared.height, .001f)
                assertEquals(declaredTop, declared.top, .001f)
                assertEquals(declaredBottom, declared.bottom, .001f)
                assertEquals(-roundedTop, checkNotNull(direct.textBaselines).first!!, 0f)
            }
            emptyPublicGeometry(direct)
            assertEquals(1, direct.shapedLineCount)
            assertEquals(expectedHeight, direct.nativeUsedLineMetrics(0).height, .001f)
            assertEquals(expectedHeight, direct.usedLineHeight(0), .001f)
            assertEquals(expectedHeight, direct.textBottom, .001f)
            assertNotNull(direct.textBaselines)
            var builds = 0
            val part = NativeFloatContextPart.Text(source, { width, exclusions ->
                builds++
                shape(source, width, exclusions)
            }, box = emptyBox)
            assertSame(source, part.text)
            assertFalse(checkNotNull(NativeFloatContextGeometry.adjoiningProfile(part)).through)
            for (adjoining in listOf(false, true)) {
                val context = NativeFloatContextGeometry.build(160, listOf(part), adjoining = adjoining)
                emptyPublicGeometry(context)
                assertEquals(expectedHeight, context.usedHeight, .001f)
                assertEquals(expectedHeight, context.textBottom, .001f)
                assertEquals(direct.textBaselines, context.textBaselines)
                val child = context.inputLeaves().single()
                assertEquals(0, child.sourceIndex)
                assertEquals(0, child.offset)
                emptyPublicGeometry(child.geometry)
                assertEquals(expectedHeight, child.geometry.extents.usedHeight, .001f)
            }
            val parts = listOf(part)
            val columns = NativeFloatContextGeometry.buildPreparedColumns(320, 320f, parts,
                NativeColumnPolicy(2, 0f, rtl = true), NativeOrdinaryPreparation(parts))
            emptyPublicGeometry(columns)
            assertEquals(expectedHeight, columns.usedHeight, .001f)
            assertEquals(expectedHeight, columns.textBottom, .001f)
            assertEquals(direct.textBaselines, columns.textBaselines)
            val columnChild = columns.inputLeaves().single()
            assertEquals(0, columnChild.sourceIndex)
            assertEquals(0, columnChild.offset)
            emptyPublicGeometry(columnChild.geometry)
            assertEquals(expectedHeight, columnChild.geometry.extents.usedHeight, .001f)
            assertEquals(3, builds)
        }
        // Plain empty boxes still skip shaping; no invented default strut is admitted.
        var plainBuilds = 0
        val plain = NativeFloatContextPart.Text(plainSource, { width, exclusions ->
            plainBuilds++
            shape(plainSource, width, exclusions)
        }, box = emptyBox)
        assertTrue(checkNotNull(NativeFloatContextGeometry.adjoiningProfile(plain)).through)
        for (adjoining in listOf(false, true)) {
            val context = NativeFloatContextGeometry.build(160, listOf(plain), adjoining = adjoining)
            emptyPublicGeometry(context)
            assertEquals(0f, context.usedHeight, 0f)
            assertTrue(context.inputLeaves().isEmpty())
        }
        val plainParts = listOf(plain)
        val plainColumns = NativeFloatContextGeometry.buildPreparedColumns(320, 320f, plainParts,
            NativeColumnPolicy(2, 0f, rtl = false), NativeOrdinaryPreparation(plainParts))
        emptyPublicGeometry(plainColumns)
        assertEquals(0f, plainColumns.usedHeight, 0f)
        assertTrue(plainColumns.inputLeaves().isEmpty())
        assertEquals(0, plainBuilds)

        // Anonymous flow must copy the real zero-length owner marker before native
        // shaping. Its source stream has no figure or generated strut character.
        val anonymousContext = AnonymousFlowContext(BidiResolvedDirection.Ltr, "ja", null)
        val rubyContent = anonymousFlowContent(Block("paragraph", 0, originalSpans), anonymousContext)
        val metricContent = anonymousFlowContent(Block("paragraph", 0, emptyList()), anonymousContext)
        for ((content, source) in listOf(rubyContent to rubySource, metricContent to metricSource)) {
            val event = content.events.single() as AnonymousFlowEvent.Inline
            if (content === rubyContent) assertSame(originalRuby, event.spans.single())
            val anonymous = NativeAnonymousFlowGeometry.build(content, root, 160,
                inline = { actual -> assertSame(event, actual); source },
                figure = { _, _ -> error("This source has no Figure") },
                inlineSemantic = { actual, text -> anonymousInlineSemantic(actual.spans, text) })
            emptyPublicGeometry(anonymous)
            assertEquals("", anonymous.offsets.nativeText)
            assertEquals("", anonymous.offsets.logicalText)
            assertSame(event, anonymous.offsets.inlineSources.single().event)
            assertTrue(anonymous.figures.isEmpty())
            assertEquals(if (source === rubySource) rubyHeight else usedHeight, anonymous.textBottom, .001f)
            assertEquals(shape(source).textBaselines, anonymous.textBaselines)
        }
        // Two copies of the same empty styled owner surround a real authored BR.
        // Each must supply its own row; losing either marker changes that row to the
        // smaller ordinary parent-font band. Public source remains exactly one LF.
        val lineBreak = Span("line_break", "")
        val emptyRepeatContent = anonymousFlowContent(Block("paragraph", 0, emptyList(), flow = listOf(
            FlowPart.Inline(originalSpans), FlowPart.Inline(listOf(lineBreak)),
            FlowPart.Inline(originalSpans))), anonymousContext)
        var emptyCalls = 0
        val emptyTwice = NativeAnonymousFlowGeometry.build(emptyRepeatContent, root, 160,
            inline = { event ->
                val span = event.spans.single()
                if (span === lineBreak) SpannedString("\n") else {
                    assertSame(originalRuby, span)
                    emptyCalls++
                    rubySource
                }
            }, figure = { _, _ -> error("This source has no Figure") },
            inlineSemantic = { event, text -> anonymousInlineSemantic(event.spans, text) })
        assertEquals(2, emptyCalls)
        assertEquals("\n", emptyTwice.text.toString())
        assertEquals("\n", emptyTwice.offsets.nativeText)
        assertEquals("\n", emptyTwice.offsets.logicalText)
        assertEquals(listOf(0 to 0, 0 to 1, 1 to 1),
            emptyTwice.offsets.inlineSources.map { it.start to it.end })
        assertSame(originalRuby, emptyTwice.offsets.inlineSources.first().event.spans.single())
        assertSame(lineBreak, emptyTwice.offsets.inlineSources[1].event.spans.single())
        assertSame(originalRuby, emptyTwice.offsets.inlineSources.last().event.spans.single())
        assertEquals(2f * rubyHeight, emptyTwice.textBottom, 0f)
        val emptyBaselines = checkNotNull(emptyTwice.textBaselines)
        assertEquals(-roundedTop, checkNotNull(emptyBaselines.first), 0f)
        assertEquals(rubyHeight - roundedTop, checkNotNull(emptyBaselines.last), 0f)
        assertTrue(emptyTwice.nodes.isEmpty())
        assertTrue(emptyTwice.figures.isEmpty())

        // A reusable styled callback is still two source occurrences. Android moves
        // the same span object on a second setSpan, so copied markers must be distinct.
        val copied = nativeInlineStyleSpanCopy(prepared) as NativeRubyPreparedSource
        assertNotSame(prepared, copied)
        assertSame(projection, copied.projection)
        assertEquals(prepared.source.toString(), copied.source.toString())
        assertTrue(prepared.paint.equalsForTextMeasurement(copied.paint))
        assertSame(prepared.direction, copied.direction)
        assertEquals(prepared.groups.keys, copied.groups.keys)
        prepared.groups.forEach { (path, format) -> assertSame(format, copied.groups.getValue(path)) }
        assertEquals(prepared.parentScript, copied.parentScript)
        assertEquals(prepared.visualOmissions, copied.visualOmissions)
        assertEquals(prepared.visualSpaces, copied.visualSpaces)
        assertEquals(prepared.visualSpaceNeighbors, copied.visualSpaceNeighbors)
        assertEquals(prepared.protectedSpaces, copied.protectedSpaces)
        val repeatBase = leaf("M", "repeat-base")
        val repeatReading = leaf("i", "repeat-reading", scale = .5f, color = "#00ff00")
        val repeatRuby = ruby(listOf(base(listOf(repeatBase))), listOf(reading(listOf(repeatReading))))
        val repeated = prepare(listOf(repeatRuby))
        val repeatContent = anonymousFlowContent(Block("paragraph", 0, emptyList(), flow = listOf(
            FlowPart.Inline(repeated.spans), FlowPart.Inline(repeated.spans))), anonymousContext)
        var repeatedCalls = 0
        val both = NativeAnonymousFlowGeometry.build(repeatContent, repeated.body, 320,
            inline = { event ->
                assertSame(repeatRuby, event.spans.single())
                repeatedCalls++
                repeated.source
            }, figure = { _, _ -> error("This source has no Figure") },
            inlineSemantic = { event, text -> anonymousInlineSemantic(event.spans, text) })
        assertEquals(2, repeatedCalls)
        assertEquals(repeated.projection.text.repeat(2), both.text.toString())
        assertEquals(2, both.offsets.inlineSources.size)
        val once = repeated.build(320)
        val baseReference = box(once, repeated.range(repeatBase))
        val readingReference = box(once, repeated.range(repeatReading))
        assertTrue(readingReference.top < baseReference.top)
        var previousBase: RectF? = null
        for (occurrence in 0..1) {
            val offset = occurrence * repeated.projection.text.length
            val baseRange = repeated.range(repeatBase)
            val readingRange = repeated.range(repeatReading)
            fun occurrenceBox(range: RubyTextRange): RectF = both.rectsForRange(
                offset + range.start, offset + range.end).map(::RectF).reduce { a, b -> a.apply { union(b) } }
            val actualBase = occurrenceBox(baseRange)
            val actualReading = occurrenceBox(readingRange)
            val translation = actualBase.left - baseReference.left
            sameRect(baseReference, RectF(actualBase).apply { offset(-translation, 0f) })
            sameRect(readingReference, RectF(actualReading).apply { offset(-translation, 0f) })
            previousBase?.let { assertTrue(actualBase.left >= it.right) }
            previousBase = actualBase
            assertSame(repeatRuby, both.offsets.inlineSources[occurrence].event.spans.single())
        }
        assertSame(projection, prepared.projection)
        assertSame(originalRuby, prepared.projection.ranges.single { it.role == RubyTextRole.Owner }.span)
        assertSame(originalBase, prepared.projection.ranges.single { it.role == RubyTextRole.Base }.base)
        assertEquals("", prepared.source.toString())
    }

    @Test fun inlinePaddingKeepsFractionalOwnerEdgesChildGeometryAndFragmentRefusal() {
        val normal = LinkState("#0000ff", false)
        val hover = LinkState("#ff0000", true)
        val linkPolicy = LinkPaint(normal, hover, normal, hover, normal, hover, normal, hover, false)
        val calls = mutableListOf<Span>()
        var witnessedRoundedPaddingHit = false
        data class PaddingCase(
            val spans: List<Span>, val base: Span, val group: Span, val children: List<Span>,
            val projection: RubyTextProjection, val prepared: NativeRubyPreparedSource, val source: Spanned,
            val body: TextPaint, val ownerPaint: TextPaint, val groupRange: RubyTextRange,
            val left: Float, val right: Float, val action: Span, val callback: () -> Unit,
            val state: NativeMissingLinkPaint?, val wrap: TextWrap,
        )
        fun resolved(body: Float, scale: Float, color: Int) = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            typeface = Typeface.MONOSPACE
            textSize = body * scale
            textLocale = Locale.forLanguageTag("vi")
            this.color = color
        }
        fun make(body: Float, density: Float, groupAction: Boolean, word: String = "nhân",
            baseText: String = "MMMMMMMM", wrap: TextWrap = TextWrap.Normal): PaddingCase {
            fun style() = InlineTextStyle(fontNormalized = true, wrap = wrap)
            fun owner(scale: Float) = RubyOwner(InlineFontSnapshot(fontScale = scale,
                fontScaleBasis = FontScaleBasis.NormalBody, fontNormalized = true, language = "vi"),
                direction = "ltr", inlineStyle = style())
            val base = Span("text", baseText, fontScale = 1f, fontScaleBasis = FontScaleBasis.NormalBody,
                language = "vi", foreground = "#000000", inlineStyle = style())
            val pieces = if (groupAction) listOf(word.take(word.length / 2), word.drop(word.length / 2)) else listOf(word)
            val children = pieces.map { text -> Span(if (groupAction) "text" else "link", text,
                if (groupAction) "" else "padding-child", fontScale = 1.35f,
                fontScaleBasis = FontScaleBasis.NormalBody, language = "vi", foreground = "#0000ff", inlineStyle = style()) }
            val padding = InlinePaddingGroup(StyleLength(StyleLengthUnit.Em, .25f),
                StyleLength(StyleLengthUnit.Px, .125f), children)
            val group = Span(if (groupAction) "link" else "text", "", if (groupAction) "padding-owner" else "",
                fontScale = 1.35f, fontScaleBasis = FontScaleBasis.NormalBody, language = "vi",
                direction = "ltr", foreground = "#0000ff", background = if (groupAction) null else "#00ff00",
                inlineStyle = style(), linkPaint = if (groupAction) linkPolicy else null, inlinePaddingGroup = padding)
            val ruby = Span("text", "", fontScale = 1f, fontScaleBasis = FontScaleBasis.NormalBody,
                language = "vi", direction = "ltr", foreground = "#000000", inlineStyle = style(),
                ruby = Ruby(listOf(RubySegment(emptyList(), listOf(RubyBase(owner(1f), emptyList(), listOf(base))),
                    listOf(RubyAnnotation(0, 1, 0, owner(.5f), emptyList(), listOf(group), emptyList(), emptyList(), false))))))
            val spans = listOf(ruby)
            val projection = rubyGraphicalProjection(spans)
            val root = resolved(body, 1f, Color.BLACK)
            val groupPaint = resolved(body, 1.35f, Color.BLUE)
            val left = padding.left.value * groupPaint.textSize
            val right = padding.right.value * density
            val state = if (groupAction) NativeMissingLinkPaint(linkPolicy, visited = false) else null
            val groups = projection.ranges.filter { it.role in setOf(RubyTextRole.Owner, RubyTextRole.Base,
                RubyTextRole.Annotation, RubyTextRole.PaddingGroup) }.associate { range ->
                val declared = when (range.role) {
                    RubyTextRole.Owner, RubyTextRole.PaddingGroup -> checkNotNull(range.span).let {
                        RubyOwner(snapshot(it), it.direction, it.inlineStyle, it.foreground, it.background)
                    }
                    RubyTextRole.Base -> checkNotNull(range.base).owner
                    RubyTextRole.Annotation -> checkNotNull(range.annotation).owner
                    else -> error("Not a declaring owner")
                }
                val paint = resolved(body, declared.font.fontScale ?: 1f,
                    declared.foreground?.let(Color::parseColor) ?: Color.BLACK).apply {
                    bgColor = declared.background?.let(Color::parseColor) ?: Color.TRANSPARENT
                }
                range.path to NativeRubyGroupFormat(paint, TextDirectionHeuristics.LTR, NativeLineHeightPolicy.Normal,
                    wrap = wrap, sourceDirection = declared.direction,
                    padding = if (range.role == RubyTextRole.PaddingGroup) NativeInlinePaddingEdges(left, right) else null,
                    actionPaint = if (range.role == RubyTextRole.PaddingGroup) state else null)
            }
            val logical = SpannableString(projection.text)
            logical.setSpan(NativeRunLineMetrics(NativePrimaryFontMetrics.from(root), NativeLineHeightPolicy.Normal, strut = true),
                0, logical.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            projection.ranges.filter { it.span != null && it.role !in setOf(RubyTextRole.Owner, RubyTextRole.PaddingGroup) }
                .forEach { range ->
                    val span = checkNotNull(range.span)
                    val value = resolved(body, span.fontScale ?: 1f, Color.parseColor(checkNotNull(span.foreground)))
                    val dynamic = state.takeIf { children.any { child -> child === span } }
                    logical.setSpan(object : MetricAffectingSpan(), NativeInlineSafePaintSpan {
                        override fun updateMeasureState(paint: TextPaint) { paint.set(value) }
                        override fun updateDrawState(paint: TextPaint) {
                            paint.set(value)
                            dynamic?.appearance()?.let { paint.color = it.color }
                        }
                    }, range.start, range.end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                    logical.setSpan(NativeRunLineMetrics(NativePrimaryFontMetrics.from(value), NativeLineHeightPolicy.Normal),
                        range.start, range.end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                    logical.setSpan(NativeAuthoredTextWrap(wrap), range.start, range.end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                }
            val prepared = NativeRubyPreparedSource(projection, SpannedString(logical), root, TextDirectionHeuristics.LTR, groups)
            val source = SpannableString(logical).apply {
                setSpan(prepared, 0, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            }
            val action = if (groupAction) group else children.single()
            val callback: () -> Unit = { calls += action }
            return PaddingCase(spans, base, group, children, projection, prepared, SpannedString(source), root, groupPaint,
                projection.ranges.single { it.role == RubyTextRole.PaddingGroup && it.span === group },
                left, right, action, callback, state, wrap)
        }
        fun build(value: PaddingCase, width: Int): NativeFloatGeometry = NativeFloatGeometry.build(value.source,
            value.body, width, emptyList(), textDirection = TextDirectionHeuristics.LTR, nodeFactory = { geometry ->
                val range = if (value.action === value.group) value.groupRange else value.projection.ranges.single {
                    it.span === value.action && it.role != RubyTextRole.PaddingGroup
                }
                val bounds = if (value.action === value.group)
                    checkNotNull(geometry.inlinePaddingGroupRects(value.group, range.start, range.end))
                    else nativeInlinePaddingChildActionRects(geometry, value.group,
                        value.groupRange.start, value.groupRange.end, NativeInlinePaddingEdges(value.left, value.right),
                        geometry.rectsForRange(range.start, range.end))
                listOf(FloatInteractionNode(0, FloatInteractionKind.LINK, range.start, range.end, bounds,
                    value.children.joinToString("") { it.text }, null, value.callback, missingLinkPaint = value.state))
            })
        fun reference(value: PaddingCase, spans: List<Span>, ownerPaint: TextPaint, width: Int): NativeFloatGeometry {
            val text = SpannableString(spans.joinToString("") { it.text })
            val root = TextPaint(ownerPaint).apply { bgColor = 0 }
            text.setSpan(NativeRunLineMetrics(NativePrimaryFontMetrics.from(root), NativeLineHeightPolicy.Normal, strut = true),
                0, text.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            var at = 0
            spans.forEach { span ->
                val paint = resolved(value.body.textSize, span.fontScale ?: 1f, Color.parseColor(checkNotNull(span.foreground)))
                text.setSpan(SourcePaint(paint), at, at + span.text.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                text.setSpan(NativeRunLineMetrics(NativePrimaryFontMetrics.from(paint), NativeLineHeightPolicy.Normal),
                    at, at + span.text.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                text.setSpan(NativeAuthoredTextWrap(value.wrap), at, at + span.text.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                at += span.text.length
            }
            text.setSpan(NativeAuthoredTextWrap(value.wrap, inheritedOwner = true), 0, text.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            return NativeFloatGeometry.build(text, root, width, emptyList(), textDirection = TextDirectionHeuristics.LTR,
                includeFontPadding = false)
        }
        fun verify(value: PaddingCase, geometry: NativeFloatGeometry): RectF {
            val range = value.groupRange
            val word = value.children.joinToString("") { it.text }
            assertEquals(value.base.text + word, value.projection.text)
            assertEquals(value.projection.text, geometry.text.toString())
            assertSame(value.projection, value.prepared.projection)
            assertSame(value.group, range.span)
            assertEquals("", value.group.text)
            assertEquals("", value.group.trail)
            val stored = checkNotNull(value.group.inlinePaddingGroup)
            value.children.zip(stored.spans).forEach { (expected, actual) -> assertSame(expected, actual) }
            val groupBox = checkNotNull(geometry.inlinePaddingGroupRects(value.group, range.start, range.end)).single()
            assertNull(geometry.inlinePaddingGroupRects(value.group.copy(), range.start, range.end))
            assertNull(geometry.inlinePaddingGroupRects(value.group, range.start + 1, range.end))
            val plain = reference(value, value.children, value.ownerPaint, 1200)
            val body = reference(value, listOf(value.base), value.body, 1200)
            val advance = plain.nativeSingleLineAdvance()
            val baseAdvance = body.nativeSingleLineAdvance()
            val padded = advance + value.left + value.right
            val baseRange = value.projection.ranges.single { it.span === value.base }
            val baseLeft = geometry.caretRect(baseRange.start).left - body.caretRect(0).left
            assertTrue("The independent base must leave real surrounding Ruby free space", baseAdvance > padded)
            assertEquals(padded, groupBox.width(), .01f)
            assertEquals(baseLeft + (baseAdvance - padded) / 2f, groupBox.left, .01f)
            assertTrue(groupBox.left > baseLeft)
            assertTrue(groupBox.right < baseLeft + baseAdvance)
            val first = plain.caretRect(0)
            val actualFirst = geometry.caretRect(range.start)
            val dx = actualFirst.left - first.left
            val dy = actualFirst.top - first.top
            assertEquals(groupBox.left + value.left, actualFirst.left, .01f)
            for (index in 0..word.length)
                sameRect(RectF(plain.caretRect(index)).apply { offset(dx, dy) }, geometry.caretRect(range.start + index))
            plain.characterRects(0, word.length).zip(geometry.characterRects(range.start, word.length)).forEach { (expected, actual) ->
                sameRect(RectF(checkNotNull(expected)).apply { offset(dx, dy) }, checkNotNull(actual))
            }
            value.children.forEach { child ->
                val childRange = value.projection.ranges.single { it.span === child }
                val expected = plain.rectsForRange(childRange.start - range.start, childRange.end - range.start)
                    .map { RectF(it).apply { offset(dx, dy) } }
                val actual = geometry.rectsForRange(childRange.start, childRange.end)
                assertEquals(expected.size, actual.size)
                expected.zip(actual).forEach { (a, b) -> sameRect(a, b) }
            }
            val actualCharacters = geometry.rectsForRange(range.start, range.end)
            val baseline = plain.nativeRubyLineBaseline(0) + dy
            val primary = NativePrimaryFontMetrics.from(value.ownerPaint)
            val content = NativeUsedLineMetrics(primary.ascent, primary.descent)
                .including(plain.nativeContentLineMetrics(0))
            assertEquals(baseline + content.top, groupBox.top, .01f)
            assertEquals(baseline + content.bottom, groupBox.bottom, .01f)
            val node = geometry.nodes.single()
            assertSame(value.callback, node.onClick)
            assertSame(value.state, node.missingLinkPaint)
            assertEquals(word, node.label.toString())
            if (value.action === value.group) sameRect(groupBox, node.bounds.single())
            else {
                assertEquals(actualCharacters.size, node.bounds.size)
                actualCharacters.zip(node.bounds).forEach { (original, action) ->
                    assertEquals(original.top, action.top, 0f)
                    assertEquals(original.bottom, action.bottom, 0f)
                    assertTrue(action.left >= groupBox.left + value.left)
                    assertTrue(action.right <= groupBox.right - value.right)
                }
            }
            val leftPoint = groupBox.left + value.left / 2f
            val rightPoint = groupBox.right - value.right / 2f
            assertEquals(value.action === value.group, node.contains(leftPoint, groupBox.centerY()))
            assertEquals(value.action === value.group, node.contains(rightPoint, groupBox.centerY()))
            if (value.action !== value.group && actualCharacters.any { it.contains(rightPoint, groupBox.centerY()) })
                witnessedRoundedPaddingHit = true
            assertTrue(node.contains(actualCharacters.first().centerX(), actualCharacters.first().centerY()))
            val before = calls.size
            checkNotNull(node.onClick).invoke()
            assertEquals(before + 1, calls.size)
            assertSame(value.action, calls.last())
            if (value.state != null) {
                val expectedUnderline = NativeFloatBounds(groupBox.left, baseline + value.ownerPaint.underlinePosition,
                    groupBox.right, baseline + value.ownerPaint.underlinePosition + value.ownerPaint.underlineThickness)
                val reserved = checkNotNull(geometry.ordinaryPaintBounds.reduceOrNull { a, b -> a.enclosing(b) })
                assertTrue(reserved.left <= expectedUnderline.left && reserved.right >= expectedUnderline.right &&
                    reserved.top <= expectedUnderline.top && reserved.bottom >= expectedUnderline.bottom)
            }
            return groupBox
        }
        for (zoom in listOf(1f, 1.5f)) for (groupAction in listOf(false, true)) {
            val density = 1.25f
            val normalBody = 24f * density * zoom
            val value = make(normalBody, density, groupAction)
            assertEquals(.25f * normalBody * 1.35f, value.left, .0001f)
            assertEquals(.125f * density, value.right, 0f)
            assertTrue(value.left != value.left.toInt().toFloat())
            assertTrue(value.right != value.right.toInt().toFloat())
            val geometry = build(value, 1200)
            val groupBox = verify(value, geometry)
            val normalInk = raster(geometry)
            assertTrue(normalInk.getValue(Color.BLUE).count > 0)
            assertEquals(0, normalInk.getValue(Color.RED).count)
            if (!groupAction) {
                assertTrue(normalInk.getValue(Color.GREEN).count > 0)
            } else {
                val state = checkNotNull(value.state)
                state.hovered = true
                val hoverInk = raster(geometry)
                assertTrue(hoverInk.getValue(Color.RED).count > 0)
                assertEquals(0, hoverInk.getValue(Color.BLUE).count)
                val red = checkNotNull(hoverInk.getValue(Color.RED).bounds)
                assertTrue("The group underline reaches the padding before child glyphs", red.left <= ceil(groupBox.left.toDouble()).toFloat())
                assertTrue(red.right >= kotlin.math.floor(groupBox.right.toDouble()).toFloat())
                sameRect(groupBox, checkNotNull(geometry.inlinePaddingGroupRects(value.group,
                    value.groupRange.start, value.groupRange.end)).single())
                state.hovered = false
                assertEquals(normalInk, raster(geometry))
            }
        }

        assertTrue("An original native selection region must reach the thin right padding while its child action excludes it",
            witnessedRoundedPaddingHit)

        // Independent native paragraphs supply the real same-source interior stops.
        // Ruby may select those stops, but this admitted padding owner cannot fragment.
        val emergency = make(24f, 1.25f, true, "abcdefghijklmnopqrstuvwx", "abcdefghijklmnop", TextWrap.BreakWord)
        val normalCase = make(24f, 1.25f, true, "abcdefghijklmnopqrstuvwx", "abcdefghijklmnop", TextWrap.Normal)
        val probes = listOf(listOf(emergency.base) to emergency.body, emergency.children to emergency.ownerPaint)
        val prefixes = probes.map { (spans, paint) ->
            val narrow = reference(emergency, spans, paint, 0)
            val wide = reference(emergency, spans, paint, 1200)
            val ends = (0 until narrow.shapedLineCount).flatMap(narrow::nativeRubyLineRanges)
                .map { it.second }.filter { it > 0 && it < narrow.text.length }.distinct().sorted()
            assertTrue("A genuine native interior endpoint is required", ends.isNotEmpty())
            wide.nativeRubyMeasuredAdvance(0, ends[minOf(3, ends.lastIndex)]) to wide.nativeSingleLineAdvance()
        }
        val width = ceil(maxOf(prefixes[0].first, prefixes[1].first + emergency.left + emergency.right).toDouble()).toInt()
        assertTrue(width > 0 && width < prefixes.minOf { it.second })
        fun widths(value: PaddingCase) = nativeTextWidthRange(value.source, value.body, textDirection = TextDirectionHeuristics.LTR)
        val normalWidths = widths(normalCase)
        assertEquals(normalWidths.minimum, widths(emergency).minimum)
        assertEquals(normalWidths.maximum, widths(emergency).maximum)
        val wide = build(emergency, 1200)
        assertEquals(1, wide.shapedLineCount)
        val error = assertThrows(UnsupportedFloatLayout::class.java) { build(emergency, width) }
        assertEquals("Inline padding group requires native fragmentation", error.message)
        val recovered = build(emergency, 1200)
        assertEquals(emergency.projection.text, recovered.text.toString())
        val range = emergency.groupRange
        sameRect(checkNotNull(wide.inlinePaddingGroupRects(emergency.group, range.start, range.end)).single(),
            checkNotNull(recovered.inlinePaddingGroupRects(emergency.group, range.start, range.end)).single())
        val node = recovered.nodes.single()
        assertSame(emergency.callback, node.onClick)
        val before = calls.size
        checkNotNull(node.onClick).invoke()
        assertEquals(before + 1, calls.size)
        assertSame(emergency.group, calls.last())
        assertSame(emergency.group, emergency.prepared.projection.ranges.single { it.role == RubyTextRole.PaddingGroup }.span)
    }


    @Test fun inlineActionOwnersKeepNativeFragmentsDeclaringPaintAndEmptyPoints() {
        val normal = LinkState("#0000ff", false)
        val pressed = LinkState("#ff0000", true)
        val policy = LinkPaint(normal, normal, pressed, pressed, normal, normal, pressed, pressed,
            underlineOnFocus = true, focusOutline = FigureFocusOutline(
                StyleLength(StyleLengthUnit.Px, 1f), FigureColor.Rgb("#ff00ff"),
                StyleLength(StyleLengthUnit.Px, 0f), SignedContainerMargin(StyleLengthUnit.Px, 0f)))
        val callbacks = mutableListOf<Span>()
        fun sourceLeaf(text: String, scale: Float = 1f, superscript: Boolean = false,
            italic: Boolean = false, direction: String = "") = Span("text", text,
            fontScale = scale, fontScaleBasis = FontScaleBasis.NormalBody, language = "ja",
            superscript = superscript, italic = italic, direction = direction, foreground = "#0000ff",
            inlineStyle = InlineTextStyle(fontNormalized = true))
        fun action(children: List<Span>, height: Float = 48f, paintPolicy: LinkPaint? = policy,
            stack: Boolean = false) = Span("link", "", "original-action", targetFragment = "source-fragment",
            fontScale = 1f, fontScaleBasis = FontScaleBasis.NormalBody, language = "ja",
            foreground = "#0000ff", background = "#00ff00", linkPaint = paintPolicy,
            fontFamily = if (stack) ContainerFontFamily.Stack(emptyList(), GenericFontFamily.Serif) else null,
            inlineStyle = InlineTextStyle(fontNormalized = true,
                lineHeight = InlineLineHeight.Computed(InlineComputedLength(height, FontScaleBasis.CssPx)), cursor = InlineCursor.Help),
            inlineActionGroup = InlineActionGroup(children))
        data class Case(val original: List<Span>, val action: Span, val projection: RubyTextProjection,
            val range: RubyTextRange, val key: NativeInlineActionOwner, val state: NativeMissingLinkPaint?,
            val prepared: NativeRubyPreparedSource, val source: Spanned, val root: TextPaint,
            val declaring: TextPaint, val callback: () -> Unit, val rtl: Boolean)
        fun resolve(font: InlineFontSnapshot, color: Int): TextPaint = paint(font.fontScale ?: 1f, color).apply {
            val family = if ((font.fontFamily as? ContainerFontFamily.Stack)?.fallback == GenericFontFamily.Serif)
                Typeface.SERIF else Typeface.MONOSPACE
            typeface = Typeface.create(family,
                (if (font.bold) Typeface.BOLD else 0) or (if (font.italic) Typeface.ITALIC else 0))
            textLocale = Locale.forLanguageTag(font.language.ifEmpty { "ja" })
            if (font.superscript) baselineShift = scriptShift(this).toInt()
        }
        fun sourcePolicy(style: InlineTextStyle?, fallback: NativeLineHeightPolicy): NativeLineHeightPolicy =
            when (val height = style?.lineHeight) {
                null -> fallback
                is InlineLineHeight.Computed -> NativeLineHeightPolicy.Pixels(height.value.value *
                    if (height.value.fontScaleBasis == FontScaleBasis.CssPx) 1f else bodyPixels)
                is InlineLineHeight.FontRelative -> NativeLineHeightPolicy.Pixels(
                    (resolve(height.font, Color.BLUE).textSize.toDouble() * height.factor).toFloat())
            }
        fun make(owner: Span, rtl: Boolean = false, outside: Boolean = false, noWrap: Boolean = false,
            rootSpans: List<Span>? = null, rootPolicy: NativeLineHeightPolicy = NativeLineHeightPolicy.Pixels(24f)): Case {
            val original = rootSpans ?: if (outside) listOf(sourceLeaf("OUT ").copy(foreground = "#000000"), owner,
                sourceLeaf(" END").copy(foreground = "#000000")) else listOf(owner)
            val projection = rubyGraphicalProjection(original)
            val range = projection.ranges.single { it.role == RubyTextRole.ActionGroup && it.span === owner }
            val key = NativeInlineActionOwner(owner, range.path)
            val state = owner.linkPaint?.let { NativeMissingLinkPaint(it, visited = false,
                actionIdentity = MissingLinkActionIdentity(original, missingLinkTarget(owner, "ja"),
                    NativeLinkOccurrenceIdentity(original, 0, range.start, range.end, owner))) }
            val root = paint(color = Color.BLACK)
            val declaring = resolve(snapshot(owner), Color.BLUE).apply { bgColor = Color.GREEN }
            val direction = if (rtl) TextDirectionHeuristics.RTL else TextDirectionHeuristics.LTR
            val groupRoles = setOf(RubyTextRole.Owner, RubyTextRole.Base, RubyTextRole.Annotation,
                RubyTextRole.PaddingGroup, RubyTextRole.ActionGroup)
            val declaringRanges = projection.ranges.filter { it.role in groupRoles }
            fun declaringOwner(part: RubyTextRange): RubyOwner = when (part.role) {
                RubyTextRole.Base -> checkNotNull(part.base).owner
                RubyTextRole.Annotation -> checkNotNull(part.annotation).owner
                else -> checkNotNull(part.span).let {
                    RubyOwner(snapshot(it), it.direction, it.inlineStyle, it.foreground, it.background)
                }
            }
            fun inheritedPolicy(part: RubyTextRange): NativeLineHeightPolicy = declaringRanges
                .filter { part.path.startsWith(it.path + "/") }.sortedBy { it.path.length }
                .fold(rootPolicy) { inherited, ancestor -> sourcePolicy(declaringOwner(ancestor).inlineStyle, inherited) }
            val groups = declaringRanges.associate { part ->
                val declared = declaringOwner(part)
                val value = resolve(declared.font, declared.foreground?.let(Color::parseColor) ?: Color.BLUE).apply {
                    bgColor = declared.background?.let(Color::parseColor) ?: Color.TRANSPARENT
                }
                val padding = part.span?.inlinePaddingGroup
                fun edge(length: StyleLength) = length.value * if (length.unit == StyleLengthUnit.Px) 1f else value.textSize
                part.path to NativeRubyGroupFormat(value,
                    if (declared.direction == "rtl") TextDirectionHeuristics.RTL else direction,
                    sourcePolicy(declared.inlineStyle, inheritedPolicy(part)),
                    baselineShift = value.baselineShift.toFloat(),
                    sourceDirection = declared.direction, cursor = declared.inlineStyle?.cursor,
                    wrap = if (noWrap && part.role == RubyTextRole.ActionGroup) TextWrap.NoWrap else null,
                    padding = padding?.let { NativeInlinePaddingEdges(edge(it.left), edge(it.right)) },
                    actionPaint = if (part.role == RubyTextRole.ActionGroup) state else null,
                    actionOwner = if (part.role == RubyTextRole.ActionGroup) key else null)
            }
            val logical = SpannableString(projection.text)
            val flags = if (logical.isEmpty()) Spanned.SPAN_MARK_MARK else Spanned.SPAN_EXCLUSIVE_EXCLUSIVE
            logical.setSpan(NativeRunLineMetrics(NativePrimaryFontMetrics.from(root), rootPolicy,
                strut = true), 0, logical.length, flags)
            projection.ranges.filter { it.span != null && it.role !in groupRoles }.forEach { part ->
                val span = checkNotNull(part.span)
                val value = resolve(snapshot(span), span.foreground?.let(Color::parseColor) ?: Color.BLUE)
                val shared = state.takeIf { part.path.startsWith(range.path + "/") }
                logical.setSpan(object : MetricAffectingSpan(), NativeInlineSafePaintSpan {
                    override fun updateMeasureState(paint: TextPaint) { paint.set(value) }
                    override fun updateDrawState(paint: TextPaint) {
                        paint.set(value)
                        shared?.appearance()?.let { paint.color = it.color }
                    }
                }, part.start, part.end, if (part.start == part.end) Spanned.SPAN_MARK_MARK else Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                val leafPolicy = sourcePolicy(span.inlineStyle, inheritedPolicy(part))
                val leafFlags = if (part.start == part.end) Spanned.SPAN_MARK_MARK else Spanned.SPAN_EXCLUSIVE_EXCLUSIVE
                logical.setSpan(NativeRunLineMetrics(NativePrimaryFontMetrics.from(value), leafPolicy),
                    part.start, part.end, leafFlags)
                val numeric = span.inlineStyle?.baselineShift
                val nativeShift = numeric?.let { -it.value } ?: value.baselineShift.toFloat()
                if (span.inlineStyle?.lineHeight != null || numeric != null) {
                    val relative = (span.inlineStyle?.lineHeight as? InlineLineHeight.FontRelative)?.let {
                        NativePrimaryFontMetrics.from(resolve(it.font, Color.BLUE)).let { metrics ->
                            if (numeric != null) metrics.copy(baselineShift = nativeShift) else metrics
                        }
                    }
                    val parent = declaringRanges.filter { part.path.startsWith(it.path + "/") }.maxByOrNull { it.path.length }
                    val declaringPrimary = relative ?: if (numeric != null) parent?.let {
                        NativePrimaryFontMetrics.from(checkNotNull(groups[it.path]).paint).copy(baselineShift = nativeShift)
                    } else null
                    logical.setSpan(NativeAuthoredInlineMetrics(NativePrimaryFontMetrics.from(value)
                        .copy(baselineShift = nativeShift), leafPolicy, declaringPrimary), part.start, part.end, leafFlags)
                }
                if (numeric != null) logical.setSpan(NativeAuthoredBaselineShift(nativeShift), part.start, part.end, leafFlags)
            }
            if (noWrap) logical.setSpan(NativeAuthoredTextWrap(TextWrap.NoWrap, inheritedOwner = true,
                sourceLineStarts = listOf(0)), 0, logical.length, flags)
            val prepared = NativeRubyPreparedSource(projection, SpannedString(logical), root, direction, groups)
            val source = SpannableString(logical).apply { setSpan(prepared, 0, length, flags) }
            return Case(original, owner, projection, range, key, state, prepared, SpannedString(source),
                root, declaring, { callbacks += owner }, rtl)
        }
        fun build(value: Case, width: Int): NativeFloatGeometry = NativeFloatGeometry.build(value.source, value.root,
            width, emptyList(), textDirection = if (value.rtl) TextDirectionHeuristics.RTL else TextDirectionHeuristics.LTR,
            nodeFactory = { geometry ->
                val boxes = checkNotNull(geometry.inlineActionGroupRects(value.key, value.range.start, value.range.end))
                listOf(FloatInteractionNode(19, FloatInteractionKind.LINK, value.range.start, value.range.end,
                    boxes, value.projection.text.substring(value.range.start, value.range.end), null, value.callback,
                    missingLinkPaint = value.state,
                    focusPaint = value.action.linkPaint?.let { ordinaryLinkFocusPaint(it, boxes, 1f, bodyPixels) }))
            })
        fun verify(value: Case, geometry: NativeFloatGeometry): List<RectF> {
            assertEquals(value.projection.text, geometry.text.toString())
            assertSame(value.action, value.range.span)
            assertSame(value.projection, value.prepared.projection)
            assertEquals("", value.action.text)
            assertEquals("", value.action.trail)
            assertSame(value.action, value.key.span)
            val node = geometry.nodes.single()
            assertEquals(19, node.id)
            assertEquals(value.range.start, node.start); assertEquals(value.range.end, node.end)
            assertSame(value.callback, node.onClick); assertSame(value.state, node.missingLinkPaint)
            assertEquals(value.projection.text.substring(node.start, node.end), node.label.toString())
            assertNull(geometry.inlineActionGroupRects(NativeInlineActionOwner(value.action, value.key.path), node.start, node.end))
            if (node.start > 0) assertNull(geometry.inlineActionGroupRects(value.key, node.start - 1, node.end))
            if (node.end < geometry.text.length) assertNull(geometry.inlineActionGroupRects(value.key, node.start, node.end + 1))
            val result = checkNotNull(geometry.inlineActionGroupRects(value.key, node.start, node.end))
            assertEquals(result, node.bounds)
            value.projection.ranges.filter { it.span != null && it.role !in setOf(RubyTextRole.Owner,
                RubyTextRole.ActionGroup, RubyTextRole.PaddingGroup) && it.start < it.end }.forEach { part ->
                assertEquals(checkNotNull(part.span).text + checkNotNull(part.span).trail,
                    geometry.text.subSequence(part.start, part.end).toString())
                for (offset in part.start until part.end) if (!geometry.text[offset].isWhitespace())
                    assertNotNull(geometry.characterRects(offset, 1).single())
            }
            node.onClick!!.invoke()
            assertSame(value.action, callbacks.last())
            return result
        }
        fun image(geometry: NativeFloatGeometry, focus: Boolean = false): Bitmap {
            val ink = geometry.extents.ink
            val top = kotlin.math.floor(minOf(0f, ink?.top ?: 0f)).toInt() - 8
            val left = kotlin.math.floor(minOf(0f, ink?.left ?: 0f)).toInt() - 8
            val right = ceil(maxOf(geometry.width.toFloat(), ink?.right ?: 0f).toDouble()).toInt() + 8
            val bottom = ceil(maxOf(geometry.height.toFloat(), ink?.bottom ?: 0f).toDouble()).toInt() + 8
            return Bitmap.createBitmap(right - left, bottom - top, Bitmap.Config.ARGB_8888).also { bitmap ->
                val canvas = Canvas(bitmap)
                canvas.translate(-left.toFloat(), -top.toFloat())
                geometry.paint(canvas)
                if (focus) geometry.nodes.single().focusPaint?.let { paintNativeFocus(canvas, it) }
            }
        }
        fun owned(bitmap: Bitmap, red: Boolean = false, blue: Boolean = false, green: Boolean = false,
            magenta: Boolean = false): Int = (0 until bitmap.height).sumOf { y -> (0 until bitmap.width).count { x ->
                val color = bitmap.getPixel(x, y)
                Color.alpha(color) > 0 && when {
                    red -> Color.red(color) > 0 && Color.green(color) == 0 && Color.blue(color) == 0
                    blue -> Color.blue(color) > 0 && Color.green(color) == 0 && Color.red(color) == 0
                    green -> Color.green(color) > 0 && Color.red(color) == 0 && Color.blue(color) == 0
                    magenta -> Color.red(color) > 0 && Color.blue(color) > 0 && Color.green(color) == 0
                    else -> false
                }
            } }

        fun assertDeclaringUnderlineChanged(value: Case, geometry: NativeFloatGeometry,
            before: Bitmap, focused: Bitmap) {
            assertEquals(before.width, focused.width); assertEquals(before.height, focused.height)
            val ink = geometry.extents.ink
            val imageLeft = kotlin.math.floor(minOf(0f, ink?.left ?: 0f)).toInt() - 8
            val imageTop = kotlin.math.floor(minOf(0f, ink?.top ?: 0f)).toInt() - 8
            assertTrue(value.declaring.underlineThickness.isFinite() && value.declaring.underlineThickness > 0f)
            var changedBackground = 0
            // Authored interior spaces give glyph-free native X allocations. The Y band
            // comes independently from the declaring font; these captures omit the outline.
            for (offset in value.range.start until value.range.end) {
                if (geometry.text[offset] != ' ' || offset <= value.range.start || offset + 1 >= value.range.end) continue
                fun asciiWord(char: Char) = char in 'a'..'z' || char in 'A'..'Z' || char in '0'..'9'
                if (!asciiWord(geometry.text[offset - 1]) || !asciiWord(geometry.text[offset + 1])) continue
                val line = (0 until geometry.shapedLineCount).singleOrNull { row ->
                    geometry.nativeRubyLineRanges(row).any { offset >= it.first && offset + 1 <= it.second }
                } ?: continue
                val first = geometry.nativeRubyLineCaret(line, offset)?.left ?: continue
                val last = geometry.nativeRubyLineCaret(line, offset + 1)?.left ?: continue
                val left = ceil(minOf(first, last).toDouble()).toInt() - imageLeft
                val right = kotlin.math.floor(maxOf(first, last).toDouble()).toInt() - imageLeft
                if (left >= right) continue
                val underlineTop = geometry.nativeRubyRaw.nativeRubyLineBaseline(line) + value.declaring.underlinePosition
                val top = kotlin.math.floor(underlineTop.toDouble()).toInt() - imageTop
                val bottom = ceil((underlineTop + value.declaring.underlineThickness).toDouble()).toInt() - imageTop
                for (y in top.coerceAtLeast(0) until bottom.coerceAtMost(before.height))
                    for (x in left.coerceAtLeast(0) until right.coerceAtMost(before.width)) {
                        val original = before.getPixel(x, y)
                        val after = focused.getPixel(x, y)
                        if (Color.alpha(original) > 0 && Color.red(original) == 0 && Color.blue(original) == 0 &&
                            Color.green(original) > 0 && Color.blue(after) > Color.blue(original) &&
                            Color.green(after) < Color.green(original)) changedBackground++
                    }
            }
            assertTrue("Focus must add declaring-font underline ink over an authored space", changedBackground > 0)
        }

        val sup = sourceLeaf("2", .5f, superscript = true)
        val italic = sourceLeaf("I", italic = true)
        val letters = sourceLeaf("owner ", .5f)
        val metricSup = sourceLeaf("2", .25f, superscript = true)
        val metricItalic = sourceLeaf("I", .5f, italic = true)
        val metricChildren = listOf(letters, metricSup, metricItalic)
        val metricOwner = action(metricChildren)
        // The compiler authenticates the paragraph strut without treating a painted
        // Normal sibling as an independent declaring owner.
        val mixed = make(metricOwner, rootPolicy = NativeLineHeightPolicy.Normal)
        assertSame(metricOwner, mixed.original.single())
        assertEquals(NativeLineHeightPolicy.Normal,
            mixed.prepared.source.getSpans(0, mixed.prepared.source.length, NativeRunLineMetrics::class.java)
                .single { it.strut }.policy)
        assertFalse(mixed.prepared.source.getSpans(0, mixed.prepared.source.length, NativeRunLineMetrics::class.java)
            .single { it.strut }.independentNormalStrut)
        val mixedGeometry = build(mixed, 400)
        verify(mixed, mixedGeometry)
        val metric = make(metricOwner)
        assertSame(metricOwner, metric.original.single())
        assertEquals(mixed.projection.text, metric.projection.text)
        assertEquals(NativeLineHeightPolicy.Pixels(24f),
            metric.prepared.source.getSpans(0, metric.prepared.source.length, NativeRunLineMetrics::class.java)
                .single { it.strut }.policy)
        val direct = build(metric, 400)
        verify(metric, direct)
        assertEquals(1, direct.shapedLineCount)
        val fm = metric.declaring.fontMetrics
        val middle = (fm.ascent + fm.descent) / 2f
        // The owner and every scripted child retain their own primary font. Inherited
        // Pixels48 contributes at each actual child baseline; compare their full union.
        val childBands = metricChildren.map { span ->
            val value = resolve(snapshot(span), Color.BLUE)
            val metrics = value.fontMetrics
            val center = (metrics.ascent + metrics.descent) / 2f + value.baselineShift
            center - 24f to center + 24f
        }
        assertTrue(middle - 24f < childBands.minOf { it.first })
        val rootPrimary = mixed.root.fontMetrics
        val mixedUsed = mixedGeometry.nativeRubyRaw.nativeUsedLineMetrics(0)
        assertEquals(minOf(rootPrimary.ascent, middle - 24f, childBands.minOf { it.first }), mixedUsed.top, .01f)
        assertEquals(maxOf(rootPrimary.descent, middle + 24f, childBands.maxOf { it.second }), mixedUsed.bottom, .01f)
        assertEquals(verify(mixed, mixedGeometry), verify(mixed, build(mixed, 400)))
        val paintedNormal = make(metricOwner, outside = true, rootPolicy = NativeLineHeightPolicy.Normal)
        assertTrue(paintedNormal.prepared.source.getSpans(0, paintedNormal.prepared.source.length,
            NativeRunLineMetrics::class.java).any { !it.strut && it.policy == NativeLineHeightPolicy.Normal &&
            paintedNormal.prepared.source.getSpanEnd(it) <= paintedNormal.range.start })
        try { build(paintedNormal, 400); fail("A painted Normal sibling must retain its fallback-aware refusal") }
        catch (failure: UnsupportedFloatLayout) { assertTrue(failure.message.orEmpty().contains("normal", ignoreCase = true)) }
        val paintedRecovery = make(metricOwner, outside = true)
        assertEquals(paintedNormal.projection.text, paintedRecovery.projection.text)
        verify(paintedRecovery, build(paintedRecovery, 400))
        val natural = NativeFloatGeometry.build(metric.prepared.source, metric.root, 400, emptyList(),
            textDirection = TextDirectionHeuristics.LTR).nativeUsedLineMetrics(0)
        val expectedTop = minOf(middle - 24f, natural.top, childBands.minOf { it.first })
        val expectedBottom = maxOf(middle + 24f, natural.bottom, childBands.maxOf { it.second })
        val used = direct.nativeRubyRaw.nativeUsedLineMetrics(0)
        assertEquals(expectedTop, used.top, .01f)
        assertEquals(expectedBottom, used.bottom, .01f)
        val supRange = metric.projection.ranges.single { it.span === metricSup }
        val italicRange = metric.projection.ranges.single { it.span === metricItalic }
        assertTrue(direct.baselineForOffset(supRange.start) < direct.baselineForOffset(italicRange.start))
        val ordinaryBox = direct.rectsForRange(metric.range.start, metric.range.start + 1).single()
        assertEquals(InlineCursor.Help, direct.cursorAt(ordinaryBox.centerX(), ordinaryBox.centerY()))
        val normalImage = image(direct)
        val interaction = checkNotNull(metric.state)
        interaction.focused = true
        val focusedTextImage = image(direct)
        val focusImage = image(direct, focus = true)
        interaction.active = true
        val activeImage = image(direct, focus = true)
        interaction.active = false; interaction.focused = false
        val recoveredImage = image(direct)
        try {
            assertTrue(owned(normalImage, blue = true) > 0)
            assertTrue(owned(normalImage, green = true) > 0)
            assertEquals(0, owned(normalImage, red = true))
            assertDeclaringUnderlineChanged(metric, direct, normalImage, focusedTextImage)
            assertTrue(owned(focusImage, magenta = true) > 0)
            assertTrue(owned(activeImage, red = true) > 0)
            assertEquals(0, owned(activeImage, blue = true))
            assertTrue(owned(activeImage, magenta = true) > 0)
            assertEquals(normalImage.width, recoveredImage.width); assertEquals(normalImage.height, recoveredImage.height)
            for (y in 0 until normalImage.height) for (x in 0 until normalImage.width)
                assertEquals(normalImage.getPixel(x, y), recoveredImage.getPixel(x, y))
            val outlines = checkNotNull(direct.nodes.single().focusPaint).outlines()
            assertEquals(direct.nodes.single().bounds.size, outlines.size)
            outlines.zip(direct.nodes.single().bounds).forEach { (outline, box) ->
                sameRect(box, outline.bounds, 0f); assertEquals(1f, outline.width, 0f); assertEquals(Color.MAGENTA, outline.color)
            }
        } finally {
            normalImage.recycle(); focusedTextImage.recycle(); focusImage.recycle(); activeImage.recycle(); recoveredImage.recycle()
        }

        // A complete normalized SUP snapshot resolves its own 1em height once. Zero
        // root/owner heights leave that actual child band observable without a UA ratio.
        val relativeSource = sourceLeaf("2", .5f, superscript = true).copy(
            fontFamily = ContainerFontFamily.Stack(emptyList(), GenericFontFamily.Serif))
        val relativeFont = snapshot(relativeSource)
        val relativeChild = relativeSource.copy(inlineStyle = InlineTextStyle(fontNormalized = true,
            lineHeight = InlineLineHeight.FontRelative(1f, relativeFont)))
        val relativeOwner = action(listOf(relativeChild), height = 0f, paintPolicy = null)
        val relativeCase = make(relativeOwner, rootPolicy = NativeLineHeightPolicy.Pixels(0f))
        val relativeGeometry = build(relativeCase, 400)
        verify(relativeCase, relativeGeometry)
        assertSame(relativeFont, (checkNotNull(relativeChild.inlineStyle).lineHeight as InlineLineHeight.FontRelative).font)
        assertEquals(.5, checkNotNull(relativeFont.fontScale).toDouble(), 0.0)
        assertEquals(FontScaleBasis.NormalBody, relativeFont.fontScaleBasis)
        assertTrue(relativeFont.fontNormalized); assertTrue(relativeFont.superscript)
        assertEquals(ContainerFontFamily.Stack(emptyList(), GenericFontFamily.Serif), relativeFont.fontFamily)
        val relativePaint = resolve(relativeFont, Color.BLUE)
        assertEquals(bodyPixels * .5f, relativePaint.textSize, 0f)
        val relativeFm = relativePaint.fontMetrics
        val relativeCenter = (relativeFm.ascent + relativeFm.descent) / 2f + relativePaint.baselineShift
        val relativeHeight = relativePaint.textSize
        val relativeRoot = relativeCase.root.fontMetrics.let { (it.ascent + it.descent) / 2f }
        val relativeDeclaring = relativeCase.declaring.fontMetrics.let { (it.ascent + it.descent) / 2f }
        val relativeUsed = relativeGeometry.nativeRubyRaw.nativeUsedLineMetrics(0)
        assertEquals(minOf(relativeRoot, relativeDeclaring, relativeCenter - relativeHeight / 2f), relativeUsed.top, .01f)
        assertEquals(maxOf(relativeRoot, relativeDeclaring, relativeCenter + relativeHeight / 2f), relativeUsed.bottom, .01f)
        val relativeRange = relativeCase.projection.ranges.single { it.span === relativeChild }
        assertEquals(relativeGeometry.nativeRubyRaw.nativeRubyLineBaseline(0) + relativePaint.baselineShift,
            relativeGeometry.baselineForOffset(relativeRange.start), .01f)
        val relativeMetrics = relativeCase.prepared.source.getSpans(relativeRange.start, relativeRange.end,
            NativeAuthoredInlineMetrics::class.java).single()
        assertEquals(NativeLineHeightPolicy.Pixels(relativeHeight), relativeMetrics.policy)
        assertEquals(relativePaint.baselineShift.toFloat(), relativeMetrics.primary.baselineShift, 0f)
        assertTrue(relativeGeometry.characterRects(relativeRange.start, 1).single() != null)
        val relativeImage = image(relativeGeometry)
        try { assertTrue(owned(relativeImage, blue = true) > 0) } finally { relativeImage.recycle() }

        val paddingText = sourceLeaf("nhân", .75f).copy(language = "vi")
        val padding = sourceLeaf("", .75f).copy(language = "vi", direction = "ltr",
            inlinePaddingGroup = InlinePaddingGroup(StyleLength(StyleLengthUnit.Em, .25f),
                StyleLength(StyleLengthUnit.Px, .125f), listOf(paddingText)))
        val baseText = sourceLeaf("漢")
        val nested = ruby(listOf(base(listOf(baseText))), listOf(reading(listOf(padding))))
        val bidi = sourceLeaf("אבגד", direction = "rtl")
        val richOwner = action(listOf(sourceLeaf("alpha beta "), sup, italic, sourceLeaf(" "), bidi,
            sourceLeaf(" gamma "), nested, sourceLeaf(" delta epsilon zeta")))
        val narrowWidth = ceil(paint().measureText("alpha beta ").toDouble()).toInt()
        assertTrue(narrowWidth > 0)
        for (rtl in listOf(false, true)) {
            val value = make(richOwner, rtl = rtl, outside = true)
            val wide = build(value, 1200)
            val narrow = build(value, narrowWidth)
            val recovered = build(value, 1200)
            val wideBoxes = verify(value, wide)
            val boxes = verify(value, narrow)
            assertTrue(narrow.shapedLineCount > wide.shapedLineCount)
            assertTrue(boxes.map { it.top to it.bottom }.distinct().size > 1)
            assertEquals(wideBoxes, verify(value, recovered))
            val paddingRange = value.projection.ranges.single { it.role == RubyTextRole.PaddingGroup && it.span === padding }
            val paddingBox = checkNotNull(narrow.inlinePaddingGroupRects(padding, paddingRange.start, paddingRange.end)).single()
            val included = checkNotNull(narrow.inlineActionGroupRects(value.key, paddingRange.start, paddingRange.end))
            assertEquals(listOf(paddingBox), included)
            assertTrue(boxes.any { it == paddingBox })
            val plainReading = NativeFloatGeometry.build(SpannableString(paddingText.text), resolve(snapshot(paddingText), Color.BLUE),
                1000, emptyList(), textDirection = TextDirectionHeuristics.LTR, includeFontPadding = false)
            val expectedWidth = plainReading.nativeSingleLineAdvance() + bodyPixels * .75f * .25f + .125f
            assertEquals(expectedWidth, paddingBox.width(), .01f)
            assertEquals(InlineCursor.Help, narrow.cursorAt(paddingBox.left + bodyPixels * .75f * .125f,
                paddingBox.centerY()))
            val readingRange = value.projection.ranges.single { it.span === paddingText }
            val readingRects = narrow.rectsForRange(readingRange.start, readingRange.end)
            assertTrue(readingRects.isNotEmpty())
            assertTrue(readingRects.all { child -> boxes.any { it.contains(child.centerX(), child.centerY()) } })
            if (!rtl) {
                // Focus underlines this declaring base line; the independently placed
                // reading remains unchanged. Pressed foreground still reaches that reading.
                val baseRange = value.projection.ranges.single { it.span === baseText }
                val underlineTop = narrow.baselineForOffset(baseRange.start) + value.declaring.underlinePosition
                assertTrue(readingRects.all { it.bottom <= underlineTop })
                val before = image(narrow)
                val shared = checkNotNull(value.state)
                shared.focused = true
                val focused = image(narrow)
                shared.active = true
                val active = image(narrow)
                shared.active = false; shared.focused = false
                try {
                    assertDeclaringUnderlineChanged(value, narrow, before, focused)
                    assertEquals(0, owned(active, blue = true))
                    val ink = narrow.extents.ink
                    val imageLeft = kotlin.math.floor(minOf(0f, ink?.left ?: 0f)).toInt() - 8
                    val imageTop = kotlin.math.floor(minOf(0f, ink?.top ?: 0f)).toInt() - 8
                    var readingRed = 0
                    readingRects.forEach { rect ->
                        val left = kotlin.math.floor(rect.left.toDouble()).toInt() - imageLeft
                        val top = kotlin.math.floor(rect.top.toDouble()).toInt() - imageTop
                        val right = ceil(rect.right.toDouble()).toInt() - imageLeft
                        val bottom = ceil(rect.bottom.toDouble()).toInt() - imageTop
                        for (y in top.coerceAtLeast(0) until bottom.coerceAtMost(before.height))
                            for (x in left.coerceAtLeast(0) until right.coerceAtMost(before.width)) {
                                assertEquals(before.getPixel(x, y), focused.getPixel(x, y))
                                val pixel = active.getPixel(x, y)
                                if (Color.alpha(pixel) > 0 && Color.red(pixel) > 0 && Color.green(pixel) == 0 && Color.blue(pixel) == 0)
                                    readingRed++
                            }
                    }
                    assertTrue(readingRed > 0)
                } finally { before.recycle(); focused.recycle(); active.recycle() }
            }
            val glyphRange = value.projection.ranges.single { it.span === bidi }
            for (offset in glyphRange.start until glyphRange.end) {
                val character = checkNotNull(narrow.characterRects(offset, 1).single())
                assertTrue(boxes.any { it.contains(character.centerX(), character.centerY()) })
            }
            assertTrue(narrow.caretRect(glyphRange.start).left > narrow.caretRect(glyphRange.start + 1).left)
            // An empty subset of a nonempty owner cannot acquire the declaring point box.
            assertTrue(checkNotNull(narrow.inlineActionGroupRects(value.key, value.range.start, value.range.start)).isEmpty())
        }

        for (height in listOf(48f, 0f)) for (noWrap in listOf(false, true)) {
            val emptyLeaf = sourceLeaf("").copy(fontFamily = ContainerFontFamily.Stack(emptyList(), GenericFontFamily.Serif))
            val owner = action(listOf(emptyLeaf), height, paintPolicy = null, stack = true)
            val value = make(owner, noWrap = noWrap)
            val geometry = build(value, 80)
            val bands = verify(value, geometry)
            assertEquals("", geometry.text.toString())
            assertEquals(1, geometry.shapedLineCount)
            assertSame(emptyLeaf, checkNotNull(owner.inlineActionGroup).spans.single())
            assertEquals(ContainerFontFamily.Stack(emptyList(), GenericFontFamily.Serif), owner.fontFamily)
            val band = bands.single()
            assertEquals(band.left, band.right, 0f)
            val baseline = checkNotNull(checkNotNull(geometry.textBaselines).first)
            val ownMetrics = value.declaring.fontMetrics
            val ownMiddle = (ownMetrics.ascent + ownMetrics.descent) / 2f
            assertEquals(baseline + ownMiddle - height / 2f, band.top, .01f)
            assertEquals(baseline + ownMiddle + height / 2f, band.bottom, .01f)
            assertEquals(height, band.height(), .01f)
            assertFalse(geometry.nodes.single().contains(band.left, band.centerY()))
            assertNull(geometry.cursorAt(band.left, band.centerY()))
            assertTrue(geometry.rectsForRange(0, 0).isEmpty())
            assertTrue(geometry.characterRects(0, 0).isEmpty())
            assertEquals(Spanned.SPAN_MARK_MARK, value.source.getSpanFlags(
                value.source.getSpans(0, 0, NativeRubyPreparedSource::class.java).single()))
            val bitmap = image(geometry)
            try { assertEquals(0, owned(bitmap, blue = true)); assertEquals(0, owned(bitmap, green = true)) }
            finally { bitmap.recycle() }
        }

        // An empty child's numeric baseline affects its own point metrics, never the
        // declaring action band's origin. The old raw.baselineForOffset(point) path
        // incorrectly added this child shift to the owner a second time.
        val emptyChild = sourceLeaf("")
        val shiftedChild = emptyChild.copy(inlineStyle = checkNotNull(emptyChild.inlineStyle).copy(
            baselineShift = InlineComputedLength(-64f, FontScaleBasis.CssPx)))
        val unshiftedOwner = action(listOf(emptyChild), paintPolicy = null)
        val shiftedOwner = unshiftedOwner.copy(inlineActionGroup = InlineActionGroup(listOf(shiftedChild)))
        val unshiftedCase = make(unshiftedOwner)
        val shiftedCase = make(shiftedOwner)
        val unshifted = build(unshiftedCase, 80)
        val shifted = build(shiftedCase, 80)
        val firstBand = verify(unshiftedCase, unshifted).single()
        val shiftedBand = verify(shiftedCase, shifted).single()
        val firstBaseline = unshifted.nativeRubyRaw.nativeRubyLineBaseline(0)
        val shiftedBaseline = shifted.nativeRubyRaw.nativeRubyLineBaseline(0)
        val own = shiftedCase.declaring.fontMetrics
        val ownCenter = (own.ascent + own.descent) / 2f
        assertEquals(firstBand.top - firstBaseline, shiftedBand.top - shiftedBaseline, .01f)
        assertEquals(firstBand.bottom - firstBaseline, shiftedBand.bottom - shiftedBaseline, .01f)
        assertEquals(shiftedBaseline + ownCenter - 24f, shiftedBand.top, .01f)
        assertEquals(shiftedBaseline + ownCenter + 24f, shiftedBand.bottom, .01f)
        assertEquals(48f, shiftedBand.height(), .01f)
        val firstUsed = unshifted.nativeRubyRaw.nativeUsedLineMetrics(0)
        val shiftedUsed = shifted.nativeRubyRaw.nativeUsedLineMetrics(0)
        assertEquals(firstUsed.top, shiftedUsed.top, .01f)
        assertEquals(firstUsed.bottom + 64f, shiftedUsed.bottom, .01f)
        assertEquals(shiftedBaseline + 64f, shifted.nativeRubyRaw.baselineForOffset(0), .01f)
        val childMetric = shiftedCase.prepared.source.getSpans(0, 0, NativeAuthoredInlineMetrics::class.java).single()
        assertEquals(NativeLineHeightPolicy.Pixels(48f), childMetric.policy)
        assertEquals(64f, childMetric.primary.baselineShift, 0f)
        assertEquals(Spanned.SPAN_MARK_MARK, shiftedCase.prepared.source.getSpanFlags(childMetric))
        val childShift = shiftedCase.prepared.source.getSpans(0, 0, NativeAuthoredBaselineShift::class.java).single()
        assertEquals(64f, childShift.shift, 0f)
        assertEquals(Spanned.SPAN_MARK_MARK, shiftedCase.prepared.source.getSpanFlags(childShift))
        assertSame(shiftedChild, checkNotNull(shiftedOwner.inlineActionGroup).spans.single())
        assertEquals(-64f, checkNotNull(checkNotNull(shiftedChild.inlineStyle).baselineShift).value, 0f)
        assertEquals("", shifted.text.toString())
        assertTrue(shifted.characterRects(0, 0).isEmpty())
        assertTrue(shifted.rectsForRange(0, 0).isEmpty())
        assertFalse(shifted.nodes.single().contains(shiftedBand.left, shiftedBand.centerY()))
        val emptyPaint = image(shifted)
        try {
            for (y in 0 until emptyPaint.height) for (x in 0 until emptyPaint.width)
                assertEquals(0, Color.alpha(emptyPaint.getPixel(x, y)))
        } finally { emptyPaint.recycle() }

        fun refused(owner: Span, reason: String) {
            try { build(make(owner), 1200); fail("Expected explicit native refusal: $reason") }
            catch (failure: UnsupportedFloatLayout) { assertTrue(failure.message.orEmpty().contains(reason)) }
        }
        refused(action(listOf(padding)), "annotation")
        val inside = action(listOf(sourceLeaf("inner")))
        val enclosing = ruby(listOf(base(listOf(inside))), emptyList())
        try {
            build(make(inside, rootSpans = listOf(enclosing)), 1200)
            fail("An action inside a native Ruby row must retain its explicit paint-capability refusal")
        } catch (failure: UnsupportedFloatLayout) {
            assertTrue(failure.message.orEmpty().contains("action", ignoreCase = true))
        }
    }

    @Test fun inlineBoxesKeepNativeEdgeAdvancesSlicePaintAndOriginalActionRanges() {
        val rootPaint = paint(color = Color.BLUE)
        val rootPolicy = NativeLineHeightPolicy.Pixels(24f)
        val callbacks = mutableListOf<Span>()
        val zero = StyleLength(StyleLengthUnit.Px, 0f)
        val one = StyleLength(StyleLengthUnit.Px, 1f)
        val none = InlineBoxBorderEdge.None
        val blue = LinkState("#0000ff", false)
        val red = LinkState("#ff0000", false)
        val linkPolicy = LinkPaint(blue, blue, red, red, blue, blue, red, red, underlineOnFocus = true)
        fun sourceLeaf(value: String, action: Boolean = false, scale: Float = 1f,
            superscript: Boolean = false, italic: Boolean = false, direction: String = "") =
            Span(if (action) "link" else "text", value, if (action) "child-source" else "",
                fontScale = scale, fontScaleBasis = FontScaleBasis.NormalBody, language = "ja",
                superscript = superscript, italic = italic, direction = direction,
                foreground = "#0000ff", inlineStyle = InlineTextStyle(fontNormalized = true))
        val overlay = InlineBoxOverlay(InlineBoxInsets(top = InlineBoxInset(StyleWidthUnit.Px, 0f),
            bottom = InlineBoxInset(StyleWidthUnit.Percent, 67f), right = InlineBoxInset(StyleWidthUnit.Percent, 0f)),
            InlineBoxBorderEdges(none, InlineBoxBorderEdge.Solid(one, InlineBoxColor.Rgb("#ff0000")), none, none))
        fun sourceBox(children: List<Span>, edges: StyleEdges = StyleEdges(one, one, one, one),
            overlays: List<InlineBoxOverlay> = listOf(overlay), action: Boolean = false,
            decorate: Boolean = false, scale: Float = 1f,
            borders: InlineBoxBorderEdges = InlineBoxBorderEdges(
                InlineBoxBorderEdge.Solid(one, InlineBoxColor.Rgb("#000000")), none, none, none)) =
            Span(if (action) "link" else "text", "", if (action) "box-source" else "",
                fontScale = scale, fontScaleBasis = FontScaleBasis.NormalBody, language = "ja",
                foreground = "#0000ff", background = "#00ff00", linkPaint = if (action) linkPolicy else null,
                inlineStyle = InlineTextStyle(fontNormalized = true, cursor = InlineCursor.Help,
                    decoration = if (decorate) InlineUnderline(InlineUnderlineStyle.Solid,
                        thickness = StyleLength(StyleLengthUnit.Px, 2f)) else null),
                inlineBoxGroup = InlineBoxGroup(edges, borders, overlays, children))
        fun sourceAction(child: Span) = Span("link", "", "ancestor-source", foreground = "#0000ff",
            fontScale = 1f, fontScaleBasis = FontScaleBasis.NormalBody, language = "ja", linkPaint = linkPolicy,
            inlineStyle = InlineTextStyle(fontNormalized = true), inlineActionGroup = InlineActionGroup(listOf(child)))
        data class Value(val original: List<Span>, val owner: Span, val range: RubyTextRange,
            val key: NativeInlineBoxOwner, val projection: RubyTextProjection, val prepared: NativeRubyPreparedSource,
            val source: Spanned, val formats: Map<String, NativeRubyGroupFormat>, val state: NativeMissingLinkPaint?,
            val action: Span?, val actionRange: RubyTextRange?, val actionKey: NativeInlineActionOwner?,
            val callback: () -> Unit, val direction: android.text.TextDirectionHeuristic)
        fun resolve(span: Span): TextPaint = paint(span.fontScale ?: 1f, Color.BLUE).apply {
            typeface = Typeface.create(Typeface.MONOSPACE, if (span.italic) Typeface.ITALIC else Typeface.NORMAL)
            textLocale = Locale.forLanguageTag(span.language.ifEmpty { "ja" })
            if (span.superscript) baselineShift = scriptShift(this).toInt()
        }
        fun make(owner: Span, ancestor: Span? = null, rtl: Boolean = false,
            before: List<Span> = emptyList(), after: List<Span> = emptyList()): Value {
            val original = before + (ancestor ?: owner) + after
            val projection = rubyGraphicalProjection(original)
            val range = projection.ranges.single { it.role == RubyTextRole.BoxGroup && it.span === owner }
            val key = NativeInlineBoxOwner(owner, range.path)
            val action = ancestor ?: owner.takeIf { it.kind == "link" }
                ?: checkNotNull(owner.inlineBoxGroup).spans.singleOrNull { it.kind == "link" }
            val actionRange = action?.let { item -> projection.ranges.single { it.span === item &&
                it.role in setOf(RubyTextRole.ActionGroup, RubyTextRole.BoxGroup, RubyTextRole.Text) } }
            val actionKey = actionRange?.takeIf { it.role in setOf(RubyTextRole.ActionGroup, RubyTextRole.BoxGroup) }
                ?.let { NativeInlineActionOwner(checkNotNull(action), it.path) }
            val state = action?.linkPaint?.let { NativeMissingLinkPaint(it, visited = false) }
            val direction = if (rtl) TextDirectionHeuristics.RTL else TextDirectionHeuristics.LTR
            val groups = projection.ranges.filter { it.role in setOf(RubyTextRole.BoxGroup, RubyTextRole.ActionGroup) }
                .associate { part ->
                    val span = checkNotNull(part.span)
                    val declaring = resolve(span).apply { baselineShift = 0; bgColor = span.background?.let(Color::parseColor) ?: 0 }
                    fun length(value: StyleLength): Float = value.value * if (value.unit == StyleLengthUnit.Px) 1f else declaring.textSize
                    fun border(value: InlineBoxBorderEdge): NativeInlineBoxBorder {
                        val width = when (value) {
                            InlineBoxBorderEdge.None, InlineBoxBorderEdge.Hidden -> 0f
                            is InlineBoxBorderEdge.Solid -> length(value.width)
                            is InlineBoxBorderEdge.Dotted -> length(value.width)
                        }
                        val color = when (value) {
                            is InlineBoxBorderEdge.Solid -> value.color
                            is InlineBoxBorderEdge.Dotted -> value.color
                            else -> InlineBoxColor.Transparent
                        }
                        return NativeInlineBoxBorder(width, when (color) {
                            InlineBoxColor.CurrentColor -> null
                            InlineBoxColor.Transparent -> Color.TRANSPARENT
                            is InlineBoxColor.Rgb -> Color.parseColor(color.value)
                            is InlineBoxColor.LightDark -> Color.parseColor(color.light)
                        }, value is InlineBoxBorderEdge.Dotted)
                    }
                    fun borders(value: InlineBoxBorderEdges) = NativeInlineBoxBorders(border(value.top), border(value.right),
                        border(value.bottom), border(value.left))
                    val group = span.inlineBoxGroup
                    val box = group?.let { value -> NativeInlineBoxFormat(key,
                        NativeInlineBoxEdges(length(value.padding.top), length(value.padding.right),
                            length(value.padding.bottom), length(value.padding.left)), borders(value.border),
                        value.overlays.map { decoration ->
                            fun inset(value: InlineBoxInset?): NativeInlineBoxInset? = value?.let {
                                NativeInlineBoxInset(it.value * if (it.unit == StyleWidthUnit.Em) declaring.textSize else 1f,
                                    it.unit == StyleWidthUnit.Percent)
                            }
                            NativeInlineBoxOverlay(NativeInlineBoxInsets(inset(decoration.insets.top), inset(decoration.insets.right),
                                inset(decoration.insets.bottom), inset(decoration.insets.left)), borders(decoration.border))
                        }, currentColorPaint = state) }
                    part.path to NativeRubyGroupFormat(declaring, direction, rootPolicy, sourceDirection = span.direction,
                        cursor = span.inlineStyle?.cursor,
                        underline = span.inlineStyle?.decoration?.let {
                            NativeAuthoredUnderline(it.style, it.color?.let(Color::parseColor), it.thickness?.let(::length))
                        }, actionPaint = if (span === action) state else null,
                        actionOwner = if (span === action) actionKey else null, box = box)
                }
            val logical = SpannableString(projection.text)
            logical.setSpan(NativeRunLineMetrics(NativePrimaryFontMetrics.from(rootPaint), rootPolicy, strut = true),
                0, logical.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            projection.ranges.filter { it.span != null && it.role !in setOf(RubyTextRole.BoxGroup, RubyTextRole.ActionGroup) }
                .forEach { part ->
                    val span = checkNotNull(part.span)
                    val child = resolve(span)
                    logical.setSpan(object : MetricAffectingSpan(), NativeInlineSafePaintSpan {
                        override fun updateMeasureState(paint: TextPaint) { paint.set(child) }
                        override fun updateDrawState(paint: TextPaint) { paint.set(child); state?.let { paint.color = it.appearance().color } }
                    }, part.start, part.end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                    logical.setSpan(NativeRunLineMetrics(NativePrimaryFontMetrics.from(child), rootPolicy),
                        part.start, part.end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                }
            val prepared = NativeRubyPreparedSource(projection, SpannedString(logical), rootPaint, direction, groups)
            val source = SpannableString(logical).apply { setSpan(prepared, 0, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE) }
            return Value(original, owner, range, key, projection, prepared, SpannedString(source), groups, state,
                action, actionRange, actionKey, { if (action != null) callbacks += action }, direction)
        }
        fun build(value: Value, width: Int): NativeFloatGeometry = NativeFloatGeometry.build(value.source,
            rootPaint, width, emptyList(), textDirection = value.direction, nodeFactory = nodes@{ geometry ->
                val action = value.action ?: return@nodes emptyList()
                val range = checkNotNull(value.actionRange)
                val bounds = when {
                    value.actionKey != null -> checkNotNull(geometry.inlineActionGroupRects(value.actionKey, range.start, range.end))
                    else -> checkNotNull(geometry.inlineBoxChildActionRects(value.key, value.range.start, value.range.end,
                        range.start, range.end, geometry.rectsForRange(range.start, range.end)))
                }
                listOf(FloatInteractionNode(31, FloatInteractionKind.LINK, range.start, range.end, bounds,
                    value.projection.text.substring(range.start, range.end), null, value.callback, missingLinkPaint = value.state))
            })
        fun verify(value: Value, geometry: NativeFloatGeometry): List<RectF> {
            assertEquals(value.projection.text, geometry.text.toString())
            assertSame(value.projection, value.prepared.projection)
            assertSame(value.owner, value.range.span)
            assertSame(checkNotNull(value.owner.inlineBoxGroup).spans.first(),
                value.projection.ranges.first { it.role == RubyTextRole.Text && it.path.startsWith(value.range.path + "/") }.span)
            val boxes = checkNotNull(geometry.inlineBoxGroupRects(value.key, value.range.start, value.range.end))
            assertNull(geometry.inlineBoxGroupRects(NativeInlineBoxOwner(value.owner, value.key.path), value.range.start, value.range.end))
            assertTrue(boxes.isNotEmpty())
            if (value.action != null) {
                val node = geometry.nodes.single()
                assertSame(value.callback, node.onClick)
                if (value.action === value.owner) assertEquals(boxes, node.bounds)
                assertEquals(value.actionRange!!.start, node.start); assertEquals(value.actionRange.end, node.end)
                assertEquals(value.projection.text.substring(node.start, node.end), node.label)
                node.onClick!!.invoke()
                assertSame(value.action, callbacks.last())
            }
            for (offset in geometry.text.indices) {
                assertEquals(1, geometry.visualLineRanges(offset).count { offset in it.first until it.second })
                assertTrue(geometry.caretRect(offset).left.isFinite())
            }
            return boxes
        }
        fun plain(text: String, width: Int, direction: android.text.TextDirectionHeuristic = TextDirectionHeuristics.LTR): NativeFloatGeometry {
            val source = SpannableString(text).apply { setSpan(NativeRunLineMetrics(
                NativePrimaryFontMetrics.from(rootPaint), rootPolicy, strut = true), 0, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE) }
            return NativeFloatGeometry.build(source, rootPaint, width, emptyList(), textDirection = direction)
        }
        fun snapshotPixels(geometry: FloatTextGeometry): IntArray {
            val bitmap = Bitmap.createBitmap(768, 512, Bitmap.Config.ARGB_8888)
            var primary: Throwable? = null
            try {
                val canvas = Canvas(bitmap)
                canvas.translate(64f, 64f)
                geometry.paint(canvas)
                return IntArray(768 * 512).also { bitmap.getPixels(it, 0, 768, 0, 0, 768, 512) }
            } catch (failure: Throwable) { primary = failure; throw failure }
            finally { try { bitmap.recycle() } catch (cleanup: Throwable) {
                if (primary == null) throw cleanup else if (cleanup !== primary) primary.addSuppressed(cleanup)
            } }
        }
        fun changesInside(first: IntArray, second: IntArray, allowed: List<RectF>): Int {
            var changed = 0
            first.indices.forEach { index -> if (first[index] != second[index]) {
                val x = index % 768 - 64; val y = index / 768 - 64
                assertTrue("Unexpected pixel $x,$y", allowed.any { x + 1 > it.left && x < it.right && y + 1 > it.top && y < it.bottom })
                changed++
            } }
            assertTrue("Expected actual changed native paint", changed > 0)
            return changed
        }
        val body = sourceLeaf("ずれ")
        val original = sourceBox(listOf(body), action = true)
        val value = make(original)
        val wide = build(value, 200)
        val ownerBox = verify(value, wide).single()
        val reference = plain(body.text, 200)
        val primary = NativePrimaryFontMetrics.from(rootPaint)
        val baseline = wide.nativeRubyLineBaseline(0)
        val advance = reference.nativeInlineVisibleAdvance(0)
        sameRect(RectF(0f, baseline + primary.ascent - 2f, advance + 2f,
            baseline + primary.descent + 1f), ownerBox, 0f)
        assertEquals(reference.usedLineHeight(0), wide.usedLineHeight(0), 0f)
        val content = wide.rectsForRange(value.range.start, value.range.end)
        reference.characterRects(0, body.text.length).zip(wide.characterRects(0, body.text.length)).forEach { (a, b) ->
            sameRect(RectF(checkNotNull(a)).apply { offset(1f, 0f) }, checkNotNull(b), 0f)
        }
        for (offset in 0..body.text.length) sameRect(RectF(reference.caretRect(offset)).apply { offset(1f, 0f) }, wide.caretRect(offset), 0f)
        assertTrue(wide.nodes.single().contains(.5f, (ownerBox.top + ownerBox.bottom) / 2f))
        val withoutOverlay = make(original.copy(inlineBoxGroup = checkNotNull(original.inlineBoxGroup).copy(overlays = emptyList())))
        val plainBox = build(withoutOverlay, 200)
        val padding = RectF(ownerBox.left, ownerBox.top + 1f, ownerBox.right, ownerBox.bottom)
        val expectedOverlay = RectF(padding.right - 1f, padding.top, padding.right,
            padding.top + padding.height() * .33f)
        changesInside(snapshotPixels(plainBox), snapshotPixels(wide), listOf(expectedOverlay))
        val blackOverlay = overlay.copy(border = overlay.border.copy(right =
            InlineBoxBorderEdge.Solid(one, InlineBoxColor.Rgb("#000000"))))
        val redThenBlack = make(original.copy(inlineBoxGroup = checkNotNull(original.inlineBoxGroup)
            .copy(overlays = listOf(overlay, blackOverlay))))
        val blackThenRed = make(original.copy(inlineBoxGroup = checkNotNull(original.inlineBoxGroup)
            .copy(overlays = listOf(blackOverlay, overlay))))
        changesInside(snapshotPixels(build(redThenBlack, 200)), snapshotPixels(build(blackThenRed, 200)), listOf(expectedOverlay))
        assertTrue(wide.scrollableBounds.top <= ownerBox.top)
        assertTrue(wide.ordinaryPaintBounds.any { it.left <= expectedOverlay.left && it.right >= expectedOverlay.right &&
            it.top <= expectedOverlay.top && it.bottom >= expectedOverlay.bottom })

        val firstAdvance = plain(body.text.substring(0, 1), 200).nativeInlineVisibleAdvance(0)
        val narrowWidth = ceil(firstAdvance + 1f).toInt()
        assertTrue(narrowWidth < advance + 2f)
        val narrow = build(value, narrowWidth)
        val sliced = verify(value, narrow)
        assertEquals(2, sliced.size)
        assertEquals(2, narrow.shapedLineCount)
        assertEquals(firstAdvance + 1f, narrow.nativeLineAdvance(0), 0f)
        val secondAdvance = plain(body.text.substring(1), 200).nativeInlineVisibleAdvance(0)
        assertEquals(secondAdvance + 1f, narrow.nativeLineAdvance(1), 0f)
        assertEquals(1f, narrow.characterRects(0, 1).single()!!.left - reference.characterRects(0, 1).single()!!.left, 0f)
        assertEquals(0f, narrow.characterRects(1, 1).single()!!.left, 0f)
        val narrowPlain = plain(body.text, narrowWidth)
        assertEquals(narrowPlain.height, narrow.height)
        sameRect(ownerBox, verify(value, build(value, 200)).single(), 0f)

        var originalSelectionCrossesEdge = false
        for (scale in listOf(1f, 1.125f)) {
            val child = sourceLeaf("thin", action = true, scale = scale)
            val childValue = make(sourceBox(listOf(child), edges = StyleEdges(zero,
                StyleLength(StyleLengthUnit.Px, .125f), zero, StyleLength(StyleLengthUnit.Em, .015625f)),
                overlays = emptyList(), scale = scale))
            val childGeometry = build(childValue, 200)
            val childBox = verify(childValue, childGeometry).single()
            val childNode = childGeometry.nodes.single()
            val originalRects = childGeometry.rectsForRange(0, child.text.length)
            val childY = originalRects.first().centerY()
            val leftPixels = .015625f * bodyPixels * scale
            val rightMidpoint = childBox.right - .0625f
            originalSelectionCrossesEdge = originalSelectionCrossesEdge || originalRects.any { it.contains(rightMidpoint, childY) }
            assertFalse(childNode.contains(childBox.left + leftPixels / 2f, childY))
            assertFalse(childNode.contains(rightMidpoint, childY))
            assertTrue(childNode.bounds.all { it.left >= childBox.left + leftPixels && it.right <= childBox.right - .125f })
            assertTrue(childNode.contains(childBox.centerX(), childY))
            val wrong = NativeInlineBoxOwner(childValue.owner, childValue.key.path)
            assertNull(childGeometry.inlineBoxChildActionRects(wrong, 0, child.text.length, 0, child.text.length, childNode.bounds))
        }
        assertTrue("The unmodified native selection must actually cross the thin right edge", originalSelectionCrossesEdge)

        val richOwner = sourceBox(listOf(sourceLeaf("ず"), sourceLeaf("れ", scale = .75f, superscript = true, italic = true)),
            overlays = emptyList())
        val rich = make(richOwner)
        val richGeometry = build(rich, 200)
        val richBox = verify(rich, richGeometry).single()
        val richBaseline = richGeometry.nativeRubyLineBaseline(0)
        assertEquals(richBaseline + primary.ascent - 2f, richBox.top, 0f)
        assertEquals(richBaseline + primary.descent + 1f, richBox.bottom, 0f)
        assertTrue(richGeometry.characterRects(1, 1).single()!!.top < richGeometry.characterRects(0, 1).single()!!.top)
        assertEquals(InlineCursor.Help, richGeometry.cursorAt(richBox.left + .5f, richBox.centerY()))
        val verticalPaddingX = richBox.left + .5f
        val verticalPaddingY = richBox.top + 1.5f // After the 1px border, inside the original 1px top padding.
        assertFalse(richGeometry.rectsForRange(0, richGeometry.text.length).any { it.contains(verticalPaddingX, verticalPaddingY) })
        assertEquals(InlineCursor.Help, richGeometry.cursorAt(verticalPaddingX, verticalPaddingY))
        assertTrue(richGeometry.containsInteraction(verticalPaddingX, verticalPaddingY))

        val rtlBody = sourceLeaf("אב")
        val symmetric = make(sourceBox(listOf(rtlBody), overlays = emptyList()))
        verify(symmetric, build(symmetric, 200))
        val asymmetricOwner = sourceBox(listOf(rtlBody), edges = StyleEdges(zero, zero, zero, one),
            overlays = emptyList(), borders = InlineBoxBorderEdges(none, none, none, none))
        val asymmetric = make(asymmetricOwner)
        try { build(asymmetric, 200); fail("Asymmetric bidi edge must retain its actual shaping affinity") }
        catch (failure: UnsupportedFloatLayout) { assertEquals("Inline box edge shaping affinity is unavailable", failure.message) }
        verify(symmetric, build(symmetric, 200))

        val decorated = sourceBox(listOf(sourceLeaf("ずれ")), overlays = emptyList(), decorate = true,
            borders = InlineBoxBorderEdges(InlineBoxBorderEdge.Solid(one, InlineBoxColor.CurrentColor), none, none, none))
        val ancestor = sourceAction(decorated)
        val styled = make(decorated, ancestor)
        val styledGeometry = build(styled, 200)
        val styledBox = verify(styled, styledGeometry).single()
        val state = checkNotNull(styled.state)
        val beforeFocus = snapshotPixels(styledGeometry)
        state.focused = true
        val afterFocus = snapshotPixels(styledGeometry)
        val decorationY = styledGeometry.nativeRubyLineBaseline(0) + rootPaint.underlinePosition
        val ownThickness = 2f
        val ancestorThickness = rootPaint.underlineThickness
        val contentUnderline = RectF(styledBox.left + 1f, decorationY, styledBox.right - 1f, decorationY + ownThickness)
        val noDecorationBox = decorated.copy(inlineStyle = checkNotNull(decorated.inlineStyle).copy(decoration = null))
        val noDecoration = make(noDecorationBox, sourceAction(noDecorationBox))
        val noDecorationGeometry = build(noDecoration, 200)
        val noDecorationPixels = snapshotPixels(noDecorationGeometry)
        changesInside(noDecorationPixels, beforeFocus, listOf(contentUnderline))
        assertTrue(beforeFocus.indices.any { Color.blue(beforeFocus[it]) > Color.blue(noDecorationPixels[it]) })
        val edgeBands = listOf(RectF(styledBox.left, decorationY, styledBox.left + 1f, decorationY + ancestorThickness),
            RectF(styledBox.right - 1f, decorationY, styledBox.right, decorationY + ancestorThickness))
        changesInside(beforeFocus, afterFocus, listOf(RectF(styledBox.left, decorationY,
            styledBox.right, decorationY + maxOf(ownThickness, ancestorThickness))))
        assertTrue(edgeBands.any { area -> beforeFocus.indices.any { index ->
            val x = index % 768 - 64; val y = index / 768 - 64
            x + 1 > area.left && x < area.right && y + 1 > area.top && y < area.bottom && beforeFocus[index] != afterFocus[index]
        } })
        state.focused = false
        assertArrayEquals(beforeFocus, snapshotPixels(styledGeometry))
        state.active = true
        val activePixels = snapshotPixels(styledGeometry)
        assertFalse(beforeFocus.contentEquals(activePixels))
        checkNotNull(noDecoration.state).active = true
        val noDecorationActive = snapshotPixels(noDecorationGeometry)
        changesInside(noDecorationActive, activePixels, listOf(contentUnderline))
        assertTrue(activePixels.indices.any { Color.red(activePixels[it]) > Color.red(noDecorationActive[it]) })
        val topBand = RectF(styledBox.left, styledBox.top, styledBox.right, styledBox.top + 1f)
        assertTrue(beforeFocus.indices.any { index ->
            val x = index % 768 - 64; val y = index / 768 - 64
            x + 1 > topBand.left && x < topBand.right && y + 1 > topBand.top && y < topBand.bottom &&
                Color.red(activePixels[index]) > Color.red(beforeFocus[index])
        })
        state.active = false
        assertArrayEquals(beforeFocus, snapshotPixels(styledGeometry))
        assertSame(ancestor, styled.action)
        assertTrue(styledGeometry.nodes.single().contains(styledBox.left + .5f, styledBox.centerY()))
        assertEquals(content.size, wide.rectsForRange(0, body.text.length).size)

        val solverBorders = NativeInlineBoxBorders(NativeInlineBoxBorder(1f, null), NativeInlineBoxBorder(3f, null),
            NativeInlineBoxBorder(4f, null), NativeInlineBoxBorder(2f, null))
        val overconstrained = NativeInlineBoxOverlay(NativeInlineBoxInsets(NativeInlineBoxInset(3f, false),
            NativeInlineBoxInset(70f, false), NativeInlineBoxInset(40f, false), NativeInlineBoxInset(-4f, false)), solverBorders)
        val containing = RectF(10f, 20f, 60f, 40f)
        sameRect(RectF(6f, 23f, 11f, 28f), nativeInlineBoxOverlayRect(overconstrained, containing, false), 0f)
        sameRect(RectF(-15f, 23f, -10f, 28f), nativeInlineBoxOverlayRect(overconstrained, containing, true), 0f)
        val definiteEnd = NativeInlineBoxOverlay(NativeInlineBoxInsets(top = null,
            right = NativeInlineBoxInset(-4f, false), bottom = NativeInlineBoxInset(-3f, false), left = null), solverBorders)
        sameRect(RectF(59f, 38f, 64f, 43f), nativeInlineBoxOverlayRect(definiteEnd, containing, false), 0f)
        sameRect(RectF(59f, 38f, 64f, 43f), nativeInlineBoxOverlayRect(definiteEnd, containing, true), 0f)

        val forcedBreakOwner = sourceBox(listOf(sourceLeaf("ず\nれ")), overlays = emptyList())
        val forcedBreak = make(forcedBreakOwner)
        assertEquals("ず\nれ", forcedBreak.projection.text)
        try { build(forcedBreak, 200); fail("An original forced break requires a supported inline box fragmentation path") }
        catch (failure: UnsupportedFloatLayout) { assertEquals("Inline box forced text breaks are unavailable", failure.message) }
        assertEquals("ず\nれ", forcedBreak.source.toString())
        assertSame(forcedBreakOwner, forcedBreak.range.span)
        assertEquals(3, forcedBreak.range.end - forcedBreak.range.start)
        verify(value, build(value, 200))

        val zeroFontOwner = sourceBox(listOf(sourceLeaf("ずれ", scale = 0f)), scale = 0f, overlays = emptyList())
        val zeroFont = make(zeroFontOwner)
        assertEquals("ずれ", zeroFont.projection.text)
        try { build(zeroFont, 200); fail("A nonempty zero-advance box needs a proved allocation") }
        catch (failure: UnsupportedFloatLayout) { assertEquals("Inline box zero-advance fragment allocation is unavailable", failure.message) }
        assertEquals("ずれ", zeroFont.source.toString())
        verify(value, build(value, 200))
        // Capture owns actual native shaping and visible-line coordinates, independently
        // of the model-backed box fixtures above. No source character is inserted.
        run {
            val capArabicText = "سلام"
            val capArabicCut = 1 // The original sin/lam joining boundary, not a surrogate or grapheme interior.
            val capArabicPaint = android.text.TextPaint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply {
                typeface = android.graphics.Typeface.create("sans-serif", android.graphics.Typeface.NORMAL)
                textSize = 32f
                textLocale = java.util.Locale.forLanguageTag("ar")
                color = android.graphics.Color.BLUE
            }
            fun capBuild(source: android.text.Spanned, paint: android.text.TextPaint, width: Int = 320) = NativeFloatGeometry.build(
                source, paint, width, emptyList(), textDirection = android.text.TextDirectionHeuristics.RTL,
                includeFontPadding = false)
            fun capRecycle(primary: Throwable?, vararg bitmaps: android.graphics.Bitmap?) {
                var failure = primary
                for (bitmap in bitmaps) if (bitmap != null) {
                    try { bitmap.recycle() } catch (cleanup: Throwable) {
                        val previous = failure
                        if (previous == null) failure = cleanup
                        else if (cleanup !== previous) previous.addSuppressed(cleanup)
                    }
                }
                if (primary == null) failure?.let { throw it }
            }
            fun capRaster(raw: NativeFloatGeometry, draw: (android.graphics.Canvas) -> Unit): android.graphics.Bitmap {
                val bitmap = android.graphics.Bitmap.createBitmap(raw.width + 32, raw.height + 32,
                    android.graphics.Bitmap.Config.ARGB_8888)
                try {
                    val canvas = android.graphics.Canvas(bitmap)
                    canvas.translate(16f, 16f)
                    draw(canvas)
                    return bitmap
                } catch (primary: Throwable) {
                    capRecycle(primary, bitmap)
                    throw primary
                }
            }
            fun capAssertReplay(label: String, raw: NativeFloatGeometry, mapped: NativeInlineMappedLine) {
                val native = capRaster(raw) { raw.paint(it) }
                var replay: android.graphics.Bitmap? = null
                var primary: Throwable? = null
                try {
                    val captured = capRaster(raw) { mapped.paint(it) }.also { replay = it }
                    val pixels = IntArray(native.width * native.height)
                    native.getPixels(pixels, 0, native.width, 0, 0, native.width, native.height)
                    assertTrue("$label has actual native ink", pixels.any { it ushr 24 != 0 })
                    assertTrue("$label preserves the actual native raster", native.sameAs(captured))
                } catch (failure: Throwable) { primary = failure; throw failure }
                finally { capRecycle(primary, replay, native) }
            }
            val capArabicSource = android.text.SpannedString(capArabicText)
            val capArabicRaw = capBuild(capArabicSource, capArabicPaint)
            assertEquals(1, capArabicRaw.shapedLineCount)
            assertEquals(capArabicText, capArabicRaw.text.toString())
            val capUntouched = nativeInlineLineCapture(capArabicRaw, 0, emptyList()).mapped(emptyList())
            capAssertReplay("Untouched Arabic capture", capArabicRaw, capUntouched)
            val capRefusal = try {
                nativeInlineLineCapture(capArabicRaw, 0, listOf(capArabicCut), setOf(capArabicCut))
                null
            } catch (failure: UnsupportedFloatLayout) { failure }
            assertNotNull("An unbounded Arabic joining run cannot acquire a shaping cut", capRefusal)
            assertEquals("Inline edge changes required native boundary shaping", capRefusal?.message)

            // Two actual nonempty metric spans establish the cut before native shaping.
            // Capture must prove and replay that selected source, rather than editing glyphs afterward.
            val capBoundedSource = android.text.SpannedString(android.text.SpannableString(capArabicText).apply {
                setSpan(NativeInlineBoxBoundarySpan(), 0, capArabicCut, android.text.Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                setSpan(NativeInlineBoxBoundarySpan(), capArabicCut, length, android.text.Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            })
            assertEquals(capArabicText, capBoundedSource.toString())
            val capBoundedRaw = capBuild(capBoundedSource, capArabicPaint)
            assertEquals(1, capBoundedRaw.shapedLineCount)
            val capBoundedCapture = nativeInlineLineCapture(capBoundedRaw, 0,
                listOf(capArabicCut), setOf(capArabicCut))
            assertTrue("Native dispatch retains the first bounded run", capBoundedCapture.pieces.any { it.end == capArabicCut })
            assertTrue("Native dispatch retains the following bounded run", capBoundedCapture.pieces.any { it.start == capArabicCut })
            capAssertReplay("Pre-bounded Arabic capture", capBoundedRaw, capBoundedCapture.mapped(emptyList()))
            val capJoinedRaster = capRaster(capArabicRaw) { capArabicRaw.paint(it) }
            var capBrokenRaster: android.graphics.Bitmap? = null
            var capRasterFailure: Throwable? = null
            try {
                val captured = capRaster(capBoundedRaw) { capBoundedRaw.paint(it) }.also { capBrokenRaster = it }
                assertEquals(capJoinedRaster.width, captured.width)
                assertEquals(capJoinedRaster.height, captured.height)
                assertFalse("The real source boundary changes Arabic joining", capJoinedRaster.sameAs(captured))
            } catch (failure: Throwable) { capRasterFailure = failure; throw failure }
            finally { capRecycle(capRasterFailure, capBrokenRaster, capJoinedRaster) }

            // A separate public native Layout supplies the omitted suffix and the
            // Float visible selection path. Raw whitespace spelling is not its authority.
            val capRtlSource = android.text.SpannedString("אבג   דהו")
            val capRtlPaint = android.text.TextPaint(capArabicPaint).apply {
                textLocale = java.util.Locale.forLanguageTag("he")
            }
            val capRtlWidth = kotlin.math.ceil(capRtlPaint.measureText("אבג   ").toDouble()).toInt()
            assertTrue("Native prefix measurement supplies a positive soft-wrap width", capRtlWidth > 0)
            val capRtlRaw = capBuild(capRtlSource, capRtlPaint, capRtlWidth)
            val capReference = android.text.StaticLayout.Builder.obtain(capRtlSource, 0, capRtlSource.length,
                android.text.TextPaint(capRtlPaint), capRtlWidth)
                .setAlignment(android.text.Layout.Alignment.ALIGN_NORMAL)
                .setTextDirection(android.text.TextDirectionHeuristics.RTL)
                .setIncludePad(false).setLineSpacing(0f, 1f).setUseLineSpacingFromFallbacks(false)
                .setBreakStrategy(android.graphics.text.LineBreaker.BREAK_STRATEGY_SIMPLE)
                .setHyphenationFrequency(android.text.Layout.HYPHENATION_FREQUENCY_NONE).build()
            assertEquals(2, capReference.lineCount)
            assertEquals(capReference.lineCount, capRtlRaw.shapedLineCount)
            val capFirst = capReference.getLineStart(0)
            val capEnd = capReference.getLineEnd(0)
            val capVisibleEnd = capReference.getLineVisibleEnd(0)
            assertTrue("Native Layout actually omits a nonempty suffix", capVisibleEnd in (capFirst + 1) until capEnd)
            assertTrue("The omitted suffix has real native width", capReference.getLineWidth(0) > capReference.getLineMax(0))
            assertEquals(capFirst to capEnd, capRtlRaw.nativeRangeOfLine(0))
            assertEquals(capVisibleEnd, capRtlRaw.nativeInlineVisibleEnd(0))
            val capVisiblePath = android.graphics.Path()
            capReference.getSelectionPath(capFirst, capVisibleEnd, capVisiblePath)
            assertFalse("The native visible interval has a real selection path", capVisiblePath.isEmpty)
            val capVisibleBounds = android.graphics.RectF().also { capVisiblePath.computeBounds(it, true) }
            val capFullBounds = requireNotNull(capRtlRaw.nativeRubyLineAdvanceBounds(0))
            assertTrue("RTL trailing space moves the full-selection origin left",
                capFullBounds.left < capVisibleBounds.left)
            val capRtlMapped = nativeInlineLineCapture(capRtlRaw, 0, emptyList()).mapped(emptyList())
            val capMappedAdvance = capRtlMapped.advanceBounds()
            assertEquals("Visible origin is independent of the full-selection origin",
                capVisibleBounds.left, capMappedAdvance.left, 0f)
            assertEquals("Visible right edge remains the native selected edge",
                capVisibleBounds.right, capMappedAdvance.right, 0f)
            assertEquals("Omitted source retains its actual selected-line query",
                capRtlRaw.nativeRubyLineRects(0, capVisibleEnd, capEnd),
                capRtlMapped.rectsForRange(capVisibleEnd, capEnd))
            assertEquals("Omitted source retains its selected-line terminal caret",
                capRtlRaw.nativeRubyLineCaret(0, capEnd),
                capRtlMapped.caretRect(capEnd, NativeInlineBoundaryAffinity.Following))
        }
    }

    @Test
    fun positionedInlineImagesKeepNativeFractionalRowsAndOriginalSourceActions() {
        // Synthetic resolved pixels: these values do not stand in for an unearned source receipt.
        val draws = mutableListOf<Int>()
        val clicks = mutableListOf<Int>()
        var legacyMeasurements = 0
        class Image(val id: Int, val offset: Int, val w: Float, val h: Float,
            val placement: NativeImageOccurrencePlacement?, val scale: Float = 1f) :
            android.text.style.ReplacementSpan(), NativeFloatInlineImage, NativeNoWrapInlineImage {
            val action: () -> Unit = { clicks += id }
            override val nativeImageId: Int get() = id
            override val nativeImageSourceOffset: Int get() = offset
            override val nativeImageWidth: Float get() = w
            override val nativeImageHeight: Float get() = h
            override val nativeImageOccurrence: NativeImageOccurrencePlacement? get() = placement
            override val nativeUsedMetrics: NativeUsedLineMetrics get() = NativeUsedLineMetrics(-4f * scale, -4f * scale + h)
            override val nativeImageInkBounds: NativeFloatBounds get() = NativeFloatBounds(0f, 0f, w, h)
            override fun nativePaintBounds(lineTop: Float, lineBottom: Float): NativeFloatBounds =
                nativeImageInkBounds.translated(0f, nativeUsedMetrics.top)
            override fun drawNativeImage(canvas: Canvas, outer: RectF) {
                draws += id
                canvas.drawRect(outer, Paint().apply { color = if (id % 2 == 0) Color.RED else Color.BLUE })
            }
            override fun getSize(paint: Paint, text: CharSequence, start: Int, end: Int,
                fm: Paint.FontMetricsInt?): Int {
                check(placement == null) { "Positioned occurrence entered the integer replacement path" }
                legacyMeasurements++
                return ceil(w).toInt()
            }
            override fun draw(canvas: Canvas, text: CharSequence, start: Int, end: Int,
                x: Float, top: Int, y: Int, bottom: Int, paint: Paint) {
                check(placement == null)
                drawNativeImage(canvas, RectF(x, y + nativeUsedMetrics.top, x + w, y + nativeUsedMetrics.bottom))
            }
        }
        class Prepared(val raw: String, val images: List<Image>, val root: TextPaint,
            val nowrap: Boolean = false, val alignment: android.text.Layout.Alignment = android.text.Layout.Alignment.ALIGN_NORMAL) {
            val source: Spanned = SpannedString(SpannableString(raw).apply {
                setSpan(NativeRunLineMetrics(NativePrimaryFontMetrics.from(root),
                    NativeLineHeightPolicy.Pixels(root.textSize), strut = true), 0, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                setSpan(android.text.style.AlignmentSpan.Standard(alignment), 0, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                images.forEach { setSpan(it, it.offset, it.offset + 1, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE) }
                if (nowrap) setSpan(NativeAuthoredTextWrap(TextWrap.NoWrap, inheritedOwner = true,
                    sourceLineStarts = listOf(0)), 0, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            })
            fun build(width: Int, rtl: Boolean = false, exclusions: List<NativeFloatExclusion> = emptyList()): NativeFloatGeometry =
                NativeFloatGeometry.build(source, root, width, emptyList(), includeFontPadding = false,
                    textDirection = if (rtl) TextDirectionHeuristics.RTL else TextDirectionHeuristics.LTR,
                    carriedExclusions = exclusions, nodeFactory = { geometry -> images.map { image ->
                        val bounds = geometry.rectsForRange(image.offset, image.offset + 1)
                        FloatInteractionNode(image.id, FloatInteractionKind.IMAGE, image.offset, image.offset + 1,
                            bounds, "original image alt ${image.id}", "original tooltip", image.action,
                            focusPaint = NativeNodeFocusPaint.Fragments(bounds.map {
                                NativeNodeFocusPaint.Outline(RectF(it), 1f, Color.GREEN, 0f, 0f)
                            }))
                    } })
        }
        fun allImages(count: Int, width: Float, alignment: android.text.Layout.Alignment = android.text.Layout.Alignment.ALIGN_NORMAL,
            nowrap: Boolean = false): Prepared {
            val zero = NativeImageOccurrencePlacement(0f, 0f, 0f, 0f)
            return Prepared("\uFFFC".repeat(count), (0 until count).map { Image(it, it, width, 5f, zero) },
                paint(), nowrap, alignment)
        }
        fun nativeImageBreaks(prepared: Prepared, width: Float): List<Int> {
            val measured = android.graphics.text.MeasuredText.Builder(prepared.raw.toCharArray()).setComputeLayout(true)
                .setComputeHyphenation(false).apply {
                    prepared.images.forEach { image ->
                        val value = image.placement
                        val advance = ((value?.paddingLeft ?: 0f).toDouble() + image.w + (value?.paddingRight ?: 0f)).toFloat()
                        appendReplacementRun(prepared.root, 1, advance)
                    }
                }.build()
            val result = android.graphics.text.LineBreaker.Builder()
                .setBreakStrategy(android.graphics.text.LineBreaker.BREAK_STRATEGY_SIMPLE)
                .setHyphenationFrequency(android.graphics.text.LineBreaker.HYPHENATION_FREQUENCY_NONE).build()
                .computeLineBreaks(measured, android.graphics.text.LineBreaker.ParagraphConstraints().apply { setWidth(width) }, 0)
            return (0 until result.lineCount).map(result::getLineBreakOffset)
        }
        val decimal = allImages(10, .2f)
        val decimalRows = decimal.build(1)
        // Native accumulation may exceed a threshold before its result is rounded to Float.
        // The platform result, not a pixel epsilon or an assumed five-per-row cut, owns this oracle.
        assertEquals(nativeImageBreaks(decimal, 1f), (0 until decimalRows.shapedLineCount).map {
            decimalRows.nativeRangeOfLine(it).second
        })
        assertEquals(decimal.raw, decimalRows.text.toString())
        assertEquals(10, decimalRows.characterRects(0, 10).size)
        assertEquals(10, decimalRows.nodes.size)
        assertEquals(10, decimalRows.positionedGroups.size)
        decimal.images.forEach { image ->
            assertSame(image.action, decimalRows.nodes.single { it.id == image.id }.onClick)
            assertEquals(image.offset to image.offset + 1, decimalRows.nodes.single { it.id == image.id }.let { it.start to it.end })
            assertEquals(.2f, decimalRows.rectsForRange(image.offset, image.offset + 1).single().width(), .000001f)
        }
        assertEquals(0, legacyMeasurements)
        // Two distinct legal Float prefixes share an integer threshold; no integer
        // scaffold can certify this actual platform cut.
        assertEquals(2, nativeImageBreaks(allImages(3, .2f), .45f).first())
        assertEquals(ceil(.4f).toInt(), ceil(.6f).toInt())
        val quarters = allImages(4, .25f)
        val exact = quarters.build(1)
        assertEquals(1, exact.shapedLineCount)
        assertEquals(1f, exact.nativeSingleLineAdvance(), 0f)
        assertEquals(NativeWidthRange(1, 1), nativeTextWidthRange(quarters.source, quarters.root,
            textDirection = TextDirectionHeuristics.LTR))
        for (space in listOf('\u00a0', '\u202f')) {
            val glued = Prepared("\uFFFC$space", listOf(Image(25, 0, .25f, 5f,
                NativeImageOccurrencePlacement(0f, 0f, 0f, 0f))), paint())
            val ordinary = nativeTextWidthRange(glued.source, glued.root, textDirection = TextDirectionHeuristics.LTR)
            val expected = ceil(.25 + glued.root.measureText(space.toString()).toDouble()).toInt()
            assertEquals(expected, ordinary.maximum)
            assertEquals(expected, ordinary.minimum)
            val emergency = nativeTextWidthRange(glued.source, glued.root, breakWordMinimum = true,
                textDirection = TextDirectionHeuristics.LTR)
            assertTrue(emergency.minimum >= ceil(glued.root.measureText(space.toString())).toInt())
            assertEquals(ordinary.maximum, emergency.maximum)
        }
        val gapSource = SpannableString(quarters.source).apply {
            setSpan(NativeLineGap(3f), length - 1, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            setSpan(object : android.text.style.LineHeightSpan, NativeFloatRowMetricEffect {
                override fun chooseHeight(text: CharSequence, start: Int, end: Int, spanstartv: Int,
                    v: Int, fm: Paint.FontMetricsInt) { error("Float rows must consume the paired immutable gap") }
            }, length - 1, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
        val withGap = NativeFloatGeometry.build(gapSource, quarters.root, 1, emptyList(),
            textDirection = TextDirectionHeuristics.LTR, includeFontPadding = false)
        assertEquals(quarters.root.textSize + 3f, withGap.usedLineHeight(0), .00001f)
        val narrow = allImages(6, .2f).build(1)
        assertEquals(nativeImageBreaks(allImages(6, .2f), 1f),
            (0 until narrow.shapedLineCount).map { narrow.nativeRangeOfLine(it).second })
        assertTrue(narrow.shapedLineCount > 1)
        val noWrap = allImages(10, .2f, nowrap = true).build(1)
        assertEquals(1, noWrap.shapedLineCount)
        assertEquals(2f, noWrap.nativeSingleLineAdvance(), 0f)
        val floated = allImages(12, .25f).build(3, exclusions = listOf(
            NativeFloatExclusion(TableFloatSide.Left, NativeFloatBounds(0f, 0f, 2f, 12f))))
        assertEquals(listOf(4, 12), (0 until floated.shapedLineCount).map { floated.nativeRangeOfLine(it).second })
        assertEquals(1f, floated.nativeLineAvailableWidth(0), 0f)
        assertEquals(3f, floated.nativeLineAvailableWidth(1), 0f)
        assertEquals(2f, floated.characterRects(0, 1).single()!!.left, 0f)
        assertEquals(0f, floated.characterRects(4, 1).single()!!.left, 0f)
        for ((alignment, left) in listOf(android.text.Layout.Alignment.ALIGN_CENTER to 1f,
            android.text.Layout.Alignment.ALIGN_OPPOSITE to 2f)) {
            val aligned = allImages(4, .25f, alignment).build(3)
            assertEquals(left, aligned.characterRects(0, 1).single()!!.left, 0f)
            assertEquals(left + 1f, aligned.characterRects(3, 1).single()!!.right, 0f)
        }
        val rtl = quarters.build(3, rtl = true)
        assertEquals(2.75f, rtl.characterRects(0, 1).single()!!.left, 0f)
        assertEquals(2f, rtl.characterRects(3, 1).single()!!.left, 0f)
        assertEquals(rtl.characterRects(3, 1).single()!!.left, rtl.caretRect(4).left, 0f)
        assertEquals(1, rtl.visualOffset(0, -1))

        val mixedText = "a\u0301\uFFFCאב🙂Z"
        val imageOffset = mixedText.indexOf('\uFFFC')
        val stationaryImage = Image(20, imageOffset, 4.25f, 5f, NativeImageOccurrencePlacement(0f, 0f, .125f, .375f))
        val shiftedImage = Image(20, imageOffset, 4.25f, 5f, NativeImageOccurrencePlacement(-.5f, -3f, .125f, .375f))
        val stationary = Prepared(mixedText, listOf(stationaryImage), paint()).build(240)
        val shifted = Prepared(mixedText, listOf(shiftedImage), paint()).build(240)
        assertEquals(mixedText, shifted.text.toString())
        assertEquals(stationary.nativeSingleLineAdvance(), shifted.nativeSingleLineAdvance(), 0f)
        assertEquals(stationary.nativeUsedLineMetrics(0), shifted.nativeUsedLineMetrics(0))
        assertEquals(stationary.height, shifted.height)
        val stationaryCharacters = stationary.characterRects(0, mixedText.length)
        val shiftedCharacters = shifted.characterRects(0, mixedText.length)
        for (index in mixedText.indices) if (index != imageOffset) {
            val before = stationaryCharacters[index]; val after = shiftedCharacters[index]
            if (before == null) assertNull(after) else sameRect(before, checkNotNull(after), 0f)
        }
        val beforeImage = stationary.rectsForRange(imageOffset, imageOffset + 1).single()
        val afterImage = shifted.rectsForRange(imageOffset, imageOffset + 1).single()
        sameRect(RectF(beforeImage).apply { offset(-.5f, -3f) }, afterImage, 0f)
        sameRect(afterImage, shifted.nodes.single().bounds.single(), 0f)
        assertEquals(4.25f, afterImage.width(), 0f)
        sameRect(stationary.caretRect(imageOffset + 1), shifted.caretRect(imageOffset + 1), 0f)
        assertFalse(shifted.nodes.single().contains(afterImage.left - .0625f, afterImage.centerY()))
        assertEquals(20, shifted.interactionNodeAt(afterImage.centerX(), afterImage.centerY())!!.id)
        shifted.nodes.single().onClick!!.invoke()
        assertEquals(listOf(20), clicks)
        assertTrue(shifted.offsetForPosition(afterImage.centerX(), afterImage.centerY()) in imageOffset..imageOffset + 1)
        val wrapWidth = ceil(stationary.nativeSingleLineAdvance() / 2f).toInt().coerceAtLeast(1)
        val wrapped = Prepared(mixedText, listOf(shiftedImage), paint()).build(wrapWidth)
        assertTrue(wrapped.shapedLineCount > 1)
        assertEquals(mixedText, wrapped.text.toString())
        assertEquals(1, wrapped.nodes.size)
        assertEquals(mixedText.indices.toList(), (0 until wrapped.shapedLineCount).flatMap {
            val range = wrapped.nativeRangeOfLine(it); (range.first until range.second).toList()
        })
        sameRect(afterImage, Prepared(mixedText, listOf(shiftedImage), paint()).build(240)
            .nodes.single().bounds.single(), 0f)

        val overlapping = Prepared("\uFFFC\uFFFC", listOf(
            Image(30, 0, 4f, 5f, NativeImageOccurrencePlacement(4f, 0f, 0f, 0f)),
            Image(31, 1, 4f, 5f, NativeImageOccurrencePlacement(0f, 0f, 0f, 0f))), paint()).build(40)
        val overlap = overlapping.nodes.first().bounds.single()
        sameRect(overlap, overlapping.nodes.last().bounds.single(), 0f)
        assertEquals(31, overlapping.interactionNodeAt(overlap.centerX(), overlap.centerY())!!.id)
        val rtlOverlapping = Prepared("\uFFFC\uFFFC", listOf(
            Image(30, 0, 4f, 5f, NativeImageOccurrencePlacement(0f, 0f, 0f, 0f)),
            Image(31, 1, 4f, 5f, NativeImageOccurrencePlacement(4f, 0f, 0f, 0f))), paint()).build(8, rtl = true)
        val rtlOverlap = rtlOverlapping.nodes.first().bounds.single()
        sameRect(rtlOverlap, rtlOverlapping.nodes.last().bounds.single(), 0f)
        assertEquals(listOf(0, 1), rtlOverlapping.positionedGroups.map { it.sourceOffset })
        assertEquals(31, rtlOverlapping.interactionNodeAt(rtlOverlap.centerX(), rtlOverlap.centerY())!!.id)
        assertEquals(rtlOverlap.left, rtlOverlapping.caretRect(2).left, 0f)
        val bitmap = Bitmap.createBitmap(64, 64, Bitmap.Config.ARGB_8888)
        try {
            draws.clear(); overlapping.paintOrdinary(Canvas(bitmap)); assertTrue(draws.isEmpty())
            overlapping.paint(Canvas(bitmap)); assertEquals(listOf(30, 31), draws)
            assertEquals(Color.BLUE, bitmap.getPixel(overlap.centerX().toInt(), overlap.centerY().toInt()))
            bitmap.eraseColor(Color.TRANSPARENT); draws.clear(); rtlOverlapping.paint(Canvas(bitmap))
            assertEquals(listOf(30, 31), draws)
            assertEquals(Color.BLUE, bitmap.getPixel(rtlOverlap.centerX().toInt(), rtlOverlap.centerY().toInt()))
            val clip = RectF(overlap.left + 1f, overlap.top, overlap.right - 1f, overlap.bottom)
            var revealed: RectF? = null
            val placement = NativeTableBlockPlacement(RectF(0f, 0f, 40f, 40f), clip, 0f, 0f, 0f,
                40, 40, 0, 0, 0f, 0f, 40, 40, null,
                revealContentRect = { rect, complete -> revealed = RectF(rect); complete() })
            val viewport = NativeTableViewportGeometry(overlapping, placement)
            assertEquals(overlapping.text.toString(), viewport.text.toString())
            assertEquals(overlapping.nodes.map { it.id }, viewport.nodes.map { it.id })
            viewport.nodes.forEach { node -> sameRect(clip, node.bounds.single(), 0f) }
            assertNull(viewport.interactionNodeAt(overlap.left + .5f, overlap.centerY()))
            assertEquals(31, viewport.interactionNodeAt(clip.centerX(), clip.centerY())!!.id)
            assertEquals(2, viewport.positionedGroups.size)
            assertEquals(1, viewport.nodes.last().focusPaint!!.outlines().size)
            assertEquals(1f, viewport.nodes.last().focusPaint!!.outlines().single().width, 0f)
            sameRect(overlap, viewport.nodes.last().focusPaint!!.outlines().single().bounds, 0f)
            viewport.revealNode(31) {}
            sameRect(overlap, checkNotNull(revealed), 0f)
            bitmap.eraseColor(Color.TRANSPARENT); draws.clear(); viewport.paint(Canvas(bitmap))
            assertEquals(listOf(30, 31), draws)
            assertEquals(Color.TRANSPARENT, bitmap.getPixel(overlap.left.toInt(), overlap.centerY().toInt()))
            assertEquals(Color.BLUE, bitmap.getPixel(clip.centerX().toInt(), clip.centerY().toInt()))
        } finally { bitmap.recycle() }

        // A null-only occurrence remains on the old integer ReplacementSpan path.
        val legacyImage = Image(40, 0, .2f, 5f, null)
        val legacy = Prepared("\uFFFC", listOf(legacyImage), paint()).build(8)
        assertTrue(legacyMeasurements > 0)
        assertTrue(legacy.positionedGroups.isEmpty())
        assertEquals(1f, legacy.nativeSingleLineAdvance(), 0f)
        val mixed = Prepared("\uFFFC\uFFFC", listOf(legacyImage,
            Image(41, 1, .25f, 5f, NativeImageOccurrencePlacement(0f, 0f, 0f, 0f))), paint()).build(8)
        assertEquals(.45f, mixed.nativeSingleLineAdvance(), .000001f)
        assertEquals(1, mixed.positionedGroups.size)
        assertEquals(2, mixed.nodes.size)
        assertSame(legacyImage.action, mixed.nodes.first().onClick)
        val shiftedOnly = Prepared("\uFFFC", listOf(Image(50, 0, 4f, 5f,
            NativeImageOccurrencePlacement(2f, -3f, .5f, 1.5f))), paint()).build(20)
        val doubled = Prepared("\uFFFC", listOf(Image(50, 0, 8f, 10f,
            NativeImageOccurrencePlacement(4f, -6f, 1f, 3f), scale = 2f)), paint(2f)).build(40)
        assertEquals(shiftedOnly.nativeSingleLineAdvance() * 2f, doubled.nativeSingleLineAdvance(), 0f)
        val first = shiftedOnly.nodes.single().bounds.single(); val second = doubled.nodes.single().bounds.single()
        assertEquals(first.left * 2f, second.left, 0f)
        assertEquals(first.width() * 2f, second.width(), 0f)
        assertEquals(shiftedOnly.usedLineHeight(0) * 2f, doubled.usedLineHeight(0), .00001f)
        assertEquals("\uFFFC", doubled.text.toString())
    }

    @Test
    fun anonymousPositionedImagesRetainNativeOwnershipAndPaintAboveLaterOrdinaryActions() {
        val root = paint()
        val draws = mutableListOf<String>()
        val calls = mutableListOf<String>()
        var integerMeasurements = 0
        val imageAction: () -> Unit = { calls += "image" }
        val inlineAction: () -> Unit = { calls += "inline" }
        val laterAction: () -> Unit = { calls += "later" }
        class Image(val placement: NativeImageOccurrencePlacement?) : android.text.style.ReplacementSpan(),
            NativeFloatInlineImage, NativeNoWrapInlineImage {
            override val nativeImageId: Int get() = 71
            override val nativeImageSourceOffset: Int get() = 0
            override val nativeImageWidth: Float get() = 40f
            override val nativeImageHeight: Float get() = 20f
            override val nativeImageOccurrence: NativeImageOccurrencePlacement? get() = placement
            override val nativeUsedMetrics: NativeUsedLineMetrics get() = NativeUsedLineMetrics(-4f, 16f)
            override val nativeImageInkBounds: NativeFloatBounds get() = NativeFloatBounds(0f, 0f, 40f, 20f)
            override fun nativePaintBounds(lineTop: Float, lineBottom: Float): NativeFloatBounds =
                nativeImageInkBounds.translated(0f, nativeUsedMetrics.top)
            override fun drawNativeImage(canvas: Canvas, outer: RectF) {
                draws += "image"
                canvas.drawRect(outer, Paint().apply { color = Color.BLUE })
            }
            override fun getSize(paint: Paint, text: CharSequence, start: Int, end: Int,
                fm: Paint.FontMetricsInt?): Int {
                check(placement == null) { "Positioned image entered the integer replacement path" }
                integerMeasurements++
                return 40
            }
            override fun draw(canvas: Canvas, text: CharSequence, start: Int, end: Int,
                x: Float, top: Int, y: Int, bottom: Int, paint: Paint) {
                check(placement == null)
                drawNativeImage(canvas, RectF(x, y - 4f, x + 40f, y + 16f))
            }
        }
        fun strut(source: SpannableString): Spanned = SpannedString(source.apply {
            setSpan(NativeRunLineMetrics(NativePrimaryFontMetrics.from(root),
                NativeLineHeightPolicy.Pixels(bodyPixels), strut = true), 0, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        })
        fun withBitmap(width: Int, height: Int, block: (Bitmap) -> Unit) {
            val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
            var primary: Throwable? = null
            try { block(bitmap) }
            catch (failure: Throwable) { primary = failure; throw failure }
            finally {
                try { bitmap.recycle() }
                catch (cleanup: Throwable) {
                    val failure = primary
                    if (failure == null) throw cleanup
                    if (failure !== cleanup) failure.addSuppressed(cleanup)
                }
            }
        }
        class FlowFixture(val alt: String, val placement: NativeImageOccurrencePlacement?, val includeInline: Boolean = true) {
            val image = Image(placement)
            val imageSpan = Span("link", "", "image-target", image = InlineImage("Synthetic.png", 40, 20, alt = alt,
                occurrenceLayout = placement?.let { InlineImageOccurrenceLayout(
                    SignedContainerMargin(StyleLengthUnit.Px, it.translationX),
                    SignedContainerMargin(StyleLengthUnit.Px, it.translationY),
                    StyleLength(StyleLengthUnit.Px, it.paddingLeft), StyleLength(StyleLengthUnit.Px, it.paddingRight)) }))
            val inlineSpan = Span("link", "F", "inline-target")
            val content = anonymousFlowContent(Block("paragraph", 0, emptyList(), flow = buildList {
                add(FlowPart.Inline(listOf(imageSpan)))
                if (includeInline) add(FlowPart.Inline(listOf(inlineSpan)))
            }),
                AnonymousFlowContext(BidiResolvedDirection.Ltr, "ja", null))
            val imageSource = strut(SpannableString("\uFFFC").apply {
                setSpan(image, 0, 1, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            })
            val inlineSource = strut(SpannableString("F"))
            fun sources(geometry: NativeAnonymousFlowGeometry): List<NativeAnonymousInlineNode> =
                geometry.offsets.inlineSources.map { source ->
                    val original = source.event.spans.single()
                    val isImage = original === imageSpan
                    check(isImage || original === inlineSpan)
                    NativeAnonymousInlineNode(FloatInteractionNode(if (isImage) 201 else 202,
                        if (isImage) FloatInteractionKind.IMAGE else FloatInteractionKind.LINK,
                        geometry.selection.semanticOffset(source.start), geometry.selection.semanticOffset(source.end),
                        geometry.nativeRectsForRange(source.start, source.end), if (isImage) alt else original.text,
                        original.target, if (isImage) imageAction else inlineAction), source.start, source.end)
                }
            fun build(width: Int, sourceProvenance: Boolean = true,
                exclusions: List<NativeFloatExclusion> = emptyList()): NativeAnonymousFlowGeometry =
                NativeAnonymousFlowGeometry.build(content, root, width,
                    inline = { event -> when (event.spans.single()) {
                        imageSpan -> imageSource
                        inlineSpan -> inlineSource
                        else -> error("Unexpected original inline event")
                    } }, figure = { _, _ -> error("No figure source in this fixture") },
                    carriedExclusions = exclusions,
                    inlineNodes = { geometry -> sources(geometry).map { it.node } },
                    inlineSemantic = { event, text -> anonymousInlineSemantic(event.layoutSpans, text) },
                    inlineNodeSources = if (sourceProvenance) ({ geometry -> sources(geometry) }) else null)
        }
        val laterSource = strut(SpannableString("M").apply {
            setSpan(android.text.style.BackgroundColorSpan(Color.RED), 0, 1, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        })
        fun later(width: Int, exclusions: List<NativeFloatExclusion> = emptyList()): NativeFloatGeometry =
            NativeFloatGeometry.build(laterSource, root, width, emptyList(), carriedExclusions = exclusions,
                textDirection = TextDirectionHeuristics.LTR, nodeFactory = { geometry -> listOf(
                    FloatInteractionNode(301, FloatInteractionKind.LINK, 0, 1, geometry.rectsForRange(0, 1),
                        "M", "later-target", laterAction)) })
        val width = 160
        val laterReference = later(width)
        val laterBox = laterReference.nodes.single().bounds.single()
        for (alt in listOf("", "original image alt")) {
            val zero = FlowFixture(alt, NativeImageOccurrencePlacement(0f, 0f, .25f, .75f)).build(width)
            val unshiftedImage = zero.nodes.single { it.kind == FloatInteractionKind.IMAGE }.bounds.single()
            assertEquals(.25f, unshiftedImage.left, 0f)
            assertEquals(40f, unshiftedImage.width(), 0f)
            assertEquals(41f, zero.caretRect(alt.length).left, 0f)
            val placement = NativeImageOccurrencePlacement(laterBox.centerX() - unshiftedImage.centerX(),
                zero.textBottom + laterBox.centerY() - unshiftedImage.centerY(), .25f, .75f)
            val fixture = FlowFixture(alt, placement)
            val unavailable = assertThrows(UnsupportedFloatLayout::class.java) {
                fixture.build(width, sourceProvenance = false)
            }
            assertEquals("Positioned anonymous inline actions need original native ranges", unavailable.message)
            var actualFlow: NativeAnonymousFlowGeometry? = null
            val outer = NativeFloatContextGeometry.build(width, listOf(
                NativeFloatContextPart.Flow(41, { available, exclusions ->
                    fixture.build(available, exclusions = exclusions).also { actualFlow = it }
                }),
                NativeFloatContextPart.Text(laterSource, { available, exclusions -> later(available, exclusions) })))
            val flow = checkNotNull(actualFlow)
            assertEquals("\uFFFCF", flow.offsets.nativeText)
            assertEquals(alt + "F", flow.text.toString())
            assertEquals(alt + "F\nM", outer.text.toString())
            assertEquals(zero.textBottom, flow.textBottom, 0f)
            assertSame(fixture.imageSpan, flow.offsets.inlineSources[0].event.spans.single())
            assertSame(fixture.inlineSpan, flow.offsets.inlineSources[1].event.spans.single())
            val imageNode = flow.nodes.single { it.kind == FloatInteractionKind.IMAGE }
            val inlineNode = flow.nodes.single { it.kind == FloatInteractionKind.LINK }
            assertEquals(0, imageNode.start)
            assertEquals(alt.length, imageNode.end)
            assertEquals(alt.length, inlineNode.start)
            assertEquals(alt.length + 1, inlineNode.end)
            assertEquals(41f, flow.caretRect(inlineNode.start).left, 0f)
            assertSame(imageAction, imageNode.onClick)
            assertSame(inlineAction, inlineNode.onClick)
            assertEquals("image-target", imageNode.tooltip)
            assertEquals(alt, imageNode.label.toString())
            if (alt.isEmpty()) assertEquals(imageNode.start, inlineNode.start)
            val phase = flow.positionedGroups.single()
            assertEquals(0, phase.sourceOffset)
            assertEquals(setOf(imageNode.id), phase.nodeIds)
            assertFalse(inlineNode.id in phase.nodeIds)
            sameRect(RectF(unshiftedImage).apply { offset(placement.translationX, placement.translationY) },
                imageNode.bounds.single(), 0f)
            val outerImage = outer.nodes.single { it.kind == FloatInteractionKind.IMAGE }
            val outerLater = outer.nodes.single { it.tooltip == "later-target" }
            assertEquals(alt.length + 2, outerLater.start)
            assertSame(laterAction, outerLater.onClick)
            val outerPhase = outer.positionedGroups.single()
            assertEquals(setOf(outerImage.id), outerPhase.nodeIds)
            assertEquals(0, outerPhase.sourceOffset)
            sameRect(imageNode.bounds.single(), outerImage.bounds.single(), 0f)
            val overlap = RectF(outerImage.bounds.single())
            assertTrue(overlap.intersect(outerLater.bounds.single()))
            assertTrue(overlap.width() > 1f && overlap.height() > 1f)
            withBitmap(width, ceil(maxOf(outer.height.toFloat(), overlap.bottom) + 4f).toInt()) { bitmap ->
                // Flow is a real separately painted child (paintHere=false); Context owns its final positioned phase.
                draws.clear()
                flow.paintOrdinary(Canvas(bitmap))
                outer.paintOrdinary(Canvas(bitmap))
                assertTrue("Ordinary phases must not draw the positioned image", draws.isEmpty())
                val backgroundPixel = (0 until bitmap.height).firstNotNullOfOrNull { y ->
                    (0 until bitmap.width).firstOrNull { x -> overlap.contains(x + .5f, y + .5f) &&
                        bitmap.getPixel(x, y) == Color.RED }?.let { x -> x to y }
                }
                assertNotNull("The later ordinary link really paints under the image", backgroundPixel)
                val (x, y) = checkNotNull(backgroundPixel)
                bitmap.eraseColor(Color.TRANSPARENT)
                draws.clear()
                flow.paintOrdinary(Canvas(bitmap))
                outer.paint(Canvas(bitmap))
                assertEquals(listOf("image"), draws)
                assertEquals(Color.BLUE, bitmap.getPixel(x, y))
                val px = x + .5f; val py = y + .5f
                assertTrue(outerLater.contains(px, py))
                assertTrue(outerImage.contains(px, py))
                assertEquals(imageNode.id, flow.interactionNodeAt(px, py)!!.id)
                assertEquals(outerImage.id, outer.interactionNodeAt(px, py)!!.id)
                assertEquals(0, flow.offsetForPosition(px, py))
                assertEquals(0, outer.offsetForPosition(px, py))
                calls.clear()
                outer.interactionNodeAt(px, py)!!.onClick!!.invoke()
                assertEquals(listOf("image"), calls)
            }
        }
        assertEquals(0, integerMeasurements)
        // Empty authored alt does not turn a real inline image into a generated figure-only strut.
        val emptyOnly = FlowFixture("", NativeImageOccurrencePlacement(0f, 0f, .25f, .75f), includeInline = false).build(width)
        assertEquals("\uFFFC", emptyOnly.offsets.nativeText)
        assertEquals("", emptyOnly.text.toString())
        assertTrue(emptyOnly.height >= 20)
        assertTrue(emptyOnly.textBottom >= 20f)
        assertEquals(20f, emptyOnly.nativeRectsForRange(0, 1).single().height(), 0f)
        assertTrue(emptyOnly.characterRects(0, 0).isEmpty())
        assertEquals(0 to 0, emptyOnly.nodes.single().let { it.start to it.end })
        assertSame(imageAction, emptyOnly.nodes.single().onClick)
        assertEquals(0, emptyOnly.positionedGroups.single().sourceOffset)
        assertEquals(setOf(emptyOnly.nodes.single().id), emptyOnly.positionedGroups.single().nodeIds)
        withBitmap(width, emptyOnly.height + 24) { emptyBitmap ->
            draws.clear(); emptyOnly.paintOrdinary(Canvas(emptyBitmap)); assertTrue(draws.isEmpty())
            draws.clear(); emptyOnly.paint(Canvas(emptyBitmap)); assertEquals(listOf("image"), draws)
        }
        // Absence of occurrence metadata retains the original inline callback and ordinary paint route.
        val legacyFixture = FlowFixture("legacy alt", null)
        val legacy = legacyFixture.build(width, sourceProvenance = false)
        val legacyWithSources = legacyFixture.build(width)
        assertTrue(integerMeasurements > 0)
        assertTrue(legacy.positionedGroups.isEmpty())
        assertTrue(legacyWithSources.positionedGroups.isEmpty())
        assertEquals("legacy altF", legacy.text.toString())
        assertEquals(legacy.text.toString(), legacyWithSources.text.toString())
        assertEquals(legacy.height, legacyWithSources.height)
        assertEquals(legacy.nodes.map { it.start to it.end }, legacyWithSources.nodes.map { it.start to it.end })
        legacy.nodes.zip(legacyWithSources.nodes).forEach { (before, after) ->
            assertSame(before.onClick, after.onClick)
            assertEquals(before.bounds, after.bounds)
        }
        withBitmap(width, legacy.height + 24) { first ->
          withBitmap(width, legacyWithSources.height + 24) { second ->
            draws.clear(); legacy.paintOrdinary(Canvas(first)); assertEquals(listOf("image"), draws)
            draws.clear(); legacyWithSources.paintOrdinary(Canvas(second)); assertEquals(listOf("image"), draws)
            val left = IntArray(first.width * first.height); val right = IntArray(second.width * second.height)
            first.getPixels(left, 0, first.width, 0, 0, first.width, first.height)
            second.getPixels(right, 0, second.width, 0, 0, second.width, second.height)
            assertArrayEquals(left, right)
          }
        }
    }
}
