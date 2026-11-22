package app.smallthingz.dict

import java.io.ByteArrayOutputStream
import org.junit.Assert.*
import org.junit.Test

/** Literal DPRQ alignment controls. These private fixtures are not source-image or runtime proof. */
class InlineImageAlignmentCodecTest {
    private enum class Owner {
        Display, Preamble, Paragraph, Cell, NestedCell, OrderedCell, TableCaption, RichTableCaption,
        Container, Reference, ReferenceBlocks, FigureCaption, FlowInline, FlowFigureCaption,
        FlowScope, FlowScopeFigureCaption, FigureMedia, InlineTable,
    }
    private class Wire(
        private val imageTag: Int = 3,
        private val alignment: Int = 0,
        private val rich: Boolean = true,
        private val writeAlignment: Boolean = true,
        private val includeCorners: Boolean = false,
        private val posterPayload: Boolean = imageTag == 2,
    ) {
        private val out = ByteArrayOutputStream()
        val marks = linkedMapOf<String, Int>()
        val file = if (posterPayload) "Alignment.stl" else "Alignment.svg"
        private fun byte(value: Int) { out.write(value) }
        private fun u16(value: Int) { repeat(2) { byte(value ushr (it * 8)) } }
        private fun u32(value: Long) { repeat(4) { byte((value ushr (it * 8)).toInt()) } }
        private fun f32(value: Float) = u32(value.toRawBits().toLong())
        private fun f64(value: Double) { val bits = value.toRawBits(); repeat(8) { byte((bits ushr (it * 8)).toInt()) } }
        private fun string(value: String) { val bytes = value.encodeToByteArray(); u32(bytes.size.toLong()); out.write(bytes) }
        private fun mark(name: String) { marks[name] = out.size() }
        private fun length(value: Float = 0f) { byte(0); f32(value) }
        private fun plainSpan(text: String = "body", target: String = "body-target") {
            byte(1); byte(0); byte(0); string(text); string(target); string(""); repeat(4) { string("") }
            repeat(6) { byte(0) } // Foreground, background, font fields, image, fragment, tooltip.
        }
        private fun imageSpan() {
            byte(1); byte(0); byte(1); string(""); string("File:$file"); string("")
            string("hu"); string(""); string(""); string("image explanation")
            byte(0); byte(0); byte(1); f32(1.25f); byte(1)
            mark("ImageTag"); byte(imageTag)
            if (imageTag != 0) {
                mark("ImagePayloadStart"); string(file); byte(if (rich) 255 else 3)
                u32(if (posterPayload) 40 else 30); u32(30)
                if (rich) {
                    string("image alt"); string("image advice")
                    byte(0); u32(1); byte(0); u32(4)
                    listOf(0.0, 0.0, 30.0, 30.0).forEach(::f64)
                    byte(0); string("Region target"); byte(1); string("region-part"); string("Region label")
                    byte(1); byte(1); string("https://example.invalid/image"); byte(0); string("Default label")
                    byte(0); string("hu")
                }
                if (posterPayload) {
                    byte(0); string("Model poster"); string("0123456789012345678901234567890123456789")
                    string("2026-01-02T03:04:05Z")
                }
                mark("ImagePayloadEnd")
                if (imageTag == 3 && writeAlignment) { mark("Alignment"); byte(alignment) }
            }
            byte(1); string("detail"); byte(1); string("outer advice")
            mark("ImageSpanEnd")
        }
        private fun spans(image: Boolean) { u32(1); if (image) imageSpan() else plainSpan() }
        private fun blockHeader(kind: Int, image: Boolean? = null) {
            byte(kind); byte(0); byte(0)
            if (image == null) u32(0) else spans(image)
            byte(0); string(""); string("")
        }
        private fun blockTail() { string(""); string(""); repeat(4) { byte(0) } }
        private fun paragraph(image: Boolean = true) { blockHeader(0, image); byte(0); blockTail() }
        private fun tableBlock(owner: Owner) { blockHeader(12); table(owner); blockTail() }
        private fun table(owner: Owner) {
            byte(1); byte(0)
            if (owner == Owner.TableCaption) spans(true) else u32(0)
            u32(1); u32(1); byte(0); u16(1); u16(1); byte(0)
            when (owner) {
                Owner.NestedCell, Owner.OrderedCell -> u32(0)
                else -> spans(owner == Owner.Cell || owner == Owner.InlineTable)
            }
            if (owner == Owner.NestedCell) table(Owner.Cell) else byte(0)
            if (owner == Owner.OrderedCell) { byte(1); u32(1); paragraph() } else byte(0)
            byte(0)
            if (owner == Owner.InlineTable) { byte(1); byte(0); byte(1); byte(2) } else byte(0)
            if (owner == Owner.RichTableCaption) { byte(1); u32(1); paragraph() } else byte(0)
        }
        private fun cornerTable() {
            blockHeader(12); byte(1); byte(0); u32(0); u32(0)
            byte(1); byte(6); byte(32); byte(0); byte(0)
            listOf(8f, 8f, 8f, 0f).forEach(::length)
            byte(0); blockTail()
        }
        private fun figure(media: Boolean = false) {
            byte(if (media) 1 else 2); byte(0); byte(0); byte(0)
            repeat(12) { length() }; f32(1f); length(18f)
            byte(1); byte(0); byte(1); byte(0); byte(0); byte(1)
            if (media) imageSpan() else plainSpan("Missing image", "missing-target")
            if (!media) { length(40f); length(18f); byte(0) }
            u32(0)
            if (media) byte(0) else { byte(1); u32(1); paragraph() }
            byte(0)
            if (media) byte(2) // RequestedFit matches the explicit 30px image axes.
            byte(0)
        }
        private fun figureBlock(media: Boolean = false) {
            blockHeader(0); byte(0); string(""); string(""); byte(0); byte(0)
            figure(media); byte(0)
        }
        private fun flowBlock(owner: Owner) {
            blockHeader(0); byte(0); string(""); string(""); byte(0); byte(0); byte(0)
            byte(1); u32(1)
            if (owner == Owner.FlowScope || owner == Owner.FlowScopeFigureCaption) {
                byte(2); byte(0); byte(2); byte(1); byte(1); string("hu"); u32(1)
            }
            if (owner == Owner.FlowFigureCaption || owner == Owner.FlowScopeFigureCaption) { byte(1); figure() }
            else { byte(0); spans(true) }
        }
        fun document(owner: Owner = Owner.Paragraph, version: Int = 81, features: Int = 0): ByteArray {
            out.write(byteArrayOf(68, 80, 82, version.toByte()))
            if (owner == Owner.Display) spans(true) else u32(0)
            u32(1); byte(2); string("Body"); string(""); string(""); u32(if (includeCorners) 2 else 1)
            when (owner) {
                Owner.Display, Owner.Preamble, Owner.Reference, Owner.ReferenceBlocks -> paragraph(false)
                Owner.Paragraph -> paragraph()
                Owner.Cell, Owner.NestedCell, Owner.OrderedCell, Owner.TableCaption, Owner.RichTableCaption,
                Owner.InlineTable -> tableBlock(owner)
                Owner.Container -> { blockHeader(13); byte(0); blockTail(); u32(0); u32(1); paragraph() }
                Owner.FigureCaption -> figureBlock()
                Owner.FigureMedia -> figureBlock(true)
                Owner.FlowInline, Owner.FlowFigureCaption, Owner.FlowScope, Owner.FlowScopeFigureCaption -> flowBlock(owner)
            }
            if (includeCorners) cornerTable()
            if (owner == Owner.Preamble) spans(true) else u32(0)
            u32(0); u32(0)
            if (owner == Owner.Reference || owner == Owner.ReferenceBlocks) {
                u32(1); byte(1); u32(1); string("")
                if (owner == Owner.Reference) { spans(true); byte(0) }
                else { u32(0); byte(1); u32(1); paragraph() }
            } else u32(0)
            u32(1); string(file); byte(0); string("catalog caption")
            if (version >= 80) { mark("Features"); byte(features) }
            return out.toByteArray()
        }
    }
    private fun read(bytes: ByteArray) = BlobDecoder.decode(bytes, "alignment", "supplemental", null, "hu")
    private fun image(entry: Entry) = entry.inlineImages.single()
    private fun imageSpan(entry: Entry): Span {
        val result = mutableListOf<Span>()
        fun collect(spans: List<Span>, preformatted: Boolean) { result += spans.filter { it.image != null } }
        collect(entry.displayTitle, false); collect(entry.preamble, false)
        entry.sections.forEach { section -> section.blocks.forEach { it.visitSpanRuns(::collect) } }
        entry.references.forEach { it.visitSpanRuns(::collect) }
        return result.single()
    }
    private fun bad(bytes: ByteArray) { assertThrows(RuntimeException::class.java) { read(bytes) } }
    private fun mutate(bytes: ByteArray, offset: Int, value: Int) = bytes.copyOf().also { it[offset] = value.toByte() }

