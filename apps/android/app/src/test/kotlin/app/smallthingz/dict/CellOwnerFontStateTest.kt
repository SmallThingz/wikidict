package app.smallthingz.dict

import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.BaselineShift
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.sp
import org.junit.Assert.*
import org.junit.Test

class CellOwnerFontStateTest {
    private val body = TextStyle(fontSize = 40.sp, fontFamily = FontFamily.Serif,
        fontWeight = FontWeight.Black, fontStyle = FontStyle.Italic)
    private val density = Density(2f, 2f)
    private fun font(scale: Float = .7f, basis: FontScaleBasis = FontScaleBasis.NormalBody,
        family: ContainerFontFamily = ContainerFontFamily.SansSerif, language: String = "th") =
        InlineFontSnapshot(fontScale = scale, fontScaleBasis = basis, language = language,
            fontFeatures = FontFeaturePolicy.SevenOn, fontFamily = family)
    private fun cell(snapshot: InlineFontSnapshot?, height: CellLineHeightValue = CellLineHeightValue.Normal,
        scale: Float = snapshot?.fontScale ?: .7f, basis: FontScaleBasis = snapshot?.fontScaleBasis ?: FontScaleBasis.NormalBody) =
        Cell(listOf(Span("link", "child", "Target", bold = true, code = true, fontScale = 3f,
            fontScaleBasis = FontScaleBasis.NormalBody)), true, 1, 1,
            style = CellStyle(lineHeight = CellLineHeight(height, CellTextStrut(scale, basis, snapshot))))
    private fun context(cell: Cell, parent: ContainerTextContext? = null, style: TextStyle = body,
        zoom: Float = 1.5f, tableHeight: Float? = null) =
        checkNotNull(nativeCellTextContext(cell, parent, style, 40.sp, density, zoom, tableHeight))

    @Test fun completeOwnerUsesTheAlreadyResolvedSizeAndFalseTraitsIndependentlyOfHeaderAndChildren() {
        for (basis in listOf(FontScaleBasis.NormalBody, FontScaleBasis.CssPx)) {
            val source = font(if (basis == FontScaleBasis.CssPx) 24f else .7f, basis)
            val original = cell(source)
            val selected = context(original).cellText!!
            val pixels = cellTextMetricPixels(source.fontScale!!, basis, 40.sp, density, 1.5f, fontSize = true)
            assertEquals(pixels, selected.fontPixels!!, 0f)
            assertSame(source, selected.ownerFont!!.snapshot)
            val style = checkNotNull(selected.ownerFont.style)
            assertEquals(pixels, with(density) { style.fontSize.toPx() }, .001f)
            assertEquals(FontFamily.SansSerif, style.fontFamily)
            assertEquals(FontWeight.Normal, style.fontWeight)
            assertEquals(FontStyle.Normal, style.fontStyle)
            assertEquals(BaselineShift.None, style.baselineShift)
            assertEquals(FontFeaturePolicy.SevenOn.nativeSettings, style.fontFeatureSettings)
            assertEquals("th", style.localeList!!.first().toLanguageTag())
            assertFalse(selected.ownerFontInvalidated)
            val changedChild = original.copy(header = false, spans = listOf(Span("text", "other", italic = true,
                fontScale = 8f, fontScaleBasis = FontScaleBasis.CssPx)))
            assertEquals(selected, context(changedChild).cellText)
            assertEquals(original.spans, cell(source).spans)
        }
    }

    @Test fun unchangedAndLineHeightOnlyContainersRetainTheSameOwnerWhileExactFontNoOpsStayValid() {
        val family = ContainerFontFamily.Stack(emptyList(), GenericFontFamily.Serif)
        val parent = context(cell(font(family = family), CellLineHeightValue.Multiplier(1.1f)))
        val owner = parent.cellText!!.ownerFont
        for (style in listOf(ContainerStyle(), ContainerStyle(ownerFontScale = .7f),
            ContainerStyle(fontFamily = family.copy(names = family.names.toList())),
            ContainerStyle(ownerFontScale = .7f, fontFamily = family))) {
            val state = style.textContext(parent).cellText!!
            assertSame(owner, state.ownerFont)
            assertEquals(parent.cellText.fontPixels, state.fontPixels)
            assertEquals(parent.cellText.lineHeight, state.lineHeight)
            assertFalse(state.ownerFontInvalidated)
        }
        val changedHeight = ContainerStyle(lineHeight = ContainerLineHeight.Multiplier(2f)).textContext(parent)
        assertSame(owner, changedHeight.cellText!!.ownerFont)
        assertFalse(changedHeight.cellText.ownerFontInvalidated)
        assertNull(changedHeight.cellText.lineHeight)
        assertEquals(NativeLineHeightPolicy.Multiplier(2f),
            nativeContainerTextFormat(changedHeight, 40.sp, body, density).lineHeight)
    }

