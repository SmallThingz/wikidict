package app.smallthingz.dict

import java.io.ByteArrayOutputStream
import org.junit.Assert.*
import org.junit.Test

/** Literal DPR documents pin the extension independently of the shared encoder. */
class SpanLinkPaintCodecTest {
    private enum class Owner { Display, Preamble, Paragraph, TableCaption, Cell, NestedCell, OrderedCell,
        RichCaption, Container, Scope, Missing, FigureCaption, FigureRichCaption, Reference, ReferenceBlocks }
    private data class Spec(val paint: Boolean = true, val kind: Int = 1, val text: String = "source",
        val target: String = "Target", val trail: String = "s", val foreground: String? = "#123456",
        val underline: Boolean = false, val scale: Float? = 12.375f, val basis: Int = 2,
        val features: Int? = 1, val image: Boolean = false, val fragment: String? = "part",
        val tooltip: String? = "source advice")
    private class Wire(val value: Spec = Spec(), val version: Char = 'M') {
        val out = ByteArrayOutputStream()
        val marks = linkedMapOf<String, Int>()
        fun byte(value: Int) { out.write(value) }
        fun u16(value: Int) { repeat(2) { byte(value ushr (it * 8)) } }
        fun u32(value: Int) { repeat(4) { byte(value ushr (it * 8)) } }
        fun f32(value: Float) = u32(value.toRawBits())
        fun string(value: String) { val bytes = value.encodeToByteArray(); u32(bytes.size); out.write(bytes) }
        fun mark(name: String) { check(marks.put(name, out.size()) == null) }
        fun length(value: Float, unit: Int = 0) { byte(unit); f32(value) }
        fun paint() {
            mark("paintPresence"); byte(1)
            listOf("#123456", "#234567", "#345678", "#456789", "#56789a", "#6789ab").forEachIndexed { i, color ->
                mark("color$i"); string(color)
            }
            mark("paintMask"); byte(0x52 or if (value.underline) 1 else 0)
            mark("focusPresence"); byte(1)
            mark("focusWidth"); length(2f)
            mark("focusColor"); byte(2); string("#abcdef")
            mark("focusRadius"); length(.5f, 1)
            mark("focusOffset"); length(-1.25f)
            mark("prefixEnd")
            mark("color6"); string("#789abc")
            mark("color7"); string("#89abcd")
            mark("combinedMask"); byte(3)
            mark("paintEnd")
        }
        fun span(source: Boolean = true) {
            val v = if (source) value else Spec(false, 0, "Missing", "", "", null, scale = null,
                basis = 0, features = null, fragment = null)
            if (source) mark("spanKind")
            byte(v.kind); byte(3); byte(3 or if (v.underline) 128 else 0)
            listOf(v.text, v.target, v.trail, "mai", "source-link", "ltr", "meaning").forEach(::string)
            byte(if (v.foreground == null) 0 else 1); v.foreground?.let(::string)
            byte(1); string("#fedcba")
            if (source) mark("fontFields")
            byte((if (v.scale == null) 0 else 1) or (if (v.features == null) 0 else 2) or (if (v.paint) 4 else 0))
            if (v.scale != null) { f32(v.scale); byte(v.basis) }
            if (source) mark("features")
            v.features?.let(::byte)
            if (v.paint) paint()
            if (source) mark("image")
            byte(if (v.image) 1 else 0)
            if (v.image) { string("Source.svg"); byte(3); u32(40); u32(20) }
            byte(if (v.fragment == null) 0 else 1); v.fragment?.let(::string)
            byte(if (v.tooltip == null) 0 else 1); v.tooltip?.let(::string)
        }
        fun spans(present: Boolean) { u32(if (present) 1 else 0); if (present) span() }
        fun blockHeader(kind: Int, text: Boolean = false) {
            byte(kind); byte(0); byte(0); spans(text); byte(0); string(""); string("")
        }
        fun blockTail() { string(""); string(""); repeat(4) { byte(0) } }
        fun paragraph() { blockHeader(0, true); byte(0); blockTail() }
        fun table(owner: Owner) {
            byte(1); byte(0); spans(owner == Owner.TableCaption)
            val cell = owner in listOf(Owner.Cell, Owner.NestedCell, Owner.OrderedCell)
            u32(if (cell) 1 else 0)
            if (cell) {
                u32(1); byte(0); u16(1); u16(1); byte(0); spans(owner == Owner.Cell)
                if (owner == Owner.NestedCell) table(Owner.Cell) else byte(0)
                if (owner == Owner.OrderedCell) { byte(1); u32(1); paragraph() } else byte(0)
                byte(0)
            }
            byte(0)
            if (owner == Owner.RichCaption) { byte(1); u32(1); paragraph() } else byte(0)
        }
        fun figure(owner: Owner, legacyPaint: Boolean) {
            byte(2); byte(0); byte(0); byte(0)
            repeat(12) { length(0f) }; f32(1f); length(1.2f, 1)
            byte(1); byte(0); byte(1); byte(0); byte(0); byte(1)
            span(source = owner == Owner.Missing); length(20f); length(1f, 1)
            byte(if (legacyPaint) 1 else 0); if (legacyPaint) byte(0)
            spans(owner == Owner.FigureCaption)
            if (owner == Owner.FigureRichCaption) { byte(1); u32(1); paragraph() } else byte(0)
            byte(0); byte(0)
        }
        fun body(owner: Owner, legacyPaint: Boolean = false) {
            when (owner) {
                Owner.Paragraph, Owner.ReferenceBlocks -> paragraph()
                Owner.Container -> {
                    blockHeader(13); byte(0); blockTail(); u32(0); u32(1); paragraph()
                }
                Owner.Scope -> {
                    blockHeader(0); byte(0); string(""); string(""); byte(0); byte(0); byte(0)
                    byte(1); u32(1); byte(2); byte(0); byte(1); byte(0); byte(1); string("mai")
                    u32(1); byte(0); spans(true)
                }
                Owner.Missing, Owner.FigureCaption, Owner.FigureRichCaption -> {
                    blockHeader(0); byte(0); string(""); string(""); byte(0); byte(0)
                    figure(owner, legacyPaint); byte(0)
                }
                else -> { blockHeader(12); table(owner); blockTail() }
            }
        }
        fun document(owner: Owner = Owner.Display, legacyPaint: Boolean = false): ByteArray {
            out.write("DPR$version".encodeToByteArray()); spans(owner == Owner.Display)
            val section = owner !in listOf(Owner.Display, Owner.Preamble, Owner.Reference, Owner.ReferenceBlocks)
            u32(if (section) 1 else 0)
            if (section) { byte(2); string("Body"); string(""); string(""); u32(1); body(owner, legacyPaint) }
            spans(owner == Owner.Preamble); u32(0); u32(0)
            val reference = owner in listOf(Owner.Reference, Owner.ReferenceBlocks)
            u32(if (reference) 1 else 0)
            if (reference) {
                byte(1); u32(1); string(""); spans(owner == Owner.Reference)
                byte(if (owner == Owner.ReferenceBlocks) 1 else 0)
                if (owner == Owner.ReferenceBlocks) { u32(1); paragraph() }
            }
            u32(if (value.image) 1 else 0)
            if (value.image) { string("Source.svg"); byte(0); string("") }
            return out.toByteArray()
        }
    }
    private fun read(bytes: ByteArray) = BlobDecoder.decode(bytes, "paint", "language", "Maithili", "mai")
    private fun allSpans(entry: Entry): List<Span> = buildList {
        addAll(entry.displayTitle); addAll(entry.preamble)
        entry.sections.forEach { section -> section.blocks.forEach { block -> block.visitSpanRuns { spans, _ -> addAll(spans) } } }
        entry.references.forEach { it.visitSpanRuns { spans, _ -> addAll(spans) } }
    }
    private fun actual(entry: Entry) = allSpans(entry).single { it.target == "Target" || it.kind == "external_link" }
    private fun expected(v: Spec) = Span(if (v.kind == 2) "external_link" else "link", v.text, v.target, v.trail,
        "mai", "source-link", "ltr", bold = true, italic = true, underline = v.underline, role = "headword",
        explanation = "meaning", foreground = v.foreground, background = "#fedcba", fontScale = v.scale,
        fontScaleBasis = if (v.scale == null) FontScaleBasis.Context else FontScaleBasis.entries[v.basis],
        image = if (v.image) InlineImage("Source.svg", 40, 20) else null, targetFragment = v.fragment,
        tooltip = v.tooltip, fontFeatures = v.features?.let { FontFeaturePolicy.entries[it] },
        linkPaint = if (!v.paint) null else LinkPaint(FigureLinkState("#123456", v.underline),
            FigureLinkState("#234567", true), FigureLinkState("#345678", false), FigureLinkState("#789abc", true),
            FigureLinkState("#456789", false), FigureLinkState("#56789a", true), FigureLinkState("#6789ab", false),
            FigureLinkState("#89abcd", true), true,
            FigureFocusOutline(StyleLength(StyleLengthUnit.Px, 2f), FigureColor.Rgb("#abcdef"),
                StyleLength(StyleLengthUnit.Em, .5f), SignedContainerMargin(StyleLengthUnit.Px, -1.25f))))

