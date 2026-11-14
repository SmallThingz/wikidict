package app.smallthingz.dict

import java.io.ByteArrayOutputStream
import org.junit.Assert.*
import org.junit.Test

/** Literal O wire controls, independent of the shared encoder and of native text shaping. */
class InlineTextStyleCodecTest {
    private enum class Owner { Display, Preamble, Paragraph, Container, Cell, NestedCell, OrderedCell,
        TableCaption, RichCaption, Scope, Missing, FigureCaption, FigureRichCaption, Reference, ReferenceBlocks }
    private data class Spec(val effects: Int? = 15, val kind: Int = 1, val text: String = "X",
        val target: String = "Target", val trail: String = "!", val flags: Int = 63, val role: Int = 7,
        val scale: Float? = .75f, val basis: Int = 1, val features: Int? = 1,
        val language: String = "ja", val classes: String = "Jpan", val direction: String = "rtl",
        val paint: Boolean = true, val image: Boolean = false, val fragment: String? = "part",
        val tooltip: String? = "source advice", val relative: Boolean = true,
        val height: Float = 1f, val heightBasis: Int = 2, val snapshotFlags: Int = 31,
        val snapshotScale: Float = .75f, val snapshotBasis: Int = 1, val face: Int = 15,
        val snapshotLanguage: String = "ja", val snapshotClasses: String = "Jpan", val snapshotRole: Int = 7,
        val snapshotFeatures: Int = 1, val cursor: Int = 0)
    private fun plain(text: String = "Z") = Spec(effects = null, kind = 0, text = text, target = "", trail = "",
        flags = 0, role = 0, scale = null, features = null, language = "", classes = "", direction = "",
        paint = false, fragment = null, tooltip = null)
    private class Wire(val value: Spec = Spec(), val version: Char = 'O') {
        val out = ByteArrayOutputStream()
        val at = linkedMapOf<String, Int>()
        private var hasImage = false
        fun byte(value: Int) { out.write(value) }
        fun u16(value: Int) { repeat(2) { byte(value ushr (it * 8)) } }
        fun u32(value: Int) { repeat(4) { byte(value ushr (it * 8)) } }
        fun f32(value: Float) = u32(value.toRawBits())
        fun string(value: String) { val bytes = value.encodeToByteArray(); u32(bytes.size); out.write(bytes) }
        fun mark(name: String) { check(at.put(name, out.size()) == null) }
        fun length(value: Float, unit: Int = 0) { byte(unit); f32(value) }
        fun span(v: Spec = value, prefix: String = "") {
            fun m(name: String) = mark(prefix + name)
            m("kind"); byte(v.kind); m("role"); byte(v.role); byte(v.flags)
            string(v.text); string(v.target); string(v.trail); string(v.language); string(v.classes); string(v.direction); string("")
            byte(0); byte(0)
            m("fontFields"); byte((if (v.scale != null) 1 else 0) or (if (v.features != null) 2 else 0) or
                (if (v.paint) 4 else 0) or (if (v.effects != null) 8 else 0))
            v.scale?.let { m("scale"); f32(it); m("basis"); byte(v.basis) }
            v.features?.let { m("features"); byte(it) }
            if (v.paint) {
                m("paintPresence"); byte(1)
                listOf("#102030", "#203040", "#304050", "#405060", "#506070", "#607080").forEach(::string)
                byte(0); byte(0) // independent normal underline false; no focus outline
                string("#708090"); string("#8090a0"); byte(3)
                m("paintEnd")
            }
            v.effects?.let { effects ->
                m("effects"); byte(effects)
                if (effects and 1 != 0) {
                    m("decorationStyle"); byte(1)
                    m("colorPresence"); byte(1); m("color"); string("#abcdef")
                    m("thicknessPresence"); byte(1); m("thicknessUnit"); byte(1); m("thickness"); f32(.125f)
                }
                if (effects and 2 != 0) {
                    m("heightTag"); byte(if (v.relative) 1 else 0); m("height"); f32(v.height)
                    if (!v.relative) { m("heightBasis"); byte(v.heightBasis) }
                    else {
                        m("snapshotFlags"); byte(v.snapshotFlags)
                        if (v.snapshotFlags and 1 != 0) {
                            m("snapshotScale"); f32(v.snapshotScale); m("snapshotBasis"); byte(v.snapshotBasis)
                        }
                        m("face"); byte(v.face)
                        m("snapshotLanguage"); string(v.snapshotLanguage)
                        m("snapshotClasses"); string(v.snapshotClasses)
                        m("snapshotRole"); byte(v.snapshotRole)
                        if (v.face and 8 != 0) { m("snapshotFeatures"); byte(v.snapshotFeatures) }
                        m("snapshotEnd")
                    }
                }
                if (effects and 4 != 0) { m("baseline"); f32(-.125f); m("baselineBasis"); byte(1) }
                if (effects and 16 != 0) { m("cursor"); byte(v.cursor) }
                m("effectsEnd")
            }
            m("image"); byte(if (v.image) 1 else 0)
            if (v.image) { hasImage = true; string("Controlled.svg"); byte(3); u32(44); u32(40) }
            m("fragmentPresence"); byte(if (v.fragment == null) 0 else 1); v.fragment?.let(::string)
            byte(if (v.tooltip == null) 0 else 1); v.tooltip?.let(::string)
            m("spanEnd")
        }
        fun spans(present: Boolean) { u32(if (present) 1 else 0); if (present) span() }
        fun blockHeader(kind: Int, text: Boolean = false) {
            byte(kind); byte(0); byte(0); spans(text); byte(0); string(""); string("")
        }
        fun blockTail() { string(""); string(""); repeat(4) { byte(0) } }
        fun paragraph() { blockHeader(0, true); byte(0); blockTail() }
        fun rule(styled: Boolean) {
            blockHeader(11); byte(0); blockTail(); mark("rulePresence")
            if (version >= 'N') {
                byte(if (styled) 1 else 0)
                if (styled) { length(.5f); byte(0); repeat(4) { length(0f) } }
            }
        }
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
        fun figure(owner: Owner) {
            byte(2); byte(0); byte(0); byte(0) // existing missing-media Figure, not a new image encoding
            repeat(12) { length(0f) }; f32(1f); length(1.2f, 1)
            byte(1); byte(0); byte(1); byte(0); byte(0); byte(1)
            val label = if (owner == Owner.Missing) value else Spec(effects = null, text = "Missing", target = "Target",
                trail = "", flags = 0, role = 0, scale = null, features = null, language = "", classes = "",
                direction = "", paint = false, fragment = null, tooltip = null)
            span(label, if (owner == Owner.Missing) "" else "missing-"); length(20f); length(1f, 1); byte(0)
            spans(owner == Owner.FigureCaption)
            if (owner == Owner.FigureRichCaption) { byte(1); u32(1); paragraph() } else byte(0)
            byte(0); byte(0)
        }
        fun body(owner: Owner) {
            when (owner) {
                Owner.Paragraph, Owner.ReferenceBlocks -> paragraph()
                Owner.Container -> { blockHeader(13); byte(0); blockTail(); u32(0); u32(1); paragraph() }
                Owner.Scope -> {
                    blockHeader(0); byte(0); string(""); string(""); byte(0); byte(0); byte(0)
                    byte(1); u32(1); byte(2); byte(0); byte(1); byte(0); byte(1); string("th")
                    u32(1); byte(0); spans(true)
                }
                Owner.Missing, Owner.FigureCaption, Owner.FigureRichCaption -> {
                    blockHeader(0); byte(0); string(""); string(""); byte(0); byte(0); figure(owner); byte(0)
                }
                else -> { blockHeader(12); table(owner); blockTail() }
            }
        }
        fun document(owner: Owner = Owner.Display, display: List<Spec>? = null, rule: Boolean? = null): ByteArray {
            out.write("DPR$version".encodeToByteArray())
            if (display == null) spans(owner == Owner.Display)
            else { u32(display.size); display.forEachIndexed { i, spec -> span(spec, "$i-") } }
            val section = rule != null || owner !in listOf(Owner.Display, Owner.Preamble, Owner.Reference, Owner.ReferenceBlocks)
            u32(if (section) 1 else 0)
            if (section) {
                byte(2); string("Body"); string(""); string(""); u32(1)
                if (rule != null) this.rule(rule) else body(owner)
            }
            spans(owner == Owner.Preamble); u32(0); u32(0)
            val reference = owner in listOf(Owner.Reference, Owner.ReferenceBlocks)
            u32(if (reference) 1 else 0)
            if (reference) {
                byte(1); u32(1); string(""); spans(owner == Owner.Reference)
                byte(if (owner == Owner.ReferenceBlocks) 1 else 0)
                if (owner == Owner.ReferenceBlocks) { u32(1); paragraph() }
            }
            u32(if (hasImage) 1 else 0)
            if (hasImage) { string("Controlled.svg"); byte(0); string("catalog") }
            return out.toByteArray()
        }
    }
    private fun read(bytes: ByteArray) = BlobDecoder.decode(bytes, "inline", "language", "Thai", "th")
    private fun rejects(label: String, bytes: ByteArray) = assertTrue(label, runCatching { read(bytes) }.isFailure)
    private fun byteAt(bytes: ByteArray, index: Int, value: Int) = bytes.copyOf().also { it[index] = value.toByte() }
    private fun floatAt(bytes: ByteArray, index: Int, value: Float) = bytes.copyOf().also {
        val bits = value.toRawBits(); repeat(4) { n -> it[index + n] = (bits ushr (n * 8)).toByte() }
    }
    private fun hex(value: String) = value.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
    private fun sourceSpans(entry: Entry): List<Span> = buildList {
        addAll(entry.displayTitle); addAll(entry.preamble)
        fun blocks(values: List<Block>) { values.forEach { block -> block.visitSpanRuns { spans, _ -> addAll(spans) } } }
        entry.sections.forEach { blocks(it.blocks) }
        entry.references.forEach { reference -> addAll(reference.spans); reference.blocks?.let(::blocks) }
    }

