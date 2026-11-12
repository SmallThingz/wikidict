package app.smallthingz.dict

import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.sp
import java.io.ByteArrayOutputStream
import org.junit.Assert.*
import org.junit.Test

class CellLineHeightTest {
    private fun cell(height: CellLineHeightValue, strut: CellTextStrut? = null) = Cell(
        listOf(Span("link", "retained", "Target")), false, 1, 1,
        style = CellStyle(lineHeight = CellLineHeight(height, strut)))
    private fun fixed(n: Float, basis: FontScaleBasis = FontScaleBasis.NormalBody) =
        CellLineHeightValue.Length(CellFixedLineHeight(n, basis))

    @Test fun cellMetricDomainsAdmitZeroWithoutWeakeningTheOlderTableContract() {
        for (basis in listOf(FontScaleBasis.NormalBody, FontScaleBasis.CssPx)) {
            for (value in listOf(0f, .7f, 12.375f)) {
                assertEquals(value, CellTextStrut(value, basis).fontScale, 0f)
                assertEquals(value, CellFixedLineHeight(value, basis).value, 0f)
            }
            for (value in listOf(-1f, Float.NaN, Float.POSITIVE_INFINITY, Float.NEGATIVE_INFINITY)) {
                assertThrows(IllegalArgumentException::class.java) { CellTextStrut(value, basis) }
                assertThrows(IllegalArgumentException::class.java) { CellFixedLineHeight(value, basis) }
                assertThrows(IllegalArgumentException::class.java) { CellLineHeightValue.Multiplier(value) }
            }
        }
        assertThrows(IllegalArgumentException::class.java) { CellTextStrut(1f, FontScaleBasis.Context) }
        assertThrows(IllegalArgumentException::class.java) { CellFixedLineHeight(1f, FontScaleBasis.Context) }
        assertThrows(IllegalArgumentException::class.java) { ComputedLineHeight(0f, FontScaleBasis.NormalBody) }
        assertThrows(IllegalArgumentException::class.java) { ComputedLineHeight(12f, FontScaleBasis.CssPx) }
        assertEquals(FontScaleBasis.Context, ComputedLineHeight(1f).fontScaleBasis)
    }

    @Test fun fixedBodyUsesIndependentConvertedBodyPixelsAndCssPixelsUseNominalZoomBeforeConversion() {
        val density = Density(2f, 2f)
        val body = 40.sp
        val bodyPixels = with(density) { body.toPx() }
        val fixedBody = cellTextMetricPixels(.7f, FontScaleBasis.NormalBody, body, density, 1.5f)
        assertEquals(bodyPixels * .7f, fixedBody, .001f)
        assertNotEquals(with(density) { (40f * .7f).sp.toPx() }, fixedBody, .001f)
        val css = cellTextMetricPixels(24f, FontScaleBasis.CssPx, body, density, 1.5f)
        assertEquals(with(density) { 36.sp.toPx() }, css, .001f)
        assertNotEquals(24f * 1.5f * density.density * density.fontScale, css, .001f)
        assertEquals(css, cellTextMetricPixels(24f, FontScaleBasis.CssPx, 12.sp, density, 1.5f), 0f)
        for (basis in listOf(FontScaleBasis.NormalBody, FontScaleBasis.CssPx))
            assertEquals(0f, cellTextMetricPixels(0f, basis, body, density, 1.5f), 0f)
        assertEquals(MaxComputedFontPixels, cellTextMetricPixels(Float.MAX_VALUE, FontScaleBasis.CssPx,
            body, density, 2f, fontSize = true), 0f)
        assertThrows(UnsupportedFloatLayout::class.java) {
            cellTextMetricPixels(Float.MAX_VALUE, FontScaleBasis.CssPx, body, density, 2f)
        }
    }

