package app.smallthingz.dict

import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.sp
import org.junit.Assert.*
import org.junit.Test

class NativeSectionHeadingTest {
    @Test fun namedFamilyAdmissionKeepsOrderAndRequestedVariantAndNeverConvertsFailureToAbsence() {
        val family = ContainerFontFamily.Stack(listOf("First Source Family", "Second Source Family"), GenericFontFamily.Serif)
        val observations = mutableListOf<Triple<String, FontWeight, FontStyle>>()
        fun admit(weight: FontWeight, style: FontStyle, loaded: String? = null) =
            nativeContainerFontAdmission(family, weight, style) { name, requestedWeight, requestedStyle ->
                observations += Triple(name, requestedWeight, requestedStyle)
                name == loaded
            }
        assertEquals(FontFamily.Serif, admit(FontWeight.Normal, FontStyle.Normal).getOrThrow())
        assertEquals(family.names.map { Triple(it, FontWeight.Normal, FontStyle.Normal) }, observations)
        observations.clear()
        assertEquals(NativeNamedFamilyUnavailable,
            admit(FontWeight.Bold, FontStyle.Italic, "Second Source Family").exceptionOrNull()!!.message)
        assertEquals(family.names.map { Triple(it, FontWeight.Bold, FontStyle.Italic) }, observations)
        assertEquals(NativeNamedFamilyProbeUnavailable, nativeContainerFontAdmission(family,
            FontWeight(550), FontStyle.Normal) { _, _, _ -> throw IllegalStateException("unavailable platform probe") }
            .exceptionOrNull()!!.message)
        assertEquals(FontFamily.Serif, admit(FontWeight.Bold, FontStyle.Italic).getOrThrow())
        assertEquals(listOf("First Source Family", "Second Source Family"), family.names)
        for ((policy, expected) in listOf(null to null, ContainerFontFamily.SansSerif to FontFamily.SansSerif,
            ContainerFontFamily.Stack(emptyList(), GenericFontFamily.Serif) to FontFamily.Serif)) {
            assertEquals(expected, nativeContainerFontAdmission(policy, FontWeight.Normal, FontStyle.Normal) { _, _, _ ->
                error("A terminal generic must not invent a named-font lookup")
            }.getOrThrow())
        }
    }

    @Test fun familyInheritancePreservesTraitsAndContainerLineHeightUsesItsExistingBasisOnce() {
        val density = Density(1.25f, 1.5f)
        val family = ContainerFontFamily.Stack(emptyList(), GenericFontFamily.Serif)
        val inherited = TextStyle(fontSize = 36.sp, fontFamily = FontFamily.Monospace,
            fontWeight = FontWeight.Bold, fontStyle = FontStyle.Italic, fontFeatureSettings = "'liga' 0")
        val context = ContainerStyle(ownerFontScale = 2f, fontFamily = family,
            lineHeight = ContainerLineHeight.Length(StyleLength(StyleLengthUnit.Em, 1f)))
            .textContext(ContainerTextContext())
        val format = nativeContainerTextFormat(context, 20.sp, inherited, density)
        assertEquals(40.sp, format.style.fontSize)
        assertEquals(FontFamily.Serif, format.style.fontFamily)
        assertEquals(FontWeight.Bold, format.style.fontWeight)
        assertEquals(FontStyle.Italic, format.style.fontStyle)
        assertEquals("'liga' 0", format.style.fontFeatureSettings)
        assertSame(family, format.sourceFamily)
        assertEquals(NativeLineHeightPolicy.Pixels(37.5f), format.lineHeight)
        val px = nativeContainerTextFormat(context.copy(lineHeight = ContainerLineHeight.Length(
            StyleLength(StyleLengthUnit.Px, 3f))), 20.sp, inherited, density)
        assertEquals(NativeLineHeightPolicy.Pixels(3.75f), px.lineHeight)
        val number = nativeContainerTextFormat(context.copy(lineHeight = ContainerLineHeight.Multiplier(1.5f)),
            20.sp, inherited, density)
        assertEquals(NativeLineHeightPolicy.Multiplier(1.5f), number.lineHeight)
        val zero = nativeContainerTextFormat(context.copy(ownerFontScale = 0f), 20.sp, inherited, density)
        assertEquals(0.sp, zero.style.fontSize)
        assertEquals(NativeLineHeightPolicy.Pixels(37.5f), zero.lineHeight)
        assertSame(family, ContainerStyle().textContext(context).fontFamily)
        val legacy = nativeContainerTextFormat(ContainerTextContext(), 20.sp, inherited, density)
        assertNull(legacy.sourceFamily)
        assertEquals(inherited.copy(fontSize = 20.sp), legacy.style)
    }