    @Test fun changedOrCrossBasisFontsRetainTheOriginalSnapshotAndInvalidateStickily() {
        val parent = context(cell(font()))
        val owner = parent.cellText!!.ownerFont
        for (change in listOf(ContainerStyle(ownerFontScale = 2f),
            ContainerStyle(fontFamily = ContainerFontFamily.Stack(emptyList(), GenericFontFamily.Serif)))) {
            val changed = change.textContext(parent)
            assertSame(owner, changed.cellText!!.ownerFont)
            assertTrue(changed.cellText.ownerFontInvalidated)
            val later = ContainerStyle(ownerFontScale = .7f, fontFamily = ContainerFontFamily.SansSerif,
                lineHeight = ContainerLineHeight.Multiplier(1f)).textContext(changed)
            assertSame(owner, later.cellText!!.ownerFont)
            assertTrue(later.cellText.ownerFontInvalidated)
        }
        val css = context(cell(font(.7f, FontScaleBasis.CssPx)))
        val numericallyEqual = ContainerStyle(ownerFontScale = .7f).textContext(css)
        assertTrue(numericallyEqual.cellText!!.ownerFontInvalidated)
        assertSame(css.cellText!!.ownerFont, numericallyEqual.cellText.ownerFont)
    }

    @Test fun nestedCellsOwnTheirResetAndDoNotRebaseAnInvalidAncestorSnapshot() {
        val parent = ContainerStyle(ownerFontScale = 3f).textContext(context(cell(font())))
        assertTrue(parent.cellText!!.ownerFontInvalidated)
        val fresh = font(12f, FontScaleBasis.CssPx, ContainerFontFamily.Stack(emptyList(), GenericFontFamily.Serif), "ru")
        val child = context(cell(fresh, CellLineHeightValue.Length(CellFixedLineHeight(9f, FontScaleBasis.CssPx))), parent)
        assertSame(fresh, child.cellText!!.ownerFont!!.snapshot)
        assertFalse(child.cellText.ownerFontInvalidated)
        assertEquals(cellTextMetricPixels(12f, FontScaleBasis.CssPx, 40.sp, density, 1.5f, fontSize = true),
            child.cellText.fontPixels!!, 0f)
        val legacy = context(cell(null), parent)
        assertNull(legacy.cellText!!.ownerFont)
        assertFalse(legacy.cellText.ownerFontInvalidated)
        val noOwnHeight = context(Cell(listOf(Span("text", "nested")), false, 1, 1), parent,
            style = TextStyle(fontSize = 18.sp), tableHeight = 75f)
        assertNull(noOwnHeight.cellText!!.ownerFont)
        assertFalse(noOwnHeight.cellText.ownerFontInvalidated)
        assertEquals(NativeLineHeightPolicy.Pixels(75f), noOwnHeight.cellText.lineHeight)
    }

    @Test fun nullOwnerKeepsLegacyStateAndRawUnsupportedLanguageOrZeroDoNotBecomeAnotherOwner() {
        val legacy = context(cell(null)).cellText!!
        assertNull(legacy.ownerFont)
        assertFalse(legacy.ownerFontInvalidated)
        val changed = ContainerStyle(ownerFontScale = 2f).textContext(ContainerTextContext(cellText = legacy)).cellText!!
        assertNull(changed.fontPixels)
        assertNull(changed.ownerFont)
        assertFalse(changed.ownerFontInvalidated)
        val raw = font(language = "i-klingon")
        val unresolved = context(cell(raw)).cellText!!
        assertSame(raw, unresolved.ownerFont!!.snapshot)
        assertNull(unresolved.ownerFont.style!!.localeList)
        val zeroFont = font(0f)
        val zero = context(cell(zeroFont, CellLineHeightValue.Multiplier(0f))).cellText!!
        assertEquals(0f, zero.fontPixels!!, 0f)
        assertSame(zeroFont, zero.ownerFont!!.snapshot)
        val empty = cell(zeroFont).copy(spans = emptyList())
        assertEquals(emptyList<Span>(), empty.spans)
        assertSame(zeroFont, context(empty).cellText!!.ownerFont!!.snapshot)
    }
}
