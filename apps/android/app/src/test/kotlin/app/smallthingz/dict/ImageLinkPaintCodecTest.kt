package app.smallthingz.dict

import java.io.ByteArrayOutputStream
import org.junit.Assert.*
import org.junit.Test

/** Literal image-owned LinkPaint controls; no source provenance or native paint claim is made. */
class ImageLinkPaintCodecTest {
    private enum class Owner { Display, Preamble, Paragraph, Cell, NestedCell, OrderedCell, TableCaption,
        RichCaption, Container, Reference, ReferenceBlocks, FigureContent, FigureCaption, FigureRichCaption,
        FlowInline, FlowFigure, ScopeInline, ScopeFigure }
    private data class Spec(val paint: Boolean = true, val outline: Boolean = true,
        val image: Boolean = true, val kind: Int = 1, val target: String = "File:Paint.svg",
        val text: String = "", val trail: String = "", val fragment: String? = "detail",
        val foreground: String? = "#123456", val underline: Boolean = false,
        val alt: String? = null, val map: Boolean = false, val poster: Boolean = false,
        val alignment: Int? = null, val mask: Int = 0x52, val combined: Int = 3)
    private class Wire(private val v: Spec = Spec(), private val corners: Boolean = false,
        private val ruleClear: Boolean = false, private val figureLayout: Boolean = false,
        private val baseMediaOutline: Boolean = false,
        private val viewportMediaOutlines: List<Boolean> = emptyList()) {
        private val out = ByteArrayOutputStream()
        val at = linkedMapOf<String, Int>()
        val file = if (v.poster) "Paint.stl" else "Paint.svg"
        private fun byte(value: Int) { out.write(value) }
        private fun u16(value: Int) { repeat(2) { byte(value ushr (it * 8)) } }
        private fun u32(value: Int) { repeat(4) { byte(value ushr (it * 8)) } }
        private fun f32(value: Float) = u32(value.toRawBits())
        private fun string(value: String) { val bytes = value.encodeToByteArray(); u32(bytes.size); out.write(bytes) }
        private fun mark(name: String) { check(at.put(name, out.size()) == null) }
        private fun length(value: Float = 0f, unit: Int = 0) { byte(unit); f32(value) }
        private fun paint() {
            mark("PaintPresence"); byte(1)
            listOf("#123456", "#234567", "#345678", "#456789", "#56789a", "#6789ab").forEachIndexed { i, color ->
                mark("Color$i"); string(color)
            }
            mark("Mask"); byte(v.mask)
            mark("FocusPresence"); byte(if (v.outline) 1 else 0)
            if (v.outline) {
                mark("FocusWidthUnit"); byte(0); mark("FocusWidth"); f32(2f)
                mark("FocusColor"); byte(2); string("#abcdef")
                mark("FocusRadiusUnit"); byte(1); mark("FocusRadius"); f32(.5f)
                mark("FocusOffsetUnit"); byte(0); mark("FocusOffset"); f32(-1.25f)
            }
            mark("Color6"); string("#789abc"); mark("Color7"); string("#89abcd")
            mark("Combined"); byte(v.combined); mark("PaintEnd")
        }
        private fun plainSpan() {
            byte(0); byte(0); byte(0); string("Missing image"); repeat(6) { string("") }; repeat(6) { byte(0) }
        }
        private fun span() {
            mark("SpanStart"); byte(v.kind); byte(3); mark("SpanFlags"); byte(3 or if (v.underline) 128 else 0)
            string(v.text); string(v.target); string(v.trail); string("mg"); string("source-image"); string("ltr"); string("meaning")
            byte(if (v.foreground == null) 0 else 1); v.foreground?.let(::string)
            byte(1); string("#fedcba")
            mark("FontFields"); byte(3 or if (v.paint) 4 else 0)
            f32(12.375f); byte(2); byte(1)
            if (v.paint) paint()
            mark("ImageTag"); byte(if (!v.image) 0 else if (v.poster) 2 else if (v.alignment != null) 3 else 1)
            if (v.image) {
                mark("ImagePayload"); string(file)
                byte(3 or 8 or 16 or (if (v.alt != null) 4 else 0) or (if (v.map) 32 else 0) or
                    (if (v.poster) 0 else 64 or 128))
                u32(40); u32(if (v.poster) 30 else 20)
                v.alt?.let(::string); string("image advice")
                if (v.map) { byte(0); u32(0); byte(0) }
                if (!v.poster) { byte(0); string("mg") }
                if (v.poster) {
                    byte(0); string("Poster"); string("0123456789012345678901234567890123456789")
                    string("2026-01-02T03:04:05Z")
                }
                if (v.alignment != null && !v.poster) byte(v.alignment)
                mark("ImageEnd")
            }
            byte(if (v.fragment == null) 0 else 1); v.fragment?.let(::string)
            byte(1); string("source advice"); mark("SpanEnd")
        }
        private fun spans(source: Boolean) { u32(if (source) 1 else 0); if (source) span() }
        private fun prefix(kind: Int, source: Boolean = false) {
            byte(kind); byte(0); byte(0); spans(source); byte(0); string(""); string("")
        }
        private fun tail() { string(""); string(""); repeat(4) { byte(0) } }
        private fun paragraph() { prefix(0, true); byte(0); tail() }
        private fun table(owner: Owner) {
            byte(1); byte(0); spans(owner == Owner.TableCaption)
            val cell = owner in listOf(Owner.Cell, Owner.NestedCell, Owner.OrderedCell)
            u32(if (cell) 1 else 0)
            if (cell) {
                u32(1); byte(1); u16(1); u16(1); byte(0); spans(owner == Owner.Cell)
                if (owner == Owner.NestedCell) table(Owner.Cell) else byte(0)
                if (owner == Owner.OrderedCell) { byte(1); u32(1); paragraph() } else byte(0)
                byte(0)
            }
            byte(0)
            if (owner == Owner.RichCaption) { byte(1); u32(1); paragraph() } else byte(0)
        }
        private fun figure(owner: Owner) {
            val content = owner == Owner.FigureContent
            byte(if (content && figureLayout) 5 else if (content) 1 else 2); byte(0); byte(0); byte(0)
            repeat(12) { length() }; f32(1f); length(18f)
            byte(1); byte(0); byte(1); byte(0); byte(0); byte(1)
            if (content) span() else { plainSpan(); length(40f); length(18f); byte(0) }
            spans(owner == Owner.FigureCaption)
            if (owner == Owner.FigureRichCaption || owner == Owner.FlowFigure || owner == Owner.ScopeFigure) {
                byte(1); u32(1); paragraph()
            } else byte(0)
            byte(0); if (content) byte(2); byte(0)
            if (content && figureLayout) tableCaptionLayout()
        }
        private fun mediaLayout(name: String, outlined: Boolean) {
            f32(1f); byte(0); string("mg"); byte(0); byte(1)
            byte(0); byte(0); byte(0)
            mark(name + "Focus"); byte(if (outlined) 1 else 0)
            if (outlined) {
                length(2f); byte(2); string("#abcdef"); length(.5f, 1); length(-1.25f)
            }
        }
        private fun tableCaptionLayout() {
            mark("FigureLayoutStart"); byte(1); u32(0); repeat(8) { byte(0) }
            mediaLayout("BaseMedia", baseMediaOutline); byte(0)
            u32(viewportMediaOutlines.size)
            viewportMediaOutlines.forEachIndexed { index, outlined ->
                u32(listOf(639, 399)[index]); u32(0); mediaLayout("Viewport${index}Media", outlined); byte(0)
            }
            byte(0); byte(0); mark("FigureLayoutEnd")
        }
        private fun body(owner: Owner) {
            when (owner) {
                Owner.Paragraph, Owner.ReferenceBlocks -> paragraph()
                Owner.Container -> { prefix(13); byte(0); tail(); u32(0); u32(1); paragraph() }
                Owner.FigureContent, Owner.FigureCaption, Owner.FigureRichCaption -> {
                    prefix(0); byte(0); string(""); string(""); byte(0); byte(0); figure(owner); byte(0)
                }
                Owner.FlowInline, Owner.FlowFigure, Owner.ScopeInline, Owner.ScopeFigure -> {
                    prefix(0); byte(0); string(""); string(""); byte(0); byte(0); byte(0); byte(1); u32(1)
                    if (owner == Owner.ScopeInline || owner == Owner.ScopeFigure) {
                        byte(2); byte(0); byte(2); byte(1); byte(1); string("mg"); u32(1)
                    }
                    if (owner == Owner.FlowFigure || owner == Owner.ScopeFigure) { byte(1); figure(owner) }
                    else { byte(0); spans(true) }
                }
                else -> { prefix(12); table(owner); tail() }
            }
        }
        private fun cornerTable() {
            prefix(12); byte(1); byte(0); u32(0); u32(0)
            byte(1); byte(6); byte(32); byte(0); byte(0)
            listOf(8f, 8f, 8f, 0f).forEach { length(it) }; byte(0); tail()
        }
        private fun rule() {
            prefix(11); byte(0); tail(); byte(2); length(1f); byte(0); repeat(4) { length() }; byte(0)
        }
        fun document(owner: Owner = Owner.Paragraph, version: Char = 'R', features: Int = 0): ByteArray {
            out.write("DPR$version".encodeToByteArray()); spans(owner == Owner.Display)
            val bodyOwner = owner !in listOf(Owner.Display, Owner.Preamble, Owner.Reference, Owner.ReferenceBlocks)
            val section = bodyOwner || corners || ruleClear
            u32(if (section) 1 else 0)
            if (section) {
                byte(2); string("Body"); string(""); string("")
                u32((if (bodyOwner) 1 else 0) + (if (corners) 1 else 0) + (if (ruleClear) 1 else 0))
                if (bodyOwner) body(owner)
                if (corners) cornerTable()
                if (ruleClear) rule()
            }
            spans(owner == Owner.Preamble); u32(0); u32(0)
            val reference = owner == Owner.Reference || owner == Owner.ReferenceBlocks
            u32(if (reference) 1 else 0)
            if (reference) {
                byte(1); u32(1); string(""); spans(owner == Owner.Reference)
                byte(if (owner == Owner.ReferenceBlocks) 1 else 0)
                if (owner == Owner.ReferenceBlocks) { u32(1); paragraph() }
            }
            u32(if (v.image) 1 else 0)
            if (v.image) { string(file); byte(0); string("catalog caption") }
            if (version >= 'P') { mark("Features"); byte(features) }
            return out.toByteArray()
        }
        fun spanBytes(bytes: ByteArray) = bytes.copyOfRange(at.getValue("SpanStart"), at.getValue("SpanEnd"))
    }
    private fun read(bytes: ByteArray) = BlobDecoder.decode(bytes, "Image paint", "supplemental", null, "mg")
    private fun allSpans(entry: Entry): List<Span> = buildList {
        addAll(entry.displayTitle); addAll(entry.preamble)
        entry.sections.forEach { section -> section.blocks.forEach { block -> block.visitSpanRuns { spans, _ -> addAll(spans) } } }
        entry.references.forEach { it.visitSpanRuns { spans, _ -> addAll(spans) } }
    }
    private fun actual(entry: Entry) = allSpans(entry).single { it.classes == "source-image" }
    private fun expectedPaint(v: Spec): LinkPaint {
        fun state(color: String, bit: Int) = LinkState(color, v.mask and (1 shl bit) != 0)
        return LinkPaint(state("#123456", 0), state("#234567", 1), state("#345678", 2),
            LinkState("#789abc", v.combined and 1 != 0), state("#456789", 3), state("#56789a", 4),
            state("#6789ab", 5), LinkState("#89abcd", v.combined and 2 != 0), v.mask and 64 != 0,
            if (!v.outline) null else FigureFocusOutline(StyleLength(StyleLengthUnit.Px, 2f), FigureColor.Rgb("#abcdef"),
                StyleLength(StyleLengthUnit.Em, .5f), SignedContainerMargin(StyleLengthUnit.Px, -1.25f)))
    }
    private fun changed(bytes: ByteArray, offset: Int, value: Int) = bytes.copyOf().also { it[offset] = value.toByte() }
    private fun changed32(bytes: ByteArray, offset: Int, value: Int) = bytes.copyOf().also { copy ->
        repeat(4) { copy[offset + it] = (value ushr (it * 8)).toByte() }
    }
    private fun bad(bytes: ByteArray) { assertTrue("Malformed literal payload was accepted", runCatching { read(bytes) }.isFailure) }

