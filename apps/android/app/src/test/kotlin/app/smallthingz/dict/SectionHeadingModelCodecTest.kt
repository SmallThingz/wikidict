package app.smallthingz.dict

import java.io.ByteArrayOutputStream
import org.junit.Assert.*
import org.junit.Test

/** Data-boundary controls only; these do not certify source CSS or installed font availability. */
class SectionHeadingModelCodecTest {
    private val names = listOf("Linux Libertine", "Georgia", "Times", "Source Serif 4")
    private val stack get() = ContainerFontFamily.Stack(names, GenericFontFamily.Serif)
    private fun px(value: Float) = StyleLength(StyleLengthUnit.Px, value)
    private val zero get() = px(0f)
    private val edges get() = StyleEdges(zero, zero, zero, zero)
    private fun box(family: ContainerFontFamily = stack) = ContainerStyle(
        margins = SignedContainerEdges(SignedContainerMargin(StyleLengthUnit.Em, -.25f), px(2.5f), px(.75f), zero),
        padding = StyleEdges(px(.5f), px(.25f), zero, zero), border = ContainerBorder.None,
        ownerFontScale = 1.25f, lineHeight = ContainerLineHeight.Multiplier(1.5f),
        fontFamily = family, clear = FigureClear.None)
    private fun owner(family: ContainerFontFamily = stack) = SectionHeadingStyle(box(family),
        InlineFontSnapshot(1.25f, FontScaleBasis.NormalBody, bold = true, italic = true,
            language = "th", fontFeatures = FontFeaturePolicy.Normal), BidiResolvedDirection.Rtl)
    private fun section(): Section {
        val spans = listOf(Span("link", "Ti", "Target", targetFragment = "part"),
            Span("external_link", "tle", "https://example.test/title", underline = true))
        val heading = Block("heading", 0, spans, level = 3, anchor = "title", anchorFallback = "old_title")
        return Section(3, "Title", listOf(heading, Block("paragraph", 0, listOf(Span("text", "Body")))),
            "title", "old_title")
    }
    private fun rejected(label: String, make: () -> Any?) = assertTrue(label, runCatching(make).isFailure)
    private fun read(bytes: ByteArray) = BlobDecoder.decode(bytes, "Entry", "language", "Thai", "th")
    private fun rejectBytes(label: String, bytes: ByteArray) = rejected(label) { read(bytes) }
    private fun header(bytes: ByteArray, version: Char) = bytes.copyOf().also { it[3] = version.code.toByte() }
    private fun word(bytes: ByteArray, offset: Int, value: Int) = bytes.copyOf().also { result ->
        repeat(4) { result[offset + it] = (value ushr (8 * it)).toByte() }
    }

