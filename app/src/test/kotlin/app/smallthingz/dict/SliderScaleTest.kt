package app.smallthingz.dict
import org.junit.Assert.*
import org.junit.Test
class SliderScaleTest {
    @Test fun logSlidersIncludeZeroAreMonotonicAndRoundTripEverySetting() {
        for (scale in listOf(SliderScale(0,1024,true),SliderScale(0,500,true),SliderScale(3,50))) {
            for (value in scale.min..scale.max) assertEquals(value,scale.value(scale.position(value)))
            assertEquals(scale.min,scale.value(0f));assertEquals(scale.max,scale.value(1f))
            val values = (0..1000).map { scale.value(it/1000f) }
            assertTrue(values.zipWithNext().all { (a,b) -> a<=b })
        }
        assertTrue(SliderScale(0,1024,true).value(.5f)<100)
    }
}
