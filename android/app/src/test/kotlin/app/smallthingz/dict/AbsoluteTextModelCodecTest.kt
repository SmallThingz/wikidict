package app.smallthingz.dict

import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import org.junit.Assert.*
import org.junit.Test

/** Literal transport and constructed ownership controls; no EN producer or rendering acceptance. */
class AbsoluteTextModelCodecTest {
    private fun px(value: Float) = StyleLength(StyleLengthUnit.Px, value)
    private val zero get() = StyleEdges(px(0f), px(0f), px(0f), px(0f))
    private fun rejects(body: () -> Any?) = assertTrue(runCatching(body).isFailure)
    private fun decode(bytes: ByteArray) = BlobDecoder.decode(bytes, "Absolute", "citations", null, "en")
    private fun owner() = InlineFontSnapshot(12f, FontScaleBasis.CssPx, language = "en")
    private fun position() = ContainerPositioning.Absolute(px(3f), px(130f), owner(),
        InlineComputedLength(12f, FontScaleBasis.CssPx), TextWrap.NoWrap)
    private fun scope() = PositionedScope(TextWrap.NoWrap, PositionedOverflowX.Scroll, PositionedOverflowY.Auto,
        listOf(PositionedViewportState(900, PositionedOverflowX.Hidden, PositionedOverflowY.Auto)))
    private fun absoluteStyle() = ContainerStyle(width = ContainerWidth.Length(StyleWidth(StyleWidthUnit.Percent, 100f)),
        height = px(0f), positioning = position())
    private fun scopeStyle() = ContainerStyle(margins = SignedContainerEdges(
        SignedContainerMargin(StyleLengthUnit.Em, .3f), px(0f), SignedContainerMargin(StyleLengthUnit.Px, -25f), px(0f)),
        padding = StyleEdges(px(0f), px(0f), px(25f), px(0f)), positioning = ContainerPositioning.RelativeAuto,
        positionedScope = scope())
    private fun box(value: Container) = Block("container", 0, emptyList(), container = value)
    private fun label() = Block("paragraph", 0, listOf(Span("link", "sh\u00eengng\u00e2", "sh\u00eengng\u00e2",
        language = "kix", targetFragment = "Khiamniungan_Naga", foreground = "#000000",
        fontScale = 12f, fontScaleBasis = FontScaleBasis.CssPx)))