    @Test fun ownerStrutIsIndependentOfFirstSpanAndFixedHeightSurvivesNestedFontChanges() {
        val density = Density(2f, 2f)
        val owner = cell(fixed(.7f), CellTextStrut(.7f, FontScaleBasis.NormalBody))
        val parent = nativeCellTextContext(owner, null, TextStyle(fontSize = 40.sp), 40.sp, density, 1f, null)!!
        val changedChild = owner.copy(spans = listOf(Span("text", "large child", fontScale = 2f)))
        assertEquals(parent, nativeCellTextContext(changedChild, null, TextStyle(fontSize = 40.sp), 40.sp, density, 1f, null))
        val fontChange = ContainerStyle(ownerFontScale = 2f).textContext(parent)
        assertEquals(parent.cellText!!.lineHeight, fontChange.cellText!!.lineHeight)
        assertNull(fontChange.cellText.fontPixels)
        val formatted = nativeContainerTextFormat(fontChange, 40.sp, TextStyle(fontSize = 40.sp), density)
        assertEquals(parent.cellText.lineHeight, formatted.lineHeight)
        assertNotEquals(parent.cellText.fontPixels, with(density) { formatted.style.fontSize.toPx() })
        val nearer = ContainerStyle(lineHeight = ContainerLineHeight.Multiplier(2f)).textContext(parent)
        assertNull(nearer.cellText!!.lineHeight)
        assertEquals(NativeLineHeightPolicy.Multiplier(2f), nativeContainerTextFormat(nearer, 40.sp,
            TextStyle(fontSize = 40.sp), density).lineHeight)
    }

    @Test fun unitlessNormalAndExplicitZeroReplaceInheritedPolicyWithoutCreatingAnotherOwner() {
        val density = Density(1f)
        val parent = nativeCellTextContext(cell(fixed(2f)), null, TextStyle(fontSize = 20.sp), 20.sp, density, 1f, null)!!
        val inheritedStyle = nativeContainerTextFormat(parent, 20.sp, TextStyle(fontSize = 20.sp), density).style
        val number = nativeCellTextContext(cell(CellLineHeightValue.Multiplier(1f)), parent, inheritedStyle,
            20.sp, density, 1f, null)!!
        val numberPolicy = nativeContainerTextFormat(ContainerStyle(ownerFontScale = 2f).textContext(number),
            20.sp, inheritedStyle, density).lineHeight
        assertEquals(NativeLineHeightPolicy.Multiplier(1f), numberPolicy)
        val normal = nativeCellTextContext(cell(CellLineHeightValue.Normal), parent, inheritedStyle,
            20.sp, density, 1f, null)!!
        assertEquals(NativeLineHeightPolicy.Normal, normal.cellText!!.lineHeight)
        val zero = nativeCellTextContext(cell(fixed(0f), CellTextStrut(0f, FontScaleBasis.CssPx)), parent,
            inheritedStyle, 20.sp, density, 1f, null)!!
        assertEquals(0f, zero.cellText!!.fontPixels!!, 0f)
        assertEquals(NativeLineHeightPolicy.Pixels(0f), zero.cellText.lineHeight)
        val nullStrut = nativeCellTextContext(cell(fixed(0f)), parent, inheritedStyle,
            20.sp, density, 1f, null)!!
        assertEquals(20f, nullStrut.cellText!!.fontPixels!!, 0f)
        assertNotEquals(nullStrut, zero)
    }