    @Test fun literalMStateOrderAndIndependentSpanFieldsSurviveEveryRecursiveOwner() {
        for (owner in Owner.entries) {
            val spec = Spec(trail = if (owner == Owner.Missing) "" else "s")
            val entry = read(Wire(spec).document(owner))
            val spans = allSpans(entry)
            assertEquals(owner.name, 1, spans.count { it.linkPaint != null })
            assertEquals(owner.name, expected(spec), actual(entry))
            val old = read(Wire(spec.copy(paint = false)).document(owner))
            assertEquals(owner.name, allSpans(old), spans.map { it.copy(linkPaint = null) })
            assertEquals(old.sections.map { it.copy(blocks = emptyList()) }, entry.sections.map { it.copy(blocks = emptyList()) })
            assertEquals(old.references.map { it.kind to it.number }, entry.references.map { it.kind to it.number })
        }
        for (underlined in listOf(false, true)) {
            val spec = Spec(kind = 2, target = "https://example.invalid/source", fragment = null, underline = underlined)
            assertEquals(expected(spec), actual(read(Wire(spec).document())))
        }
    }

    @Test fun nullPaintKeepsLiteralOlderBytesAndUnknownFontFlagMovesToBitThree() {
        for (scale in listOf<Float?>(null, 0f, 1.25f)) {
            val spec = Spec(paint = false, scale = scale, basis = 1, features = null)
            val old = Wire(spec, 'L').document(); val current = Wire(spec).document()
            assertArrayEquals(old.drop(4).toByteArray(), current.drop(4).toByteArray())
            assertEquals(read(old), read(current)); assertNull(actual(read(current)).linkPaint)
        }
        val wire = Wire(); val good = wire.document()
        for (flags in listOf(8, 16, 128, 255)) {
            val bad = good.copyOf(); bad[wire.marks.getValue("fontFields")] = flags.toByte()
            assertThrows(RuntimeException::class.java) { read(bad) }
        }
        val paintOnly = Wire(Spec(scale = null, features = null)).document()
        assertNotNull(actual(read(paintOnly)).linkPaint)
        for (version in 'A'..'L') {
            val bad = paintOnly.copyOf(); bad[3] = version.code.toByte()
            assertThrows("version $version", RuntimeException::class.java) { read(bad) }
        }
    }