    @Test fun oReadsAllEffectsAfterEightStatePaintAndBeforeLegacyImageAndActionTails() {
        val wire = Wire(); val bytes = wire.document(display = listOf(Spec(), plain("").copy(image = true)))
        val decoded = read(bytes).displayTitle
        val span = decoded.first(); val style = span.inlineStyle!!
        assertEquals(InlineUnderline(InlineUnderlineStyle.Dotted, "#abcdef", StyleLength(StyleLengthUnit.Em, .125f)), style.decoration)
        val relative = style.lineHeight as InlineLineHeight.FontRelative
        assertEquals(1f, relative.factor, 0f)
        assertEquals(InlineFontSnapshot(.75f, FontScaleBasis.NormalBody, true, true, true, true,
            true, true, true, "ja", "Jpan", "reference", FontFeaturePolicy.SevenOn), relative.font)
        assertEquals(InlineComputedLength(-.125f, FontScaleBasis.NormalBody), style.baselineShift)
        assertTrue(style.fontNormalized)
        assertEquals("#708090", span.linkPaint!!.hoverActive.foreground)
        assertEquals("#8090a0", span.linkPaint!!.visitedHoverActive.foreground)
        assertFalse(span.linkPaint!!.normal.underline); assertTrue(span.linkPaint!!.hoverActive.underline)
        assertEquals(EntryLink("Target", "part"), span.entryLink()); assertEquals("source advice", span.tooltip)
        assertEquals("!", span.trail); assertNull(span.image)
        assertEquals("Controlled.svg", decoded.last().image!!.file); assertNull(decoded.last().inlineStyle)
        assertEquals(wire.at.getValue("0-paintEnd"), wire.at.getValue("0-effects"))
        assertEquals(wire.at.getValue("0-effectsEnd"), wire.at.getValue("0-image"))
    }

