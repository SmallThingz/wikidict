package app.smallthingz.dict

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

/** Raster controls use the same measured preflight then paint contract as the Table owner. */
@RunWith(AndroidJUnit4::class)
class NativeTableCornersDeviceTest {
    private inline fun bitmap(width: Int, height: Int, block: (Bitmap, Canvas) -> Unit) {
        val image = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        try { block(image, Canvas(image)) } finally { image.recycle() }
    }

    @Test fun actualThreeRoundedCornersAndSquareBottomLeftUseFractionalDensityAndOrigin() {
        val box = RectF(.25f, .75f, 60.25f, 30.75f)
        val decoration = NativeContainerDecoration(Color.rgb(245, 244, 170), Color.rgb(188, 166, 116), 1.25f,
            nativeCorners = NativeCornerRadii(10f, 10f, 10f, 0f))
        decoration.prepareCorners(box)
        bitmap(64, 36) { image, canvas ->
            image.eraseColor(Color.WHITE)
            decoration.paint(canvas, box)
            assertEquals(Color.WHITE, image.getPixel(1, 2))
            assertEquals(Color.WHITE, image.getPixel(58, 2))
            assertEquals(Color.WHITE, image.getPixel(58, 29))
            // Fractional border coverage can mix the two authored opaque colors here;
            // a rounded bottom-left would leave this whole pixel white instead.
            assertNotEquals(Color.WHITE, image.getPixel(1, 28))
            assertEquals(255, Color.alpha(image.getPixel(1, 28)))
            assertEquals(Color.rgb(245, 244, 170), image.getPixel(20, 10))
            assertEquals(Color.rgb(188, 166, 116), image.getPixel(20, 1))
            assertEquals(Color.WHITE, image.getPixel(62, 10))
        }
        // A new final box needs its own preflight; drawing cannot silently reuse old geometry.
        val narrower = RectF(.25f, .75f, 8.25f, 6.75f)
        bitmap(12, 10) { _, canvas ->
            assertThrows(IllegalStateException::class.java) { decoration.paint(canvas, narrower) }
            decoration.prepareCorners(narrower)
            decoration.paint(canvas, narrower)
        }
    }

    @Test fun innerOpposingBorderArcUsesLiteralIntersectionAndFloatVisibleBounds() {
        val box = RectF(4f, 4f, 104f, 104f)
        val corners = NativeCornerRadii(0f, 100f, 0f, 0f)
        val decoration = NativeContainerDecoration(Color.YELLOW, Color.BLUE, 20f, nativeCorners = corners)
        decoration.prepareCorners(box)
        val shape = NativeTableCornerShape(NativeFloatBounds(4f, 4f, 104f, 104f), corners, 20f)
        bitmap(110, 110) { image, canvas ->
            decoration.paint(canvas, box)
            // Padding is [24,84], but the true TR inner radius remains80, centered(4,104).
            // A separately normalized roundRect(radius60) incorrectly paints this yellow.
            assertEquals(Color.BLUE, image.getPixel(24, 25))
            assertEquals(Color.YELLOW, image.getPixel(50, 60))
            assertEquals(0, image.getPixel(102, 5))
        }
        assertNull(nativeTableCornerIntersection(shape, RectF(24f, 25f, 25f, 26f), padding = true))
        val visible = checkNotNull(nativeTableCornerIntersection(shape,
            RectF(24.125f, 26f, 25.875f, 28f), padding = true))
        // AX uses a conservative native-path envelope, bounded by both original rectangles.
        // Exact point admission and the fully removed corner are checked independently.
        assertTrue(visible.left >= 24.125f && visible.right <= 25.875f)
        assertTrue(visible.top >= 26f && visible.bottom <= 28f)
        assertFalse(visible.isEmpty)
        assertTrue(shape.contains(24.5f, 27.5f, padding = true))
        val moved = shape.translated(.375f, -.25f)
        val shifted = checkNotNull(nativeTableCornerIntersection(moved,
            RectF(24.5f, 25.75f, 26.25f, 27.75f), padding = true))
        assertTrue(shifted.left >= 24.5f && shifted.right <= 26.25f)
        assertTrue(shifted.top >= 25.75f && shifted.bottom <= 27.75f)
        assertFalse(shifted.isEmpty)
        assertTrue(moved.contains(24.875f, 27.25f, padding = true))
    }

