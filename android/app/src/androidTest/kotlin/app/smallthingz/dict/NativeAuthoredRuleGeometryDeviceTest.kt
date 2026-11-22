package app.smallthingz.dict

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.RectF
import android.text.SpannableString
import android.text.TextPaint
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

/** Native geometry controls; no source corpus, activity tree or raster acquisition is simulated. */
@RunWith(AndroidJUnit4::class)
class NativeAuthoredRuleGeometryDeviceTest {
    private val paint = TextPaint().apply { textSize = 20f }
    private fun rule(id: Int, height: Float, top: Float = 0f, bottom: Float = 0f,
        left: Float = 0f, right: Float = 0f, fill: Int? = Color.RED, containing: Float? = null) =
        NativeFloatContextPart.Rule(id, NativeRuleMetrics(height, fill,
            FloatMargins(top, right, bottom, left)), containing)
    private fun text(value: String, action: (() -> Unit)? = null,
        observed: (List<NativeFloatExclusion>) -> Unit = {}) = NativeFloatContextPart.Text(value, { width, carried ->
        observed(carried)
        NativeFloatGeometry.build(SpannableString(value), paint, width, emptyList(), carriedExclusions = carried,
            nodeFactory = { geometry -> if (action == null) emptyList() else listOf(FloatInteractionNode(1,
                FloatInteractionKind.LINK, 0, value.length, geometry.rectsForRange(0, value.length), value, null, action)) })
    })
    private fun group(id: Int, parts: List<NativeFloatContextPart>) = NativeFloatContextPart.Container(id, 200,
        { _, _ -> error("Prepared rule groups must retain their original parts") }, preparedParts = parts)

    @Test fun rulesDoNotCreateCopyCharactersOrTakeThePrecedingTextCaret() {
        val clicked = mutableListOf<String>()
        val first = text("A", { clicked += "A" })
        val last = text("B", { clicked += "B" })
        val geometry = NativeFloatContextGeometry.build(200, listOf(first, rule(1, .25f),
            group(20, listOf(rule(2, .75f), rule(3, 0f))), last), adjoining = true)
        assertEquals("A\nB", geometry.text.toString())
        val firstOwner = checkNotNull(geometry.textPaintPart(0))
        val expectedCaret = firstOwner.geometry.caretRect(1).apply { offset(firstOwner.x, firstOwner.y) }
        assertEquals(expectedCaret, geometry.caretRect(1))
        assertEquals(0 to 2, geometry.lineRange(1))
        assertEquals(2 to 3, geometry.lineRange(2))
        assertEquals(3, geometry.nodes.count { it.kind == FloatInteractionKind.SEPARATOR })
        val actions = geometry.nodes.filter { it.onClick != null }
        assertEquals(listOf(0, 2), actions.map { it.start })
        actions.forEach { checkNotNull(it.onClick).invoke() }
        assertEquals(listOf("A", "B"), clicked)
        assertEquals(2, geometry.characterRects(0, 3).count { it != null })
        assertTrue(geometry.nodes.filter { it.kind == FloatInteractionKind.SEPARATOR }.all {
            it.start == it.end && it.onClick == null
        })
    }

    @Test fun fractionalSourceHeightAndMarginsAdvanceWithoutCeilPadding() {
        val geometry = NativeFloatContextGeometry.build(100, listOf(
            rule(1, .25f, 3.125f, 7.5f, left = 2.25f, right = 3.5f, containing = 100.5f),
            rule(2, .75f, 5.25f, 2.5f, containing = 100.5f)), adjoining = true)
        assertEquals("", geometry.text.toString())
        assertNull(geometry.textBaselines)
        assertTrue(geometry.children.isEmpty())
        assertEquals(14.125f, geometry.usedHeight, 0f)
        assertEquals(15, geometry.height)
        val first = checkNotNull(geometry.textPaintPart(0))
        val last = checkNotNull(geometry.textPaintPart(1))
        assertEquals(3.125f, first.y, 0f)
        assertEquals(10.875f, last.y, 0f)
        assertEquals(2.25f, first.x, 0f)
        assertEquals(94.75f, (first.geometry as NativeRuleGeometry).contentWidth, 0f)
        assertEquals(1, first.geometry.height)
        assertEquals(.25f, first.geometry.extents.usedHeight, 0f)
        assertEquals(RectF(2.25f, 3.125f, 97f, 3.375f), geometry.nodes.first().bounds.single())
        assertEquals(14.125f, geometry.scrollableBounds.bottom, 0f)
    }

    @Test fun zeroHeightAdjoinsThroughAndHasNoGeneratedTextLine() {
        val zero = NativeFloatContextGeometry.build(100, listOf(rule(1, 0f)), adjoining = true)
        assertEquals(0, zero.height)
        assertEquals(0f, zero.usedHeight, 0f)
        assertNull(zero.textBaselines)
        assertTrue(zero.rectsForRange(0, 0).isEmpty())
        fun followingTop(height: Float): Float {
            val geometry = NativeFloatContextGeometry.build(100, listOf(rule(1, 10f, bottom = 4f),
                rule(2, height, 7f, 11f), rule(3, 1f, top = 8f)), adjoining = true)
            return checkNotNull(geometry.textPaintPart(2)).y
        }
        assertEquals(21f, followingTop(0f), 0f)
        assertEquals(28.25f, followingTop(.25f), 0f)
    }