    @Test fun authoredHeadingRetainsRawCompanionActionsAnchorsAndExplicitOwnerContext() {
        val old = section(); val style = owner(); val actual = old.copy(headingStyle = style)
        assertNull(old.headingStyle); assertEquals(old, actual.copy(headingStyle = null))
        assertSame(old.blocks, actual.blocks); assertSame(old.blocks[0], actual.blocks[0])
        assertSame(old.blocks[1], actual.blocks[1]); assertEquals(old.level, actual.level)
        assertEquals(old.anchor, actual.anchor); assertEquals(old.anchorFallback, actual.anchorFallback)
        assertEquals(EntryLink("Target", "part"), actual.blocks[0].spans[0].entryLink())
        assertEquals("https://example.test/title", actual.blocks[0].spans[1].target)
        assertTrue(actual.blocks[0].spans[1].underline)
        assertEquals(BidiResolvedDirection.Rtl, style.direction)
        assertEquals("", actual.blocks[0].spans[0].direction)
        assertEquals(names, (style.box.fontFamily as ContainerFontFamily.Stack).names)
        assertEquals(-.25f, style.box.margins!!.top.value, 0f)
        val inherited = ContainerTextContext(2f, ContainerLineHeight.Normal, fontFamily = ContainerFontFamily.SansSerif)
        val owned = style.box.textContext(inherited)
        assertEquals(1.25f, owned.ownerFontScale, 0f); assertSame(style.box.fontFamily, owned.fontFamily)
        assertEquals(ContainerLineHeight.Multiplier(1.5f), owned.lineHeight)
        assertSame(owned.fontFamily, ContainerStyle().textContext(owned).fontFamily)
        assertEquals(ContainerFontFamily.SansSerif,
            ContainerStyle(fontFamily = ContainerFontFamily.SansSerif).textContext(owned).fontFamily)
        for (sizing in listOf(null, ContainerBoxSizing.ContentBox, ContainerBoxSizing.BorderBox))
            assertEquals(sizing, style.copy(box = style.box.copy(boxSizing = sizing)).box.boxSizing)
        val zeroOwner = style.copy(box = style.box.copy(ownerFontScale = 0f), font = style.font.copy(fontScale = 0f))
        assertEquals(0f, zeroOwner.font.fontScale!!, 0f)
        for (text in listOf(" ", " \u00a0  ")) {
            val raw = Span("link", text, "WhitespaceTarget", targetFragment = "part")
            val blank = Block("heading", 0, listOf(raw), level = 2)
            val retained = Section(2, text, listOf(blank), headingStyle = style)
            assertEquals(text, retained.title); assertSame(blank, retained.blocks.single())
            assertSame(raw, retained.copy().blocks.single().spans.single())
            assertEquals(EntryLink("WhitespaceTarget", "part"), retained.blocks.single().spans.single().entryLink())
        }
    }

    @Test fun familyNamesRemainOpaqueOrderedDataWithClosedAliasAndByteBounds() {
        val mixed = listOf("Linux Libertine", "Custom  Family", "Family.2", "Family_Name", "Family-Name")
        assertEquals(mixed, ContainerFontFamily.Stack(mixed, GenericFontFamily.Serif).names)
        assertEquals(emptyList<String>(), ContainerFontFamily.Stack(emptyList(), GenericFontFamily.SansSerif).names)
        assertEquals(16, ContainerFontFamily.Stack(List(16) { "Family $it" }, GenericFontFamily.Serif).names.size)
        assertEquals(128, ContainerFontFamily.Stack(listOf("A".repeat(128)), GenericFontFamily.Serif).names.single().length)
        val aliases = listOf("serif", "sans-serif", "sans serif", "sans", "monospace", "cursive", "fantasy",
            "system", "system-ui", "ui-serif", "ui-sans-serif", "ui-monospace", "ui-rounded", "emoji", "math", "fangsong")
        for (alias in aliases) for (value in listOf(alias, alias.uppercase(), alias.replace(" ", "   ")))
            rejected("Named alias $value") { ContainerFontFamily.Stack(listOf(value), GenericFontFamily.Serif) }
        for (value in listOf("", " Leading", "Trailing ", "A\tB", "A\nB", "A\u0000B", "A\u007fB",
            "\u00e9", "A[Foundry]", "A]", "A".repeat(129)))
            rejected("Closed family $value") { ContainerFontFamily.Stack(listOf(value), GenericFontFamily.Serif) }
        rejected("Too many names") { ContainerFontFamily.Stack(List(17) { "Family $it" }, GenericFontFamily.Serif) }
        assertEquals(names, stack.names) // Validation never rewrites the retained source stack.
    }