    private class Wire {
        val out = ByteArrayOutputStream()
        val marks = linkedMapOf<String, Int>()
        private fun mark(name: String) { marks.putIfAbsent(name, out.size()) }
        fun byte(value: Int) { out.write(value) }
        fun u16(value: Int) { repeat(2) { byte(value ushr (it * 8)) } }
        fun u32(value: Int) { repeat(4) { byte(value ushr (it * 8)) } }
        fun f32(value: Float) = u32(value.toRawBits())
        fun string(value: String) { val encoded = value.encodeToByteArray(); u32(encoded.size); out.write(encoded) }
        fun length(value: Float, unit: Int = 0) { byte(unit); f32(value) }
        fun edges() { repeat(4) { length(0f) } }
        fun span(text: String, wrap: Int? = null, trail: String = "") {
            byte(1); byte(0); byte(0)
            string(text); string(text); string(trail); string("kix"); string(""); string("rtl"); string("")
            byte(1); string("#000000"); byte(0); byte(1 or (if (wrap == null) 0 else 8))
            f32(12f); byte(2)
            if (wrap != null) { byte(32); mark("InlineWrap"); byte(wrap) }
            byte(0); byte(1); string("Khiamniungan_Naga"); byte(0)
        }
        fun header(kind: Int, text: String? = null, wrap: Int? = null, trail: String = "") {
            byte(kind); byte(0); byte(0); u32(if (text == null) 0 else 1)
            if (text != null) span(text, wrap, trail)
            byte(0); string(""); string("")
        }
        fun tail() { string(""); string(""); repeat(4) { byte(0) } }
        fun paragraph(text: String = "Body", wrap: Int? = null, trail: String = " !") {
            header(0, text, wrap, trail); byte(0); tail()
        }
        fun plain(children: List<Wire.() -> Unit>) {
            header(13); byte(0); tail(); u32(0); u32(children.size); children.forEach { it(this) }
        }
        fun scoped(children: List<Wire.() -> Unit>, enabled: Boolean = true, thresholds: List<Int> = listOf(900)) {
            header(13); byte(0); tail(); mark("ScopeFlags")
            u32(0x80003 or (if (enabled) 0x800000 else 0))
            length(.3f, 1); length(0f); length(-25f); length(0f)
            length(0f); length(0f); length(25f); length(0f)
            mark("RelativeTag"); byte(0)
            if (enabled) {
                mark("ScopeTail"); byte(2); mark("ScopeX"); byte(0); mark("ScopeY"); byte(0)
                mark("StateCount"); u32(thresholds.size)
                thresholds.forEach { threshold ->
                    mark("Threshold"); u32(threshold); mark("StateX"); byte(1); mark("StateY"); byte(0)
                }
                mark("ScopeEnd")
            }
            u32(children.size); children.forEach { it(this) }
        }
        fun absolute(index: Int = 0, family: Int? = null, inlineWrap: Int? = null, duplicate: Int? = null) {
            val names = listOf("sh\u00eengng\u00e2", "\u014dts\u012bp\u00edk", "sh\u00eengm\u00f9i", "\u014dts\u012bn\u00e1p")
            val tops = listOf(3f, 60f, 150f, 70f); val lefts = listOf(130f, 250f, 125f, 20f)
            header(13); byte(0); tail(); mark("AbsoluteFlags")
            u32(0xa0004 or when (duplicate) { 0 -> 65536; 1 -> 4194304; 2 -> 4096; else -> 0 })
            byte(1); byte(2); mark("Width"); f32(100f)
            if (duplicate == 2) { byte(2); length(12f) }
            if (duplicate == 0) f32(.75f)
            mark("HeightUnit"); byte(0); mark("Height"); f32(0f)
            mark("AbsoluteTag"); byte(1); mark("TopUnit"); byte(0); mark("Top"); f32(tops[index])
            mark("LeftUnit"); byte(0); mark("Left"); f32(lefts[index])
            mark("OwnerFlags"); byte(1); mark("OwnerScale"); f32(12f); mark("OwnerBasis"); byte(2)
            byte(if (family == null) 0 else 16); string("en"); string(""); byte(0)
            if (family != null) {
                byte(family)
                if (family == 1) { u32(1); string("Source Face"); byte(1) }
            }
            mark("LineHeight"); f32(12f); mark("LineBasis"); byte(2); mark("AbsoluteWrap"); byte(2); mark("PositionEnd")
            if (duplicate == 1) byte(0)
            u32(1); paragraph(names[index], inlineWrap, "")
        }
        fun table(child: Wire.() -> Unit) {
            header(12); byte(1); byte(0); u32(0); u32(1); u32(1)
            byte(0); u16(1); u16(1); byte(0); u32(0); byte(0); byte(1); u32(1); child()
            byte(0); byte(0); byte(0); tail()
        }
        fun figure(child: Wire.() -> Unit) {
            header(0); byte(0); string(""); string(""); byte(0); byte(0)
            byte(2); byte(0); byte(0); byte(0); repeat(3) { edges() }; f32(1f); length(12f)
            byte(1); byte(0); byte(1); byte(0); byte(0); byte(1)
            span("Retained missing media"); length(20f); length(10f); byte(0)
            u32(0); byte(1); u32(1); child(); byte(0); byte(0)
            byte(0)
        }
        fun pairedTable(clear: Boolean = false) {
            header(12); byte(if (clear) 13 else 7); byte(0); u32(0); u32(1); u32(1)
            byte(0); u16(1); u16(1); byte(0); u32(1); span("Pair"); byte(0); byte(0); byte(0)
            byte(1); byte(28); byte(0); byte(1); edges(); byte(1); byte(0)
            if (!clear) {
                u32(639); byte(1); byte(8); byte(0); edges(); byte(1); byte(2); f32(100f)
                byte(1); byte(4); byte(0); byte(1); byte(0); string("en"); byte(1); byte(0)
            }
            u32(639); byte(0); byte(0); string("en"); if (clear) byte(2)
            tail()
        }
        fun document(root: Wire.() -> Unit = { scoped((0..3).map { i -> { absolute(i) } }) },
            features: Int = 64, version: Int = 80, reference: Boolean = false, paired: Boolean = false,
            clear: Boolean = false): ByteArray {
            byte(68); byte(80); byte(82); byte(version); u32(0)
            u32(if (reference) 0 else 1)
            if (!reference) {
                byte(0); string(""); string(""); string(""); u32(1 + (if (paired) 1 else 0) + (if (clear) 1 else 0))
                root(); if (paired) pairedTable(); if (clear) pairedTable(true)
            }
            u32(0); u32(0); u32(0); u32(if (reference) 1 else 0)
            if (reference) { byte(1); u32(1); string("refs"); u32(0); byte(1); u32(1); root() }
            u32(0)
            if (version == 80) { mark("Features"); byte(features) }
            return out.toByteArray()
        }
    }
    private fun changed(bytes: ByteArray, at: Int, value: Int) = bytes.copyOf().also { it[at] = value.toByte() }
    private fun floatAt(bytes: ByteArray, at: Int, value: Float) = bytes.copyOf().also {
        ByteBuffer.wrap(it).order(ByteOrder.LITTLE_ENDIAN).putFloat(at, value)
    }

