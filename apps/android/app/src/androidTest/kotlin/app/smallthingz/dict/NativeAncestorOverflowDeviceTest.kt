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
import android.text.TextDirectionHeuristics
import android.text.TextPaint
import android.text.style.BackgroundColorSpan
import android.text.style.MetricAffectingSpan
import android.text.style.ReplacementSpan
import android.text.style.StrikethroughSpan
import android.text.style.UnderlineSpan
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class NativeAncestorOverflowDeviceTest {
    @Test fun nativeGlyphEnvelopeContainsRealMixedScriptDecorationsWithoutInflatingZeroUsedBoxes() {
        for (direction in listOf(TextDirectionHeuristics.LTR, TextDirectionHeuristics.RTL)) {
            for (alignment in listOf(Layout.Alignment.ALIGN_NORMAL, Layout.Alignment.ALIGN_CENTER,
                Layout.Alignment.ALIGN_OPPOSITE)) {
                val paint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
                    textSize = 34f; color = Color.RED
                    typeface = Typeface.create("serif", Typeface.ITALIC)
                    textSkewX = -.4f
                }
                val source = SpannableString("j\u0301\t\u05d0\u05d1\u00adW\ud83d\ude42").apply {
                    setSpan(UnderlineSpan(), 0, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                    setSpan(StrikethroughSpan(), 0, 2, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                    setSpan(BackgroundColorSpan(Color.YELLOW), 3, 5, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                    setSpan(object : MetricAffectingSpan() {
                        override fun updateMeasureState(tp: TextPaint) { tp.textSize = 49f; tp.baselineShift = -7 }
                        override fun updateDrawState(tp: TextPaint) = updateMeasureState(tp)
                    }, 3, 5, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                }
                val geometry = NativeFloatGeometry.build(source, paint, 0, emptyList(),
                    alignment = alignment, textDirection = direction, insets = NativeTextInsets(11f, 9f),
                    usedLineMetrics = { _, _ -> NativeUsedLineMetrics(0f, 0f) })
                assertEquals(0, geometry.width); assertEquals(0, geometry.height)
                val area = geometry.extents
                assertEquals(0, area.usedWidth); assertEquals(0f, area.usedHeight, 0f)
                val ink = checkNotNull(area.ink)
                assertTrue(ink.top < 0f)
                val physical = NativeSurfaceGeometry(geometry)
                assertTrue(physical.width > 0 && physical.height > 0)
                val original = Bitmap.createBitmap(768, 384, Bitmap.Config.ARGB_8888)
                val projected = Bitmap.createBitmap(768, 384, Bitmap.Config.ARGB_8888)
                try {
                    Canvas(original).apply { translate(384f, 192f); geometry.paint(this) }
                    Canvas(projected).apply {
                        translate(384f + physical.surface.left, 192f + physical.surface.top)
                        // The real physical view clips only at its allocation, not the used box.
                        clipRect(0, 0, physical.width, physical.height)
                        physical.paint(this)
                    }
                    val expected = pixels(original)
                    assertTrue(expected.count { it ushr 24 != 0 } > 20)
                    assertArrayEquals(expected, pixels(projected))
                    expected.indices.filter { expected[it] ushr 24 != 0 }.forEach { index ->
                        val x = index % original.width - 384
                        val y = index / original.width - 192
                        assertTrue("Paint at $x,$y outside $area", x + 1 > ink.left &&
                            x < ink.right && y + 1 > ink.top && y < ink.bottom)
                    }
                    val first = geometry.characterRects(0, 1).single()!!
                    val translated = physical.characterRects(0, 1).single()!!
                    assertEquals(first.left - physical.surface.left, translated.left, 0f)
                    assertEquals(first.top - physical.surface.top, translated.top, 0f)
                    assertEquals(geometry.offsetForPosition(first.centerX(), first.centerY()),
                        physical.offsetForPosition(translated.centerX(), translated.centerY()))
                } finally { original.recycle(); projected.recycle() }
            }
        }
    }

    private class OwnedInk : ReplacementSpan(), NativeReplacementPaintBounds {
        var draws = 0
        val ink = NativeFloatBounds(-9f, -23f, 53f, 9f)
        override fun nativePaintBounds(lineTop: Float, lineBottom: Float) = ink
        override fun getSize(paint: Paint, text: CharSequence, start: Int, end: Int,
            fm: Paint.FontMetricsInt?): Int {
            fm?.let { it.ascent = -18; it.top = -18; it.descent = 6; it.bottom = 6 }
            return 48
        }
        override fun draw(canvas: Canvas, text: CharSequence, start: Int, end: Int,
            x: Float, top: Int, y: Int, bottom: Int, paint: Paint) {
            draws++
            canvas.drawRect(x + ink.left, y + ink.top, x + ink.right, y + ink.bottom,
                Paint().apply { color = Color.BLUE })
        }
    }

    @Test fun signedOverflowCrossesZeroSizedAncestorsAndKeepsOriginalSelectionActionAndPaintOwner() {
        val owner = OwnedInk()
        var clicks = 0
        val source = SpannableString("\ufffc").apply { setSpan(owner, 0, 1, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE) }
        val native = NativeFloatGeometry.build(source, TextPaint().apply { textSize = 18f }, 0, emptyList(),
            usedLineMetrics = { _, _ -> NativeUsedLineMetrics(0f, 0f) }, nodeFactory = { g -> listOf(
                FloatInteractionNode(0, FloatInteractionKind.LINK, 0, 1, g.rectsForRange(0, 1),
                    "Original action", null, { clicks++ })) })
        val inner = NativeSemanticGroup(0, 0, listOf(PositionedSemanticChild(native, -12f, -7f, BidiResolvedDirection.Ltr)))
        val outer = NativeSemanticGroup(0, 0, listOf(PositionedSemanticChild(inner, 4f, -11f, BidiResolvedDirection.Ltr)))
        assertEquals(0, outer.width); assertEquals(0, outer.height)
        assertEquals(0f, outer.extents.usedHeight, 0f)
        val nativeInk = checkNotNull(native.extents.ink)
        val outerInk = checkNotNull(outer.extents.ink)
        assertTrue(outerInk.left <= nativeInk.left - 8f && outerInk.top <= nativeInk.top - 18f)
        val action = outer.nodes.single()
        val range = outer.characterRects(0, 1).single()!!
        assertTrue(range.top < 0f && range.left < 0f)
        assertTrue(outer.containsInteraction(range.centerX(), range.centerY()))
        assertEquals(0, outer.offsetForPosition(range.left + 1f, range.centerY()))
        action.onClick!!(); assertEquals(1, clicks)
        val surface = NativeSurfaceGeometry(outer)
        assertFalse(surface.containsInput(surface.width - 1f, surface.height - 1f))
        val expectedCaret = outer.caretRect(0)
        val caret = surface.caretRect(0)
        assertEquals(expectedCaret.top - surface.surface.top, caret.top, 0f)
        val image = Bitmap.createBitmap(surface.width, surface.height, Bitmap.Config.ARGB_8888)
        try {
            surface.paint(Canvas(image))
            assertEquals(1, owner.draws)
            assertTrue(pixels(image).count { it == Color.BLUE } > 100)
            assertSame(owner, source.getSpans(0, 1, ReplacementSpan::class.java).single())
        } finally { image.recycle() }
    }

    private fun pixels(bitmap: Bitmap) = IntArray(bitmap.width * bitmap.height).also {
        bitmap.getPixels(it, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
    }
}