    @Test fun headingModelRefusesMissingComputedValuesUnsupportedBoxesFontsAndWrongCompanions() {
        val good = owner(); val b = good.box
        val badBoxes = listOf(b.copy(margins = null), b.copy(padding = null), b.copy(border = null),
            b.copy(ownerFontScale = null), b.copy(lineHeight = null), b.copy(fontFamily = null), b.copy(clear = null),
            b.copy(width = ContainerWidth.FitContent), b.copy(maxWidth = ContainerMaxWidth.Length(StyleWidth(StyleWidthUnit.Px, 10f))),
            b.copy(layout = ContainerLayout.FlexRow), b.copy(overflow = ContainerOverflow.Auto),
            b.copy(floatSide = TableFloatSide.Left), b.copy(flexItem = ContainerFlexItem.None),
            b.copy(layout = ContainerLayout.FlexRow, alignItems = ContainerAlignItems.Center),
            b.copy(columns = ContainerColumns(2, zero)), b.copy(positioning = ContainerPositioning.RelativeAuto),
            b.copy(screenMaxWidth = ContainerScreenMaxWidth(639, width = ContainerWidth.Auto)),
            b.copy(height = zero), b.copy(minHeight = zero), b.copy(margins = null,
                marginValues = ContainerMargins(ContainerMargin.Length(zero), ContainerMargin.Length(zero),
                    ContainerMargin.Length(zero), ContainerMargin.Length(zero))))
        badBoxes.forEachIndexed { index, value -> rejected("Box $index") { good.copy(box = value) } }
        val f = good.font
        val badFonts = listOf(f.copy(fontScale = null, fontScaleBasis = FontScaleBasis.Context),
            f.copy(fontScaleBasis = FontScaleBasis.Context), f.copy(fontScaleBasis = FontScaleBasis.CssPx),
            f.copy(fontScale = 1f), f.copy(language = ""), f.copy(language = "x".repeat(1025)),
            f.copy(language = "\u00e9".repeat(513)), f.copy(role = "label"), f.copy(classes = "source"),
            f.copy(small = true), f.copy(superscript = true), f.copy(subscript = true),
            f.copy(fontNormalized = true), f.copy(code = true))
        badFonts.forEachIndexed { index, value -> rejected("Font $index") { good.copy(font = value) } }
        assertEquals("\u00e9".repeat(512), good.copy(font = f.copy(language = "\u00e9".repeat(512))).font.language)
        assertEquals("zh-cmn", good.copy(font = f.copy(language = "zh-cmn")).font.language)
        rejected("Ill-formed UTF16") { good.copy(font = f.copy(language = "\ud800")) }
        rejected("Embedded NUL") { good.copy(font = f.copy(language = "th\u0000x")) }
        val s = section(); val h = s.blocks.first()
        val bad = listOf(h.copy(kind = "paragraph"), h.copy(depth = 1), h.copy(level = h.level + 1),
            h.copy(anchor = "wrong"), h.copy(anchorFallback = "wrong"), h.copy(listPath = "*"), h.copy(number = "1"),
            h.copy(feature = Feature("x", "", "", "", "")), h.copy(table = Table(emptyList(), emptyList())),
            h.copy(textAlign = CellTextAlign.Center), h.copy(spans = emptyList()),
            h.copy(spans = listOf(Span("line_break", "Title"))), h.copy(spans = listOf(Span("template", "Title"))),
            h.copy(spans = listOf(Span("text", "Title", direction = "ltr"))),
            h.copy(spans = listOf(Span("text", "Title", direction = "rtl"))),
            h.copy(spans = listOf(Span("text", "Title", direction = "auto"))),
            h.copy(spans = listOf(Span("text", "Title", trail = "!"))), h.copy(spans = listOf(Span("text", "Other"))),
            h.copy(spans = h.spans + Span("text", "", inlineStyle = InlineTextStyle(
                lineHeight = InlineLineHeight.Computed(InlineComputedLength(1f, FontScaleBasis.NormalBody))))))
        bad.forEachIndexed { index, value -> rejected("Companion $index") { s.copy(blocks = listOf(value), headingStyle = good) } }
        rejected("Absent companion") { s.copy(blocks = emptyList(), headingStyle = good) }
        rejected("Later companion cannot substitute") { s.copy(blocks = s.blocks.reversed(), headingStyle = good) }
        assertNull(s.copy(blocks = emptyList()).headingStyle) // Null does not acquire new validation.
    }