    @Test fun emptyMetricOwnersKeepEveryOccurrenceAndBodyActionOffset() {
        val first = plain("").copy(effects = 2, flags = 16, language = "th", classes = "first",
            snapshotFlags = 4, face = 0, snapshotLanguage = "", snapshotClasses = "", snapshotRole = 0)
        val second = plain("").copy(effects = 2, flags = 10, scale = .5f, relative = false, height = 0f,
            role = 1, heightBasis = 2)
        val action = plain("B").copy(kind = 1, target = "Target", fragment = "part")
        val spans = read(Wire().document(display = listOf(plain("A"), first, second, action))).displayTitle
        assertEquals(listOf("A", "", "", "B"), spans.map { it.text })
        assertEquals("AB", textOf(spans)); assertEquals(2, spans.nativeLogicalLength())
        assertEquals(listOf(0, 1, 1, 1, 2), spans.runningFold(0) { n, span -> n + listOf(span).nativeLogicalLength() })
        assertTrue(spans[1].superscript); assertEquals("th", spans[1].language); assertEquals("first", spans[1].classes)
        assertTrue(spans[2].small && spans[2].italic); assertEquals(.5f, spans[2].fontScale!!, 0f)
        assertEquals("label", spans[2].role)
        assertNotEquals(spans[1].inlineStyle, spans[2].inlineStyle)
        assertEquals(EntryLink("Target", "part"), spans.last().entryLink())
    }

