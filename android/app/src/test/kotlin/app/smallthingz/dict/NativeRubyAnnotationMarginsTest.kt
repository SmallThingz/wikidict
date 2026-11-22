package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test

class NativeRubyAnnotationMarginsTest {
    @Test fun readingEmAndCssPixelsResolveIndependentlyBeforeMarginReservation() {
        val source = RubyAnnotationMargins(StyleLength(unit = StyleLengthUnit.Em, value = .25f),
            StyleLength(unit = StyleLengthUnit.Px, value = 1.5f))
        val first = nativeRubyAnnotationMargins(source, declaringFontPixels = 14.4f, density = 1.75f)
        assertEquals(3.6f, first.top, .00001f)
        assertEquals(2.625f, first.bottom, 0f)
        val larger = nativeRubyAnnotationMargins(source, declaringFontPixels = 28.8f, density = 1.75f)
        assertEquals(7.2f, larger.top, .00001f)
        assertEquals(first.bottom, larger.bottom, 0f)
        val content = NativeUsedLineMetrics(-9.25f, 2.5f)
        assertEquals(NativeUsedLineMetrics(-12.85f, 5.125f), first.reservation(content))
        assertEquals(NativeUsedLineMetrics(-9.25f, 2.5f), content)
        assertEquals(content, NativeRubyAnnotationMargins(0f, 0f).reservation(content))
        val zeroFont = nativeRubyAnnotationMargins(source, 0f, 1.75f)
        assertEquals(0f, zeroFont.top, 0f)
        assertEquals(2.625f, zeroFont.bottom, 0f)
    }

    @Test fun physicalMarginBoxRetainsSignedMetricsAndRejectsUnrepresentableEdges() {
        val above = NativeUsedLineMetrics(-12f, -4f)
        val below = NativeUsedLineMetrics(3f, 11f)
        val margin = NativeRubyAnnotationMargins(2.25f, 3.5f)
        assertEquals(NativeUsedLineMetrics(-14.25f, -.5f), margin.reservation(above))
        assertEquals(NativeUsedLineMetrics(.75f, 14.5f), margin.reservation(below))
        fun unavailable(body: () -> Unit) {
            try { body(); fail("Expected native geometry refusal") }
            catch (_: UnsupportedFloatLayout) { }
        }
        unavailable { NativeRubyAnnotationMargins(Float.NaN, 0f) }
        unavailable { NativeRubyAnnotationMargins(-1f, 0f) }
        unavailable { NativeRubyAnnotationMargins(Float.MAX_VALUE, 0f) }
        unavailable { NativeRubyAnnotationMargins(0f, TablePixelLimit.toFloat())
            .reservation(NativeUsedLineMetrics(-1f, 100f)) }
        unavailable { nativeRubyAnnotationMargins(RubyAnnotationMargins(
            StyleLength(unit = StyleLengthUnit.Em, value = 2f), StyleLength(unit = StyleLengthUnit.Px, value = 0f)),
            TablePixelLimit.toFloat(), 1f) }
        assertEquals(NativeUsedLineMetrics(-3.25f, 5.5f), margin.reservation(NativeUsedLineMetrics(-1f, 2f)))
    }
}