    @Test fun defaultExplicitNoneAndOutlinePreserveEightSamplesWithoutChangingImageMetadata() {
        val default = actual(read(Wire(Spec(paint = false)).document(version = 'M')))
        assertNull(default.linkPaint)
        for (outline in listOf(false, true)) for (alt in listOf<String?>(null, "")) {
            val spec = Spec(outline = outline, alt = alt); val wire = Wire(spec); val bytes = wire.document()
            val entry = read(bytes); val span = actual(entry); val policy = span.linkPaint!!
            assertEquals(expectedPaint(spec), policy); assertEquals(default.copy(image = default.image!!.copy(alt = alt)), span.copy(linkPaint = null))
            assertEquals(0, bytes.last().toInt()); assertNull(entry.bodyAdjoining)
            val image = span.image!!
            assertEquals("Paint.svg", image.file); assertEquals(40L, image.widthPx); assertEquals(20L, image.heightPx)
            assertEquals("image advice", image.tooltip); assertTrue(image.border)
            assertEquals(ImageDarkModeFilter.InvertHueRotate180, image.darkModeFilter); assertEquals("mg", image.svgLanguage)
            assertEquals("File:Paint.svg", span.target); assertEquals("detail", span.targetFragment)
            assertEquals("source advice", span.tooltip); assertEquals(12.375f, span.fontScale!!, 0f)
            assertEquals(FontScaleBasis.CssPx, span.fontScaleBasis); assertEquals(FontFeaturePolicy.SevenOn, span.fontFeatures)
            assertEquals(listOf(Media("Paint.svg", "image", "catalog caption")), entry.media)
            assertEquals(outline, policy.focusOutline != null)
        }
        for (mask in listOf(0, 127)) for (combined in 0..3) {
            val spec = Spec(outline = false, underline = mask and 1 != 0, mask = mask, combined = combined)
            assertEquals(expectedPaint(spec), actual(read(Wire(spec).document())).linkPaint)
        }
        for (alignment in 0..1) {
            val span = actual(read(Wire(Spec(alignment = alignment)).document()))
            assertEquals(InlineImageVerticalAlign.entries[alignment], span.image!!.verticalAlign)
            assertEquals(expectedPaint(Spec()), span.linkPaint)
        }
    }