    @Test fun oInlinePolicySurvivesEveryRecursiveSpanSinkWithoutChangingItsAction() {
        for (owner in Owner.entries) {
            val entry = read(Wire(Spec(paint = false, trail = if (owner == Owner.Missing) "" else "!")).document(owner))
            val actual = sourceSpans(entry).filter { it.inlineStyle != null }
            assertEquals(owner.name, 1, actual.size)
            assertEquals("X", actual.single().text)
            assertEquals(EntryLink("Target", "part"), actual.single().entryLink())
            assertEquals("source advice", actual.single().tooltip)
            assertEquals("reference", (actual.single().inlineStyle!!.lineHeight as InlineLineHeight.FontRelative).font.role)
            assertEquals(InlineFontSnapshot(.75f, FontScaleBasis.NormalBody, true, true, true, true,
                true, true, true, "ja", "Jpan", "reference", FontFeaturePolicy.SevenOn),
                (actual.single().inlineStyle!!.lineHeight as InlineLineHeight.FontRelative).font)
            assertEquals("ja", actual.single().language)
            assertEquals("Jpan", actual.single().classes)
            assertEquals("rtl", actual.single().direction)
            assertEquals(if (owner == Owner.Missing) "" else "!", actual.single().trail)
            assertEquals("th", entry.languageCode)
            assertEquals("", entry.edition) // Dictionary ownership is attached by LibraryStore, not the payload.
        }
    }

    @Test fun nullPolicyHasLiteralLegacyBytesAndOIncludesBothStyledAndNullNRuleTails() {
        // One plain Z span: seven strings, two color presences, font fields, image and two action tails.
        val goldenM = hex("4450524d01000000000000010000005a" + "00000000".repeat(6) +
            "000000000000" + "00000000".repeat(6))
        assertArrayEquals(goldenM, Wire(plain(), 'M').document())
        for (version in listOf('M', 'N', 'O')) {
            val bytes = goldenM.copyOf().also { it[3] = version.code.toByte() }
            assertEquals(listOf(Span("text", "Z")), read(bytes).displayTitle)
        }
        for (styled in listOf(false, true)) {
            val n = Wire(plain(), 'N').document(rule = styled)
            val o = Wire(plain(), 'O').document(rule = styled)
            assertArrayEquals(n.copyOf().also { it[3] = 'O'.code.toByte() }, o)
            assertEquals(read(n).sections.single().blocks.single().ruleStyle, read(o).sections.single().blocks.single().ruleStyle)
            assertEquals(styled, read(o).sections.single().blocks.single().ruleStyle != null)
        }
        val wire = Wire(plain(), 'O'); val bytes = wire.document(rule = false)
        val position = wire.at.getValue("rulePresence")
        rejects("O missing N null Rule presence", bytes.copyOfRange(0, position) + bytes.copyOfRange(position + 1, bytes.size))
        rejects("O invalid Rule presence", byteAt(bytes, position, 2))
        val mixed = read(Wire().document(rule = true))
        assertNotNull(mixed.displayTitle.single().inlineStyle)
        assertEquals(.5f, mixed.sections.single().blocks.single().ruleStyle!!.height.value, 0f)
    }