    @Test fun nestedTableHeightAndCellOverrideRemainSeparateFromRebasedBoxLengths() {
        val density = Density(2f, 2f)
        val bodyStyle = TextStyle(fontSize = 40.sp)
        val parent = nativeCellTextContext(cell(fixed(.7f), CellTextStrut(.7f, FontScaleBasis.NormalBody)),
            null, bodyStyle, 40.sp, density, 1f, null)!!
        val style = nativeContainerTextFormat(parent, 40.sp, bodyStyle, density).style
        val child = Cell(listOf(Span("text", "child")), false, 1, 1)
        val nested = nativeCellTextContext(child, parent, style, 40.sp, density, 1f, 75f)!!
        assertEquals(parent.cellText!!.fontPixels, nested.cellText!!.fontPixels)
        assertEquals(NativeLineHeightPolicy.Pixels(75f), nested.cellText.lineHeight)
        val own = nativeCellTextContext(child.copy(style = CellStyle(lineHeight = CellLineHeight(CellLineHeightValue.Normal))),
            parent, style, 40.sp, density, 1f, 75f)!!
        assertEquals(NativeLineHeightPolicy.Normal, own.cellText!!.lineHeight)
        val declared = ContainerStyle(ownerFontScale = 2f, lineHeight = ContainerLineHeight.Multiplier(1.5f)).textContext(parent)
        assertNotNull(declared.cellText); assertNull(declared.cellText!!.fontPixels); assertNull(declared.cellText.lineHeight)
        val bodyPixels = with(density) { 40.sp.toPx() }
        assertEquals(bodyPixels * 3f, tableStyleLengthPixels(StyleLength(StyleLengthUnit.Em, 3f), density.density, bodyPixels), .001f)
    }

    @Test fun measuredBaselinePresencePreservesZeroAndSignedPlacementWhileEmptyGroupsStayUnspecified() {
        val empty = EmptyCaptionGeometry(0)
        assertNull(empty.textBaselines)
        assertNull(NativeSemanticGroup(0, 0, emptyList()).textBaselines)
        val measuredLine = object : FloatTextGeometry by empty {
            override val textBaselines = NativeTextBaselines(0f, 0f)
        }
        val placed = NativeSemanticGroup(0, 0, listOf(PositionedSemanticChild(measuredLine, 0f, -3f, BidiResolvedDirection.Ltr)))
        assertEquals(NativeTextBaselines(-3f, -3f), placed.textBaselines)
        assertEquals(NativeTextBaselines(0f, 0f), NativeSurfaceGeometry(placed, NativeSurfaceBox(0, -3, 0, 3)).textBaselines)
    }

    @Test fun selectedTableBaselinesUseTheSameRowMaximumAndKeepMissingFirstIndependent() {
        val small = NativeTextBaselines(5f, 5f)
        val tall = NativeTextBaselines(20f, 20f)
        val later = NativeTextBaselines(-2f, -2f)
        val table = nativeTableTextBaselines(listOf(small, tall, later), listOf(0, 0, 1), listOf(0f, 0f, 40f))
        assertEquals(NativeTextBaselines(20f, 38f), table)
        val empty = EmptyCaptionGeometry(0)
        fun child(lines: NativeTextBaselines) = object : FloatTextGeometry by empty {
            override val textBaselines = lines
        }
        val selected = NativeSemanticGroup(0, 0, listOf(
            PositionedSemanticChild(child(small), 0f, 0f, BidiResolvedDirection.Ltr),
            PositionedSemanticChild(child(tall), 0f, 0f, BidiResolvedDirection.Ltr),
            PositionedSemanticChild(child(later), 0f, 40f, BidiResolvedDirection.Ltr)), baselineProvider = { table })
        assertEquals(table, selected.textBaselines)
        val parent = nativeTableTextBaselines(listOf(selected.textBaselines, small), listOf(0, 0), listOf(3f, 0f))
        assertEquals(NativeTextBaselines(23f, 41f), parent)
        val emptyFirst = nativeTableTextBaselines(listOf(null, NativeTextBaselines(0f, 0f)), listOf(0, 1), listOf(0f, 20f))
        assertEquals(NativeTextBaselines(null, 20f), emptyFirst)
        assertEquals(NativeTextBaselines(null, 17f), emptyFirst!!.translated(-3f))
        assertNull(nativeTableTextBaselines(listOf(null), listOf(0), listOf(0f)))
    }