    @Test fun allPaintFlagsAndAbsentOutlineStayIndependentOfTheStaticNormalState() {
        for (mask in listOf(0, 127)) for (combined in 0..3) {
            val spec = Spec(underline = mask and 1 != 0)
            val wire = Wire(spec); val bytes = wire.document()
            bytes[wire.marks.getValue("paintMask")] = mask.toByte()
            bytes[wire.marks.getValue("combinedMask")] = combined.toByte()
            val presence = wire.marks.getValue("focusPresence")
            val withoutOutline = bytes.copyOfRange(0, presence) + byteArrayOf(0) +
                bytes.copyOfRange(wire.marks.getValue("prefixEnd"), bytes.size)
            val policy = actual(read(withoutOutline)).linkPaint!!
            val states = listOf(policy.normal, policy.hover, policy.active, policy.visited, policy.visitedHover, policy.visitedActive)
            states.forEachIndexed { index, state -> assertEquals(mask and (1 shl index) != 0, state.underline) }
            assertEquals(mask and 64 != 0, policy.underlineOnFocus)
            assertEquals(combined and 1 != 0, policy.hoverActive.underline)
            assertEquals(combined and 2 != 0, policy.visitedHoverActive.underline)
            assertEquals("#789abc", policy.hoverActive.foreground)
            assertEquals("#89abcd", policy.visitedHoverActive.foreground)
            assertNull(policy.focusOutline)
            assertEquals(spec.underline, actual(read(withoutOutline)).underline)
        }
    }

    @Test fun actualOwnerAndStaticNormalConflictsRejectWithoutBreakingLegacyImages() {
        val invalid = listOf(Spec(kind = 0, fragment = null), Spec(kind = 3, fragment = null),
            Spec(target = ""), Spec(target = "", fragment = null), Spec(foreground = "#654321"),
            Spec(text = "", trail = "", image = true))
        for (spec in invalid) assertThrows(RuntimeException::class.java) { read(Wire(spec).document()) }
        val image = Spec(paint = false, text = "", trail = "", image = true)
        assertEquals(expected(image), actual(read(Wire(image).document())))
        assertEquals(expected(Spec(foreground = null)), actual(read(Wire(Spec(foreground = null)).document())))
        val wire = Wire(); val good = wire.document(); val bad = good.copyOf()
        bad[wire.marks.getValue("spanKind") + 2] = (3 or 128).toByte()
        assertThrows(RuntimeException::class.java) { read(bad) }
        val missing = Spec(trail = "", foreground = null)
        assertThrows(RuntimeException::class.java) { read(Wire(missing).document(Owner.Missing, legacyPaint = true)) }
        assertNotNull(read(Wire(missing.copy(paint = false)).document(Owner.Missing, legacyPaint = true)))
    }

