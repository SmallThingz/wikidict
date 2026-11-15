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

/** Geometry/Canvas regression controls. The separate real Table controls own native glyph,
 * pointer and AX qualification; these deliberately supply known rectangular fragments. */
@RunWith(AndroidJUnit4::class)
class NativeTableCornerClipDeviceTest {
    private class Fragment(private val source: String, private val rectangle: RectF,
        private val action: () -> Unit = {}) : FloatTextGeometry {
        override val text: CharSequence get() = source
        override val width = 20
        override val height = 20
        override val nodes = listOf(FloatInteractionNode(0, FloatInteractionKind.LINK, 0, source.length,
            listOf(RectF(rectangle)), source, null, action))
        override fun paint(canvas: Canvas) { canvas.drawRect(rectangle, Paint().apply { color = Color.BLUE }) }
        override fun offsetForPosition(x: Float, y: Float) = 0
        override fun rectsForRange(start: Int, end: Int): List<RectF> {
            require(start in 0..source.length && end in start..source.length)
            return if (start == end) emptyList() else listOf(RectF(rectangle))
        }
        override fun characterRects(start: Int, length: Int): List<RectF?> {
            require(start in 0..source.length && length >= 0 && length <= source.length - start)
            return List(length) { RectF(rectangle) }
        }
        override fun caretRect(offset: Int): RectF = RectF(rectangle.left, rectangle.top, rectangle.left + 1f, rectangle.bottom)
        override fun lineRange(offset: Int) = 0 to source.length
        override fun visualOffset(offset: Int, direction: Int) = (offset + direction).coerceIn(0, source.length)
    }

    private fun viewport(content: FloatTextGeometry, rectangle: RectF, corners: NativeTableCornerShape?) =
        NativeTableViewportGeometry(content, NativeTableBlockPlacement(
            borderBox = RectF(0f, 0f, 20f, 20f), contentClip = rectangle,
            contentX = 0f, contentY = 0f, physicalScrollX = 0f,
            gridWidth = content.width, gridHeight = content.height, captionWidth = 0, captionHeight = 0,
            captionY = 0f, gridY = 0f, ownerWidth = 20, ownerHeight = 20,
            scrollTarget = null, revealContentRect = { _, done -> done() }, cornerClip = corners))

    @Test fun nestedRectangleNeverResurrectsACurvedAwayCharacterOrAction() {
        var clicks = 0
        val source = Fragment("A", RectF(0f, 0f, 10f, 10f)) { clicks++ }
        val shape = NativeTableCornerShape(NativeFloatBounds(0f, 0f, 20f, 20f),
            NativeCornerRadii(10f, 0f, 0f, 0f), 0f)
        val inner = viewport(source, RectF(0f, 0f, 20f, 20f), shape)
        assertNotNull(inner.characterRects(0, 1).single())
        // The inner visible fragment has a broad rectangular envelope. A later rectangle
        // at the excluded corner must intersect the original shape, not that envelope.
        val outer = viewport(inner, RectF(0f, 0f, 1f, 1f), null)
        assertEquals("A", outer.text.toString())
        assertNull(outer.characterRects(0, 1).single())
        assertTrue(outer.rectsForRange(0, 1).isEmpty())
        assertTrue(outer.nodes.single().bounds.isEmpty())
        assertFalse(outer.nodes.single().contains(.5f, .5f))
        assertFalse(outer.containsInteraction(.5f, .5f))
        assertSame(source.nodes.single().onClick, outer.nodes.single().onClick)
        outer.nodes.single().onClick!!.invoke()
        assertEquals(1, clicks) // Logical action identity survives offscreen geometry.

        val translated = NativeSemanticGroup(30, 30, listOf(PositionedSemanticChild(
            NativeSurfaceGeometry(outer, NativeSurfaceBox(-3, -2, 23, 22)),
            1.25f, 2.5f, BidiResolvedDirection.Ltr)))
        assertEquals("A", translated.text)
        assertNull(translated.characterRects(0, 1).single())
        assertFalse(checkNotNull(translated.preciseClipForOffset(0)).contains(4.75f, 5f))
        assertEquals(0, translated.nodes.single().start)
        assertEquals(1, translated.nodes.single().end)
    }

    @Test fun translatedSelectionClipsOnlyItsRoundedOwnerAndKeepsTheSibling() {
        val source = Fragment("A", RectF(0f, 0f, 20f, 20f))
        val shape = NativeTableCornerShape(NativeFloatBounds(0f, 0f, 20f, 20f),
            NativeCornerRadii(8f, 8f, 8f, 0f), 1f)
        val rounded = viewport(source, RectF(1f, 1f, 19f, 19f), shape)
        val sibling = Fragment("B", RectF(0f, 0f, 4f, 4f))
        val group = NativeSemanticGroup(32, 20, listOf(
            PositionedSemanticChild(rounded, 0f, 0f, BidiResolvedDirection.Ltr),
            PositionedSemanticChild(sibling, 24f, 0f, BidiResolvedDirection.Ltr)))
        val surface = NativeSurfaceGeometry(group, NativeSurfaceBox(-3, -2, 35, 22))
        assertEquals("AB", surface.text)
        assertTrue(surface.hasPreciseClips)
        assertNull(surface.preciseClipForOffset(1))
        val bitmap = Bitmap.createBitmap(40, 30, Bitmap.Config.ARGB_8888)
        try {
            surface.paintSelection(Canvas(bitmap), 0, 2, Paint().apply { color = Color.GREEN })
            assertEquals(0, Color.alpha(bitmap.getPixel(4, 3))) // Rounded TL excluded.
            assertEquals(Color.GREEN, bitmap.getPixel(13, 3)) // Visible part of the same owner.
            assertEquals(Color.GREEN, bitmap.getPixel(4, 20)) // Authored square BL stays square.
            assertEquals(Color.GREEN, bitmap.getPixel(28, 3)) // Unrelated sibling is not clipped.
            assertFalse(surface.nodes[0].contains(4.5f, 3.5f))
            assertTrue(surface.nodes[0].contains(13.5f, 3.5f))
            assertTrue(surface.nodes[1].contains(28.5f, 3.5f))
        } finally { bitmap.recycle() }
        val wide = viewport(source, RectF(1f, 1f, 19f, 19f), null)
        assertFalse(wide.hasPreciseClips)
        assertNull(wide.preciseClipForOffset(0))
        assertTrue(wide.nodes.single().contains(1.5f, 1.5f))
        assertEquals(rounded.text, wide.text)
        assertEquals(rounded.width, wide.width)
        assertEquals(rounded.height, wide.height)
    }
}