    @Test fun imagePaintCensusIncludesEveryRecursiveSpanOwnerAndRejectsVersionCorrectDowngrades() {
        for (owner in Owner.entries) {
            val spec = Spec(); val entry = read(Wire(spec).document(owner))
            val span = actual(entry)
            assertEquals(owner.name, expectedPaint(spec), span.linkPaint)
            assertEquals(owner.name, 1, allSpans(entry).count { it.image != null && it.linkPaint != null })
            assertEquals("File:Paint.svg", span.target); assertEquals("detail", span.targetFragment)
            for (header in listOf('M', 'N', 'O', 'P', 'Q')) {
                val bytes = Wire(spec, corners = header == 'Q').document(owner, version = header,
                    features = if (header == 'P') 1 else 0)
                val failure = assertThrows(IllegalArgumentException::class.java) { read(bytes) }
                assertEquals("Image link paint requires R", failure.message)
            }
        }
        val external = Spec(kind = 2, target = "https://example.invalid/image", fragment = null)
        assertEquals("external_link", actual(read(Wire(external).document())).kind)
        assertEquals(external.target, actual(read(Wire(external).document())).target)
        assertNull(actual(read(Wire(external).document())).targetFragment)
        assertNotNull(actual(read(Wire(Spec(foreground = null)).document())).linkPaint)
    }