    @Test fun qAlignmentAloneKeepsBothEnumsAndTheCompleteOldImageAndActionPayload() {
        val oldWire = Wire(imageTag = 1); val old = oldWire.document(version = 80, features = 1)
        val oldEntry = read(old); val legacy = image(oldEntry)
        assertNull(legacy.verticalAlign)
        val m = Wire(imageTag = 1).document(version = 77)
        assertArrayEquals(old.copyOf(old.size - 1).also { it[3] = 77 }, m)
        assertEquals(legacy, image(read(m)))
        for (alignment in 0..1) {
            val wire = Wire(alignment = alignment); val bytes = wire.document(features = 1)
            val entry = read(bytes); val value = image(entry); val span = imageSpan(entry)
            assertEquals(InlineImageVerticalAlign.entries[alignment], value.verticalAlign)
            assertEquals(legacy, value.copy(verticalAlign = null))
            assertEquals(imageSpan(oldEntry), span.copy(image = value.copy(verticalAlign = null)))
            assertEquals(BodyAdjoiningPolicy.Ordinary, entry.bodyAdjoining)
            assertEquals("Alignment.svg", value.file); assertEquals(30L, value.widthPx); assertEquals(30L, value.heightPx)
            assertEquals("image alt", value.alt); assertEquals("image advice", value.tooltip)
            assertTrue(value.border); assertEquals(ImageDarkModeFilter.InvertHueRotate180, value.darkModeFilter)
            assertEquals("hu", value.svgLanguage)
            assertEquals("Region target", value.map!!.regions.single().action.target)
            assertEquals("region-part", value.map!!.regions.single().action.targetFragment)
            assertEquals("https://example.invalid/image", value.map!!.defaultAction!!.target)
            assertEquals("File:Alignment.svg", span.target); assertEquals("detail", span.targetFragment)
            assertEquals("outer advice", span.tooltip); assertEquals("image explanation", span.explanation)
            assertEquals(1.25f, span.fontScale!!, 0f); assertEquals(FontScaleBasis.NormalBody, span.fontScaleBasis)
            assertEquals(wire.marks.getValue("ImagePayloadEnd"), wire.marks.getValue("Alignment"))
            assertArrayEquals(old.copyOfRange(oldWire.marks.getValue("ImagePayloadStart"), oldWire.marks.getValue("ImagePayloadEnd")),
                bytes.copyOfRange(wire.marks.getValue("ImagePayloadStart"), wire.marks.getValue("ImagePayloadEnd")))
            val at = wire.marks.getValue("Alignment")
            val stripped = bytes.copyOfRange(0, at) + bytes.copyOfRange(at + 1, bytes.size)
            stripped[3] = 80; stripped[wire.marks.getValue("ImageTag")] = 1
            assertArrayEquals(old, stripped)
            assertNull(read(Wire(alignment = alignment).document()).bodyAdjoining)
        }
        val absentP = Wire(imageTag = 0).document(version = 80, features = 1)
        val absentM = Wire(imageTag = 0).document(version = 77)
        assertArrayEquals(absentP.copyOf(absentP.size - 1).also { it[3] = 77 }, absentM)
        assertTrue(read(absentP).inlineImages.isEmpty())
    }

