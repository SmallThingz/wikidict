package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test

class ColorSwatchTest {
    private fun feature(kind: String = "color_swatch", data: String) = Feature(kind, "", data, "none", "")
    @Test fun canonicalRgbUsesOpaqueColorWithoutChangingItsLabel() {
        assertEquals(ColorSwatch("#ffff00", 0xffffff00L), colorSwatch(feature(data = "#ffff00")))
        assertEquals(ColorSwatch("#0012ab", 0xff0012abL), colorSwatch(feature(data = "#0012ab")))
    }
    @Test fun unknownMalformedAndSourceLikeValuesKeepTableFallback() {
        assertNull(colorSwatch(null))
        assertNull(colorSwatch(feature("future_feature", "#ffff00")))
        assertNull(colorSwatch(Feature("color_swatch", "af", "#ffff00", "none", "")))
        assertNull(colorSwatch(Feature("color_swatch", "", "#ffff00", "text", "note")))
        assertNull(colorSwatch(Feature("color_swatch", "", "#ffff00", "none", "note")))
        for (data in listOf("#FFFF00", "#ff0", "#ffff0000", "ffff00", " #ffff00", "#ffff00 ", "#gggggg", "background:#ffff00", ""))
            assertNull("Must preserve table for $data", colorSwatch(feature(data = data)))
    }
    @Test fun compiledCellBackgroundIsOpaqueCanonicalRgbWithoutFeatureOrLabel() {
        assertEquals(0xffeeeeeeL, canonicalColorArgb("#eeeeee"))
        assertEquals(0xff000000L, canonicalColorArgb("#000000"))
        assertNull(canonicalColorArgb(null))
        for (value in listOf("", "red", "#EEEEEE", "#eee", "#gggggg", "background:#eeeeee")) assertNull(canonicalColorArgb(value))
    }

}