    @Test fun headingWrapsTheSameChildWithFractionalEdgesAndRefusesUnprovedOverconstraint() {
        fun px(value: Float) = StyleLength(StyleLengthUnit.Px, value)
        val box = ContainerStyle(margins = StyleEdges(StyleLength(StyleLengthUnit.Em, .5f), px(1.25f), px(0f), px(.25f)),
            padding = StyleEdges(px(2f), px(3f), px(4f), px(5f)), border = ContainerBorder.None,
            clear = FigureClear.Both, ownerFontScale = 2f, lineHeight = ContainerLineHeight.Multiplier(1f),
            fontFamily = ContainerFontFamily.SansSerif)
        val font = InlineFontSnapshot(fontScale = 2f, fontScaleBasis = FontScaleBasis.NormalBody, language = "th")
        val prepared = PreparedNativeFloatText("Heading", null, Any(), null, {}, fallback = {})
        val child = NativeFloatContextSpec.Text(prepared, 0f, "heading-0",
            ParagraphBox(ParagraphEdges(), ParagraphEdges(), 0f, 0f))
        val intrinsic = ContainerWidths(8f, 200f)
        for (direction in BidiResolvedDirection.entries) {
            val spec = nativeSectionHeadingSpec(10, SectionHeadingStyle(box, font, direction), child, 1.5f, 40f, false)
            assertTrue(spec.isolatesFloats)
            assertEquals(FigureClear.Both, spec.clear)
            assertSame(child, spec.preparedParts!!.single())
            assertNull(spec.unavailableReason)
            assertEquals(20f, spec.margins(100).top, 0f)
            assertEquals(85, spec.contentWidth(100, intrinsic))
            val horizontal = spec.horizontal!!(100, intrinsic)
            assertEquals(.375f, horizontal.borderLeft, .001f)
            assertEquals(97.75f, horizontal.borderWidth, .001f)
            assertEquals(7.875f, horizontal.contentLeft, .001f)
            assertEquals(85.75f, horizontal.content, .001f)
            val failure = assertThrows(UnsupportedFloatLayout::class.java) { spec.contentWidth(10, intrinsic) }
            assertEquals("An overconstrained heading box requires its containing direction.", failure.message)
            assertEquals(85, spec.contentWidth(100, intrinsic))
            val allocation = checkNotNull(spec.headingAllocation)
            val requestedWidths = mutableListOf<Float>()
            val placed = placeNativeFloatBlock(100f, 0f, listOf(NativeFloatExclusion(TableFloatSide.Left,
                NativeFloatBounds(0f, 0f, 85.755f, 6.5f))), strictWidth = true) { request ->
                requestedWidths += request.availableWidth
                val solved = allocation.horizontal(request.availableWidth)
                NativeBlockMeasure(solved.allocation, allocation.minimumWidth, 4f)
            }
            // A band .005px below the fixed edges must move below, without solving
            // an overconstrained box using an unrepresented containing direction.
            assertEquals(listOf(100f, 100f), requestedWidths)
            assertEquals(6.5f, placed.bounds.top, 0f)
            assertEquals(0f, placed.bounds.left, 0f)
        }
    }
}