    @Test fun explicitAlignmentParticipatesInEverySpanSinkAndCoexistsWithOrdinaryCorners() {
        val owners = Owner.entries.filter { it != Owner.FigureMedia && it != Owner.InlineTable }
        for (owner in owners) for (alignment in 0..1) {
            val wire = Wire(alignment = alignment)
            val bytes = wire.document(owner)
            val entry = read(bytes)
            assertEquals("Owner $owner", InlineImageVerticalAlign.entries[alignment], image(entry).verticalAlign)
            assertEquals("File:Alignment.svg", imageSpan(entry).target)
            assertEquals("detail", imageSpan(entry).targetFragment)
            assertEquals(0, bytes[wire.marks.getValue("Features")].toInt())
            assertNull(entry.bodyAdjoining)
            bad(Wire(imageTag = 1).document(owner))
            assertNull(image(read(Wire(imageTag = 1).document(owner, version = 80, features = 1))).verticalAlign)
        }
        for (tag in listOf(1, 3)) {
            val entry = read(Wire(imageTag = tag, alignment = 1, includeCorners = true).document())
            assertEquals(if (tag == 3) InlineImageVerticalAlign.Baseline else null, image(entry).verticalAlign)
            val table = entry.sections.single().blocks.last().table!!
            assertEquals(TableCollapse.Separate, table.style!!.collapse)
            assertNotNull(table.style!!.cornerRadii)
            assertEquals("File:Alignment.svg", imageSpan(entry).target)
        }
        bad(Wire(imageTag = 1).document())
    }

