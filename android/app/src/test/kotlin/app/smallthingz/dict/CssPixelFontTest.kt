package app.smallthingz.dict

import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.sp
import java.io.ByteArrayOutputStream
import org.junit.Assert.*
import org.junit.Test

class CssPixelFontTest {
    private fun source(size: Float = 12f) = Span("link", "source text", "Target", fontScale = size,
        fontScaleBasis = FontScaleBasis.CssPx)

    @Test fun cssPixelsUseNominalSpIndependentOfBodyAndParentTypography() {
        for (size in listOf(0f, 1f, 12f, 12.375f)) for (zoom in listOf(.75f, 1f, 1.5f)) {
            val span = source(size)
            for (density in listOf(Density(1f, 1f), Density(2f, 1f))) {
                val expected = with(density) { (size * zoom).sp.toPx() }
                for ((parent, body) in listOf(24.sp to 20.sp, 10.sp to 32.sp)) {
                    val result = renderedSpanFontSize(span, parent, body, density, zoom)
                    assertTrue(result.isSp)
                    assertEquals(expected, with(density) { result.toPx() }, .001f)
                }
            }
            assertEquals(size, span.fontScale)
            assertEquals("source text", span.text); assertEquals("Target", span.target)
        }
    }

    @Test fun fullNonlinearForwardConversionPrecedesInverseAndLegacyReductionOccursOnce() {
        val density = Density(2f, 2f)
        val span = source(40f).copy(code = true)
        val zoom = 1.5f
        val nominal = 40f * zoom * .8f
        val expected = with(density) { nominal.sp.toPx() }
        assertNotEquals(nominal * density.density * density.fontScale, expected, .001f)
        assertNotEquals(nominal * density.density, expected, .001f)
        assertNotEquals(with(density) { (40f * zoom).sp.toPx() } * .8f, expected, .001f)
        for (legacy in listOf(span.copy(small = true), span.copy(superscript = true),
                span.copy(subscript = true), span.copy(small = true, superscript = true, subscript = true))) {
            assertEquals(nominal, cssPixelNominalFontSp(legacy, zoom), .001f)
            val result = renderedSpanFontSize(legacy, 72.sp, 20.sp, density, zoom)
            assertEquals(expected, with(density) { result.toPx() }, .01f)
            assertTrue(legacy.code)
        }
        for (basis in listOf(FontScaleBasis.Context, FontScaleBasis.NormalBody)) {
            val relative = Span("text", "old origin", fontScale = 1.25f, fontScaleBasis = basis)
            assertEquals(renderedSpanFontSize(relative, 32.sp, 20.sp, density),
                renderedSpanFontSize(relative, 32.sp, 20.sp, density, zoom))
        }
    }

    @Test fun cssPixelDomainDoesNotLeakIntoMultipliersOrComputedLineHeight() {
        for (size in listOf(Float.NaN, Float.POSITIVE_INFINITY, Float.NEGATIVE_INFINITY, -1f))
            assertThrows(IllegalArgumentException::class.java) { source(size) }
        assertThrows(IllegalArgumentException::class.java) {
            Span("text", "missing size", fontScaleBasis = FontScaleBasis.CssPx)
        }
        for (zoom in listOf(0f, -1f, Float.NaN, Float.POSITIVE_INFINITY))
            assertThrows(IllegalArgumentException::class.java) { cssPixelNominalFontSp(source(), zoom) }
        assertThrows(IllegalArgumentException::class.java) { spanFontScale(source()) }
        assertThrows(IllegalArgumentException::class.java) { spanFontPixels(source(), 24f, 20f) }
        assertThrows(IllegalArgumentException::class.java) { ComputedLineHeight(12f, FontScaleBasis.CssPx) }
        for (basis in listOf(FontScaleBasis.Context, FontScaleBasis.NormalBody))
            assertEquals(basis, ComputedLineHeight(1.2f, basis).fontScaleBasis)
    }

