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

    @Test fun emptyDeclaringBandsKeepAnalyticClipsIdentityAndActualRevealBounds() {
        fun band(expected: RectF, actual: RectF?) {
            assertNotNull(actual)
            val value = checkNotNull(actual)
            assertEquals(expected.left, value.left, 0f)
            assertEquals(expected.top, value.top, 0f)
            assertEquals(expected.right, value.right, 0f)
            assertEquals(expected.bottom, value.bottom, 0f)
        }
        val square = NativeTextClip.rectangle(RectF(0f, 0f, 20f, 20f))
        band(RectF(0f, 0f, 0f, 20f), square.segmentBounds(0f, -5f, 0f, 25f))
        band(RectF(0f, 0f, 20f, 0f), square.segmentBounds(-5f, 0f, 25f, 0f))
        assertNull(square.segmentBounds(20f, -5f, 20f, 25f))
        assertNull(square.segmentBounds(-5f, 20f, 25f, 20f))
        assertNull(square.segmentBounds(-1f, -1f, 0f, 0f))
        assertNull(square.segmentBounds(8f, 11f, 8f, 11f))

        // The normalized outer radius is 20; border 5 leaves radius 15 at the ORIGINAL
        // center (20,20), even though the padding box is only 10 wide. A 9-12-15 triangle
        // gives y=11 at x=8. Clamping or renormalizing the inner radius changes this result.
        val shape = NativeTableCornerShape(NativeFloatBounds(0f, 0f, 20f, 20f),
            NativeCornerRadii(20f, 0f, 0f, 0f), 5f)
        val clipped = nativeTableContentClip(shape, RectF(0f, 0f, 20f, 20f))
        band(RectF(8f, 11f, 8f, 15f), clipped.segmentBounds(8f, 0f, 8f, 20f))
        band(RectF(8f, 11f, 8f, 15f), clipped.segmentBounds(8f, 20f, 8f, 0f))
        assertTrue(clipped.contains(8f, 11f)) // The circular boundary is inclusive.
        assertNull(clipped.bounds(RectF(8f, 0f, 8f, 20f))) // Existing area query is unchanged.
        band(RectF(10.5f, 9.75f, 10.5f, 13.75f), clipped.translated(2.5f, -1.25f)
            .segmentBounds(10.5f, -1.25f, 10.5f, 18.75f))
        val circle = nativeTableContentClip(NativeTableCornerShape(NativeFloatBounds(0f, 0f, 20f, 20f),
            NativeCornerRadii(10f, 10f, 10f, 10f), 0f), RectF(0f, 0f, 20f, 20f))
        assertNull(circle.segmentBounds(0f, 0f, 0f, 20f)) // Isolated circular tangency.
        val oneCorner = nativeTableContentClip(NativeTableCornerShape(NativeFloatBounds(0f, 0f, 100f, 100f),
            NativeCornerRadii(10f, 0f, 0f, 0f), 0f), RectF(0f, 0f, 100f, 100f))
        // A tangent circle root can also begin a positive straight-edge survivor.
        band(RectF(0f, 10f, 0f, 50f), oneCorner.segmentBounds(0f, 0f, 0f, 50f))
        band(RectF(0f, 10f, 0f, 50f), oneCorner.segmentBounds(0f, 50f, 0f, 0f))
        band(RectF(10f, 0f, 50f, 0f), oneCorner.segmentBounds(0f, 0f, 50f, 0f))
        assertNull(oneCorner.segmentBounds(0f, 0f, 0f, 10f))
        // This rectangle intersects the diagonal survivor's ENVELOPE but not the segment.
        assertNotNull(clipped.segmentBounds(0f, 0f, 20f, 20f))
        assertNull(clipped.intersected(RectF(13f, 10f, 14f, 11f)).segmentBounds(0f, 0f, 20f, 20f))

        val rotation = android.graphics.Matrix().apply {
            setValues(floatArrayOf(0f, -1f, 40f, 1f, 0f, 2f, 0f, 0f, 1f))
        }
        band(RectF(25f, 10f, 29f, 10f), clipped.transformed(rotation).segmentBounds(40f, 10f, 20f, 10f))
        val skew = android.graphics.Matrix().apply {
            setValues(floatArrayOf(1f, 0f, 3f, .5f, 1f, -2f, 0f, 0f, 1f))
        }
        // Independently applying (40-y,x+2), then (x+3,y+x/2-2), maps the known
        // survivor endpoints to (32,22.5) and (28,20.5). Inverses are exact binary values.
        band(RectF(28f, 20.5f, 32f, 22.5f), clipped.transformed(rotation).transformed(skew)
            .segmentBounds(43f, 28f, 23f, 18f))
        val perspective = android.graphics.Matrix().apply {
            setValues(floatArrayOf(1f, 0f, 0f, 0f, 1f, 0f, .01f, 0f, 1f))
        }
        try {
            clipped.transformed(perspective).segmentBounds(8f, 0f, 8f, 20f)
            fail("Perspective segment clipping must refuse unsupported geometry")
        } catch (failure: UnsupportedFloatLayout) {
            assertTrue(failure.message.orEmpty().contains("Perspective"))
        }

        var clicks = 0
        var revealedChild = -1
        var revealedBounds: RectF? = null
        val original = Fragment("", RectF(8f, 0f, 8f, 20f))
        val source = object : FloatTextGeometry by original {
            override val width = 40
            override val nodes = listOf(
                FloatInteractionNode(70, FloatInteractionKind.LINK, 0, 0,
                    listOf(RectF(8f, 0f, 8f, 20f)), "", null, { clicks++ }),
                FloatInteractionNode(71, FloatInteractionKind.LINK, 0, 0,
                    listOf(RectF(31f, 2f, 31f, 6f)), "", null, { clicks++ }),
                FloatInteractionNode(72, FloatInteractionKind.LINK, 0, 0,
                    listOf(RectF(11f, 7f, 11f, 7f)), "", null, { clicks++ }))
            override fun caretRect(offset: Int) = RectF(777f, 1f, 778f, 2f)
            override fun revealNode(id: Int, onRevealed: () -> Unit) {
                revealedChild = id
                onRevealed()
            }
        }
        val fresh = object : FloatTextGeometry by source {
            override val nodes = listOf(
                source.nodes[0].copy(bounds = listOf(RectF(6f, 7f, 6f, 12f))),
                source.nodes[1].copy(bounds = listOf(RectF(28f, 4f, 28f, 9f))),
                source.nodes[2].copy(bounds = listOf(RectF(21f, 5f, 21f, 5f))))
        }
        val placement = NativeTableBlockPlacement(
            borderBox = RectF(0f, 0f, 20f, 20f), contentClip = RectF(5f, 5f, 15f, 15f),
            contentX = 2.5f, contentY = 3f, physicalScrollX = -1.25f,
            gridWidth = 40, gridHeight = 20, captionWidth = 0, captionHeight = 0,
            captionY = 0f, gridY = 0f, ownerWidth = 20, ownerHeight = 20,
            scrollTarget = null, revealContentRect = { rect, done -> revealedBounds = RectF(rect); done() },
            cornerClip = shape)
        val currentPlacement = placement.copy(physicalScrollX = -6f)
        val wrapped = NativeTableViewportGeometry(source, placement) { continuation ->
            continuation(fresh, currentPlacement)
        }
        assertEquals("", wrapped.text.toString())
        assertEquals(listOf(70, 71, 72), wrapped.nodes.map { it.id })
        band(RectF(9.25f, 3f, 9.25f, 23f), wrapped.nodes[0].bounds.single())
        band(RectF(32.25f, 5f, 32.25f, 9f), wrapped.nodes[1].bounds.single())
        band(RectF(12.25f, 10f, 12.25f, 10f), wrapped.nodes[2].bounds.single())
        wrapped.nodes.forEach { node ->
            band(RectF(5f, 5f, 15f, 15f), node.clipBounds)
            assertNotNull(node.preciseClip)
            val raw = node.bounds.single()
            assertFalse(node.contains(raw.left, (raw.top + raw.bottom) / 2f))
        }
        assertNotNull(checkNotNull(wrapped.nodes[0].preciseClip).segmentBounds(9.25f, 3f, 9.25f, 23f))
        assertNull(checkNotNull(wrapped.nodes[1].preciseClip).segmentBounds(32.25f, 5f, 32.25f, 9f))
        assertTrue(checkNotNull(wrapped.nodes[2].preciseClip).contains(12.25f, 10f)) // Point metadata, no segment.
        assertFalse(wrapped.containsInteraction(9.25f, 13f))
        assertNull(wrapped.interactionNodeAt(9.25f, 13f))
        assertTrue(wrapped.characterRects(0, 0).isEmpty())
        assertTrue(wrapped.rectsForRange(0, 0).isEmpty())
        assertSame(source.nodes[1].onClick, wrapped.nodes[1].onClick)
        wrapped.nodes[1].onClick!!.invoke()
        assertEquals(1, clicks)
        var revealed = false
        wrapped.revealNode(71) { revealed = true }
        assertTrue(revealed)
        assertEquals(71, revealedChild)
        band(RectF(28f, 4f, 28f, 9f), revealedBounds) // Fresh owner, never sibling/old band/caret.
        revealed = false
        wrapped.revealNode(72) { revealed = true }
        assertTrue(revealed)
        assertEquals(72, revealedChild)
        band(RectF(21f, 5f, 21f, 5f), revealedBounds) // Exact H0 logical location, no invented visible area.
        val nonDeclaring = object : FloatTextGeometry by original {
            override val nodes = original.nodes.map { it.copy(kind = FloatInteractionKind.CONTROL) } +
                source.nodes[2].copy(kind = FloatInteractionKind.CONTROL)
        }
        assertTrue(viewport(nonDeclaring, RectF(0f, 0f, 20f, 20f), null).nodes.all { it.bounds.isEmpty() })
    }
}