    @Test fun zeroUsedBoxRetainsIndependentTextMetricsRawBodyAndOriginalAction() {
        val raw = label(); val child = Container(listOf(raw), absoluteStyle())
        val parent = Container(listOf(box(child)), scopeStyle())
        val entry = Section(0, "", listOf(box(parent)))
        assertSame(raw, entry.blocks.single().container!!.blocks.single().container!!.blocks.single())
        assertEquals(0f, child.style.height!!.value, 0f); assertNull(child.style.lineHeight)
        val absolute = child.style.positioning as ContainerPositioning.Absolute
        assertEquals(12f, absolute.ownerFont.fontScale!!, 0f)
        assertEquals(InlineComputedLength(12f, FontScaleBasis.CssPx), absolute.lineHeight)
        assertEquals(EntryLink("sh\u00eengng\u00e2", "Khiamniungan_Naga"), raw.spans.single().entryLink())
        assertEquals(-25f, parent.style.margins!!.bottom.value, 0f)
        assertEquals(25f, parent.style.padding!!.bottom.value, 0f)
        val independent = absolute.copy(lineHeight = InlineComputedLength(1.5f, FontScaleBasis.NormalBody))
        assertEquals(FontScaleBasis.CssPx, independent.ownerFont.fontScaleBasis)
        assertEquals(FontScaleBasis.NormalBody, independent.lineHeight.fontScaleBasis)
        rejects { absolute.copy(top = StyleLength(StyleLengthUnit.Em, 3f)) }
        rejects { absolute.copy(left = px(-1f)) }
        rejects { absolute.copy(ownerFont = owner().copy(fontScaleBasis = FontScaleBasis.Context)) }
        rejects { absolute.copy(lineHeight = InlineComputedLength(-1f, FontScaleBasis.CssPx)) }
        rejects { absolute.copy(lineHeight = InlineComputedLength(12f, FontScaleBasis.Context)) }
        rejects { absolute.copy(textWrap = TextWrap.Normal) }
        rejects { absoluteStyle().copy(lineHeight = ContainerLineHeight.Length(px(12f))) }
        rejects { absoluteStyle().copy(ownerFontScale = .75f) }
        rejects { absoluteStyle().copy(fontFamily = ContainerFontFamily.SansSerif) }
        rejects { absoluteStyle().copy(height = px(1f)) }
        rejects { absoluteStyle().copy(width = ContainerWidth.Length(StyleWidth(StyleWidthUnit.Percent, 99f))) }
        rejects { absoluteStyle().copy(padding = zero) }
        rejects { absoluteStyle().copy(margins = zero) }
        rejects { absoluteStyle().copy(border = ContainerBorder.None) }
        rejects { absoluteStyle().copy(floatSide = TableFloatSide.Left) }
        rejects { absoluteStyle().copy(maxWidth = ContainerMaxWidth.None) }
        rejects { absoluteStyle().copy(overflow = ContainerOverflow.Visible) }
    }

