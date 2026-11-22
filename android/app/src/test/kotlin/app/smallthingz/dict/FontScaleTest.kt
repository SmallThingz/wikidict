package app.smallthingz.dict

import java.io.ByteArrayOutputStream
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.sp
import org.junit.Assert.*
import org.junit.Test

class FontScaleTest {
    private class Wire {
        val out = ByteArrayOutputStream()
        fun byte(n: Int) { out.write(n) }
        fun u16(n: Int) { repeat(2) { byte(n ushr (it * 8)) } }
        fun u32(n: Int) { repeat(4) { byte(n ushr (it * 8)) } }
        fun string(s: String) { val b=s.toByteArray(Charsets.UTF_8); u32(b.size); out.write(b) }
        fun spans(scale: Float?, version: Char, text: String = "\u0633\u0628\u062a\u0645\u0628\u0631", flags: Int = 0, basis: Int = 0) {
            u32(1); byte(1); byte(0); byte(flags)
            listOf(text, text, "", "ar", "AR", "rtl", "meaning").forEach(::string)
            byte(1); string("#123456"); byte(1); string("#fedcba")
            if (version in "AB") { byte(if (scale == null) 0 else 1); if (scale != null) { u32(scale.toRawBits()); if (version == 'B') byte(basis) } }
        }
        fun emptySpans() { u32(0) }
        fun block(version: Char, scale: Float?, basis: Int = 0) {
            byte(12); byte(0); byte(0); emptySpans(); byte(0); string(""); string("")
            byte(1); byte(7); u16(1); u16(2); u16(3)
            spans(scale, version, "caption", basis=basis)
            u32(1); u32(2); byte(1); u16(1); u16(1); byte(1); string("#abcdef")
            emptySpans()
            byte(1); byte(0); spans(scale, version, "nested caption", basis=basis); u32(0)
            byte(0)
            byte(0); u16(1); u16(1); byte(0); emptySpans(); byte(0)
            byte(1); u32(1)
            byte(0); byte(0); byte(0); spans(scale, version, "ordered cell", basis=basis)
            byte(0); string(""); string(""); byte(0); string(""); string("")
            string(""); string("")
        }
    }
    private fun fixture(scale: Float?, version: Char = 'A', basis: Int = 0): ByteArray = Wire().apply {
        out.write("DPR$version".toByteArray())
        spans(scale, version, basis=basis)
        u32(1); byte(3); string("Noun"); string("noun"); string("Noun")
        u32(1); block(version, scale, basis)
        emptySpans(); u32(0); u32(0)
        u32(2)
        byte(1); u32(2); string("notes"); spans(scale, version, "fragment", basis=basis)
        byte(0); u32(1); u32(3); string("authored"); string("notes"); spans(scale, version, "note", basis=basis)
        u32(0)
    }.out.toByteArray()
    private fun decode(bytes: ByteArray) = BlobDecoder.decode(bytes, "ARchar", "language", "Arabic", "ar")

    @Test fun dpraPreservesScaleAndAllDpr9ReferenceAndNestedCellFields() {
        val entry=decode(fixture(1.25f))
        val span=entry.displayTitle.single()
        assertEquals(1.25f, span.fontScale)
        assertEquals("\u0633\u0628\u062a\u0645\u0628\u0631", span.text)
        assertEquals(span.text, span.target)
        assertEquals("AR", span.classes); assertEquals("rtl", span.direction)
        assertEquals("#123456", span.foreground); assertEquals("#fedcba", span.background)
        assertEquals(listOf(ReferenceKind.Fragment, ReferenceKind.Note), entry.references.map { it.kind })
        assertEquals(listOf(null, 3L), entry.references.map { it.groupNumber })
        assertEquals(listOf(2L, 1L), entry.references.map { it.number })
        val table=entry.sections.single().blocks.single().table!!
        assertEquals(3, table.geometry!!.cellPadding)
        assertEquals(1.25f, table.caption.single().fontScale)
        val cell=table.rows.single().first()
        assertEquals(1, cell.colspan)
        assertEquals(1.25f, cell.nestedTable!!.caption.single().fontScale)
        assertEquals(1.25f, table.rows.single()[1].blocks!!.single().spans.single().fontScale)
    }
    @Test fun legacyNineAndAbsentDpraScaleStayIdentity() {
        assertNull(decode(fixture(null, '9')).displayTitle.single().fontScale)
        assertNull(decode(fixture(null)).displayTitle.single().fontScale)
        assertEquals(1f, spanFontScale(Span("text", "identity")), 0f)
    }
    @Test fun malformedScaleAndTruncatedDpraAreRejectedWithoutLosingValidZero() {
        for (scale in listOf(Float.NaN, Float.POSITIVE_INFINITY, Float.NEGATIVE_INFINITY, -1f))
            assertThrows(Exception::class.java) { decode(fixture(scale)) }
        assertEquals(0f, decode(fixture(0f)).displayTitle.single().fontScale)
        val valid=fixture(1.25f)
        for (length in valid.indices) assertThrows(Exception::class.java) { decode(valid.copyOf(length)) }
    }
    @Test fun positiveScaleUsesInheritedEmAndDoesNotDoubleLegacyReduction() {
        for (size in listOf(12f, 18f)) {
            val scaled=Span("text", "ARchar", fontScale=1.25f)
            assertEquals(size * 1.25f, size * spanFontScale(scaled), 0.00001f)
            for (legacy in listOf(scaled.copy(small=true), scaled.copy(superscript=true),
                    scaled.copy(subscript=true), scaled.copy(small=true, superscript=true, subscript=true)))
                assertEquals(size, size * spanFontScale(legacy), 0.00001f)
        }
    }
    @Test fun zeroEgyptianStaysOriginalTextAndNeverRequestsCustomShaping() {
        val text="\uD80C\uDC00"
        assertTrue(egyptianTextRuns(listOf(Span("text", text, classes="Egyp", fontScale=0f))).isEmpty())
        val runs=egyptianTextRuns(listOf(Span("text", "before", fontScale=0f),
            Span("text", text, classes="Egyp", fontScale=1.25f)))
        assertEquals(6, runs.single().start); assertEquals(text, runs.single().text)
        // This tests routing only; zero Compose ink/layout/accessibility is not qualified here.
    }

