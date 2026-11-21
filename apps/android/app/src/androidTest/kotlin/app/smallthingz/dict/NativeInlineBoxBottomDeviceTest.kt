package app.smallthingz.dict

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Typeface
import android.text.SpannableString
import android.text.Spanned
import android.text.SpannedString
import android.text.StaticLayout
import android.text.TextDirectionHeuristics
import android.text.TextPaint
import android.text.style.RelativeSizeSpan
import android.text.style.MetricAffectingSpan
import androidx.activity.compose.setContent
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.SideEffect
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.sp
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.util.Locale
import kotlin.math.ceil
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** Device controls are compiled on the host; only actual device execution earns paint evidence. */
@RunWith(AndroidJUnit4::class)
class NativeInlineBoxBottomDeviceTest {
    @get:Rule val compose = createPhysicalComposeRule()
    private fun owner(body: String, scale: Float = 1f): Span {
        val zero = StyleLength(StyleLengthUnit.Px, 0f)
        val pad = StyleLength(StyleLengthUnit.Px, 3f)
        val edge = InlineBoxBorderEdge.Dotted(StyleLength(StyleLengthUnit.Px, 1f), InlineBoxColor.Rgb("#cc3333"))
        val child = Span("text", body, foreground = "#cc3300", background = "#ffdddd",
            fontScale = scale.takeUnless { it == 1f })
        return child.copy(text = "", tooltip = "See vajab kontrollimist!", inlineBoxGroup = InlineBoxGroup(
            StyleEdges(zero, pad, zero, pad), InlineBoxBorderEdges(edge, edge, edge, edge), spans = listOf(child),
            verticalAlign = InlineBoxGroupVerticalAlign.Bottom))
    }
    private data class Fixture(val source: Spanned, val paint: TextPaint, val ownPaint: TextPaint,
        val range: RubyTextRange, val key: NativeInlineBoxOwner, val question: Int,
        val direction: android.text.TextDirectionHeuristic)
    private fun fixture(body: String = "pesemisvahend", ownerScale: Float = 1f,
        siblingScale: Float = 1f, rtl: Boolean = false,
        height: NativeLineHeightPolicy = NativeLineHeightPolicy.Normal,
        alignment: InlineBoxGroupVerticalAlign? = InlineBoxGroupVerticalAlign.Bottom,
        suffixShift: Int = 0, prefix: String? = null): Fixture {
        val originalOwner = owner(body, ownerScale)
        val own = originalOwner.copy(direction = "ltr",
            inlineBoxGroup = checkNotNull(originalOwner.inlineBoxGroup).copy(verticalAlign = alignment))
        val projection = rubyGraphicalProjection(listOf(Span("text", prefix ?: if (rtl) "אב " else "Hi "), own,
            Span("text", "? "), Span("link", "seebiooper", target = "seebiooper")))
        val range = projection.ranges.single { it.role == RubyTextRole.BoxGroup }
        val paint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            typeface = Typeface.MONOSPACE; textSize = 20f; color = Color.BLUE; textLocale = Locale.US
        }
        val ownPaint = TextPaint(paint).apply { textSize *= ownerScale; color = 0xffcc3300.toInt(); bgColor = 0xffffdddd.toInt() }
        val direction = if (rtl) TextDirectionHeuristics.RTL else TextDirectionHeuristics.LTR
        val key = NativeInlineBoxOwner(own, range.path)
        val edge = NativeInlineBoxBorder(1f, 0xffcc3333.toInt(), dotted = true)
        val format = NativeRubyGroupFormat(ownPaint, TextDirectionHeuristics.LTR, NativeLineHeightPolicy.Normal,
            sourceDirection = "ltr",
            box = NativeInlineBoxFormat(key, NativeInlineBoxEdges(0f, 3f, 0f, 3f),
                NativeInlineBoxBorders(edge, edge, edge, edge), emptyList(), verticalAlign = alignment))
        val text = SpannableString(projection.text)
        if (siblingScale != 1f) text.setSpan(RelativeSizeSpan(siblingScale), 0, range.start, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        text.setSpan(NativeRunLineMetrics(NativePrimaryFontMetrics.from(paint), height, strut = true),
            0, text.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        if (suffixShift != 0) {
            val shifted = TextPaint(paint).apply { baselineShift = suffixShift }
            text.setSpan(object : MetricAffectingSpan(), NativeInlineSafePaintSpan {
                override fun updateDrawState(paint: TextPaint) { paint.baselineShift = suffixShift }
                override fun updateMeasureState(paint: TextPaint) = updateDrawState(paint)
            }, range.end, text.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            text.setSpan(NativeAuthoredInlineMetrics(NativePrimaryFontMetrics.from(shifted), NativeLineHeightPolicy.Normal),
                range.end, text.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            text.setSpan(NativeAuthoredBaselineShift(suffixShift.toFloat()), range.end, text.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
        text.setSpan(NativeRubyPreparedSource(projection, SpannedString(text), paint, direction,
            mapOf(range.path to format)), 0, text.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        return Fixture(SpannedString(text), paint, ownPaint, range, key, range.end, direction)
    }
    private fun build(value: Fixture, width: Int, includeFontPadding: Boolean = false) = NativeFloatGeometry.build(value.source, value.paint,
        width, emptyList(), textDirection = value.direction, includeFontPadding = includeFontPadding)

    @Test fun tallerBottomOwnerKeepsTheParentBaselineAndAllPaintAtItsAlignedPosition() = compose.runOnIdle {
        val value = fixture(ownerScale = 2f)
        val geometry = build(value, 1000)
        val primary = value.paint.fontMetrics
        val own = value.ownPaint.fontMetrics
        val rootBaseline = geometry.baselineForOffset(0)
        val ownerBaseline = geometry.baselineForOffset(value.range.start)
        assertEquals(-primary.ascent, rootBaseline, .05f)
        assertEquals(rootBaseline, geometry.baselineForOffset(value.question), .001f)
        assertTrue(ownerBaseline > rootBaseline)
        val band = geometry.firstLineBand()
        assertEquals(own.descent - own.ascent, band.height(), .05f)
        assertEquals(band.bottom, ownerBaseline + own.descent, .05f)
        val rect = checkNotNull(geometry.inlineBoxGroupRects(value.key, value.range.start, value.range.end)).single()
        assertEquals(ownerBaseline + own.ascent - 1f, rect.top, .05f)
        assertEquals(band.bottom + 1f, rect.bottom, .05f)
        val caret = geometry.caretRect(value.range.start + 1)
        assertEquals(band.bottom, caret.bottom, .05f)
        assertEquals(value.range.start + 1, geometry.offsetForPosition(caret.left + .1f, caret.centerY()))
        val lastGlyph = geometry.rectsForRange(value.range.end - 1, value.range.end).single()
        val ownerEnd = geometry.caretAt(lastGlyph.right - lastGlyph.width() * .1f, lastGlyph.centerY())
        assertEquals(NativeTextCaret(value.range.end, NativeTextAffinity.Upstream), ownerEnd)
        assertEquals(band.bottom, geometry.caretRect(ownerEnd).bottom, .05f)
        val suffixGlyph = geometry.rectsForRange(value.question, value.question + 1).single()
        val suffixStart = geometry.caretAt(suffixGlyph.left + suffixGlyph.width() * .1f, suffixGlyph.centerY())
        assertEquals(NativeTextCaret(value.question, NativeTextAffinity.Downstream), suffixStart)
        assertEquals(rootBaseline, geometry.baselineForOffset(suffixStart.offset), .001f)
        val bitmap = Bitmap.createBitmap(1000, ceil(geometry.extents.usedHeight + 10f).toInt(), Bitmap.Config.ARGB_8888)
        val expected = Bitmap.createBitmap(bitmap.width, bitmap.height, Bitmap.Config.ARGB_8888)
        try {
            bitmap.eraseColor(Color.WHITE)
            geometry.paint(Canvas(bitmap))
            assertTrue((rect.top.toInt().coerceAtLeast(0)..rect.bottom.toInt().coerceAtMost(bitmap.height - 1)).any { y ->
                (rect.left.toInt().coerceAtLeast(0)..rect.right.toInt().coerceAtMost(bitmap.width - 1)).any { x ->
                    bitmap.getPixel(x, y) == 0xffffdddd.toInt()
                }
            })
            // Independent native draw at the specified logical bottom: a shifted
            // border/background alone cannot satisfy this glyph mask.
            val expectedCanvas = Canvas(expected)
            val body = value.source.subSequence(value.range.start, value.range.end)
            expectedCanvas.drawTextRun(body, 0, body.length, 0, body.length,
                rect.left + 4f, band.bottom - own.descent, false, value.ownPaint)
            val suffix = value.source.subSequence(value.question, value.source.length)
            val suffixX = geometry.caretRect(value.question).left
            expectedCanvas.drawTextRun(suffix, 0, suffix.length, 0, suffix.length,
                suffixX, -primary.ascent, false, value.paint)
            var red = 0
            var blue = 0
            for (y in 0 until bitmap.height) for (x in 0 until bitmap.width) {
                val actualColor = bitmap.getPixel(x, y)
                val expectedColor = expected.getPixel(x, y)
                assertEquals("Owner glyph at $x,$y", expectedColor == 0xffcc3300.toInt(), actualColor == 0xffcc3300.toInt())
                if (expectedColor == 0xffcc3300.toInt()) red++
                if (x >= ceil(suffixX).toInt()) {
                    assertEquals("Unaligned suffix at $x,$y", expectedColor == Color.BLUE, actualColor == Color.BLUE)
                    if (expectedColor == Color.BLUE) blue++
                }
            }
            assertTrue(red > 0 && blue > 0)
        } finally { bitmap.recycle(); expected.recycle() }
        for (prefix in listOf("Hi ", "Hi\n")) {
            val paddedValue = fixture(ownerScale = 2f, prefix = prefix)
            val plain = build(paddedValue, 1000)
            val padded = build(paddedValue, 1000, includeFontPadding = true)
            val source = plain.nativeRubyShapingSource
            val native = StaticLayout.Builder.obtain(source, 0, source.length, paddedValue.paint, 1000)
                .setTextDirection(paddedValue.direction).setUseLineSpacingFromFallbacks(true).setIncludePad(true).build()
            val firstPadding = -native.topPadding.toFloat()
            val lastPadding = native.bottomPadding.toFloat()
            assertTrue(firstPadding >= 0f && lastPadding >= 0f && firstPadding + lastPadding > 0f)
            assertEquals(plain.baselineForOffset(0) + firstPadding, padded.baselineForOffset(0), .05f)
            assertEquals(plain.baselineForOffset(paddedValue.range.start) + firstPadding,
                padded.baselineForOffset(paddedValue.range.start), .05f)
            assertEquals(plain.textBottom + firstPadding + lastPadding, padded.textBottom, .05f)
            val ownerBand = padded.rectsForRange(paddedValue.range.start, paddedValue.range.start + 1).first()
            assertEquals(padded.baselineForOffset(paddedValue.range.start) + paddedValue.ownPaint.descent(), ownerBand.bottom, .05f)
            assertEquals(padded.textBottom - lastPadding, ownerBand.bottom, .05f)
        }
    }

    @Test fun wrappedOwnersRetainPerLineAlignmentAndBidiCaretOrderingWithATallerSibling() = compose.runOnIdle {
        for (rtl in listOf(false, true)) {
            val value = fixture("pesemise vahend pikk tekst", ownerScale = .8f, siblingScale = 2f, rtl = rtl)
            val geometry = build(value, 180)
            val rects = checkNotNull(geometry.inlineBoxGroupRects(value.key, value.range.start, value.range.end))
            assertTrue(rects.size > 1)
            val own = value.ownPaint.fontMetrics
            val lines = (value.range.start until value.range.end).groupBy { geometry.lineRange(it) }
            assertTrue(lines.size > 1)
            lines.values.forEach { offsets ->
                val first = offsets.first()
                val baseline = geometry.baselineForOffset(first)
                val selection = geometry.rectsForRange(first, first + 1).first()
                assertEquals(baseline + own.descent, selection.bottom, .1f)
                for (offset in offsets.filter { value.source[it] != ' ' }) {
                    val caret = geometry.caretRect(offset)
                    assertEquals(baseline + own.descent, caret.bottom, .1f)
                    val hit = geometry.offsetForPosition(caret.left + .1f, caret.centerY())
                    assertTrue(hit in geometry.lineRange(offset).let { it.first..it.second })
                }
            }
            assertEquals(geometry.text.toString(), value.source.toString())
            assertTrue(geometry.caretRect(0).height() > geometry.caretRect(value.range.start + 1).height())
        }
    }

    @Test fun customParentLineHeightRefusesInsteadOfUsingTheOldBaselineUnion() = compose.runOnIdle {
        val value = fixture(height = NativeLineHeightPolicy.Pixels(10f))
        assertTrue(runCatching { build(value, 1000) }.exceptionOrNull() is UnsupportedFloatLayout)
        val ordinary = fixture(alignment = null, suffixShift = -3)
        val geometry = build(ordinary, 1000)
        assertEquals(geometry.baselineForOffset(0) - 3f, geometry.baselineForOffset(ordinary.question), .001f)
        assertEquals(geometry.baselineForOffset(0), geometry.baselineForOffset(ordinary.range.start), .001f)
    }

    @Test fun ordinaryComposeEntryKeepsTooltipAndFollowingLinkWithDensityResolvedOnce() {
        val subject = owner("pesemisvahend")
        val link = Span("link", "seebiooper", target = "seebiooper")
        val spans = listOf(subject, Span("text", "? "), link)
        val calls = mutableListOf<EntryLink>()
        var prepared: PreparedNativeFloatText? = null
        var primary: Throwable? = null
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                MaterialTheme {
                    CompositionLocalProvider(LocalDensity provides Density(1.25f, 1.2f)) {
                        val style = TextStyle(fontSize = 20.sp, fontFamily = FontFamily.SansSerif)
                        val annotation = styledTextAnnotation(spans, null, style) { calls += it }
                        val value = prepareNativeFloatText(spans, annotation, egyptianTextRuns(spans), style,
                            MaterialTheme.colorScheme.primary, emptyList(), AppSettings(), "", { calls += it },
                            nativeLineHeight = NativeLineHeightPolicy.Normal, ownerDirection = BidiResolvedDirection.Ltr)
                        SideEffect { prepared = value }
                    }
                }
            } }
            compose.waitForIdle()
            compose.runOnIdle {
                val value = checkNotNull(prepared)
                assertNull(value.stateDescription)
                val native = checkNotNull(value.native)
                val source = native.source(500)
                val marker = source.getSpans(0, source.length, NativeRubyPreparedSource::class.java).single()
                val range = marker.projection.ranges.single { it.role == RubyTextRole.BoxGroup }
                val box = checkNotNull(marker.groups.getValue(range.path).box)
                assertSame(subject, box.owner.span)
                assertEquals(InlineBoxGroupVerticalAlign.Bottom, box.verticalAlign)
                assertEquals(3.75f, box.padding.left, .001f)
                assertEquals(1.25f, box.border.left.width, .001f)
                val geometry = checkNotNull(value.geometry)(500, emptyList(), false)
                assertEquals("pesemisvahend? seebiooper", geometry.text.toString())
                assertEquals(2, geometry.nodes.size)
                assertTrue(geometry.nodes.any { it.start == range.start && it.end == range.end })
                assertTrue(geometry.nodes.any { it.start == range.end + 2 && it.end == geometry.text.length })
                assertTrue(calls.isEmpty())
            }
        } catch (failure: Throwable) { primary = failure; throw failure }
        finally {
            try { compose.activityRule.scenario.onActivity { it.setContent {} }; compose.waitForIdle() }
            catch (cleanup: Throwable) { if (primary == null) throw cleanup else primary.addSuppressed(cleanup) }
        }
    }
}