    @Test fun zeroComputedHeightAndDefaultSnapshotHaveStrictMandatoryTails() {
        for (basis in listOf(1, 2)) {
            val spec = plain("x").copy(effects = 6, relative = false, height = 0f, heightBasis = basis)
            val decoded = read(Wire(spec).document()).displayTitle.single().inlineStyle!!
            val height = decoded.lineHeight as InlineLineHeight.Computed
            assertEquals(0f, height.value.value, 0f)
            assertEquals(FontScaleBasis.entries[basis], height.value.fontScaleBasis)
            assertEquals(-.125f, decoded.baselineShift!!.value, 0f)
        }
        val spec = plain("x").copy(effects = 2, snapshotFlags = 0, face = 0,
            snapshotLanguage = "", snapshotClasses = "", snapshotRole = 0)
        val wire = Wire(spec); val bytes = wire.document()
        assertEquals(InlineFontSnapshot(), (read(bytes).displayTitle.single().inlineStyle!!.lineHeight as InlineLineHeight.FontRelative).font)
        assertEquals(11, wire.at.getValue("snapshotEnd") - wire.at.getValue("snapshotFlags"))
        for (end in wire.at.getValue("snapshotFlags") until wire.at.getValue("snapshotEnd"))
            rejects("snapshot truncated at $end", bytes.copyOf(end))
        rejects("flags-only snapshot cannot omit mandatory face, strings and role",
            bytes.copyOfRange(0, wire.at.getValue("snapshotFlags") + 1) +
                bytes.copyOfRange(wire.at.getValue("snapshotEnd"), bytes.size))
    }

    @Test fun snapshotAndRunCanonicalizeContextOneTogetherWhileBodyOneAndOtherScalesRemainExplicit() {
        val spec = plain("x").copy(effects = 6, scale = 1f, basis = 0, snapshotFlags = 1,
            snapshotScale = 1f, snapshotBasis = 0, face = 0, snapshotLanguage = "", snapshotClasses = "", snapshotRole = 0)
        val span = read(Wire(spec).document()).displayTitle.single()
        assertNull(span.fontScale)
        assertNull((span.inlineStyle!!.lineHeight as InlineLineHeight.FontRelative).font.fontScale)
        assertEquals(span, read(Wire(spec.copy(scale = null)).document()).displayTitle.single())
        assertEquals(span, read(Wire(spec.copy(snapshotFlags = 0)).document()).displayTitle.single())
        assertEquals(span, read(Wire(spec.copy(scale = null, snapshotFlags = 0)).document()).displayTitle.single())
        for (basis in listOf(1, 2)) {
            val explicit = read(Wire(spec.copy(basis = basis, snapshotBasis = basis)).document()).displayTitle.single()
            assertEquals(FontScaleBasis.entries[basis], explicit.fontScaleBasis)
            assertEquals(1f, explicit.fontScale!!, 0f)
            assertEquals(1f, (explicit.inlineStyle!!.lineHeight as InlineLineHeight.FontRelative).font.fontScale!!, 0f)
        }
        rejects("context two vs absent run", Wire(spec.copy(scale = null, snapshotScale = 2f)).document())
        rejects("absent snapshot vs context two", Wire(spec.copy(scale = 2f, snapshotFlags = 0)).document())
        assertNotNull(read(Wire(spec.copy(effects = 2, scale = null)).document()).displayTitle.single().inlineStyle)
        assertNull(read(Wire(plain("x").copy(scale = 1f, basis = 0)).document()).displayTitle.single().fontScale)
        assertEquals(0f, read(Wire(spec.copy(scale = 0f, snapshotScale = -0f)).document()).displayTitle.single().fontScale!!, 0f)
    }