    @Test fun dprbBodyIdentityAndZeroSurviveEveryRecursiveSpanSink() {
        for (scale in listOf(0f, 1f, 1.25f)) {
            val entry=decode(fixture(scale, 'B', 1))
            val table=entry.sections.single().blocks.single().table!!
            val spans=listOf(entry.displayTitle.single(), table.caption.single(),
                table.rows.single()[0].nestedTable!!.caption.single(),
                table.rows.single()[1].blocks!!.single().spans.single()) + entry.references.map { it.spans.single() }
            for (span in spans) {
                assertEquals(scale, span.fontScale)
                assertEquals(FontScaleBasis.NormalBody, span.fontScaleBasis)
            }
            assertEquals(listOf(2L, 1L), entry.references.map { it.number })
        }
        assertNull(decode(fixture(1f, 'B')).displayTitle.single().fontScale)
        assertEquals(FontScaleBasis.Context, decode(fixture(1.25f)).displayTitle.single().fontScaleBasis)
    }
    @Test fun dprbRejectsUnknownBasisTruncationAndBodyWithoutScaleModel() {
        for (basis in listOf(2, 255)) assertThrows(Exception::class.java) { decode(fixture(1f, 'B', basis)) }
        val valid=fixture(1f, 'B', 1)
        for (length in valid.indices) assertThrows(Exception::class.java) { decode(valid.copyOf(length)) }
        assertThrows(IllegalArgumentException::class.java) { Span("text", "reset", fontScaleBasis=FontScaleBasis.NormalBody) }
        for (scale in listOf(Float.NaN, Float.POSITIVE_INFINITY, -1f))
            assertThrows(Exception::class.java) { decode(fixture(scale, 'B', 1)) }
    }
    @Test fun dprbAbsentScaleSpansKeepTheirThirtyFourByteMinimum() {
        val bytes=Wire().apply {
            out.write("DPRB".toByteArray())
            u32(64)
            repeat(63) {
                byte(0); byte(0); byte(0); repeat(7) { string("") }; byte(0); byte(0); byte(0)
            }
            byte(0); byte(0); byte(0); repeat(7) { string("") }; byte(0); byte(0); byte(1); u32(1f.toRawBits()); byte(1)
            u32(0); emptySpans(); u32(0); u32(0); u32(0); u32(0)
        }.out.toByteArray()
        val spans=decode(bytes).displayTitle
        assertEquals(64, spans.size)
        assertTrue(spans.dropLast(1).all { it.fontScale == null && it.fontScaleBasis == FontScaleBasis.Context })
        assertEquals(1f, spans.last().fontScale)
        assertEquals(FontScaleBasis.NormalBody, spans.last().fontScaleBasis)
    }
    @Test fun bodyBasisUsesConfiguredReadingSizeAndContextKeepsHeadingSize() {
        for (body in listOf(12f, 18f)) {
            val heading=body * 1.5f
            val context=Span("link", "heading", target="Target", fontScale=1.25f)
            val normal=context.copy(fontScaleBasis=FontScaleBasis.NormalBody)
            assertEquals(heading * 1.25f, spanFontPixels(context, heading, body), 0.00001f)
            assertEquals(body * 1.25f, spanFontPixels(normal, heading, body), 0.00001f)
            assertEquals(body, spanFontPixels(normal.copy(fontScale=1f), heading, body), 0f)
            assertEquals(0f, spanFontPixels(normal.copy(fontScale=0f), heading, body), 0f)
            assertEquals(body, spanFontPixels(normal.copy(small=true, superscript=true, subscript=true), heading, body), 0.00001f)
            assertEquals("Target", normal.target)
            assertEquals("heading", normal.text)
        }
    }