    private enum class Sink { NestedBody, TableCell, TableCaption, FigureCaption, ScopeFigureCaption, Reference,
        FigureWrapper, FigureBefore, ViewportWrapper, ViewportBefore }
    private data class FamilyWire(val tag: Int = 1, val names: List<String> = listOf("Linux Libertine", "Georgia", "Times", "Source Serif 4"),
        val fallback: Int = 1)
    private class Wire(private val omitFamily: Boolean = false) {
        private val out = ByteArrayOutputStream()
        val familyTags = mutableListOf<Int>()
        val familyCounts = mutableListOf<Int>()
        val familyFallbacks = mutableListOf<Int>()
        val indices = mutableListOf<Int>()
        val directions = mutableListOf<Int>()
        val snapshotScales = mutableListOf<Int>()
        var tail = -1
            private set
        fun byte(value: Int) { out.write(value) }
        fun u16(value: Int) { byte(value); byte(value ushr 8) }
        fun u32(value: Int) { repeat(4) { byte(value ushr (8 * it)) } }
        fun f32(value: Float) = u32(value.toRawBits())
        fun string(value: String) { val bytes = value.encodeToByteArray(); u32(bytes.size); out.write(bytes) }
        fun length(value: Float, unit: Int = 0) { byte(unit); f32(value) }
        fun span(text: String, target: String = "", kind: Int = if (target.isEmpty()) 0 else 1,
            fragment: String? = null, trail: String = "") {
            byte(kind); byte(0); byte(0)
            string(text); string(target); string(trail); string("th"); string(""); string(""); string("")
            repeat(4) { byte(0) } // foreground, background, font flags and image
            byte(if (fragment == null) 0 else 1); fragment?.let(::string); byte(0)
        }
        fun family(value: FamilyWire) {
            familyTags += out.size(); byte(value.tag)
            if (value.tag == 1) {
                familyCounts += out.size(); u32(value.names.size); value.names.forEach(::string)
                familyFallbacks += out.size(); byte(value.fallback)
            }
        }
        fun familyStyle(value: FamilyWire?) {
            val retained = value.takeUnless { omitFamily }
            u32(if (retained == null) 0 else 1 shl 22); retained?.let(::family)
        }
        fun block(kind: Int, level: Int = 0, anchor: String = "", fallback: String = "",
            text: (() -> Unit)? = null, table: (() -> Unit)? = null, figure: (() -> Unit)? = null,
            flow: (() -> Unit)? = null, align: Int? = null) {
            byte(kind); byte(0); byte(level); if (text == null) u32(0) else text()
            byte(0); string(""); string(""); if (table == null) byte(0) else table()
            string(anchor); string(fallback); byte(if (align == null) 0 else 1); align?.let(::byte)
            byte(0); if (figure == null) byte(0) else figure()
            byte(if (flow == null) 0 else 1); flow?.invoke()
        }
        fun paragraph() = block(0, text = { u32(1); span("Body action", "Body", fragment = "part") })
        fun container(value: FamilyWire?, nested: Boolean = false) {
            block(13); familyStyle(if (nested) null else value); u32(1)
            if (nested) container(value) else paragraph()
        }
        fun table(value: FamilyWire, caption: Boolean) {
            byte(1); byte(0); u32(0) // present, geometry absent, flat caption empty
            u32(if (caption) 0 else 1)
            if (!caption) {
                u32(1); byte(0); u16(1); u16(1); byte(0); u32(0); byte(0)
                byte(1); u32(1); container(value); byte(0)
            }
            byte(0); byte(if (caption) 1 else 0)
            if (caption) { u32(1); container(value) }
        }
        fun media() {
            f32(1f); byte(0); string("th"); byte(0); byte(0); repeat(4) { byte(0) }
        }
        fun before(value: FamilyWire?) {
            val retained = value.takeUnless { omitFamily }
            u32(4 or 8 or 131072 or (if (retained == null) 0 else (1 shl 22)))
            byte(1); byte(0); f32(4f); byte(0); length(3f); retained?.let(::family)
        }
        fun figure(value: FamilyWire, sink: Sink) {
            val layout = sink in listOf(Sink.FigureWrapper, Sink.FigureBefore, Sink.ViewportWrapper, Sink.ViewportBefore)
            byte(if (layout) 6 else 2); byte(1); byte(0); byte(0)
            repeat(12) { length(0f) }; f32(1f); length(1f); repeat(6) { byte(0) }
            span("Missing label"); length(2f); length(1f); byte(0)
            u32(0); byte(if (layout) 0 else 1)
            if (!layout) { u32(1); container(value) }
            byte(0); byte(0)
            if (layout) {
                byte(1); familyStyle(value.takeIf { sink == Sink.FigureWrapper }); repeat(8) { byte(0) }; media()
                byte(if (sink == Sink.FigureBefore) 1 else 0); if (sink == Sink.FigureBefore) before(value)
                u32(1); u32(639); familyStyle(value.takeIf { sink == Sink.ViewportWrapper }); media()
                byte(if (sink == Sink.ViewportBefore) 1 else 0); if (sink == Sink.ViewportBefore) before(value)
                byte(0); byte(0)
            }
        }
        fun heading(value: FamilyWire) {
            u32(1 or 2 or 16 or 2048 or 4096 or 65536 or (1 shl 22))
            length(-.25f, 1); length(2.5f); length(.75f); length(0f)
            length(.5f); length(.25f); length(0f); length(0f)
            byte(0); byte(0); byte(1); f32(1.5f); f32(1.25f); family(value)
            byte(1); snapshotScales += out.size(); f32(1.25f); byte(1); byte(11)
            string("th"); string(""); byte(0); byte(0)
            directions += out.size(); byte(1)
        }
        fun document(features: Int? = null, sink: Sink? = null, family: FamilyWire = FamilyWire(),
            headingIndices: List<Int> = if (features != null && features and 2 != 0) listOf(0) else emptyList(),
            companionText: String = "Title", companionTrail: String = "", companionAlign: Int? = null): ByteArray {
            out.write((if (features == null) "DPRO" else "DPRP").encodeToByteArray())
            u32(1); span("Display"); u32(2)
            repeat(2) { index ->
                val title = if (index == 0) "Title" else "Other"
                byte(3); string(title); string("heading$index"); string("fallback$index")
                val bodySink = sink != null && sink != Sink.Reference && index == 0
                u32(if (bodySink) 2 else 1)
                block(9, 3, "heading$index", "fallback$index", text = {
                    u32(1); span(if (index == 0) companionText else title, "Target$index", fragment = "part",
                        trail = if (index == 0) companionTrail else "")
                }, align = if (index == 0) companionAlign else null)
                if (bodySink) when (sink) {
                    Sink.NestedBody -> container(family, nested = true)
                    Sink.TableCell, Sink.TableCaption -> block(12, table = { table(family, sink == Sink.TableCaption) })
                    Sink.ScopeFigureCaption -> block(0, flow = {
                        u32(1); byte(2); byte(0); byte(1); byte(0); byte(0)
                        u32(1); byte(1); figure(family, Sink.FigureCaption)
                    })
                    else -> block(0, figure = { figure(family, checkNotNull(sink)) })
                }
            }
            u32(1); span("Preamble"); u32(0); u32(0)
            u32(1); byte(1); u32(7); string("notes")
            u32(if (sink == Sink.Reference) 0 else 1)
            if (sink != Sink.Reference) span("Reference", "https://example.test/reference", kind = 2)
            byte(if (sink == Sink.Reference) 1 else 0)
            if (sink == Sink.Reference) { u32(1); container(family) }
            u32(1); string("Sound.ogg"); byte(1); string("Media")
            if (features != null) {
                tail = out.size(); byte(features)
                if (features and 2 != 0) {
                    u32(headingIndices.size)
                    for (index in headingIndices) { indices += out.size(); u32(index); heading(family) }
                }
            }
            return out.toByteArray()
        }
    }