    private class Wire {
        val out = ByteArrayOutputStream()
        fun byte(n: Int) { out.write(n) }
        fun short(n: Int) { byte(n); byte(n ushr 8) }
        fun int(n: Int) { repeat(4) { byte(n ushr (it * 8)) } }
        fun number(n: Float) = int(n.toRawBits())
        fun text(s: String) { val b = s.encodeToByteArray(); int(b.size); out.write(b) }
        fun length(n: Float) { byte(0); number(n) }
    }
    private fun fixture(version: Char = 'M', style: Wire.() -> Unit): ByteArray = Wire().apply {
        out.write("DPR$version".toByteArray()); int(0)
        int(1); byte(2); text("Cell control"); text(""); text("")
        int(1); byte(12); byte(0); byte(0); int(0); byte(0); text(""); text("")
        byte(1); byte(0); int(0); int(1); int(1)
        byte(0); short(1); short(1); byte(0); int(0); byte(0); byte(0)
        byte(1); style(); byte(0); byte(0)
        text(""); text(""); byte(0); byte(0); byte(0); byte(0); repeat(5) { int(0) }
    }.out.toByteArray()
    private fun read(bytes: ByteArray) = BlobDecoder.decode(bytes, "cell", "language", "English", "en")
        .sections.single().blocks.single().table!!.rows.single().single().style!!

    @Test fun cell08TailFollowsEveryOldFieldAndDistinguishesNullFromExplicitZero() {
        val normal = read(fixture { byte(8); byte(0); byte(0) })
        assertEquals(CellLineHeight(CellLineHeightValue.Normal), normal.lineHeight)
        val zero = read(fixture { byte(8); byte(1); number(0f); byte(1); byte(2); number(0f); byte(1) })
        assertEquals(CellLineHeight(fixed(0f), CellTextStrut(0f, FontScaleBasis.NormalBody)), zero.lineHeight)
        val complete = read(fixture {
            byte(0xef); byte(0); repeat(4) { length(3f) }; byte(2)
            byte(2); number(75f); length(19f); byte(0)
            byte(1); number(.7f); byte(1); byte(2); number(12.375f); byte(2)
        })
        assertEquals(StyleBorder.None, complete.border)
        assertEquals(CellTextAlign.Right, complete.textAlign)
        assertEquals(StyleWidth(StyleWidthUnit.Percent, 75f), complete.width)
        assertEquals(StyleLength(StyleLengthUnit.Px, 19f), complete.minWidth)
        assertEquals(CellVerticalAlign.Top, complete.verticalAlign)
        assertEquals(CellLineHeight(fixed(12.375f, FontScaleBasis.CssPx), CellTextStrut(.7f, FontScaleBasis.NormalBody)), complete.lineHeight)
        assertNull(read(fixture { byte(1); byte(0) }).lineHeight)
    }

    @Test fun cell08RejectsMalformedPresenceOriginsNumbersAndEveryTruncationAndOlderHeaders() {
        val good = fixture { byte(8); byte(1); number(.7f); byte(1); byte(1); number(1.5f) }
        for (length in good.indices) assertThrows(Exception::class.java) { read(good.copyOf(length)) }
        assertThrows(Exception::class.java) { read(good + byteArrayOf(0)) }
        for (version in listOf('J', 'K', 'L')) {
            assertThrows(Exception::class.java) { read(good.copyOf().also { it[3] = version.code.toByte() }) }
            assertEquals(read(fixture { byte(1); byte(0) }), read(fixture(version) { byte(1); byte(0) }))
        }
        val bad: List<Wire.() -> Unit> = listOf(
            { byte(8); byte(2); byte(0) }, { byte(8); byte(0); byte(3) },
            { byte(8); byte(1); number(1f); byte(0); byte(0) },
            { byte(8); byte(0); byte(2); number(1f); byte(0) },
            { byte(16); byte(0); byte(0) },
        )
        bad.forEach { assertThrows(Exception::class.java) { read(fixture(style = it)) } }
        for (value in listOf(-1f, Float.NaN, Float.POSITIVE_INFINITY, Float.NEGATIVE_INFINITY)) {
            assertThrows(Exception::class.java) { read(fixture { byte(8); byte(1); number(value); byte(1); byte(0) }) }
            assertThrows(Exception::class.java) { read(fixture { byte(8); byte(0); byte(1); number(value) }) }
            assertThrows(Exception::class.java) { read(fixture { byte(8); byte(0); byte(2); number(value); byte(2) }) }
        }
    }
}
