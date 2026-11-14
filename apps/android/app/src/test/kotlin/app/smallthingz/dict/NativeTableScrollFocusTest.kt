package app.smallthingz.dict

import android.view.KeyEvent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.roundToInt

class NativeTableScrollFocusTest {
    @Test fun physicalKeyboardDistancesUsePlatformStepAndFractionalSourceRange() {
        fun distance(key: Int, alt: Boolean = false, shift: Boolean = false) =
            nativeTableFocusKeyDistance(key, alt, shift, 17.5f, 81.75f, 12.5f, 38.25f)
        assertEquals(-17.5f, distance(KeyEvent.KEYCODE_DPAD_LEFT)!!, 0f)
        assertEquals(17.5f, distance(KeyEvent.KEYCODE_DPAD_RIGHT)!!, 0f)
        assertEquals(-39f, distance(KeyEvent.KEYCODE_DPAD_LEFT, alt = true)!!, 0f)
        assertEquals(39f, distance(KeyEvent.KEYCODE_MOVE_END)!!, 0f)
        assertEquals(-81.75f, distance(KeyEvent.KEYCODE_SPACE, shift = true)!!, 0f)
        assertEquals(81.75f, distance(KeyEvent.KEYCODE_PAGE_DOWN)!!, 0f)
        assertNull(distance(KeyEvent.KEYCODE_TAB))
        assertNull(nativeTableFocusKeyDistance(KeyEvent.KEYCODE_MOVE_END, false, false,
            17.5f, 81.75f, 39f, 38.25f))
        for (rtl in listOf(false, true)) {
            val start = tableBlockScrollGeometry(81.75f, 120, 12, rtl)
            val endRequest = nativeTableFocusKeyDistance(KeyEvent.KEYCODE_MOVE_END, false, false,
                17.5f, 81.75f, -start.physicalTranslation, start.overflow)!!
            val endValue = (12f + if (rtl) -endRequest else endRequest).coerceIn(0f, 39f).roundToInt()
            val end = tableBlockScrollGeometry(81.75f, 120, endValue, rtl)
            assertEquals(-38.25f, end.physicalTranslation, 0f)
            val homeRequest = nativeTableFocusKeyDistance(KeyEvent.KEYCODE_MOVE_HOME, false, false,
                17.5f, 81.75f, -end.physicalTranslation, end.overflow)!!
            val homeValue = (endValue + if (rtl) -homeRequest else homeRequest).coerceIn(0f, 39f).roundToInt()
            assertEquals(0f, tableBlockScrollGeometry(81.75f, 120, homeValue, rtl).physicalTranslation, 0f)
        }
    }

    @Test fun sameSourceBindingRetainsExactRangeWhileWideAndRefusalDisableScrolling() {
        val owner = NativeTableScrollFocusOwner(TableScrollFocusPaint(TableScrollFocusMode.UaAuto))
        var offset = 0f
        var moves = 0
        val target = object : NativeHorizontalScrollTarget {
            override fun scrollBy(physicalDistance: Float): Float {
                moves++
                val previous = offset
                offset = (offset + physicalDistance).coerceIn(0f, 38.25f)
                return offset - previous
            }
            override fun fling(physicalVelocity: Float) = Unit
            override fun cancel() = Unit
        }
        owner.update(true, 81.75f, offset, 38.25f, target, null)
        assertTrue(owner.canAcquireFocus)
        assertFalse(owner.requestSourceFocus()) // No View is manufactured by the state owner.
        assertTrue(owner.scrollBy(100f))
        assertEquals(38.25f, offset, 0f)
        owner.update(true, 81.75f, offset, 38.25f, target, null)
        assertEquals(38.25f, owner.physicalOffset, 0f)
        assertEquals(38.25f, owner.overflow, 0f)
        owner.update(false, 120f, 0f, 0f, null, null)
        assertFalse(owner.canAcquireFocus)
        assertFalse(owner.scrollBy(-20f))
        assertEquals(1, moves)
        owner.update(true, 81.75f, offset, 38.25f, target, null)
        assertTrue(owner.scrollBy(-12.5f))
        assertEquals(25.75f, offset, 0f)
        owner.unavailable()
        assertFalse(owner.canAcquireFocus)
        assertFalse(owner.scrollBy(-1f))
        owner.update(true, 161f, 0f, 0f, target, null)
        assertTrue(owner.canAcquireFocus)
        assertFalse(owner.canScroll)
        assertFalse(owner.scrollBy(1f))
        assertEquals(2, moves)
        owner.close()
        owner.update(true, 81.75f, 0f, 38.25f, target, null)
        assertFalse(owner.canAcquireFocus)
    }
}