    @Test fun hugeNominalSizeUsesExistingComputedPixelCapWithoutChangingStoredMagnitude() {
        val huge = source(Float.MAX_VALUE).copy(small = true, superscript = true)
        for (density in listOf(Density(1f, 1f), Density(2f, 2f))) {
            val result = renderedSpanFontSize(huge, 24.sp, 20.sp, density, 2f)
            assertEquals(MaxComputedFontPixels, with(density) { result.toPx() }, .01f)
            assertEquals(0f, with(density) {
                renderedSpanFontSize(huge.copy(fontScale = 0f), 24.sp, 20.sp, density, 2f).toPx()
            }, 0f)
        }
        assertEquals(Float.MAX_VALUE, huge.fontScale)
        assertEquals("Target", huge.target)
    }

    // Literal test wire for this font-origin slice. It uses the existing M graph;
    // no source CSS, alternate reader or Figure table-caption policy is involved.
    private class Wire(val size: Float, val basis: Int = 2, val version: Char = 'M') {
        val out = ByteArrayOutputStream()
        fun byte(n: Int) { out.write(n) }
        fun u16(n: Int) { byte(n); byte(n ushr 8) }
        fun u32(n: Int) { repeat(4) { byte(n ushr (it * 8)) } }
        fun number(n: Float) { u32(n.toRawBits()) }
        fun string(s: String) { val b = s.toByteArray(Charsets.UTF_8); u32(b.size); out.write(b) }
        fun emptySpans() { u32(0) }
        fun span(label: String) {
            byte(1); byte(0); byte(3)
            listOf(label, "Target", "", "en", "authored-font", "ltr", "meaning").forEach(::string)
            byte(0); byte(0); byte(1); number(size); byte(basis)
            if (version >= 'C') byte(0)
            if (version >= 'F') { byte(1); string("section") }
            if (version >= 'H') { byte(1); string("source tooltip") }
        }
        fun spans(label: String) { u32(1); span(label) }
        fun length(n: Float = 0f) { byte(0); number(n) }
        fun figure(label: String, rich: Boolean = false) {
            byte(2); byte(0); byte(0); byte(0)
            repeat(12) { length() }; number(1f); length(20f)
            byte(1); byte(0); byte(1); byte(0); byte(0); byte(1)
            span("$label label"); length(100f); length(20f); byte(0)
            if (rich) emptySpans() else spans("$label caption")
            byte(if (rich) 1 else 0)
            if (rich) { u32(1); block("$label rich caption") }
            byte(0); byte(0)
        }
        fun cell(content: () -> Unit) { byte(0); u16(1); u16(1); byte(0); content(); byte(0) }
        fun table(label: String, nested: Boolean = false, lineBasis: Int? = null) {
            byte(1); byte(0); spans("$label caption"); u32(1); u32(if (nested) 1 else 3)
            cell { spans("$label cell"); byte(0); byte(0) }
            if (!nested) {
                cell { emptySpans(); table("nested", true); byte(0) }
                cell { emptySpans(); byte(0); byte(1); u32(1); block("cell block") }
            }
            if (lineBasis == null) byte(0) else {
                byte(1); byte(0); byte(4); number(1.2f); byte(lineBasis)
            }
            byte(0)
        }
        fun block(label: String = "", kind: Int = 0, table: (() -> Unit)? = null,
            figure: (() -> Unit)? = null, flow: (() -> Unit)? = null, children: (() -> Unit)? = null) {
            byte(kind); byte(0); byte(0)
            if (label.isEmpty()) emptySpans() else spans(label)
            byte(0); string(""); string("")
            if (table == null) byte(0) else table()
            string(""); string(""); byte(0); byte(0)
            if (figure == null) byte(0) else figure()
            byte(if (flow == null) 0 else 1); flow?.invoke()
            children?.let { u32(0); it() }
        }
        fun entry(recursive: Boolean = false, lineBasis: Int? = null): ByteArray {
            out.write("DPR$version".toByteArray(Charsets.US_ASCII)); spans("display")
            if (recursive || lineBasis != null) {
                u32(1); byte(2); string("Section"); string("Section"); string("Section")
                u32(if (recursive) 5 else 1)
                block(kind = 12, table = { table("table", lineBasis = lineBasis) })
                if (recursive) {
                    block("paragraph")
                    block(figure = { figure("figure") })
                    block(figure = { figure("rich figure", true) })
                    block(kind = 13, children = {
                        u32(2); block("container paragraph")
                        block(flow = {
                            u32(3); byte(0); spans("flow inline")
                            byte(1); figure("flow figure")
                            byte(2); byte(0); byte(1); byte(0); byte(0)
                            u32(1); byte(0); spans("scope inline")
                        })
                    })
                }
            } else u32(0)
            if (recursive) spans("preamble") else emptySpans()
            u32(0); u32(0)
            u32(if (recursive) 2 else 0)
            if (recursive) {
                byte(1); u32(1); string("notes"); spans("reference span"); byte(0)
                byte(0); u32(2); u32(1); string("note"); string("notes"); emptySpans()
                byte(1); u32(1); block("reference block")
            }
            u32(0)
            return out.toByteArray()
        }
    }
    private fun decode(bytes: ByteArray) = BlobDecoder.decode(bytes, "font origin", "language", "English", "en")

