package app.smallthingz.dict

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.text.SpannableString
import android.text.Spanned
import android.text.TextPaint
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.util.IdentityHashMap
import kotlin.math.ceil

@RunWith(AndroidJUnit4::class)
class NativeAnonymousInlineMetricsDeviceTest {
    private val paint = TextPaint().apply { textSize = 20f; color = Color.BLACK }
    private val zeroPrimary = NativePrimaryFontMetrics(0f, 0f, 0f, 0f)

    private fun content(parts: List<FlowPart>): AnonymousFlowContent = anonymousFlowContent(
        Block("paragraph", 0, emptyList(), flow = parts),
        AnonymousFlowContext(BidiResolvedDirection.Ltr, "th", null))

    private fun captured(content: AnonymousFlowContent, width: Int, inline: (AnonymousFlowEvent.Inline) -> Spanned):
        Pair<NativeAnonymousFlowGeometry, NativeFloatGeometry> {
        var native: NativeFloatGeometry? = null
        val geometry = NativeAnonymousFlowGeometry.build(content, paint, width, inline,
            { _, _ -> error("This control has no figure object") }, decoration = { _, value -> native = value })
        val bitmap = Bitmap.createBitmap(maxOf(1, width), maxOf(1, geometry.height), Bitmap.Config.ARGB_8888)
        try { geometry.paint(Canvas(bitmap)) } finally { bitmap.recycle() }
        return geometry to checkNotNull(native)
    }