    @Test fun payloadFlagsTagsPresenceNumbersStringsAndSpanOwnershipAreStrict() {
        val wire = Wire(); val bytes = wire.document()
        val mutations = mapOf("fontFields" to listOf(16, 128), "effects" to listOf(0, 32, 255),
            "decorationStyle" to listOf(2), "colorPresence" to listOf(2), "thicknessPresence" to listOf(2),
            "thicknessUnit" to listOf(2), "heightTag" to listOf(2), "snapshotFlags" to listOf(63, 159),
            "face" to listOf(31, 143), "snapshotBasis" to listOf(3), "snapshotRole" to listOf(8),
            "snapshotFeatures" to listOf(2), "baselineBasis" to listOf(0, 3), "kind" to listOf(3, 4))
        for ((field, values) in mutations) for (value in values)
            rejects("$field=$value", byteAt(bytes, wire.at.getValue(field), value))
        for (field in listOf("height", "thickness", "snapshotScale"))
            for (bad in listOf(-.01f, Float.NaN, Float.POSITIVE_INFINITY, Float.NEGATIVE_INFINITY))
                rejects("$field=$bad", floatAt(bytes, wire.at.getValue(field), bad))
        for (bad in listOf(Float.NaN, Float.POSITIVE_INFINITY, Float.NEGATIVE_INFINITY))
            rejects("baseline=$bad", floatAt(bytes, wire.at.getValue("baseline"), bad))
        rejects("noncanonical RGB", byteAt(bytes, wire.at.getValue("color") + 5, 'A'.code))
        rejects("NUL snapshot language", byteAt(bytes, wire.at.getValue("snapshotLanguage") + 4, 0))
        rejects("NUL snapshot classes", byteAt(bytes, wire.at.getValue("snapshotClasses") + 4, 0))
        rejects("invalid UTF-8 snapshot", byteAt(bytes, wire.at.getValue("snapshotLanguage") + 4, 255))
        rejects("different face under explicit shift", byteAt(bytes, wire.at.getValue("face"), 14))
        rejects("inline image owner", Wire(Spec(effects = 2, kind = 0, text = "", target = "",
            trail = "", paint = false, image = true, fragment = null)).document())
        rejects("empty link", Wire(Spec(text = "")).document())
        rejects("missing action", Wire(Spec(target = "", paint = false)).document())
        rejects("text action", Wire(Spec(kind = 0, paint = false, fragment = null)).document())
        rejects("line break effects", Wire(plain("").copy(kind = 3, effects = 2)).document())
        rejects("empty decoration-only owner", Wire(plain("").copy(effects = 1)).document())
        rejects("normalized context owner", Wire(plain("x").copy(effects = 8, scale = 1f, basis = 0)).document())
        val computed = Wire(plain("x").copy(effects = 2, relative = false)); val fixed = computed.document()
        for (basis in listOf(0, 3)) rejects("computed basis$basis", byteAt(fixed, computed.at.getValue("heightBasis"), basis))
        rejects("negative computed height", floatAt(fixed, computed.at.getValue("height"), -1f))
    }

    @Test fun foreignHeadersAndEveryTruncatedCompletePayloadRefuseWithoutLosingLegacyCapability() {
        val wire = Wire(); val bytes = wire.document()
        for (version in listOf('M', 'N', 'P')) rejects("header $version", byteAt(bytes, 3, version.code))
        for (end in 0 until bytes.size) rejects("prefix $end", bytes.copyOf(end))
        rejects("trailing payload", bytes + byteArrayOf(0))
        val start = wire.at.getValue("effects"); val end = wire.at.getValue("effectsEnd")
        val beforePaint = wire.at.getValue("paintPresence")
        val moved = bytes.copyOfRange(0, beforePaint) + bytes.copyOfRange(start, end) +
            bytes.copyOfRange(beforePaint, start) + bytes.copyOfRange(end, bytes.size)
        rejects("inline effects before mandatory paint", moved)
        assertNotNull(read(bytes).displayTitle.single().linkPaint)
    }