    @Test fun mPreservesExplicitZeroOneAndFractionalCssPixelsAcrossRecursiveOwners() {
        for (size in listOf(0f, 1f, 12.375f)) {
            val entry = decode(Wire(size).entry(recursive = true))
            val found = mutableListOf<Span>()
            fun figure(f: Figure) { found += f.content.span; found += f.caption }
            fun flow(parts: List<FlowPart>) {
                parts.forEach { when (it) {
                    is FlowPart.Inline -> found += it.spans
                    is FlowPart.ImageFigure -> figure(it.figure)
                    is FlowPart.Scope -> flow(it.scope.parts)
                } }
            }
            lateinit var blocks: (List<Block>) -> Unit
            fun table(t: Table) {
                found += t.caption; t.captionBlocks?.let { blocks(it) }
                t.rows.flatten().forEach { c -> found += c.spans; c.nestedTable?.let(::table); c.blocks?.let { blocks(it) } }
            }
            blocks = { values -> values.forEach { b ->
                found += b.spans; b.table?.let(::table); b.container?.let { blocks(it.blocks) }
                b.figure?.let { figure(it); it.captionBlocks?.let { rich -> blocks(rich) } }; b.flow?.let(::flow)
            } }
            found += entry.displayTitle; found += entry.preamble
            entry.sections.forEach { blocks(it.blocks) }
            entry.references.forEach { found += it.spans; it.blocks?.let { values -> blocks(values) } }
            assertEquals(setOf("display", "preamble", "table caption", "table cell", "nested caption", "nested cell",
                "cell block", "paragraph", "figure label", "figure caption", "rich figure label", "rich figure rich caption",
                "container paragraph", "flow inline", "flow figure label", "flow figure caption", "scope inline",
                "reference span", "reference block"), found.map { it.text }.toSet())
            assertEquals(19, found.size)
            found.forEach {
                assertEquals(FontScaleBasis.CssPx, it.fontScaleBasis); assertEquals(size, it.fontScale)
                assertEquals("Target", it.target); assertEquals("section", it.targetFragment)
                assertEquals("source tooltip", it.tooltip); assertTrue(it.bold && it.italic)
            }
        }
    }

    @Test fun earlierBasisBearingHeadersRejectCssPxAndMRejectsUnknownOrMalformedMagnitude() {
        for (version in 'B'..'L') {
            assertEquals(FontScaleBasis.NormalBody, decode(Wire(1f, 1, version).entry()).displayTitle.single().fontScaleBasis)
            val error = assertThrows(IllegalArgumentException::class.java) { decode(Wire(12f, 2, version).entry()) }
            assertTrue(checkNotNull(error.message).contains("requires M"))
        }
        for (basis in listOf(3, 255)) assertThrows(Exception::class.java) { decode(Wire(12f, basis).entry()) }
        for (size in listOf(-1f, Float.NaN, Float.POSITIVE_INFINITY, Float.NEGATIVE_INFINITY))
            assertThrows(Exception::class.java) { decode(Wire(size).entry()) }
        val valid = Wire(12.375f).entry(recursive = true)
        for (length in valid.indices) assertThrows(Exception::class.java) { decode(valid.copyOf(length)) }
        for (basis in listOf(0, 1)) assertEquals(basis,
            decode(Wire(12f).entry(lineBasis = basis)).sections.single().blocks.single().table!!.style!!.lineHeight!!.fontScaleBasis.ordinal)
        assertThrows(Exception::class.java) { decode(Wire(12f).entry(lineBasis = 2)) }
    }
}