    @Test fun scopeValidationKeepsPhysicalEdgesButClosesStateOrderAndMixedPositioningDomains() {
        assertEquals(ContainerPositioning.RelativeAuto, scopeStyle().positioning)
        assertEquals(listOf(900L), scope().viewportStates.map { it.minWidthPx })
        assertEquals(16, scope().copy(viewportStates = (1L..16L).map {
            PositionedViewportState(it, PositionedOverflowX.Scroll, PositionedOverflowY.Auto)
        }).viewportStates.size)
        rejects { PositionedViewportState(0, PositionedOverflowX.Hidden, PositionedOverflowY.Auto) }
        rejects { PositionedViewportState(0x1_0000_0000L, PositionedOverflowX.Hidden, PositionedOverflowY.Auto) }
        rejects { scope().copy(viewportStates = List(17) { PositionedViewportState(it + 1L, PositionedOverflowX.Scroll, PositionedOverflowY.Auto) }) }
        rejects { scope().copy(viewportStates = listOf(scope().viewportStates.single(), scope().viewportStates.single())) }
        rejects { scope().copy(viewportStates = listOf(PositionedViewportState(901, PositionedOverflowX.Scroll, PositionedOverflowY.Auto)) + scope().viewportStates) }
        rejects { scope().copy(textWrap = TextWrap.BreakWord) }
        rejects { scopeStyle().copy(positioning = null) }
        rejects { scopeStyle().copy(padding = zero.copy(left = px(1f))) }
        rejects { scopeStyle().copy(overflow = ContainerOverflow.Auto) }
        rejects { scopeStyle().copy(columns = ContainerColumns(2, px(0f))) }
        rejects { scopeStyle().copy(layout = ContainerLayout.FlexRow) }
        rejects { scopeStyle().copy(flexItem = ContainerFlexItem.None) }
        rejects { scopeStyle().copy(screenMaxWidth = ContainerScreenMaxWidth(900, width = ContainerWidth.Auto)) }
    }

    @Test fun completeModelRootsResetDirectParentAndAncestorScopeStillRejectsNestedOwners() {
        val absolute = box(Container(listOf(label()), absoluteStyle()))
        val good = box(Container(listOf(absolute), scopeStyle()))
        Section(0, "", listOf(good)); Reference(1, null, "", emptyList(), ReferenceKind.Fragment, listOf(good))
        Cell(emptyList(), false, 1, 1, blocks = listOf(good))
        rejects { Section(0, "", listOf(absolute)) }
        rejects { Reference(1, null, "", emptyList(), ReferenceKind.Fragment, listOf(absolute)) }
        rejects { Cell(emptyList(), false, 1, 1, blocks = listOf(absolute)) }
        rejects { Table(emptyList(), emptyList(), captionBlocks = listOf(absolute)) }
        rejects { Container(listOf(absolute)) }
        val throughTable = Block("table", 0, emptyList(), table = Table(emptyList(), listOf(listOf(
            Cell(emptyList(), false, 1, 1, blocks = listOf(good))))))
        rejects { Container(listOf(throughTable), scopeStyle()) }
        rejects { Container(listOf(box(Container(listOf(good)))), scopeStyle()) }
        val siblings = Container(listOf(good, good))
        Section(0, "", listOf(box(siblings))) // Sequential independent scopes do not leak active state.
    }

    @Test fun literalPayloadOrdersTypographyBeforeNoWrapAndPreservesAllFourLabelsAndEdges() {
        val wire = Wire(); val bytes = wire.document(); val frozen = bytes.copyOf(); val entry = decode(bytes)
        assertArrayEquals(frozen, bytes)
        assertArrayEquals(byteArrayOf(3, 0, -120, 0), bytes.copyOfRange(wire.marks.getValue("ScopeFlags"), wire.marks.getValue("ScopeFlags") + 4))
        assertArrayEquals(byteArrayOf(2, 0, 0, 1, 0, 0, 0, -124, 3, 0, 0, 1, 0),
            bytes.copyOfRange(wire.marks.getValue("ScopeTail"), wire.marks.getValue("ScopeEnd")))
        assertArrayEquals(byteArrayOf(1, 0, 0, 0, 64, 64, 0, 0, 0, 2, 67),
            bytes.copyOfRange(wire.marks.getValue("AbsoluteTag"), wire.marks.getValue("OwnerFlags")))
        assertArrayEquals(byteArrayOf(0, 0, 64, 65, 2, 2),
            bytes.copyOfRange(wire.marks.getValue("LineHeight"), wire.marks.getValue("PositionEnd")))
        val parent = entry.sections.single().blocks.single().container!!
        val expected = listOf("sh\u00eengng\u00e2", "\u014dts\u012bp\u00edk", "sh\u00eengm\u00f9i", "\u014dts\u012bn\u00e1p")
        val tops = listOf(3f, 60f, 150f, 70f); val lefts = listOf(130f, 250f, 125f, 20f)
        parent.blocks.forEachIndexed { index, block ->
            val child = block.container!!; val absolute = child.style.positioning as ContainerPositioning.Absolute
            assertEquals(tops[index], absolute.top.value); assertEquals(lefts[index], absolute.left.value)
            assertEquals(0f, child.style.height!!.value, 0f); assertNull(child.style.lineHeight)
            assertEquals(position().lineHeight, absolute.lineHeight)
            val action = child.blocks.single().spans.single()
            assertEquals(expected[index], action.text); assertEquals("kix", action.language)
            assertEquals("rtl", action.direction); assertEquals("#000000", action.foreground)
            assertEquals(EntryLink(expected[index], "Khiamniungan_Naga"), action.entryLink())
        }
        assertEquals(-25f, parent.style.margins!!.bottom.value, 0f)
        assertEquals(25f, parent.style.padding!!.bottom.value, 0f)
    }

