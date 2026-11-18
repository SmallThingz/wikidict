package app.smallthingz.dict

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import androidx.test.ext.junit.runners.AndroidJUnit4
import kotlin.math.abs
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class NativeInlineBoxEllipseDeviceTest {
    private fun bitmap(slices: List<NativeInlineBoxEllipseSlice>, dotted: Boolean): Bitmap {
        val result = Bitmap.createBitmap(128, 128, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(result)
        val decorators = mutableMapOf<NativeInlineBoxEllipseShape, NativeInlineBoxEllipseDecoration>()
        slices.forEach { slice ->
            decorators.getOrPut(slice.shape) { NativeInlineBoxEllipseDecoration(slice.shape, dotted) }
                .slice(slice).paint(canvas, Color.TRANSPARENT, Color.GRAY)
        }
        return result
    }

    @Test fun dottedEllipticalSlicesRetainOnePhaseAcrossCutsAndReverseProgression() {
        val whole = nativeInlineBoxEllipseSlices(listOf(NativeFloatBounds(0f, 0f, 40f, 24f)),
            false, 50f, true, 2f)
        val reference = bitmap(whole, true)
        try {
            for (rtl in listOf(false, true)) {
                val boxes = listOf(NativeFloatBounds(11f, 8f, 14f, 32f),
                    NativeFloatBounds(30f, 40f, 39f, 64f), NativeFloatBounds(7f, 80f, 35f, 104f))
                val slices = nativeInlineBoxEllipseSlices(boxes, rtl, 50f, true, 2f)
                val actual = bitmap(slices, true)
                try {
                    slices.forEach { slice ->
                        for (y in 0 until 24) for (x in 0 until (slice.fragment.right - slice.fragment.left).toInt()) {
                            val expected = reference.getPixel(slice.offset.toInt() + x, y)
                            val observed = actual.getPixel(slice.fragment.left.toInt() + x, slice.fragment.top.toInt() + y)
                            assertTrue("Dot phase moved at $rtl/$x/$y: $expected != $observed",
                                abs(Color.alpha(expected) - Color.alpha(observed)) <= 3)
                        }
                    }
                } finally { actual.recycle() }
            }
        } finally { reference.recycle() }
    }

    @Test fun dottedEllipseHasRealGapsTransparentInteriorAndContinuousOuterHit() {
        val slices = nativeInlineBoxEllipseSlices(listOf(NativeFloatBounds(10f, 10f, 30f, 50f)),
            false, 50f, true, 2f)
        val dotted = bitmap(slices, true)
        val solid = bitmap(slices, false)
        try {
            var painted = 0
            var gaps = 0
            for (y in 10 until 50) for (x in 10 until 30) {
                val d = Color.alpha(dotted.getPixel(x, y))
                val s = Color.alpha(solid.getPixel(x, y))
                if (d > 128) painted++
                if (s > 128 && d == 0) gaps++
            }
            assertTrue(painted > 0)
            assertTrue(gaps > 0)
            assertEquals(0, Color.alpha(dotted.getPixel(20, 30)))
            assertEquals(0, Color.alpha(dotted.getPixel(10, 10)))
            assertTrue(slices.single().contains(20f, 30f))
            assertTrue(slices.single().contains(20f, 10.5f))
            assertFalse(slices.single().contains(10.5f, 10.5f))
        } finally { dotted.recycle(); solid.recycle() }
    }
}