    @Test fun everyNonzeroFeatureUnionDecodesActualPresenceAndBodyOnlyRetainsExactOPrefix() {
        val oldBytes = Wire().document(); val old = read(oldBytes)
        val bodyBytes = Wire().document(1)
        assertArrayEquals(header(oldBytes, 'P') + byteArrayOf(1), bodyBytes)
        assertEquals(old.copy(bodyAdjoining = BodyAdjoiningPolicy.Ordinary), read(bodyBytes))
        for (flags in 1..7) {
            val family = if (flags and 4 != 0) FamilyWire() else FamilyWire(tag = 0)
            val sink = if (flags and 4 != 0 && flags and 2 == 0) Sink.NestedBody else null
            val wire = Wire(); val bytes = wire.document(flags, sink, family); val frozen = bytes.copyOf()
            val actual = read(bytes)
            assertEquals(if (flags and 1 != 0) BodyAdjoiningPolicy.Ordinary else null, actual.bodyAdjoining)
            assertEquals(flags and 2 != 0, actual.sections[0].headingStyle != null)
            assertNull(actual.sections[1].headingStyle)
            assertEquals(old.references, actual.references); assertEquals(old.media, actual.media)
            assertEquals(old.displayTitle, actual.displayTitle); assertEquals(old.preamble, actual.preamble)
            assertEquals(old.sections[0].blocks[0], actual.sections[0].blocks[0])
            assertEquals(EntryLink("Target0", "part"), actual.sections[0].blocks[0].spans.single().entryLink())
            actual.sections[0].headingStyle?.let {
                assertEquals(owner(if (flags and 4 != 0) stack else ContainerFontFamily.SansSerif), it)
            }
            assertArrayEquals(frozen, bytes)
        }
        val both = read(Wire().document(6, headingIndices = listOf(0, 1)))
        assertTrue(both.sections.all { it.headingStyle != null })
        assertEquals(listOf("heading0", "heading1"), both.sections.map { it.anchor })
    }