    @Test fun qOnlyTagAndStrictAlignmentTailRejectOldHeadersUnknownValuesAndFalseFeatureClaims() {
        val wire = Wire(); val valid = wire.document()
        for (version in listOf(77, 78, 79, 80)) bad(mutate(valid, 3, version))
        for (tag in listOf(4, 255)) bad(mutate(valid, wire.marks.getValue("ImageTag"), tag))
        for (alignment in listOf(2, 255)) bad(mutate(valid, wire.marks.getValue("Alignment"), alignment))
        bad(Wire(writeAlignment = false).document())
        val at = wire.marks.getValue("Alignment")
        bad(valid.copyOfRange(0, at) + valid.copyOfRange(at + 1, valid.size))
        for (size in wire.marks.getValue("ImageTag") until wire.marks.getValue("ImageSpanEnd"))
            bad(valid.copyOf(size))
        for (feature in listOf(2, 4, 8, 16, 32, 64, 128))
            bad(mutate(valid, wire.marks.getValue("Features"), feature))
        bad(valid + byteArrayOf(0))
        // Header Q alone grants neither a synthetic alignment default nor a corner feature.
        bad(Wire(imageTag = 0).document())
        bad(Wire(imageTag = 1).document())
    }

    @Test fun legacyPosterFigureAndInlineTableStayValidWhileTheirAlignedOverlapsRefuse() {
        val posterWire = Wire(imageTag = 2, rich = false)
        val posterP = posterWire.document(version = 80, features = 1)
        val poster = image(read(posterP))
        assertNull(poster.verticalAlign); assertEquals(StaticPosterPolicy.ThreeDStlV1, poster.staticPoster!!.policy)
        assertEquals("Alignment.stl", poster.file); assertEquals(40L, poster.widthPx); assertEquals(30L, poster.heightPx)
        val posterM = Wire(imageTag = 2, rich = false).document(version = 77)
        assertArrayEquals(posterP.copyOf(posterP.size - 1).also { it[3] = 77 }, posterM)
        assertEquals(poster, image(read(posterM)))
        for (alignment in InlineImageVerticalAlign.entries) {
            assertThrows(IllegalArgumentException::class.java) { poster.copy(verticalAlign = alignment) }
            bad(Wire(alignment = alignment.ordinal, rich = false, posterPayload = true).document())
        }
        for (owner in listOf(Owner.FigureMedia, Owner.InlineTable)) {
            val legacy = read(Wire(imageTag = 1, rich = false).document(owner, version = 80, features = 1))
            assertNull(image(legacy).verticalAlign)
            for (alignment in InlineImageVerticalAlign.entries) {
                bad(Wire(alignment = alignment.ordinal, rich = false).document(owner))
                val block = legacy.sections.single().blocks.single()
                val span = imageSpan(legacy)
                val aligned = span.copy(image = span.image!!.copy(verticalAlign = alignment))
                if (owner == Owner.FigureMedia) {
                    val figure = block.figure!!
                    val content = figure.content as FigureContent.Image
                    assertThrows(IllegalArgumentException::class.java) { figure.copy(content = content.copy(span = aligned)) }
                } else {
                    val table = block.table!!; val cell = table.rows.single().single()
                    assertThrows(IllegalArgumentException::class.java) { table.copy(rows = listOf(listOf(cell.copy(spans = listOf(aligned))))) }
                }
            }
        }
    }
}