    @Test fun computedPixelCeilingPreservesSemanticScaleAndBothTypographyBases() {
        val source=Span("link", "original", target="Target", fontScale=Float.MAX_VALUE)
        for (basis in listOf(FontScaleBasis.Context, FontScaleBasis.NormalBody)) {
            val span=source.copy(fontScaleBasis=basis)
            assertEquals(10000f, spanFontPixels(span, 24f, 18f), 0f)
            assertEquals(Float.MAX_VALUE, span.fontScale)
            assertEquals("original", span.text); assertEquals("Target", span.target)
            assertEquals(0f, spanFontPixels(span.copy(fontScale=0f), 24f, 18f), 0f)
            for (density in listOf(Density(1f, 1f), Density(2f, 1.5f))) {
                val size=renderedSpanFontSize(span, 24.sp, 18.sp, density)
                assertTrue(size.isSp)
                assertEquals(10000f, with(density) { size.toPx() }, 0.01f)
                val zero=renderedSpanFontSize(span.copy(fontScale=0f), 24.sp, 18.sp, density)
                assertEquals(0f, zero.value, 0f)
            }
        }
        val ordinary=source.copy(fontScale=1.25f)
        val context=renderedSpanFontSize(ordinary, 24.sp, 18.sp, Density(2f, 1.5f))
        assertTrue(context.isEm); assertEquals(1.25f, context.value, 0f)
        val body=ordinary.copy(fontScaleBasis=FontScaleBasis.NormalBody)
        val density=Density(2f, 1.5f)
        assertEquals(with(density) { 18.sp.toPx() } * 1.25f, with(density) { renderedSpanFontSize(body, 24.sp, 18.sp, density).toPx() }, 0.001f)
        // Changing configured body size or density recomputes physical sizing.
        assertEquals(with(density) { 24.sp.toPx() } * 1.25f, with(density) { renderedSpanFontSize(body, 24.sp, 24.sp, density).toPx() }, 0.001f)
        assertEquals(22.5f, with(Density(1f, 1f)) { renderedSpanFontSize(body, 24.sp, 18.sp, Density(1f, 1f)).toPx() }, 0.001f)
        assertEquals(9999f, spanFontPixels(ordinary.copy(fontScale=9999f), 1f, 1f), 0f)
        assertEquals(10000f, spanFontPixels(ordinary.copy(fontScale=10000f), 1f, 1f), 0f)
        assertEquals(10000f, spanFontPixels(ordinary.copy(fontScale=10001f), 1f, 1f), 0f)
        assertEquals(10000f, spanFontPixels(source.copy(small=true, superscript=true), 24f, 18f), 0f)
        // This is Compose's actual Android nonlinear FontScaling implementation,
        // whose Density TextUnit.toDp / Dp.toSp methods share an inverse converter.
        val nonlinear=Density(2f, 2f)
        val normalSize=48.sp
        val basePixels=with(nonlinear) { normalSize.toPx() }
        assertNotEquals(48f * nonlinear.density * nonlinear.fontScale, basePixels, 0.001f)
        val sameContext=renderedSpanFontSize(ordinary, normalSize, normalSize, nonlinear)
        val sameBody=renderedSpanFontSize(body, normalSize, normalSize, nonlinear)
        assertTrue(sameContext.isEm)
        assertEquals(basePixels * sameContext.value, with(nonlinear) { sameBody.toPx() }, 0.01f)
        for (basis in listOf(FontScaleBasis.Context, FontScaleBasis.NormalBody)) {
            val huge=source.copy(fontScaleBasis=basis)
            val capped=renderedSpanFontSize(huge, normalSize, normalSize, nonlinear)
            assertTrue(capped.isSp)
            assertEquals(10000f, with(nonlinear) { capped.toPx() }, 0.01f)
            val zero=renderedSpanFontSize(huge.copy(fontScale=0f), normalSize, normalSize, nonlinear)
            assertEquals(0f, zero.value, 0f)
            if (zero.isSp) assertEquals(0f, with(nonlinear) { zero.toPx() }, 0f)
        }
    }
}