    @Test fun recursiveCensusAndOwnerResetCoverReferenceCellFigureAndIndependentScopes() {
        val roots: List<Wire.() -> Unit> = listOf(
            { scoped(listOf({ absolute() })) },
            { table { scoped(listOf({ absolute() })) } },
            { figure { scoped(listOf({ absolute() })) } },
            { plain(listOf({ scoped(listOf({ absolute() })) }, { scoped(listOf({ absolute(1) })) })) })
        for (root in roots) for (reference in listOf(false, true)) {
            val good = Wire().document(root, reference = reference)
            assertNotNull(decode(good)); rejects { decode(good.copyOf().also { it[it.lastIndex] = 1 }) }
        }
        val invalid: List<Wire.() -> Unit> = listOf(
            { absolute() }, { plain(listOf({ absolute() })) },
            { scoped(listOf({ plain(listOf({ absolute() })) })) },
            { scoped(listOf({ table { absolute() } })) }, { scoped(listOf({ figure { absolute() } })) },
            { scoped(listOf({ plain(listOf({ scoped(emptyList()) })) })) },
            { scoped(listOf({ table { scoped(emptyList()) } })) },
            { scoped(listOf({ figure { scoped(emptyList()) } })) })
        for (root in invalid) rejects { decode(Wire().document(root)) }
    }

    @Test fun anySnapshotFamilyCombinesWithExistingBodyTextFlowClearAndPairedTableFeatures() {
        for (family in listOf(0, 1)) {
            val wire = Wire(); val good = wire.document(root = { plain(listOf(
                { scoped(listOf({ absolute(family = family) })) }, { paragraph("Body", wrap = 0, trail = " !") })) },
                features = 1 or 4 or 8 or 16 or 32 or 64, paired = true, clear = true)
            val entry = decode(good)
            assertEquals(BodyAdjoiningPolicy.Ordinary, entry.bodyAdjoining)
            val body = entry.sections.single().blocks.first().container!!
            assertEquals("Body !", body.blocks[1].spans.single().let { it.text + it.trail })
            val child = body.blocks.first().container!!.blocks.single().container!!
            val absolute = child.style.positioning as ContainerPositioning.Absolute
            assertEquals(if (family == 0) ContainerFontFamily.SansSerif else
                ContainerFontFamily.Stack(listOf("Source Face"), GenericFontFamily.Serif), absolute.ownerFont.fontFamily)
            assertEquals(TextWrap.Normal, body.blocks[1].spans.single().inlineStyle!!.wrap)
            assertNotNull(entry.sections.single().blocks[1].table!!.blockViewport!!.focusPaint)
            assertEquals(FigureClear.Right, entry.sections.single().blocks[2].table!!.floatViewport!!.narrowClear)
            for (bit in listOf(4, 8, 16, 32, 64)) rejects { decode(changed(good, wire.marks.getValue("Features"), 125 and bit.inv())) }
        }
    }