    @Test fun oldNullImageAndOrdinaryTextBytesRemainExactAcrossLegacyAndNewCapability() {
        for (spec in listOf(Spec(paint = false), Spec(image = false, target = "Target", text = "source", trail = "s"))) {
            val mWire = Wire(spec); val m = mWire.document(version = 'M'); val old = actual(read(m))
            for (header in listOf('N', 'O', 'P', 'Q', 'R')) {
                val wire = Wire(spec, corners = header == 'Q', ruleClear = header == 'R')
                val bytes = wire.document(version = header, features = if (header == 'P') 1 else 0)
                assertEquals(old, actual(read(bytes)))
                assertArrayEquals(mWire.spanBytes(m), wire.spanBytes(bytes))
                if (header == 'N' || header == 'O')
                    assertArrayEquals(m.copyOfRange(4, m.size), bytes.copyOfRange(4, bytes.size))
            }
            bad(Wire(spec).document())
        }
        val nullQ = Wire(Spec(paint = false), corners = true).document(version = 'Q')
        bad(changed(nullQ, 3, 'R'.code))
        val joined = read(Wire(corners = true, ruleClear = true).document(features = 1))
        assertEquals(BodyAdjoiningPolicy.Ordinary, joined.bodyAdjoining)
        assertNotNull(joined.sections.single().blocks[1].table!!.style!!.cornerRadii)
        assertEquals(FigureClear.None, joined.sections.single().blocks[2].ruleStyle!!.clear)
        assertNotNull(actual(joined).linkPaint)
    }

