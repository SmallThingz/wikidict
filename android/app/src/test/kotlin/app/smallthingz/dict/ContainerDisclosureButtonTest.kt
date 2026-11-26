package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test

/** Integrate under android/app/src/test/kotlin/app/smallthingz/dict/.
 * Minimal NEW JVM delta inputs: patched ContainerStyle.kt, new ContainerDisclosureButton.kt,
 * new NativeContainerDisclosureButtonGeometry.kt, and this test. Supply the matching existing
 * model/support module (same module or friend path), JDK 17, Kotlin stdlib, JUnit 4.13+ and Hamcrest.
 * Direct existing value dependencies: Model.kt, FigureTableCaptionStyle.kt; geometry dependencies:
 * NativeUsedLineMetrics.kt (NativeGeometryExtents/NativeSurfaceBox), NativeFloatBounds from
 * NativeFloatBlockPlacement.kt, UnsupportedFloatLayout from NativeFloatGeometry.kt.
 * This is a delta list, NOT a verified standalone source closure: ContainerStyle.kt also uses
 * NativeCellTextState/NativeContainerTextState/NativeBodyTextOrigin/NativeLineHeightPolicy.
 * Reuse a qualified local support module; do not create substitute model stubs or invoke SDK builds/downloads.
 * Do not add painter/toggle/Compose adapter sources to the JVM-only target.
 * New value/geometry tests only. Does not qualify fonts, UA painting, Android View input or public encoding.
 * Source capture: c5b0e5998409bf5f26dae8d7dbb9160402b4ea016e07356e317a0e4f94873c4e.
 */
class ContainerDisclosureButtonTest {
    private fun px(value: Float) = StyleLength(StyleLengthUnit.Px, value)
    private fun edges(edge: ResolvedStyleBorderEdge) = StyleBorder.ResolvedEdges(edge, edge, edge, edge)
    private fun state(color: String, pressed: Boolean = false) = ContainerDisclosureButtonState(FigureColor.Rgb(color),
        edges(if (pressed) ResolvedStyleBorderEdge.Inset(px(2f), StyleBorderPaint.Rgb("#000000"))
              else ResolvedStyleBorderEdge.Outset(px(2f), StyleBorderPaint.Rgb("#000000"))))
    private fun button() = ContainerDisclosureButton(ContainerDisclosureButtonAppearance.NativeButton,
        ContainerDisclosureNamedFont("Arial"), px(13.3333f), 400, false, ContainerLineHeight.Normal,
        StyleEdges(px(1f), px(6f), px(1f), px(6f)), state("#efefef"), state("#efefef"),
        state("#efefef", true), state("#efefef", true),
        ContainerDisclosureButtonFocus(ContainerDisclosureFocusMode.UaAuto,
            FigureFocusOutline(px(1f), FigureColor.Rgb("#3366cc"), px(0f), px(0f))))

    @Test fun independentFourStateChoicePreservesAllSourceValues() {
        val b = button().copy(hover = state("#111111"), active = state("#222222", true),
            hoverActive = state("#333333", true))
        assertSame(b.normal,b.state(false,false)); assertSame(b.hover,b.state(true,false))
        assertSame(b.active,b.state(false,true)); assertSame(b.hoverActive,b.state(true,true))
        assertEquals("Arial",b.fontFamily.name)
        assertEquals(13.3333f,b.fontSize.value,0f)
    }

    @Test fun capturedPaddingAndBordersContributeToBothIntrinsicAndUsedBox() {
        val b = button()
        val insets = nativeDisclosureButtonInsets(b,b.normal,1f)
        assertEquals(NativeDisclosureButtonInsets(3f,8f,3f,8f),insets)
        assertEquals(16f,insets.horizontal,0f); assertEquals(6f,insets.vertical,0f)
        assertEquals(NativeDisclosureButtonInsets(6f,16f,6f,16f),nativeDisclosureButtonInsets(b,b.active,2f))
        val label = NativeGeometryExtents(40,15.25f,NativeFloatBounds(-2f,-1f,42f,16f),null)
        val measured = nativeDisclosureButtonExtents(56f,15.25f,label,insets,
            nativeDisclosureButtonFocusOverflow(b,1f))
        assertEquals(56,measured.usedWidth); assertEquals(21.25f,measured.usedHeight,0f)
        assertEquals(NativeFloatBounds(-1f,-1f,57f,22.25f),measured.ink)
        assertEquals(NativeFloatBounds(0f,0f,56f,21.25f),measured.interaction)
        assertEquals(NativeSurfaceBox(-1,-1,58,24),NativeSurfaceBox.from(measured))
    }

    @Test fun signedGlyphInkRemainsOutsideBoxWithoutInflatingParentFlowHeight() {
        val b=button().copy(focusVisible=null)
        val text=NativeGeometryExtents(40,15f,NativeFloatBounds(-20f,-12f,70f,30f),null)
        val measured=nativeDisclosureButtonExtents(56f,15f,text,nativeDisclosureButtonInsets(b,b.normal,1f),0f)
        assertEquals(21f,measured.usedHeight,0f)
        assertEquals(NativeFloatBounds(-12f,-9f,78f,33f),measured.ink)
        assertEquals(NativeSurfaceBox(-12,-9,90,42),NativeSurfaceBox.from(measured))
    }

