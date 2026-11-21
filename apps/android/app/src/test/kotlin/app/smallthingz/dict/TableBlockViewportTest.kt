package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test

/** API03 model and coordinate controls. Source only; not compiled or executed. */
class TableBlockViewportTest {
    private fun px(value: Float) = StyleLength(StyleLengthUnit.Px, value)
    private val zeroEdges = StyleEdges(px(0f), px(0f), px(0f), px(0f))
    private val vertical = ContainerMargin.Length(StyleLength(StyleLengthUnit.Em, .2f))
    private val margins = ContainerMargins(vertical, ContainerMargin.Auto, vertical, ContainerMargin.Auto)
    private fun policy() = TableBlockViewport(639,
        TableStyle(width = StyleWidth(StyleWidthUnit.Percent, 70f), clear = FigureClear.None,
            marginValues = margins, containingDirection = TableContainingDirection.Ltr),
        ContainerBoxSizing.ContentBox, StyleWidth(StyleWidthUnit.Percent, 100f),
        TableStyle(collapse = TableCollapse.Collapse), TableContainingDirection.Rtl, language = "ru")

    @Test fun rolesKeepIndependentDirectionsPaintAndTheExistingSingleAutoDomain() {
        val original = policy()
        val box = original.boxStyle.copy(background = "#123456", border = StyleBorder.None, padding = zeroEdges)
        val grid = original.gridStyle.copy(lineHeight = ComputedLineHeight(1.2f, FontScaleBasis.NormalBody))
        val fixed = ContainerMargin.Length(px(3f))
        for (edges in listOf(margins, margins.copy(left = fixed), margins.copy(right = fixed))) {
            val value = original.copy(boxStyle = box.copy(marginValues = edges), gridStyle = grid)
            assertEquals(TableContainingDirection.Ltr, value.boxStyle.containingDirection)
            assertEquals(TableContainingDirection.Rtl, value.gridDirection)
            assertEquals("#123456", value.boxStyle.background)
            assertNull(value.gridStyle.background)
            assertEquals(ComputedLineHeight(1.2f, FontScaleBasis.NormalBody), value.gridStyle.lineHeight)
            assertEquals(value, Table(emptyList(), emptyList(), blockViewport = value).blockViewport)
        }
        for (unit in StyleWidthUnit.entries) {
            assertEquals(0f, original.copy(maxWidth = StyleWidth(unit, 0f)).maxWidth.value, 0f)
            assertEquals(150f, original.copy(maxWidth = StyleWidth(unit, 150f)).maxWidth.value, 0f)
        }
    }

    @Test fun boxRejectsMissingWidthAutoPairAndForbiddenTableFields() {
        val original = policy()
        val box = original.boxStyle
        val invalid = listOf(box.copy(width = null), box.copy(width = StyleWidth(StyleWidthUnit.Px, 0f)),
            box.copy(marginValues = null, containingDirection = null),
            box.copy(margins = zeroEdges, marginValues = null, containingDirection = null),
            box.copy(floatSide = TableFloatSide.Left), box.copy(display = TableDisplay.Table),
            box.copy(verticalAlign = TableVerticalAlign.Middle), box.copy(collapse = TableCollapse.Collapse),
            box.copy(lineHeight = ComputedLineHeight(1f)))
        for (style in invalid) assertThrows(IllegalArgumentException::class.java) { original.copy(boxStyle = style) }
        for (number in listOf(-1f, Float.NaN, Float.POSITIVE_INFINITY, Float.NEGATIVE_INFINITY)) {
            assertThrows(IllegalArgumentException::class.java) { original.copy(maxWidth = StyleWidth(StyleWidthUnit.Px, number)) }
            assertThrows(IllegalArgumentException::class.java) { original.copy(boxStyle = box.copy(width = StyleWidth(StyleWidthUnit.Percent, number))) }
        }
    }

    @Test fun gridRejectsSourceBoxFieldsEvenWhenTheirValuesLookLikeDefaults() {
        val original = policy()
        val grid = original.gridStyle
        val invalid = listOf(TableStyle(lineHeight = ComputedLineHeight(1f)),
            grid.copy(collapse = TableCollapse.Separate), grid.copy(background = "#ffffff"),
            grid.copy(border = StyleBorder.None), grid.copy(padding = zeroEdges),
            grid.copy(width = StyleWidth(StyleWidthUnit.Px, 0f)), grid.copy(margins = zeroEdges),
            grid.copy(marginValues = margins, containingDirection = TableContainingDirection.Ltr),
            grid.copy(floatSide = TableFloatSide.Right), grid.copy(clear = FigureClear.None),
            grid.copy(display = TableDisplay.Table), grid.copy(verticalAlign = TableVerticalAlign.Middle))
        for (style in invalid) assertThrows(IllegalArgumentException::class.java) { original.copy(gridStyle = style) }
    }

