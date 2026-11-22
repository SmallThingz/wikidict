package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test

/** Unrun JVM controls for source binding and actual border/viewport publication. */
class NativeTableAutoMarginHookTest {
    private val zero = ContainerMargin.Length(StyleLength(StyleLengthUnit.Px, 0f))
    private val auto = ContainerMargins(zero, ContainerMargin.Auto, zero, ContainerMargin.Auto)
    private fun table(direction: TableContainingDirection = TableContainingDirection.Ltr,
        display: TableDisplay? = null, floatSide: TableFloatSide? = null) = Table(emptyList(),
        listOf(listOf(Cell(listOf(Span("text", "body")), false, 1, 1))),
        style = TableStyle(marginValues = auto, containingDirection = direction,
            display = display, floatSide = floatSide))

    @Test fun absentPublicationAndEveryRepeatedBeginRefuseStaleMeasuredGeometry() {
        val source = table()
        val input = NativeTableMarginMeasureInput(source)
        val owner = Any()
        input.bind(owner)
        assertThrows(UnsupportedFloatLayout::class.java) { input.ready(100, 20) }
        input.begin(100, 100, 140)
        assertThrows(UnsupportedFloatLayout::class.java) { input.ready(100, 20) }
        input.publish(owner, source, 140, 20, 100, true)
        assertEquals(NativeTableMarginBox(140, 20, 100, 20, 140, true), input.ready(100, 20))
        // Equal constraints can still have different measured caption or content geometry.
        input.begin(100, 100, 140)
        assertThrows(UnsupportedFloatLayout::class.java) { input.ready(100, 20) }
        input.publish(owner, source, 160, 28, 100, true)
        assertEquals(NativeTableMarginBox(160, 28, 100, 28, 140, true), input.ready(100, 28))
        assertThrows(UnsupportedFloatLayout::class.java) { input.ready(100, 20) }
    }

    @Test fun equalTableValuesStillHaveDifferentSourceOwnership() {
        val source = table()
        val replacement = source.copy()
        assertEquals(source, replacement)
        assertNotEquals(NativeDelegatedTableIdentity(source), NativeDelegatedTableIdentity(replacement))
        val input = NativeTableMarginMeasureInput(source)
        val owner = Any()
        input.bind(owner)
        input.begin(100, 100, 140)
        assertThrows(UnsupportedFloatLayout::class.java) {
            input.publish(owner, replacement, 140, 20, 100, true)
        }
        assertThrows(UnsupportedFloatLayout::class.java) { input.ready(100, 20) }
        input.publish(owner, source, 140, 20, 100, true)
        assertEquals(140, input.ready(100, 20).borderWidth)
    }

    @Test fun replacingOwnerAndDetachingInvalidatePublishedGeometry() {
        val source = table()
        val input = NativeTableMarginMeasureInput(source)
        val first = Any()
        val second = Any()
        input.bind(first)
        input.begin(100, 100, 140)
        input.publish(first, source, 140, 20, 100, true)
        input.bind(second)
        assertThrows(UnsupportedFloatLayout::class.java) { input.ready(100, 20) }
        assertThrows(UnsupportedFloatLayout::class.java) {
            input.publish(first, source, 140, 20, 100, true)
        }
        input.publish(second, source, 140, 20, 100, true)
        input.unbind(first)
        assertEquals(140, input.ready(100, 20).borderWidth)
        input.unbind(second)
        assertThrows(UnsupportedFloatLayout::class.java) { input.ready(100, 20) }
    }

    @Test fun containingReferenceAndViewportAreIndependentAndBothBindTheRequest() {
        val source = table(TableContainingDirection.Rtl)
        val input = NativeTableMarginMeasureInput(source)
        val owner = Any()
        input.bind(owner)
        input.begin(300, 100, 140)
        input.publish(owner, source, 140, 20, 100, true)
        assertEquals(300, input.containingWidth)
        assertEquals(100, input.viewportWidth)
        assertEquals(140, input.ready(100, 20).minimumWidth)
        input.begin(200, 90, 140)
        assertThrows(UnsupportedFloatLayout::class.java) { input.ready(100, 20) }
        assertThrows(UnsupportedFloatLayout::class.java) {
            input.publish(owner, source, 140, 20, 100, true)
        }
        input.publish(owner, source, 140, 20, 90, true)
        assertEquals(200, input.containingWidth)
        assertEquals(NativeTableMarginBox(140, 20, 90, 20, 140, true), input.ready(90, 20))
    }

    @Test fun viewportCoercionAndInvalidMeasuredBoxesUseTheUnavailableLayoutPath() {
        val source = table()
        val input = NativeTableMarginMeasureInput(source)
        val owner = Any()
        input.bind(owner)
        input.begin(100, 100, 140)
        assertThrows(UnsupportedFloatLayout::class.java) {
            input.publish(owner, source, 120, 20, 100, true)
        }
        assertThrows(UnsupportedFloatLayout::class.java) {
            input.publish(owner, source, 140, 20, 100, false)
        }
        assertThrows(UnsupportedFloatLayout::class.java) {
            input.publish(owner, source, TablePixelLimit + 1, 20, 100, true)
        }
        input.publish(owner, source, 140, 20, 100, true)
        assertThrows(UnsupportedFloatLayout::class.java) { input.ready(140, 20) }
        assertThrows(UnsupportedFloatLayout::class.java) { input.ready(100, 21) }
        assertEquals(140, input.ready(100, 20).borderWidth)
    }

    @Test fun nestedUnclippedBorderHasTheSameMeasuredAndViewportOwner() {
        val source = table(TableContainingDirection.Rtl)
        val input = NativeTableMarginMeasureInput(source)
        val owner = Any()
        input.bind(owner)
        input.begin(100, 140, 140)
        input.publish(owner, source, 140, 20, 140, false)
        val box = input.ready(140, 20)
        assertFalse(box.scrolling)
        assertEquals(box.borderWidth, box.viewportWidth)
        assertEquals(100, input.containingWidth)
        assertThrows(UnsupportedFloatLayout::class.java) {
            input.begin(TablePixelLimit + 1, 140, 140)
        }
        assertThrows(UnsupportedFloatLayout::class.java) { input.ready(140, 20) }
    }

    @Test fun autoMarginsEnrollTheirSharedBlockContextWithoutInventingAFloat() {
        val ordinary = Block("table", 0, emptyList(), table = table())
        assertTrue(ordinary.needsNativeBlockContext())
        assertFalse(ordinary.hasBodyFloat())
        assertTrue(listOf(ordinary).needsNativeBlockSequence(null))
        val old = ordinary.copy(table = Table(emptyList(), ordinary.table!!.rows,
            style = TableStyle(width = StyleWidth(StyleWidthUnit.Px, 100f))))
        assertFalse(old.needsNativeBlockContext())
        val inline = ordinary.copy(table = table(display = TableDisplay.InlineTable))
        assertFalse(inline.needsNativeBlockContext())
        assertFalse(inline.hasBodyFloat())
        val floated = ordinary.copy(table = table(floatSide = TableFloatSide.Right))
        assertTrue(floated.needsNativeBlockContext())
        assertTrue(floated.hasBodyFloat())
    }
}
