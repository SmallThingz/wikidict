package app.smallthingz.dict

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Typeface
import android.text.TextPaint
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class NativeMarkerTextDeviceTest {
    @Test fun undecoratedMarkersRetainNativeGlyphPixelsAdvanceAndCallerBaselineForBothAnchors() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        for (face in listOf(Typeface.DEFAULT, context.resources.getFont(R.font.newsreader))) {
            for (text in listOf("\u2022", "12.", "\u0661.", "!", "\u05d0.", "1. ")) {
                for (right in listOf(false, true)) {
                    val paint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
                        textSize = 31f; typeface = face; color = Color.BLACK
                        textAlign = if (right) Paint.Align.RIGHT else Paint.Align.LEFT
                    }
                    val marker = NativeMarkerText(text, paint)
                    assertEquals(paint.measureText(text), marker.advance, .001f)
                    val old = Bitmap.createBitmap(320, 160, Bitmap.Config.ARGB_8888)
                    val current = Bitmap.createBitmap(320, 160, Bitmap.Config.ARGB_8888)
                    try {
                        Canvas(old).drawText(text, 160.25f, 83.5f, paint)
                        marker.paint(Canvas(current), 160.25f, 83.5f, rightAligned = right)
                        assertArrayEquals("Native marker origin/glyph mismatch for $text right=$right", pixels(old), pixels(current))
                        assertTrue(pixels(current).any { it ushr 24 != 0 })
                        assertEquals(if (right) Paint.Align.RIGHT else Paint.Align.LEFT, paint.textAlign)
                    } finally { old.recycle(); current.recycle() }
                }
            }
        }
    }

    @Test fun markerUsesParagraphDecorationPolicyAndRetainsOneEnvelopeAcrossMissingHoverState() {
        val paint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            textSize = 37f; color = Color.BLACK; isStrikeThruText = true
        }
        val state = NativeMissingLinkPaint(MissingLinkPaint.VectorNewLinkV1, false, false)
        val marker = NativeMarkerText("!", paint, state)
        val area = checkNotNull(marker.bounds(70f, 60f))
        val ordinary = Bitmap.createBitmap(160, 120, Bitmap.Config.ARGB_8888)
        val hovered = Bitmap.createBitmap(160, 120, Bitmap.Config.ARGB_8888)
        try {
            marker.paint(Canvas(ordinary), 70f, 60f)
            val normalColor = state.appearance().color
            state.hovered = true
            marker.paint(Canvas(hovered), 70f, 60f)
            assertEquals(area, marker.bounds(70f, 60f))
            assertTrue(state.appearance().underline)
            assertTrue(pixels(ordinary).any { it == normalColor })
            assertTrue(pixels(hovered).any { it == state.appearance().color })
            for (image in listOf(ordinary, hovered)) pixels(image).forEachIndexed { index, pixel ->
                if (pixel ushr 24 != 0) {
                    val x = index % image.width
                    val y = index / image.width
                    assertTrue("Native marker paint escaped its retained envelope", x + 1 > area.left &&
                        x < area.right && y + 1 > area.top && y < area.bottom)
                }
            }
            assertFalse(paint.isUnderlineText)
            assertTrue(paint.isStrikeThruText)
        } finally { ordinary.recycle(); hovered.recycle() }
    }

    private fun pixels(bitmap: Bitmap) = IntArray(bitmap.width * bitmap.height).also {
        bitmap.getPixels(it, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
    }
}