    @Test fun trailerRejectsUnknownMissingOrOrphanFeaturesAndNoncanonicalHeadingIndices() {
        val wire = Wire(); val bytes = wire.document(7)
        for (value in listOf(0, 8, 128, 255)) rejectBytes("Feature $value", bytes.copyOf().also { it[wire.tail] = value.toByte() })
        rejectBytes("Missing features", bytes.copyOf(wire.tail))
        rejectBytes("Missing indexed payload", bytes.copyOf(wire.tail + 1))
        rejectBytes("Heading payload without bit", bytes.copyOf().also { it[wire.tail] = 5 })
        rejectBytes("Stack omitted from union", bytes.copyOf().also { it[wire.tail] = 3 })
        rejectBytes("Unused stack feature", Wire().document(5))
        rejectBytes("Empty heading list", Wire().document(2, family = FamilyWire(tag = 0), headingIndices = emptyList()))
        for (indices in listOf(listOf(0, 0), listOf(1, 0), listOf(2), listOf(-1)))
            rejectBytes("Indices $indices", Wire().document(6, headingIndices = indices))
        rejectBytes("Unknown direction", bytes.copyOf().also { it[wire.directions.single()] = 2 })
        rejectBytes("Mismatched owner scale", word(bytes, wire.snapshotScales.single(), 1f.toRawBits()))
        rejectBytes("Trailing byte", bytes + byteArrayOf(0))
        for (version in "MNOQ") rejectBytes("Heading-bearing $version", header(bytes, version))
        for (size in wire.tail until bytes.size) rejectBytes("Truncated heading tail $size", bytes.copyOf(size))
        for (bad in listOf(Wire().document(6, companionText = "Wrong"), Wire().document(6, companionTrail = "!"),
            Wire().document(6, companionAlign = 1), Wire().document(6, companionText = "")))
            rejectBytes("Malformed companion", bad)
        assertNull(read(Wire().document(companionText = "Wrong", companionAlign = 1)).sections[0].headingStyle)
    }