    @Test fun ordinaryRuleKeepsFullWidthBeforeDisjointFloatsWithoutClearing() {
        val inherited = listOf(
            NativeFloatExclusion(TableFloatSide.Left, NativeFloatBounds(0f, 8f, 30f, 100f)),
            NativeFloatExclusion(TableFloatSide.Right, NativeFloatBounds(170f, 8f, 200f, 100f)))
        var following: List<NativeFloatExclusion>? = null
        val geometry = NativeFloatContextGeometry.build(200, listOf(rule(1, 8f),
            text("following body", observed = { following = it })), carriedExclusions = inherited, adjoining = true)
        val separator = checkNotNull(geometry.textPaintPart(0))
        assertEquals(0f, separator.y, 0f)
        assertEquals(200f, (separator.geometry as NativeRuleGeometry).contentWidth, 0f)
        assertEquals(8f, checkNotNull(geometry.textPaintPart(1)).y, 0f)
        assertEquals(inherited.map { it.copy(outer = it.outer.translated(0f, -8f)) }, following)
        assertTrue(geometry.ownExclusions.isEmpty())
        assertFalse(RectF(geometry.nodes.first { it.kind == FloatInteractionKind.SEPARATOR }.bounds.single()).intersect(
            RectF(0f, 8f, 30f, 100f)))
        assertEquals("following body", geometry.text.toString())
    }

    @Test fun positiveRuleRefusesOnlyIntersectingInheritedOrOwnedFloatGeometry() {
        val overlap = NativeFloatExclusion(TableFloatSide.Left, NativeFloatBounds(0f, 0f, 30f, 40f))
        for (fill in listOf(Color.RED, null)) {
            val failure = assertThrows(UnsupportedFloatLayout::class.java) {
                NativeFloatContextGeometry.build(200, listOf(rule(1, 8f, fill = fill)),
                    carriedExclusions = listOf(overlap), adjoining = true)
            }
            assertEquals("Authored rule overlaps a float without shared paint and hit order", failure.message)
        }
        val owned = NativeFloatContextPart.Child(2, NativeBlockWidth.FixedPx(30f),
            { NativeBlockMeasure(30f, 30f, 40f) }, floatSide = TableFloatSide.Left, logicalObject = false)
        assertThrows(UnsupportedFloatLayout::class.java) {
            NativeFloatContextGeometry.build(200, listOf(owned, rule(1, 8f)), adjoining = true)
        }
        for (allowed in listOf(rule(1, 0f), rule(1, 8f, left = 200f),
                rule(1, 8f, left = 30f), rule(1, 8f, left = 30f, fill = null))) {
            val geometry = NativeFloatContextGeometry.build(200, listOf(allowed),
                carriedExclusions = listOf(overlap), adjoining = true)
            assertEquals(0f, checkNotNull(geometry.textPaintPart(0)).y, 0f)
            assertEquals(allowed.metrics.height, geometry.usedHeight, 0f)
            assertTrue(geometry.ownExclusions.isEmpty())
        }
        val expired = overlap.copy(outer = NativeFloatBounds(0f, -40f, 30f, 0f))
        val after = NativeFloatContextGeometry.build(200, listOf(rule(1, 8f)),
            carriedExclusions = listOf(expired), adjoining = true)
        assertEquals(0f, checkNotNull(after.textPaintPart(0)).y, 0f)
        assertEquals(8f, after.usedHeight, 0f)
    }

    @Test fun aggregateOrdinaryPaintUsesAuthoredFillWhileTransparentKeepsLayout() {
        val opaque = NativeFloatContextGeometry.build(20, listOf(rule(1, 3f, top = 2f, bottom = 4f,
            left = 2f, right = 3f)), adjoining = true)
        val transparent = NativeFloatContextGeometry.build(20, listOf(rule(1, 3f, top = 2f, bottom = 4f,
            left = 2f, right = 3f, fill = null)), adjoining = true)
        assertEquals(opaque.usedHeight, transparent.usedHeight, 0f)
        assertEquals(opaque.nodes.single().bounds, transparent.nodes.single().bounds)
        val bitmap = Bitmap.createBitmap(20, 9, Bitmap.Config.ARGB_8888)
        try {
            bitmap.eraseColor(Color.TRANSPARENT)
            opaque.paintOrdinary(Canvas(bitmap))
            assertEquals(Color.RED, bitmap.getPixel(3, 3))
            assertEquals(Color.TRANSPARENT, bitmap.getPixel(1, 3))
            assertEquals(Color.TRANSPARENT, bitmap.getPixel(3, 1))
            assertEquals(Color.TRANSPARENT, bitmap.getPixel(17, 3))
            bitmap.eraseColor(Color.TRANSPARENT)
            transparent.paintOrdinary(Canvas(bitmap))
            assertEquals(Color.TRANSPARENT, bitmap.getPixel(3, 3))
        } finally { bitmap.recycle() }
    }
}