    @Test fun oldRelativeNullBytesAndHeadersRemainSeparateFromMandatoryNewFeature() {
        val root: Wire.() -> Unit = { scoped(listOf({ paragraph() }), enabled = false) }
        val old = Wire().document(root, version = 77)
        for (version in listOf(78, 79)) {
            val bytes = Wire().document(root, version = version)
            assertArrayEquals(old.copyOf().also { it[3] = version.toByte() }, bytes)
            assertEquals(decode(old), decode(bytes))
        }
        val oldP = Wire().document(root, features = 1)
        assertArrayEquals(old.copyOf().also { it[3] = 80 } + byteArrayOf(1), oldP)
        assertEquals(decode(old).copy(bodyAdjoining = BodyAdjoiningPolicy.Ordinary), decode(oldP))
        rejects { decode(Wire().document(root, features = 64)) }
        rejects { decode(Wire().document(root, features = 0)) }
        rejects { decode(old.copyOf().also { it[3] = 81 }) }
        for (version in listOf(77, 78, 79)) rejects { decode(Wire().document(version = version)) }
    }

    @Test fun malformedTagsTypographyStatesAndPartialEntriesRefuseWithoutBroadeningOrdinaryWrap() {
        val wire = Wire(); val good = wire.document()
        for ((name, values) in mapOf("RelativeTag" to listOf(2, 255), "AbsoluteTag" to listOf(2, 255),
            "TopUnit" to listOf(1, 2), "LeftUnit" to listOf(1, 2), "HeightUnit" to listOf(1),
            "OwnerBasis" to listOf(0, 3), "LineBasis" to listOf(0, 3), "AbsoluteWrap" to listOf(0, 1, 3),
            "ScopeTail" to listOf(0, 1, 3), "ScopeX" to listOf(2), "ScopeY" to listOf(1),
            "StateX" to listOf(2), "StateY" to listOf(1), "StateCount" to listOf(17), "Features" to listOf(0, 1, 68, 80, 96, 128)))
            for (value in values) rejects { decode(changed(good, wire.marks.getValue(name), value)) }
        for (name in listOf("Top", "Left", "OwnerScale", "LineHeight"))
            for (value in listOf(-1f, Float.NaN, Float.POSITIVE_INFINITY)) rejects { decode(floatAt(good, wire.marks.getValue(name), value)) }
        rejects { decode(floatAt(good, wire.marks.getValue("Height"), 1f)) }
        rejects { decode(floatAt(good, wire.marks.getValue("Width"), 99f)) }
        for (duplicate in 0..2) rejects { decode(Wire().document(root = {
            scoped(listOf({ absolute(duplicate = duplicate) }))
        })) }
        rejects { decode(Wire().document(root = { scoped(emptyList(), thresholds = listOf(900, 900)) })) }
        rejects { decode(Wire().document(root = { scoped(emptyList(), thresholds = listOf(900, 899)) })) }
        rejects { decode(Wire().document(root = { scoped(emptyList(), thresholds = listOf(0)) })) }
        rejects { decode(good + byteArrayOf(0)) }
        for (end in 0 until good.size) rejects { decode(good.copyOf(end)) }
        rejects { decode(Wire().document(root = { scoped(listOf({ absolute(inlineWrap = 2) })) }, features = 80)) }
        rejects { InlineTextStyle(wrap = TextWrap.NoWrap) }
        val headingBox = ContainerStyle(margins = zero, padding = zero, border = ContainerBorder.None,
            ownerFontScale = 1f, lineHeight = ContainerLineHeight.Multiplier(1f), fontFamily = ContainerFontFamily.SansSerif,
            clear = FigureClear.None)
        rejects { SectionHeadingStyle(headingBox, InlineFontSnapshot(1f, FontScaleBasis.NormalBody, language = "en"),
            BidiResolvedDirection.Ltr, titleWrap = TextWrap.NoWrap) }
        rejects { FigureMediaLayout(FigureMediaStrut(1f, direction = BidiResolvedDirection.Ltr),
            InlineBoxVerticalAlign.Baseline, positioning = position()) }
        assertEquals(ContainerPositioning.RelativeAuto, FigureMediaLayout(FigureMediaStrut(1f,
            direction = BidiResolvedDirection.Ltr), InlineBoxVerticalAlign.Baseline,
            positioning = ContainerPositioning.RelativeAuto).positioning)
        assertNotNull(decode(good))
    }
}