    @Test fun noVisibleBorderRetainsPaddingAndNoExtraStrokeWidth() {
        val b=button()
        val state=ContainerDisclosureButtonState(FigureColor.Transparent,
            StyleBorder.ResolvedEdges(ResolvedStyleBorderEdge.None,ResolvedStyleBorderEdge.Hidden,
                ResolvedStyleBorderEdge.None,ResolvedStyleBorderEdge.Hidden))
        assertEquals(NativeDisclosureButtonInsets(1f,6f,1f,6f),nativeDisclosureButtonInsets(b,state,1f))
    }

    @Test fun visibleFocusOverridesComputedColorButColorsAloneCreateNoGeometry() {
        val b=button().copy(outlineColors=ContainerDisclosureButtonOutlineColors(
            FigureColor.Rgb("#111111"),FigureColor.Rgb("#222222")))
        assertEquals(FigureColor.Rgb("#111111"),b.outlineColor(false,false))
        assertEquals(FigureColor.Rgb("#222222"),b.outlineColor(true,false))
        assertEquals(FigureColor.Rgb("#3366cc"),b.outlineColor(true,true))
        assertThrows(IllegalArgumentException::class.java) { b.outlineColor(false,true) }
        val colorsOnly=b.copy(focusVisible=null)
        assertEquals(FigureColor.Rgb("#222222"),colorsOnly.outlineColor(true,true))
        assertEquals(0f,nativeDisclosureButtonFocusOverflow(colorsOnly,2f),0f)
        assertNull(button().outlineColor(false,false)); assertNull(button().outlineColor(true,false))
    }

    @Test fun signedFocusOffsetDoesNotChangeUsedBoxAndNoNullBecomesKnownAbsence() {
        val b=button()
        val focus=checkNotNull(b.focusVisible)
        val inward=b.copy(focusVisible=focus.copy(outline=focus.outline.copy(offset=SignedContainerMargin(StyleLengthUnit.Px,-2f))))
        val outward=b.copy(focusVisible=focus.copy(outline=focus.outline.copy(offset=px(3f))))
        assertEquals(0f,nativeDisclosureButtonFocusOverflow(inward,2f),0f)
        assertEquals(8f,nativeDisclosureButtonFocusOverflow(outward,2f),0f)
        assertNull(b.outlineColors)
    }

    @Test fun legacyNullButtonAndFocusRemainValidButDualFocusOwnerRejects() {
        val focus=ContainerDisclosureFocusPaint(ContainerDisclosureFocusMode.UaAuto,FigureColor.Rgb("#3366cc"))
        val legacy=ContainerDisclosure(1,true,"Mostra","Nascondi",focus,
            ContainerDisclosurePlacement.FloatRight)
        assertNull(legacy.button); assertSame(focus,legacy.focus)
        assertEquals(ContainerDisclosurePlacement.FloatRight,legacy.placement)
        assertThrows(IllegalArgumentException::class.java) { legacy.copy(button=button()) }
        assertEquals(button(),legacy.copy(focus=null,button=button()).button)
    }

    @Test fun exactModelRefusesFallbackAliasesAndUnsupportedMetricsPaintAndFocus() {
        for (name in listOf("", "Arial ", " Arial", "[Arial]", "Arial\n", "é", "a".repeat(129),
            "sans-serif", "SANS  SERIF", "System-UI"))
            assertThrows(IllegalArgumentException::class.java) { ContainerDisclosureNamedFont(name) }
        assertEquals("Times New Roman",ContainerDisclosureNamedFont("Times New Roman").name)
        val b=button()
        assertThrows(IllegalArgumentException::class.java) { b.copy(fontWeight=700) }
        assertThrows(IllegalArgumentException::class.java) { b.copy(fontItalic=true) }
        assertThrows(IllegalArgumentException::class.java) { b.copy(fontSize=px(0f)) }
        assertThrows(IllegalArgumentException::class.java) { b.copy(fontSize=StyleLength(StyleLengthUnit.Em,1f)) }
        assertThrows(IllegalArgumentException::class.java) { b.copy(lineHeight=ContainerLineHeight.Multiplier(1f)) }
        assertThrows(IllegalArgumentException::class.java) { b.copy(lineHeight=ContainerLineHeight.Length(px(0f))) }
        assertThrows(IllegalArgumentException::class.java) { b.copy(padding=b.padding.copy(top=StyleLength(StyleLengthUnit.Em,1f))) }
        assertThrows(IllegalArgumentException::class.java) { b.normal.copy(background=FigureColor.NativeTheme) }
        assertThrows(IllegalArgumentException::class.java) { b.normal.copy(border=edges(
            ResolvedStyleBorderEdge.Solid(px(1f),StyleBorderPaint.OwnerCurrentColor))) }
        assertThrows(IllegalArgumentException::class.java) { b.focusVisible!!.copy(mode=ContainerDisclosureFocusMode.AuthoredNone) }
        assertThrows(IllegalArgumentException::class.java) { checkNotNull(b.focusVisible).let { it.copy(outline=it.outline.copy(radius=px(1f))) } }
        assertThrows(IllegalArgumentException::class.java) {
            ContainerDisclosureButtonOutlineColors(FigureColor.Transparent,FigureColor.Rgb("#000000")) }
    }
}