    @Test fun singleRingDoesNotDoubleBlendCornersAndBackgroundBorderPassesNeverClipChildren() {
        val box = RectF(4f, 4f, 44f, 34f)
        val corners = NativeCornerRadii(8f, 8f, 8f, 0f)
        val translucent = NativeContainerDecoration(null, Color.argb(128, 0, 255, 0), 3f, nativeCorners = corners)
        translucent.prepareCorners(box)
        bitmap(50, 40) { image, canvas ->
            translucent.paint(canvas, box)
            assertEquals(128, Color.alpha(image.getPixel(7, 7)))
            assertEquals(128, Color.alpha(image.getPixel(20, 5)))
            assertEquals(128, Color.alpha(image.getPixel(5, 32)))
            assertEquals(0, Color.alpha(image.getPixel(20, 15)))
        }
        val split = NativeContainerDecoration(Color.YELLOW, Color.BLUE, 3f, nativeCorners = corners)
        split.prepareCorners(box)
        bitmap(50, 40) { image, canvas ->
            split.paint(canvas, box, paintBorder = false)
            // A real authored child background may extend into the transparent rounded corner.
            // Decoration must neither leave a Canvas clip nor erase it during the border pass.
            canvas.drawRect(box, Paint().apply { color = Color.RED })
            split.paint(canvas, box, paintBackground = false)
            assertEquals(Color.RED, image.getPixel(4, 4))
            assertEquals(Color.RED, image.getPixel(20, 15))
            assertEquals(Color.BLUE, image.getPixel(20, 5))
            canvas.drawRect(0f, 0f, 2f, 2f, Paint().apply { color = Color.GREEN })
            assertEquals(Color.GREEN, image.getPixel(0, 0))
        }
    }

    @Test fun noBorderFullBorderAndLegacyNullKeepTheirDistinctPaintContracts() {
        val box = RectF(2f, 2f, 22f, 22f)
        val corners = NativeCornerRadii(8f, 8f, 8f, 0f)
        val none = NativeContainerDecoration(Color.YELLOW, null, 0f, nativeCorners = corners)
        val full = NativeContainerDecoration(Color.YELLOW, Color.BLUE, 10f, nativeCorners = corners)
        none.prepareCorners(box); full.prepareCorners(box)
        bitmap(26, 26) { image, canvas ->
            none.paint(canvas, box)
            assertEquals(Color.YELLOW, image.getPixel(12, 12))
            assertEquals(0, image.getPixel(2, 2))
            full.paint(canvas, box)
            assertEquals(Color.BLUE, image.getPixel(12, 12))
        }
        // Null takes the literal legacy four-band route, including its previous translucent
        // corner overlap. Explicit zero radii use the new single ring rather than rewriting null.
        val color = Color.argb(128, 255, 0, 0)
        val old = NativeContainerDecoration(null, color, 4f)
        val zero = NativeContainerDecoration(null, color, 4f, nativeCorners = NativeCornerRadii(0f, 0f, 0f, 0f))
        zero.prepareCorners(box)
        bitmap(26, 26) { image, canvas ->
            old.paint(canvas, box) // No new preflight is required for old owners.
            assertEquals(192, Color.alpha(image.getPixel(3, 3)))
            assertEquals(128, Color.alpha(image.getPixel(12, 3)))
            image.eraseColor(0)
            zero.paint(canvas, box)
            assertEquals(128, Color.alpha(image.getPixel(3, 3)))
            assertEquals(128, Color.alpha(image.getPixel(12, 3)))
        }
        assertThrows(UnsupportedFloatLayout::class.java) {
            NativeContainerDecoration(null, null, 0f, listOf(
                NativeContainerPaintEdge(1f, Color.BLUE), NativeContainerPaintEdge(2f, Color.BLUE),
                NativeContainerPaintEdge(1f, Color.BLUE), NativeContainerPaintEdge(1f, Color.BLUE)), corners)
        }
        assertThrows(UnsupportedFloatLayout::class.java) {
            NativeContainerDecoration(null, null, 0f, List(4) { NativeContainerPaintEdge(1f, Color.BLUE, true) }, corners)
        }
        assertThrows(UnsupportedFloatLayout::class.java) { none.prepareCorners(RectF(2f, 2f, 1f, 4f)) }
        val empty = RectF(2f, 2f, 2f, 4f)
        none.prepareCorners(empty)
        bitmap(8, 8) { image, canvas ->
            none.paint(canvas, empty)
            assertTrue((0 until 8).all { y -> (0 until 8).all { x -> image.getPixel(x, y) == 0 } })
        }
    }
}