    @Test fun simpleImageOwnerAdmissionRetainsValidLegacyAltMapAndPosterWithoutPaint() {
        val valid = actual(read(Wire().document())); val image = valid.image!!
        val map = ImageMap(ImageMapDescription.None, emptyList())
        val poster = StaticPoster(StaticPosterPolicy.ThreeDStlV1, "Poster",
            "0123456789012345678901234567890123456789", "2026-01-02T03:04:05Z")
        for (changedImage in listOf(image.copy(alt = "fallback"), image.copy(map = map),
            InlineImage("Paint.stl", 40, 30, staticPoster = poster))) {
            assertThrows(IllegalArgumentException::class.java) { valid.copy(image = changedImage) }
            assertEquals(changedImage, valid.copy(image = changedImage, linkPaint = null).image)
        }
        for (spec in listOf(Spec(alt = "fallback"), Spec(map = true), Spec(poster = true))) {
            bad(Wire(spec).document())
            assertNull(actual(read(Wire(spec.copy(paint = false)).document(version = 'M'))).linkPaint)
        }
        val invalid = listOf<() -> Span>(
            { valid.copy(kind = "text", target = "", targetFragment = null) },
            { valid.copy(target = "", targetFragment = null) }, { valid.copy(text = "fallback") },
            { valid.copy(trail = "s") }, { valid.copy(foreground = "#654321") },
            { valid.copy(underline = !valid.underline) },
            { valid.copy(kind = "external_link", target = "https://example.invalid/image") },
        )
        invalid.forEach { make -> assertThrows(IllegalArgumentException::class.java) { make() } }
        for (spec in listOf(Spec(kind = 0, target = "", fragment = null), Spec(kind = 3, fragment = null),
            Spec(target = "", fragment = null), Spec(text = "fallback"), Spec(trail = "s"),
            Spec(foreground = "#654321"), Spec(underline = true))) bad(Wire(spec).document())
    }

    @Test fun malformedPaintMasksOutlineTailsAndUnmatchedPFeaturesRefuse() {
        val wire = Wire(); val bytes = wire.document(); val at = wire.at
        for (value in listOf(0, 2, 255)) bad(changed(bytes, at.getValue("PaintPresence"), value))
        bad(changed(bytes, at.getValue("Mask"), 128)); bad(changed(bytes, at.getValue("FocusPresence"), 2))
        for (value in listOf(4, 128, 255)) bad(changed(bytes, at.getValue("Combined"), value))
        for (value in listOf(32, 64, 128, 255)) bad(changed(bytes, at.getValue("FontFields"), value))
        for (index in 0..7) bad(changed(bytes, at.getValue("Color$index") + 5, 'G'.code))
        for (name in listOf("FocusWidth", "FocusRadius", "FocusOffset")) {
            bad(changed(bytes, at.getValue(name + "Unit"), 2))
            for (value in listOf(Float.NaN, Float.POSITIVE_INFINITY))
                bad(changed32(bytes, at.getValue(name), value.toRawBits()))
        }
        for (name in listOf("FocusWidth", "FocusRadius")) bad(changed32(bytes, at.getValue(name), (-1f).toRawBits()))
        for (color in listOf(0, 1, 3)) bad(changed(bytes, at.getValue("FocusColor"), color))
        for (end in bytes.indices) bad(bytes.copyOf(end))
        bad(bytes + byteArrayOf(0))
        bad(changed(bytes, 3, 'S'.code))
        // Existing P bits retain their meanings; this fixture has none of their corresponding payloads.
        for (feature in listOf(4, 8, 16, 32, 64, 128)) bad(changed(bytes, at.getValue("Features"), feature))
        assertEquals(BodyAdjoiningPolicy.Ordinary, read(Wire().document(features = 1)).bodyAdjoining)
    }