    @Test fun helpCursorIsAnIndependentStrictTailAfterBaselineAndBeforeImage() {
        val beforeWire = Wire(); val before = beforeWire.document()
        val wire = Wire(Spec(effects = 31)); val bytes = wire.document()
        val flag = beforeWire.at.getValue("effects"); val insertion = beforeWire.at.getValue("effectsEnd")
        val withFlag = byteAt(before, flag, 31)
        assertArrayEquals(withFlag.copyOfRange(0, insertion) + byteArrayOf(0) +
            withFlag.copyOfRange(insertion, withFlag.size), bytes)
        assertEquals(wire.at.getValue("baselineBasis") + 1, wire.at.getValue("cursor"))
        assertEquals(wire.at.getValue("cursor") + 1, wire.at.getValue("image"))
        val prior = read(before).displayTitle.single(); val actual = read(bytes).displayTitle.single()
        assertEquals(prior.copy(inlineStyle = prior.inlineStyle!!.copy(cursor = InlineCursor.Help)), actual)
        assertEquals(EntryLink("Target", "part"), actual.entryLink())
        for (owner in Owner.entries) {
            val spec = Spec(effects = 16, paint = false, trail = if (owner == Owner.Missing) "" else "!")
            val occurrence = sourceSpans(read(Wire(spec).document(owner))).single { it.inlineStyle != null }
            assertEquals(owner.name, InlineTextStyle(cursor = InlineCursor.Help), occurrence.inlineStyle)
            assertEquals("X", occurrence.text); assertEquals(EntryLink("Target", "part"), occurrence.entryLink())
            assertNull(occurrence.linkPaint)
        }
        val text = read(Wire(plain("text").copy(effects = 16)).document()).displayTitle.single()
        assertFalse(text.hasInternalAction()); assertEquals("text", text.text)
        assertEquals(InlineCursor.Help, text.inlineStyle!!.cursor)
        val external = read(Wire(plain("external").copy(effects = 16, kind = 2,
            target = "https://example.test/")).document()).displayTitle.single()
        assertEquals("external_link", external.kind); assertEquals("https://example.test/", external.target)
        for (tag in listOf(1, 255)) rejects("unknown cursor $tag", byteAt(bytes, wire.at.getValue("cursor"), tag))
        rejects("missing mandatory cursor byte", bytes.copyOfRange(0, wire.at.getValue("cursor")) +
            bytes.copyOfRange(wire.at.getValue("cursor") + 1, bytes.size))
        assertNull(prior.inlineStyle!!.cursor)
    }

    @Test fun cursorRefusesEmptyMetricOwnersOldHeadersAndUnknownEffectBits() {
        val empty = plain("").copy(effects = 18, relative = false, height = 0f, heightBasis = 2)
        rejects("empty metric owner cannot carry help", Wire(empty).document())
        val metricOnly = read(Wire(empty.copy(effects = 2)).document()).displayTitle.single()
        assertEquals("", metricOnly.text); assertEquals(0, listOf(metricOnly).nativeLogicalLength())
        assertNull(metricOnly.inlineStyle!!.cursor)
        rejects("cursor-only empty owner", Wire(plain("").copy(effects = 16)).document())
        rejects("cursor on line break", Wire(plain("").copy(kind = 3, effects = 16)).document())
        val wire = Wire(plain("help").copy(effects = 16)); val bytes = wire.document()
        for (version in listOf('M', 'N')) rejects("cursor under $version", byteAt(bytes, 3, version.code))
        for (mask in listOf(32, 64, 128))
            rejects("reserved cursor payload bit $mask", byteAt(bytes, wire.at.getValue("effects"), 16 or mask))
        assertEquals(Span("text", "help", inlineStyle = InlineTextStyle(cursor = InlineCursor.Help)), read(bytes).displayTitle.single())
    }
}
