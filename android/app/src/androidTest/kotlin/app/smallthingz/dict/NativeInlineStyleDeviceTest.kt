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

    @Test fun floatRowRunsRetainNativeMetricContextsGlyphsFallbacksAndLivePaintWithoutIntegerImages() {
        val root = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            typeface = Typeface.SERIF; textSize = 37.25f; color = Color.BLUE
            baselineShift = -3; bgColor = Color.GREEN; density = 1.75f; linkColor = Color.MAGENTA
        }
        fun copy(p: TextPaint) = TextPaint().apply { set(p) }
        val logical = "office a\u0301 \uD83D\uDE00"
        var active = false
        val live = object : android.text.style.CharacterStyle(), NativeInlineSafePaintSpan, NativeMayUnderline {
            override val mayUnderline = true
            override fun updateDrawState(paint: TextPaint) {
                paint.color = if (active) Color.RED else Color.BLUE
                paint.isUnderlineText = active
            }
        }
        val source = SpannableString(logical).also { range(it, live, 0, 2) }
        val owner = NativeFloatRowRuns(source, root, TextDirectionHeuristics.LTR)
        assertEquals(logical, owner.source.toString())
        assertSame(live, owner.source.getSpans(0, 2, android.text.style.CharacterStyle::class.java).single())
        assertEquals(root.baselineShift, owner.paint.baselineShift)
        assertEquals(root.bgColor, owner.paint.bgColor)
        assertEquals(root.density, owner.paint.density, 0f)
        assertEquals(root.linkColor, owner.paint.linkColor)
        val paragraph = owner.paragraphs.single()
        val run = owner.visualRuns(paragraph, 0, logical.length).single()
        val shaped = android.graphics.text.TextRunShaper.shapeTextRun(logical, 0, logical.length,
            0, logical.length, 0f, 0f, false, root)
        assertEquals(shaped.advance, run.advance, 0f)
        assertEquals(shaped.advance, paragraph.measured!!.getWidth(0, logical.length), .001f)
        assertEquals(shaped.ascent + root.baselineShift, run.natural.top, 0f)
        assertEquals(shaped.descent + root.baselineShift, run.natural.bottom, 0f)
        val fallbackFonts = (0 until shaped.glyphCount()).map { shaped.getFont(it) }.distinct()
        assertTrue("The explicit serif plus emoji fixture must use actual fallback", fallbackFonts.size > 1)
        val fallbackMetrics = fallbackFonts.map { font -> Paint.FontMetrics().also { font.getMetrics(root, it) } }
        assertEquals(minOf(fallbackMetrics.minOf { it.top }, shaped.ascent) + root.baselineShift,
            run.paddedNatural.top, 0f)
        assertEquals(maxOf(fallbackMetrics.maxOf { it.bottom }, shaped.descent) + root.baselineShift,
            run.paddedNatural.bottom, 0f)
        val combining = logical.indexOf('\u0301')
        val supplementary = logical.indexOf('\uD83D')
        assertNotEquals(combining, root.getTextRunCursor(logical, 0, logical.length, false,
            combining, Paint.CURSOR_AT_OR_AFTER))
        assertNotEquals(supplementary + 1, root.getTextRunCursor(logical, 0, logical.length, false,
            supplementary + 1, Paint.CURSOR_AT_OR_AFTER))
        for (offset in listOf(0, 2, combining - 1, combining + 1, supplementary, supplementary + 2, logical.length)) {
            assertEquals(offset, root.getTextRunCursor(logical, 0, logical.length, false,
                offset, Paint.CURSOR_AT_OR_AFTER))
        }
        fun refusesPaintCut(text: String, cut: Int, rtl: Boolean) {
            val split = SpannableString(text).also {
                range(it, android.text.style.ForegroundColorSpan(Color.RED), 0, cut)
            }
            val splitOwner = NativeFloatRowRuns(split, root,
                if (rtl) TextDirectionHeuristics.RTL else TextDirectionHeuristics.LTR)
            refused("Float row paint boundary is inside a native cluster") {
                splitOwner.visualRuns(splitOwner.paragraphs.single(), 0, text.length)
            }
        }
        refusesPaintCut(logical, combining, false)
        refusesPaintCut(logical, supplementary + 1, false)
        val markedArabic = "\u0628\u064E\u062A"
        assertNotEquals(1, root.getTextRunCursor(markedArabic, 0, markedArabic.length, true,
            1, Paint.CURSOR_AT_OR_AFTER))
        for (offset in listOf(0, 2, markedArabic.length)) {
            assertEquals(offset, root.getTextRunCursor(markedArabic, 0, markedArabic.length, true,
                offset, Paint.CURSOR_AT_OR_AFTER))
        }
        refusesPaintCut(markedArabic, 1, true)
        for (offset in 0..logical.length) {
            assertEquals(root.getRunAdvance(logical, 0, logical.length, 0, logical.length, false, offset),
                run.advanceTo(offset), 0f)
        }
        assertEquals(0, run.cursor(0, false))
        assertEquals(logical.length, run.cursor(logical.length, true))
        for (offset in 1 until logical.length) {
            assertEquals(root.getTextRunCursor(logical, 0, logical.length, false, offset, Paint.CURSOR_AFTER),
                run.cursor(offset, true))
            assertEquals(root.getTextRunCursor(logical, 0, logical.length, false, offset, Paint.CURSOR_BEFORE),
                run.cursor(offset, false))
        }
        for (step in 0..8) {
            val advance = run.advance * step / 8f
            assertEquals(root.getOffsetForAdvance(logical, 0, logical.length, 0, logical.length, false, advance),
                run.offsetForAdvance(advance))
        }
        val x = 18f
        val baseline = ceil(-run.paddedNatural.top).toFloat() + 18f
        val top = run.paddedNatural.top - 4f
        val bottom = run.paddedNatural.bottom + 4f
        val bitmapWidth = ceil(run.advance + x * 2).toInt()
        val bitmapHeight = ceil(baseline + bottom + 18f).toInt()
        fun raster(draw: (Canvas) -> Unit): IntArray {
            val bitmap = Bitmap.createBitmap(bitmapWidth, bitmapHeight, Bitmap.Config.ARGB_8888)
            var primary: Throwable? = null
            return try { draw(Canvas(bitmap)); pixels(bitmap) }
            catch (failure: Throwable) { primary = failure; throw failure }
            finally {
                try { bitmap.recycle() }
                catch (cleanup: Throwable) {
                    val failure = primary
                    if (failure == null) throw cleanup
                    if (cleanup !== failure) failure.addSuppressed(cleanup)
                }
            }
        }
        fun actual() = raster { canvas ->
            run.paintBackground(canvas, x, baseline, top, bottom)
            run.paintGlyphs(canvas, x, baseline)
            run.paintDecorations(canvas, x, baseline)
        }
        fun reference() = raster { canvas ->
            canvas.drawRect(x, baseline + top, x + shaped.advance, baseline + bottom,
                Paint(root).apply { color = root.bgColor; style = Paint.Style.FILL })
            val cut = root.getRunAdvance(logical, 0, logical.length, 0, logical.length, false, 2)
            fun glyphs(left: Float, right: Float, color: Int) {
                val saved = canvas.save()
                try {
                    canvas.clipRect(left, 0f, right, bitmapHeight.toFloat())
                    canvas.drawTextRun(logical, 0, logical.length, 0, logical.length,
                        x, baseline + root.baselineShift, false, copy(root).apply { this.color = color })
                } finally { canvas.restoreToCount(saved) }
            }
            glyphs(0f, x + cut, if (active) Color.RED else Color.BLUE)
            glyphs(x + cut, bitmapWidth.toFloat(), Color.BLUE)
            if (active) {
                val y = baseline + root.baselineShift + root.underlinePosition
                canvas.drawRect(x, y, x + cut, y + maxOf(root.underlineThickness, 1f),
                    Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.RED })
            }
        }
        val normal = actual()
        assertArrayEquals(reference(), normal)
        active = true
        val focused = actual()
        assertArrayEquals(reference(), focused)
        assertFalse(normal.contentEquals(focused))
        val reserve = checkNotNull(run.paintBounds(x, baseline, top, bottom))
        assertTrue(reserve.left <= x && reserve.right >= x + run.advance)
        active = false
        assertArrayEquals(normal, actual())

        // Equal native metric paints still own separate shaping contexts. The reference
        // directly shapes each original context; joining Arabic across it is not allowed.
        val arabic = SpannableString("\u0628\u0628")
        range(arabic, SnapshotPaint(copy(root)), 0, 1)
        range(arabic, SnapshotPaint(copy(root)), 1, 2)
        val arabicOwner = NativeFloatRowRuns(arabic, root, TextDirectionHeuristics.RTL)
        val arabicRuns = arabicOwner.visualRuns(arabicOwner.paragraphs.single(), 0, 2)
        assertEquals(listOf(1 to 2, 0 to 1), arabicRuns.map { it.start to it.end })
        for (part in arabicRuns) {
            assertTrue(part.rtl)
            assertEquals(part.start, part.contextStart); assertEquals(part.end, part.contextEnd)
            for (edge in listOf(part.contextStart, part.contextEnd)) {
                assertEquals(edge, root.getTextRunCursor(arabic, part.contextStart, part.contextEnd, true,
                    edge, Paint.CURSOR_AT_OR_AFTER))
            }
            val native = android.graphics.text.TextRunShaper.shapeTextRun(arabic, part.start, part.end - part.start,
                part.start, part.end - part.start, 0f, 0f, true, root)
            assertEquals(native.advance, part.advance, 0f)
        }
        val dipSource = SpannableString("a").also {
            range(it, android.text.style.AbsoluteSizeSpan(10, true))
        }
        val dipOwner = NativeFloatRowRuns(dipSource, root, TextDirectionHeuristics.LTR)
        val dipPaint = copy(root).apply { textSize = 10f * root.density }
        val dipNative = android.graphics.text.TextRunShaper.shapeTextRun("a", 0, 1, 0, 1, 0f, 0f, false, dipPaint)
        assertEquals(dipNative.advance, dipOwner.visualRuns(dipOwner.paragraphs.single(), 0, 1).single().advance, 0f)

        val spaced = SpannableString("a  \n\n")
        val spaceOwner = NativeFloatRowRuns(spaced, root, TextDirectionHeuristics.LTR)
        assertEquals(listOf(Triple(0, 4, 3), Triple(4, 5, 4), Triple(5, 5, 5)),
            spaceOwner.paragraphs.map { Triple(it.start, it.end, it.measuredEnd) })
        spaceOwner.paragraphs.drop(1).forEach { assertTrue(it.isEmpty); assertNull(it.measured); assertNull(it.bidi) }
        val retainedSpaces = spaceOwner.visualRuns(spaceOwner.paragraphs.first(), 0, 3, visibleEnd = 1)
        assertEquals(listOf(0 to 1, 1 to 3), retainedSpaces.map { it.start to it.end })
        assertEquals(listOf(true, false), retainedSpaces.map { it.visible })
        assertTrue(retainedSpaces.last().advance > 0f)
        assertEquals(3, retainedSpaces.last().cursor(2, true))
        assertTrue(NativeFloatRowRuns(SpannableString(""), root, TextDirectionHeuristics.LTR).paragraphs.single().isEmpty)
        val ideographic = NativeFloatRowRuns(SpannableString("a\u3000"), root, TextDirectionHeuristics.LTR)
        val ideographicRuns = ideographic.visualRuns(ideographic.paragraphs.single(), 0, 2, visibleEnd = 1)
        assertEquals(listOf(true, false), ideographicRuns.map { it.visible })
        assertTrue(ideographicRuns.last().advance > 0f)
        for (unbroken in listOf('\u00A0', '\u2007', '\u202F')) {
            val kept = NativeFloatRowRuns(SpannableString("a$unbroken"), root, TextDirectionHeuristics.LTR)
            assertTrue(kept.visualRuns(kept.paragraphs.single(), 0, 2).all { it.visible })
            refused("Float row omitted trailing source is not native space") {
                kept.visualRuns(kept.paragraphs.single(), 0, 2, visibleEnd = 1)
            }
        }

        val image = object : android.text.style.ReplacementSpan(), NativeFloatInlineImage {
            override val nativeImageId = 42
            override val nativeImageSourceOffset = 0
            override val nativeImageWidth = .2f
            override val nativeImageHeight = .75f
            override val nativeImageInkBounds = NativeFloatBounds(0f, 0f, .2f, .75f)
            override val nativeImageOccurrence = NativeImageOccurrencePlacement(17.25f, -23.5f, .125f, .25f)
            override val nativeUsedMetrics = NativeUsedLineMetrics(-.75f, 0f)
            override fun drawNativeImage(canvas: Canvas, outer: RectF) { error("Image scheduler owns painting") }
            override fun getSize(paint: Paint, text: CharSequence, start: Int, end: Int, fm: Paint.FontMetricsInt?): Int =
                error("Integer ReplacementSpan measurement must not run")
            override fun draw(canvas: Canvas, text: CharSequence, start: Int, end: Int, x: Float,
                top: Int, y: Int, bottom: Int, paint: Paint) { error("Static replacement painting must not run") }
            override fun nativePaintBounds(lineTop: Float, lineBottom: Float): NativeFloatBounds =
                error("Image scheduler owns bounds")
        }
        val imageSource = SpannableString("\uFFFC").also { range(it, image) }
        val images = NativeFloatRowRuns(imageSource, root, TextDirectionHeuristics.RTL)
        val imageRun = images.visualRuns(images.paragraphs.single(), 0, 1).single()
        val exact = (.125.toDouble() + .2f + .25f).toFloat()
        assertSame(image, imageRun.image)
        assertEquals(exact, imageRun.advance, 0f)
        assertEquals(exact, images.paragraphs.single().measured!!.getWidth(0, 1), 0f)
        assertEquals(0f, imageRun.advanceTo(0), 0f); assertEquals(exact, imageRun.advanceTo(1), 0f)
        val expectedImage = NativeUsedLineMetrics(root.fontMetrics.ascent, root.fontMetrics.descent)
            .including(image.nativeUsedMetrics)
        assertEquals(expectedImage, imageRun.natural); assertEquals(expectedImage, imageRun.paddedNatural)
        assertNull(imageRun.paintBounds(0f, 0f, expectedImage.top, expectedImage.bottom))
        raster { canvas ->
            imageRun.paintBackground(canvas, 0f, 0f, expectedImage.top, expectedImage.bottom)
            imageRun.paintGlyphs(canvas, 0f, 0f); imageRun.paintDecorations(canvas, 0f, 0f)
        }.also { assertTrue(it.all { color -> color == Color.TRANSPARENT }) }

        val aligned = SpannableString("a").also {
            range(it, android.text.style.AlignmentSpan.Standard(Layout.Alignment.ALIGN_CENTER))
            val effect = object : android.text.style.LineHeightSpan, NativeFloatRowMetricEffect {
                override fun chooseHeight(text: CharSequence, start: Int, end: Int, spanstartv: Int,
                    v: Int, fm: Paint.FontMetricsInt) { error("Immutable line marker owns metrics") }
            }
            range(it, effect); range(it, NativeLineGap(3f))
        }
        assertEquals("a", NativeFloatRowRuns(aligned, root, TextDirectionHeuristics.LTR).source.toString())
        aligned.getSpans(0, 1, NativeLineGap::class.java).forEach(aligned::removeSpan)
        refused("Float row custom paragraph effects are unavailable") {
            NativeFloatRowRuns(aligned, root, TextDirectionHeuristics.LTR)
        }
    }
}