    @Test fun primaryFigureImageAndMediaHaveOneFocusOwnerInBaseAndEveryViewport() {
        for (outlined in listOf(false, true)) {
            val spec = Spec(outline = outlined)
            val valid = read(Wire(spec, figureLayout = true,
                viewportMediaOutlines = listOf(false, false)).document(Owner.FigureContent))
                .sections.single().blocks.single().figure!!
            val image = valid.content as FigureContent.Image
            val layout = valid.tableCaptionLayout!!
            assertEquals(expectedPaint(spec), image.span.linkPaint)
            assertNull(layout.media.focusOutline)
            assertEquals(listOf(639L, 399L), layout.viewportStates.map { it.maxWidthPx })
            assertTrue(layout.viewportStates.all { it.media.focusOutline == null })
            val outline = expectedPaint(Spec()).focusOutline!!
            for (slot in 0..2) {
                val competing = if (slot == 0) layout.copy(media = layout.media.copy(focusOutline = outline))
                    else layout.copy(viewportStates = layout.viewportStates.mapIndexed { index, state ->
                        if (index == slot - 1) state.copy(media = state.media.copy(focusOutline = outline)) else state
                    })
                val failure = assertThrows(IllegalArgumentException::class.java) {
                    valid.copy(tableCaptionLayout = competing)
                }
                assertEquals("Unsupported Figure table-caption combination", failure.message)
                val legacy = valid.copy(content = image.copy(span = image.span.copy(linkPaint = null)),
                    tableCaptionLayout = competing)
                assertNull(legacy.content.span.linkPaint)
                assertEquals(outline, if (slot == 0) legacy.tableCaptionLayout!!.media.focusOutline
                    else legacy.tableCaptionLayout!!.viewportStates[slot - 1].media.focusOutline)
                val captionOwner = legacy.copy(caption = listOf(image.span))
                assertEquals(image.span, captionOwner.caption.single())
                assertNull(captionOwner.content.span.linkPaint)
            }
        }
    }

    @Test fun forgedFigureMediaTailsRejectCompetingImagePoliciesWithoutChangingTheirSourceSpan() {
        for (outlined in listOf(false, true)) for (slot in 0..2) {
            val spec = Spec(outline = outlined)
            val validWire = Wire(spec, figureLayout = true, viewportMediaOutlines = listOf(false, false))
            val validBytes = validWire.document(Owner.FigureContent)
            val valid = read(validBytes).sections.single().blocks.single().figure!!
            val legacyWire = Wire(spec.copy(paint = false), figureLayout = true,
                baseMediaOutline = slot == 0,
                viewportMediaOutlines = listOf(slot == 1, slot == 2))
            val legacyBytes = legacyWire.document(Owner.FigureContent, version = 'M')
            val legacy = read(legacyBytes).sections.single().blocks.single().figure!!
            assertEquals(valid.content.span.copy(linkPaint = null), legacy.content.span)
            val tail = legacyBytes.copyOfRange(legacyWire.at.getValue("FigureLayoutStart"),
                legacyWire.at.getValue("FigureLayoutEnd"))
            val oldTailStart = validWire.at.getValue("FigureLayoutStart")
            val oldTailEnd = validWire.at.getValue("FigureLayoutEnd")
            val forged = validBytes.copyOfRange(0, oldTailStart) + tail + validBytes.copyOfRange(oldTailEnd, validBytes.size)
            assertArrayEquals(validWire.spanBytes(validBytes), validWire.spanBytes(forged))
            val failure = assertThrows(IllegalArgumentException::class.java) { read(forged) }
            assertEquals("Unsupported Figure table-caption combination", failure.message)
            assertEquals(expectedPaint(spec), valid.content.span.linkPaint)
            assertEquals("File:Paint.svg", legacy.content.span.target)
            assertEquals("detail", legacy.content.span.targetFragment)
        }
    }
}