    @Test fun headerForbidsLegacyGeometryAndFloatingOrInlineWideStates() {
        val value = policy()
        val cell = Cell(listOf(Span("text", "body")), false, 1, 1)
        val table = Table(emptyList(), listOf(listOf(cell)), blockViewport = value)
        for (geometry in listOf(TableGeometry(), TableGeometry(border = 0), TableGeometry(cellPadding = 5),
            TableGeometry(width = TableWidth(TableWidthUnit.Percent, 70)))) {
            assertThrows(IllegalArgumentException::class.java) { table.copy(geometry = geometry) }
        }
        for (style in listOf(TableStyle(floatSide = TableFloatSide.Left),
            TableStyle(display = TableDisplay.InlineBlock), TableStyle(display = TableDisplay.InlineTable))) {
            assertThrows(IllegalArgumentException::class.java) { table.copy(style = style) }
        }
        assertEquals(TableDisplay.Table, table.copy(style = TableStyle(display = TableDisplay.Table)).style!!.display)
        assertNull(Table(emptyList(), emptyList()).blockViewport)
        assertNull(Table(emptyList(), emptyList(), geometry = TableGeometry(border = 1)).blockViewport)
    }

    @Test fun documentViewportUsesFractionalBoundaryAndFullUnsignedThreshold() {
        val value = policy()
        val table = Table(emptyList(), emptyList(), blockViewport = value)
        for (viewport in listOf(0f, 638.75f, 639f)) assertSame(value, table.blockViewportAt(viewport))
        for (viewport in listOf(639.25f, 640f, 800f)) assertNull(table.blockViewportAt(viewport))
        assertSame(value, table.blockViewportAt(639.0))
        assertNull(table.blockViewportAt(639.0 + .0000001))
        assertSame(value, table.blockViewportAt(639.0 - .0000001))
        val zero = table.copy(blockViewport = value.copy(maxViewportWidthPx = 0))
        assertNotNull(zero.blockViewportAt(0f)); assertNull(zero.blockViewportAt(.01f))
        val largest = table.copy(blockViewport = value.copy(maxViewportWidthPx = 0xffff_ffffL))
        assertNotNull(largest.blockViewportAt(4294967295.0))
        assertNull(largest.blockViewportAt(4294967296f))
        for (threshold in listOf(-1L, 0x1_0000_0000L))
            assertThrows(IllegalArgumentException::class.java) { value.copy(maxViewportWidthPx = threshold) }
        for (viewport in listOf(-1f, Float.NaN, Float.POSITIVE_INFINITY, Float.NEGATIVE_INFINITY))
            assertThrows(IllegalArgumentException::class.java) { table.blockViewportAt(viewport) }
        for (viewport in listOf(-1.0, Double.NaN, Double.POSITIVE_INFINITY, Double.NEGATIVE_INFINITY))
            assertThrows(IllegalArgumentException::class.java) { table.blockViewportAt(viewport) }
        assertNull(Table(emptyList(), emptyList()).blockViewportAt(0f))
    }

    @Test fun requiredSourceLanguageKeepsSharedBytesSeparateFromNativeAdmission() {
        val original = policy()
        for ((source, canonical) in listOf("ru" to "ru", "RU" to "ru", "sr-Latn-RS" to "sr-Latn-RS",
            "und" to "und", "x-source" to "x-source")) {
            val value = original.copy(language = source)
            assertEquals(source, value.language)
            assertEquals(canonical, nativeTableOwnerLanguageTag(value.language))
        }
        for (source in listOf("", "\uD800", "\uDC00")) {
            val failure = assertThrows(IllegalArgumentException::class.java) { original.copy(language = source) }
            assertEquals("Invalid table source language", failure.message)
        }
        val tooManyUtf8Bytes = "\u0800".repeat(32 * 1024 * 1024 / 3 + 1)
        val tooLarge = assertThrows(IllegalArgumentException::class.java) { original.copy(language = tooManyUtf8Bytes) }
        assertEquals("Invalid table source language", tooLarge.message)
        for (source in listOf("ru--RU", "ru_RU", " ru", "ru ", "not a tag", "zh-cmn", "i-klingon",
            "\u65e5\u672c", "\uD83D\uDE00", "\u0000")) {
            val value = original.copy(language = source)
            assertEquals(source, value.language)
            assertNull(nativeTableOwnerLanguageTag(value.language))
        }
    }
}