    @Test fun reusedEmptyOwnersSurviveAtOneOffsetWithRealScopedLineAndNoSemanticCharacters() {
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            val policy = InlineTextStyle(lineHeight = InlineLineHeight.Computed(
                InlineComputedLength(40f, FontScaleBasis.CssPx)))
            val owner = Span("text", "", superscript = true, inlineStyle = policy)
            val marker = NativeAuthoredInlineMetrics(NativePrimaryFontMetrics(-10f, 2f, 20f, -6f),
                NativeLineHeightPolicy.Pixels(40f))
            val source = SpannableString("").apply {
                setSpan(NativeRunLineMetrics(zeroPrimary, NativeLineHeightPolicy.Pixels(0f), strut = true),
                    0, 0, Spanned.SPAN_MARK_MARK)
                setSpan(marker, 0, 0, Spanned.SPAN_MARK_MARK)
            }
            for (scoped in listOf(false, true)) {
                val parts = List(7) { FlowPart.Inline(listOf(owner)) }
                val body = content(if (!scoped) parts else listOf(FlowPart.Scope(BidiScope(
                    BidiMode.Isolate, BidiDirectionInput.Rtl, BidiResolvedDirection.Rtl, "th", parts))))
                val (geometry, native) = captured(body, 120) { source }
                val assembled = native.text as Spanned
                val markers = assembled.getSpans(0, assembled.length, NativeAuthoredInlineMetrics::class.java)
                assertEquals(7, markers.size)
                val identities = IdentityHashMap<NativeAuthoredInlineMetrics, Boolean>()
                markers.forEach { value ->
                    identities[value] = true
                    assertNotSame(marker, value)
                    assertEquals(if (scoped) 1 else 0, assembled.getSpanStart(value))
                    assertEquals(assembled.getSpanStart(value), assembled.getSpanEnd(value))
                    assertEquals(Spanned.SPAN_MARK_MARK, assembled.getSpanFlags(value))
                }
                assertEquals(7, identities.size)
                assertEquals("", geometry.text.toString())
                assertEquals("", geometry.offsets.logicalText)
                assertEquals(if (scoped) 2 else 0, assembled.length)
                assertTrue(geometry.nodes.isEmpty())
                assertTrue(geometry.rectsForRange(0, 0).isEmpty())
                assertTrue(geometry.characterRects(0, 0).isEmpty())
                // Independent half-leading oracle: (-10, 2), 40px line height, and -6px shift.
                assertEquals(40f, geometry.textBottom, 0.001f)
                assertEquals(30f, checkNotNull(geometry.textBaselines?.first), 0.001f)
                assertEquals(40f, geometry.caretRect(0).height(), 0.001f)
                assertEquals(0, geometry.offsetForPosition(geometry.caretRect(0).centerX(), 20f))
                val (legacy, _) = captured(body, 120) { SpannableString("") }
                assertEquals("", legacy.text.toString())
                assertEquals(0f, legacy.caretRect(0).height(), 0f)
                if (scoped) assertEquals(0f, legacy.textBottom, 0f)
            }
            assertSame(marker, source.getSpans(0, 0, NativeAuthoredInlineMetrics::class.java).single())
        }
    }

    @Test fun reusedCoveredFragmentsKeepEveryMetricDecorationAndShiftOwnerOnAllWrappedLines() {
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            val text = "ab cd ef "
            val declaringPaint = TextPaint(paint).apply { textSize = 30f; baselineShift = -6 }
            val primary = NativePrimaryFontMetrics.from(paint)
            val declaring = NativePrimaryFontMetrics.from(declaringPaint)
            val metric = NativeAuthoredInlineMetrics(primary, NativeLineHeightPolicy.Pixels(40f), declaring)
            val shift = NativeAuthoredBaselineShift(0f)
            val underline = NativeAuthoredUnderline(InlineUnderlineStyle.Dotted, Color.BLUE, 1.25f)
            val cursor = NativeAuthoredCursor(InlineCursor.Help)
            val source = SpannableString(text).apply {
                setSpan(NativeRunLineMetrics(zeroPrimary, NativeLineHeightPolicy.Pixels(0f), strut = true),
                    0, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                for (value in listOf(metric, shift, underline, cursor))
                    setSpan(value, 0, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            }
            val span = Span("text", text)
            val body = content(listOf(FlowPart.Inline(listOf(span)), FlowPart.Inline(listOf(span))))
            for (width in listOf(58, 140)) {
                val (geometry, native) = captured(body, width) { source }
                val assembled = native.text as Spanned
                assertEquals(text + text, geometry.text.toString())
                assertEquals(text + text, assembled.toString())
                for (kind in listOf(NativeAuthoredInlineMetrics::class.java,
                    NativeAuthoredBaselineShift::class.java, NativeAuthoredUnderline::class.java,
                    NativeAuthoredCursor::class.java)) {
                    val owners = assembled.getSpans(0, assembled.length, kind).sortedBy { assembled.getSpanStart(it) }
                    assertEquals(2, owners.size)
                    assertNotSame(owners[0], owners[1])
                    owners.forEachIndexed { index, value ->
                        assertEquals(index * text.length, assembled.getSpanStart(value))
                        assertEquals((index + 1) * text.length, assembled.getSpanEnd(value))
                        assertEquals(Spanned.SPAN_EXCLUSIVE_EXCLUSIVE, assembled.getSpanFlags(value))
                    }
                }
                // Parent snapshot and covered child contribute independently on every wrapped line.
                val bounds = listOf(paint, declaringPaint).map { value ->
                    val fm = value.fontMetrics
                    val leading = (40f - (fm.descent - fm.ascent)) / 2f
                    (fm.ascent - leading + value.baselineShift) to (fm.descent + leading + value.baselineShift)
                }
                val top = minOf(0f, bounds.minOf { it.first })
                val bottom = maxOf(0f, bounds.maxOf { it.second })
                val lineHeight = bottom - top
                val lineStarts = (0 until assembled.length).map { native.lineRange(it).first }.distinct()
                assertTrue(lineStarts.size > 1)
                lineStarts.forEachIndexed { index, offset ->
                    assertEquals(index * lineHeight - top, native.baselineForOffset(offset), 0.001f)
                }
                assertEquals(lineStarts.size * lineHeight, geometry.textBottom, 0.001f)
                assertEquals(ceil(lineStarts.size * lineHeight).toInt(), geometry.height)
                assertEquals(geometry.text.length, geometry.characterRects(0, geometry.text.length).size)
                assertTrue(geometry.nodes.isEmpty())
            }
            assertSame(metric, source.getSpans(0, source.length, NativeAuthoredInlineMetrics::class.java).single())
            assertSame(shift, source.getSpans(0, source.length, NativeAuthoredBaselineShift::class.java).single())
            assertSame(underline, source.getSpans(0, source.length, NativeAuthoredUnderline::class.java).single())
            assertSame(cursor, source.getSpans(0, source.length, NativeAuthoredCursor::class.java).single())
        }
    }
}