    @Test fun malformedPresencePaintFlagsColorsAndOutlineRefuse() {
        val wire = Wire(); val good = wire.document()
        fun invalidByte(name: String, value: Int, offset: Int = 0) {
            val bad = good.copyOf(); bad[wire.marks.getValue(name) + offset] = value.toByte()
            assertThrows("$name/$value/$offset", RuntimeException::class.java) { read(bad) }
        }
        fun invalidWord(name: String, value: Int, offset: Int = 0) {
            val bad = good.copyOf(); repeat(4) { bad[wire.marks.getValue(name) + offset + it] = (value ushr (it * 8)).toByte() }
            assertThrows("$name/$value/$offset", RuntimeException::class.java) { read(bad) }
        }
        for (presence in listOf(0, 2, 255)) invalidByte("paintPresence", presence)
        invalidByte("paintMask", 128); invalidByte("focusPresence", 2)
        for (flags in listOf(4, 8, 128, 255)) invalidByte("combinedMask", flags)
        for (i in 0..7) {
            invalidByte("color$i", 'G'.code, 5)
            val malformedUtf8 = good.copyOf().also { it[wire.marks.getValue("color$i") + 4] = 255.toByte() }
            assertThrows(java.nio.charset.MalformedInputException::class.java) { read(malformedUtf8) }
            invalidWord("color$i", 32 * 1024 * 1024 + 1)
        }
        for (color in listOf(3, 255)) invalidByte("focusColor", color)
        for (color in listOf(0, 1)) {
            // Theme/transparent colors carry no RGB string; keep the rest of the outline well formed.
            val bad = good.copyOfRange(0, wire.marks.getValue("focusColor")) + byteArrayOf(color.toByte()) +
                good.copyOfRange(wire.marks.getValue("focusRadius"), good.size)
            assertThrows(RuntimeException::class.java) { read(bad) }
        }
        for (name in listOf("focusWidth", "focusRadius", "focusOffset")) {
            invalidByte(name, 2)
            invalidWord(name, Float.NaN.toRawBits(), 1)
            invalidWord(name, Float.POSITIVE_INFINITY.toRawBits(), 1)
        }
        for (name in listOf("focusWidth", "focusRadius")) invalidWord(name, (-1f).toRawBits(), 1)
    }

    @Test fun payloadCannotMoveAcrossFontFeaturesOrImageAndTruncationNeverDefaults() {
        val wire = Wire(); val good = wire.document()
        val start = wire.marks.getValue("paintPresence"); val end = wire.marks.getValue("paintEnd")
        val feature = wire.marks.getValue("features"); val image = wire.marks.getValue("image")
        val beforeFeatures = good.copyOfRange(0, feature) + good.copyOfRange(start, end) +
            good.copyOfRange(feature, start) + good.copyOfRange(end, good.size)
        val afterImage = good.copyOfRange(0, start) + byteArrayOf(good[image]) +
            good.copyOfRange(start, end) + good.copyOfRange(image + 1, good.size)
        assertThrows(RuntimeException::class.java) { read(beforeFeatures) }
        assertThrows(RuntimeException::class.java) { read(afterImage) }
        for (size in good.indices) assertThrows("prefix $size", RuntimeException::class.java) { read(good.copyOf(size)) }
        assertThrows(RuntimeException::class.java) { read(good + byteArrayOf(0)) }
    }

    @Test fun oldSixStateOrdinaryRecordsAndIncompleteCombinedStatesNeverAcquireDefaults() {
        for (minimalTail in listOf(false, true)) {
            val spec = if (minimalTail) Spec(scale = null, features = null, fragment = null, tooltip = null) else Spec()
            val wire = Wire(spec); val good = wire.document()
            val prefixEnd = wire.marks.getValue("prefixEnd")
            val paintEnd = wire.marks.getValue("paintEnd")
            val oldSixState = good.copyOfRange(0, prefixEnd) + good.copyOfRange(paintEnd, good.size)
            val firstCombinedOnly = good.copyOfRange(0, wire.marks.getValue("color7")) + good.copyOfRange(paintEnd, good.size)
            val absentFlags = good.copyOfRange(0, wire.marks.getValue("combinedMask")) + good.copyOfRange(paintEnd, good.size)
            for (invalid in listOf(oldSixState, firstCombinedOnly, absentFlags))
                assertThrows(RuntimeException::class.java) { read(invalid) }
            val focus = wire.marks.getValue("focusPresence")
            val beforeFocus = good.copyOfRange(0, focus) + good.copyOfRange(prefixEnd, paintEnd) +
                good.copyOfRange(focus, prefixEnd) + good.copyOfRange(paintEnd, good.size)
            assertThrows(RuntimeException::class.java) { read(beforeFocus) }
        }
    }
}