    @Test fun stackCapabilityIsExactAcrossNestedBodyCellCaptionScopeAndReferenceContainers() {
        val accepted = listOf(Sink.NestedBody, Sink.TableCell, Sink.TableCaption, Sink.FigureCaption,
            Sink.ScopeFigureCaption, Sink.Reference)
        for (sink in accepted) {
            val wire = Wire(); val bytes = wire.document(4, sink); val entry = read(bytes)
            assertNull(entry.bodyAdjoining); assertTrue(entry.sections.all { it.headingStyle == null })
            val block = entry.sections[0].blocks.getOrNull(1)
            val container = when (sink) {
                Sink.NestedBody -> block!!.container!!.blocks.single().container!!
                Sink.TableCell -> block!!.table!!.rows.single().single().blocks!!.single().container!!
                Sink.TableCaption -> block!!.table!!.captionBlocks!!.single().container!!
                Sink.FigureCaption -> block!!.figure!!.captionBlocks!!.single().container!!
                Sink.ScopeFigureCaption -> ((block!!.flow!!.single() as FlowPart.Scope).scope.parts.single()
                    as FlowPart.ImageFigure).figure.captionBlocks!!.single().container!!
                Sink.Reference -> entry.references.single().blocks!!.single().container!!
                else -> error("Unexpected sink")
            }
            assertEquals(stack, container.style.fontFamily)
            assertEquals(EntryLink("Body", "part"), container.blocks.single().spans.single().entryLink())
            rejectBytes("Unflagged $sink stack", bytes.copyOf().also { it[wire.tail] = 1 })
            for (version in "MNO") rejectBytes("$version $sink stack", header(bytes.copyOf(wire.tail), version))
            val old = Wire().document(sink = sink, family = FamilyWire(tag = 0))
            for (version in "MNO") {
                val actual = read(header(old, version))
                assertNull(actual.bodyAdjoining); assertTrue(actual.sections.all { it.headingStyle == null })
            }
            rejectBytes("Unused bit at $sink", Wire().document(4, sink, FamilyWire(tag = 0)))
        }
        // The common style decoder sees these fields, but the existing Figure shape validators stay closed.
        for (sink in listOf(Sink.FigureWrapper, Sink.FigureBefore, Sink.ViewportWrapper, Sink.ViewportBefore)) {
            assertEquals(BodyAdjoiningPolicy.Ordinary, read(Wire(omitFamily = true).document(1, sink)).bodyAdjoining)
            rejectBytes("No family widening of $sink", Wire().document(4, sink))
        }
    }

    @Test fun stackWireClosesTagsFallbackCountsNamesAndLegacyVersionWithoutDiscardingValidData() {
        val good = Wire(); val bytes = good.document(6)
        assertEquals(stack, read(bytes).sections[0].headingStyle!!.box.fontFamily)
        rejectBytes("Unknown family tag", bytes.copyOf().also { it[good.familyTags.single()] = 2 })
        rejectBytes("Unknown generic fallback", bytes.copyOf().also { it[good.familyFallbacks.single()] = 2 })
        rejectBytes("Count over native schema bound", word(bytes, good.familyCounts.single(), 17))
        rejectBytes("Unbounded count", word(bytes, good.familyCounts.single(), -1))
        for (invalid in listOf("", " sans", "sans   serif", "SERIF", "Family[Foundry]", "A\tB", "\u00e9", "A".repeat(129)))
            rejectBytes("Invalid wire name $invalid", Wire().document(6, family = FamilyWire(names = listOf(invalid))))
        for (fallback in 0..1) {
            val decoded = read(Wire().document(6, family = FamilyWire(names = emptyList(), fallback = fallback)))
            assertEquals(ContainerFontFamily.Stack(emptyList(), GenericFontFamily.entries[fallback]),
                decoded.sections[0].headingStyle!!.box.fontFamily)
        }
        val noFeatures = "DPRO".encodeToByteArray() + ByteArray(28)
        assertNull(read(noFeatures).bodyAdjoining)
        val future = runCatching { read(header(noFeatures, 'U')) }.exceptionOrNull()
        assertEquals("Unsupported presentation format", future!!.message)
        val malformed = runCatching { read(header(noFeatures, 'P') + byteArrayOf(0)) }.exceptionOrNull()
        assertEquals("Unsupported body adjoining policy", malformed!!.message)
    }
}
