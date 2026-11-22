package app.smallthingz.dict

import java.io.ByteArrayOutputStream
import org.junit.Assert.*
import org.junit.Test

/** Literal complete M documents; no producer or network response is used as the oracle. */
class FigureBlockMediaCodecTest {
    private class Wire(val rich: Boolean = false, val states: List<Long> = listOf(639, 399),
        val oneUrl: String = "https://example.test/controlled-1x.png",
        val oneHash: String = "1".repeat(64),
        val twoUrl: String = "https://example.test/controlled-2x.png",
        val twoHash: String = "2".repeat(64)) {
        val out = ByteArrayOutputStream()
        val offsets = linkedMapOf<String, Int>()
        fun mark(name: String) { check(offsets.put(name, out.size()) == null) }
        fun byte(value: Int) { out.write(value) }
        fun u32(value: Long) { repeat(4) { byte((value ushr (it * 8)).toInt()) } }
        fun f32(value: Float) = u32(value.toRawBits().toLong())
        fun string(value: String) { val bytes = value.encodeToByteArray(); u32(bytes.size.toLong()); out.write(bytes) }
        fun length(value: Float, unit: Int = 0) { byte(unit); f32(value) }
        fun span(text: String = "", image: Boolean = false, target: String = "") {
            byte(if (target.isEmpty()) 0 else 1); byte(0); byte(0)
            string(text); string(target); string(""); string("vi"); string(""); string(""); string("")
            byte(0); byte(0); byte(0) // static colors and null font fields, including ordinary link paint
            mark(if (image) "imageTag" else "textImageTag$text"); byte(if (image) 1 else 0)
            if (image) {
                string("Controlled.svg"); byte(15); u32(44); u32(40); string("original alt"); string("original image tooltip")
            }
            byte(0); byte(1); string("original span tooltip")
        }
        fun wrapper(prefix: String, index: Int) {
            val auto = index == 1
            mark(prefix + "WrapperFlags"); u32(if (auto) 0x213004 else 0x13005)
            if (!auto) repeat(4) { length(if (it == 3) -.25f else 0f) }
            mark(prefix + "Width"); byte(0)
            mark(prefix + "LineHeight"); byte(if (index == 1) 2 else 1)
            if (index == 1) length(24f) else f32(1.5f)
            mark(prefix + "TextAlign"); byte(index.coerceAtMost(2))
            mark(prefix + "OwnerScale"); f32(1f + index * .25f)
            if (auto) {
                byte(1); length(0f); byte(0); byte(1); length(0f); byte(0)
            }
        }
        fun media(prefix: String, index: Int) {
            mark(prefix + "Scale"); f32(1f + index * .25f)
            mark(prefix + "FontFlags"); byte(0)
            string("vi"); mark(prefix + "Direction"); byte(if (index == 1) 1 else 0)
            mark(prefix + "Align"); byte(1)
            mark(prefix + "Cap"); byte(if (index == 2) 0 else 1)
            if (index != 2) { mark(prefix + "Percent"); f32(100f); byte(0); mark(prefix + "Subtract"); f32(0f) }
            mark(prefix + "Position"); byte(0); mark(prefix + "After"); byte(0); mark(prefix + "Focus"); byte(0)
        }
        fun tail() {
            mark("newTail"); wrapper("base", 0); media("base", 0)
            mark("preferredWidth"); u32(44); mark("naturalWidth"); u32(120); mark("naturalHeight"); u32(110)
            mark("oneUrl"); string(oneUrl); mark("oneHash"); string(oneHash)
            mark("twoUrl"); string(twoUrl); mark("twoHash"); string(twoHash)
            mark("stateCount"); u32(states.size.toLong())
            states.forEachIndexed { index, threshold ->
                mark("threshold$index"); u32(threshold); wrapper("state$index", (index % 2) + 1)
                media("state$index", (index % 2) + 1)
            }
            mark("tailEnd")
        }
        fun figure(tag: Int) {
            mark("figureTag"); byte(tag); mark("imageFigurePayload"); byte(0); byte(0); byte(0)
            repeat(12) { length(0f) }; f32(.875f); length(1.25f, 1)
            byte(1); byte(0); byte(1); byte(0); byte(0); byte(1)
            span(image = true)
            u32(0); byte(if (rich) 1 else 0); if (rich) u32(0)
            byte(0); mark("sizing"); byte(2); mark("minimumPresence"); byte(0)
            mark("imageFigurePayloadEnd")
            if (tag == 7) tail()
        }
        fun document(tag: Int = 7, version: Char = 'M', flow: Boolean = false, catalog: Boolean = true): ByteArray {
            out.write(byteArrayOf(68, 80, 82, version.code.toByte())); u32(0); u32(1)
            byte(2); string("Body"); string(""); string(""); u32(1)
            byte(0); byte(0); byte(0); u32(0); byte(0); string(""); string(""); byte(0)
            string(""); string(""); byte(0); byte(0)
            if (flow) {
                byte(0); byte(1); u32(3)
                byte(0); u32(1); span("Before", target = "before-target")
                byte(1); figure(tag)
                byte(0); u32(1); span("After", target = "after-target")
            } else { figure(tag); byte(0) }
            repeat(4) { u32(0) }
            mark("catalogCount"); u32(if (catalog) 1 else 0)
            if (catalog) { string("Controlled.svg"); byte(0); string("original catalog caption") }
            return out.toByteArray()
        }
    }
    private fun decode(bytes: ByteArray) = BlobDecoder.decode(bytes, "Controlled", "language", "Vietnamese", "vi")
    private fun figure(bytes: ByteArray): Figure = decode(bytes).sections.single().blocks.single().let { block ->
        block.figure ?: (block.flow!![1] as FlowPart.ImageFigure).figure
    }
    private fun rejects(label: String, bytes: ByteArray) { assertTrue(label, runCatching { decode(bytes) }.isFailure) }
    private fun set32(bytes: ByteArray, offset: Int, value: Long): ByteArray = bytes.copyOf().also { copy ->
        repeat(4) { copy[offset + it] = (value ushr (it * 8)).toByte() }
    }
    private fun setByte(bytes: ByteArray, offset: Int, value: Int) = bytes.copyOf().also { it[offset] = value.toByte() }

    @Test fun literalMTagSevenPreservesImageBodyActionsAndCompleteResponsiveLineStates() {
        val wire = Wire(); val bytes = wire.document(flow = true)
        val entry = decode(bytes); val value = figure(bytes); val policy = value.blockMediaLayout!!
        assertNull(value.tableCaptionLayout)
        assertEquals(44L, policy.preferredWidthPx); assertEquals(120L, policy.naturalWidth); assertEquals(110L, policy.naturalHeight)
        assertEquals("https://example.test/controlled-1x.png", policy.rendition1x.url)
        assertEquals("1".repeat(64), policy.rendition1x.sha256)
        assertEquals("https://example.test/controlled-2x.png", policy.rendition2x.url)
        assertEquals("2".repeat(64), policy.rendition2x.sha256)
        assertEquals(ContainerWidth.Auto, policy.wrapper.width)
        assertEquals(-.25f, policy.wrapper.margins!!.left.value, 0f)
        assertEquals(ContainerLineHeight.Multiplier(1.5f), policy.wrapper.lineHeight)
        assertEquals(listOf(639L, 399L), policy.viewportStates.map { it.maxWidthPx })
        val first = policy.viewportStates[0]; val last = policy.viewportStates[1]
        assertEquals(ContainerMargin.Auto, first.wrapper.marginValues!!.left)
        assertEquals(ContainerLineHeight.Length(StyleLength(StyleLengthUnit.Px, 24f)), first.wrapper.lineHeight)
        assertEquals(1.25f, first.media.strut.fontScale, 0f)
        assertEquals(BidiResolvedDirection.Rtl, first.media.strut.direction)
        assertEquals(CellTextAlign.Center, first.wrapper.textAlign)
        assertEquals(CellTextAlign.Right, last.wrapper.textAlign)
        assertNull(last.media.maxWidth)
        assertNull(policy.stateAtViewport(639.25)); assertEquals(first, policy.stateAtViewport(639.0))
        assertEquals(last, policy.stateAtViewport(399.0))
        assertEquals(44L, value.content.span.image!!.widthPx); assertEquals(40L, value.content.span.image!!.heightPx)
        assertEquals("original alt", value.content.span.image!!.alt)
        assertEquals("original span tooltip", value.content.span.tooltip)
        val spans = mutableListOf<Span>()
        entry.sections.single().blocks.single().visitSpanRuns { run, _ -> spans += run }
        assertEquals(listOf("Before", "", "After"), spans.map { it.text })
        assertEquals(listOf("before-target", "", "after-target"), spans.map { it.target })
        assertEquals(listOf(Media("Controlled.svg", "image", "original catalog caption")), entry.media)
        assertEquals(1, entry.inlineImages.size)
        assertEquals(emptyList<Block>(), figure(Wire(rich = true).document()).captionBlocks)
        assertNull(value.captionBlocks)
    }

    @Test fun absentBlockPolicyKeepsWholeLegacyPayloadAndOldHeadersExact() {
        val newWire = Wire(); val current = newWire.document()
        val oldWire = Wire(); val old = oldWire.document(tag = 1)
        assertArrayEquals(old.copyOfRange(oldWire.offsets.getValue("imageFigurePayload"), oldWire.offsets.getValue("imageFigurePayloadEnd")),
            current.copyOfRange(newWire.offsets.getValue("imageFigurePayload"), newWire.offsets.getValue("imageFigurePayloadEnd")))
        val removed = current.copyOfRange(0, newWire.offsets.getValue("newTail")) +
            current.copyOfRange(newWire.offsets.getValue("tailEnd"), current.size)
        removed[newWire.offsets.getValue("figureTag")] = 1
        assertArrayEquals(old, removed)
        val legacy = figure(old)
        assertNull(legacy.blockMediaLayout)
        for (header in listOf('J', 'K', 'L', 'M')) {
            val literal = Wire().document(tag = 1, version = header)
            assertArrayEquals(old.copyOfRange(4, old.size), literal.copyOfRange(4, literal.size))
            assertEquals(legacy, figure(literal))
        }
    }

    @Test fun newTagAndRequiredRenditionTailRejectForeignHeadersMissingFieldsAndTrailingData() {
        val wire = Wire(); val bytes = wire.document()
        for (header in listOf('J', 'K', 'L')) rejects("tag7 header $header", setByte(bytes, 3, header.code))
        for (tag in listOf(3, 4, 8, 255)) rejects("tag $tag", setByte(bytes, wire.offsets.getValue("figureTag"), tag))
        for (end in 0 until bytes.size) rejects("truncated $end", bytes.copyOf(end))
        rejects("trailing", bytes + byteArrayOf(0))
        rejects("missing raster catalog", Wire().document(catalog = false))
        val noIdentity = bytes.copyOfRange(0, wire.offsets.getValue("oneUrl")) +
            bytes.copyOfRange(wire.offsets.getValue("stateCount"), bytes.size)
        rejects("old unpublished tag7 without identity", noIdentity)
        val oneOnly = bytes.copyOfRange(0, wire.offsets.getValue("twoUrl")) +
            bytes.copyOfRange(wire.offsets.getValue("stateCount"), bytes.size)
        rejects("missing mandatory second density", oneOnly)
        val extraPresence = bytes.copyOfRange(0, wire.offsets.getValue("newTail")) + byteArrayOf(1) +
            bytes.copyOfRange(wire.offsets.getValue("newTail"), bytes.size)
        rejects("no optional tail presence", extraPresence)
    }

    @Test fun literalAxesCountsOrderingAndSourceStateDomainsAreStrict() {
        val wire = Wire(); val bytes = wire.document(); val at = wire.offsets
        for (field in listOf("preferredWidth", "naturalWidth", "naturalHeight")) rejects("zero $field", set32(bytes, at.getValue(field), 0))
        for (field in listOf("naturalWidth", "naturalHeight")) rejects("double overflow $field", set32(bytes, at.getValue(field), 0x8000_0000L))
        assertEquals(0xffff_ffffL, figure(set32(bytes, at.getValue("preferredWidth"), 0xffff_ffffL)).blockMediaLayout!!.preferredWidthPx)
        rejects("count huge", set32(bytes, at.getValue("stateCount"), 0xffff_ffffL))
        rejects("duplicate states", set32(bytes, at.getValue("threshold1"), 639))
        rejects("ascending states", set32(bytes, at.getValue("threshold1"), 640))
        assertEquals(16, figure(Wire(states = (16L downTo 1L).toList()).document()).blockMediaLayout!!.viewportStates.size)
        rejects("seventeen states", Wire(states = (17L downTo 1L).toList()).document())
        for ((field, value) in listOf("baseWidth" to 3, "baseLineHeight" to 3, "baseTextAlign" to 3,
            "baseDirection" to 2, "baseAlign" to 0, "baseCap" to 2, "baseFontFlags" to 16)) {
            rejects(field, setByte(bytes, at.getValue(field), value))
        }
        val missingWidth = set32(bytes, at.getValue("baseWrapperFlags"), 0x13001)
        rejects("missing wrapper width", missingWidth.copyOfRange(0, at.getValue("baseWidth")) +
            missingWidth.copyOfRange(at.getValue("baseWidth") + 1, missingWidth.size))
        rejects("unknown wrapper field", set32(bytes, at.getValue("baseWrapperFlags"), 0x80013005L))
        rejects("owner mismatch", set32(bytes, at.getValue("baseOwnerScale"), 1.5f.toRawBits().toLong()))
        rejects("NaN strut", set32(bytes, at.getValue("baseScale"), Float.NaN.toRawBits().toLong()))
        rejects("percent", set32(bytes, at.getValue("basePercent"), 99f.toRawBits().toLong()))
        rejects("cap subtraction", set32(bytes, at.getValue("baseSubtract"), 1f.toRawBits().toLong()))
    }

    @Test fun literalIdentityStringsRemainMandatoryBoundedDistinctAndCanonical() {
        for (url in listOf("", "http://example.test/a.png", "https://user@example.test/a.png", "https://example.test/a#x")) {
            rejects("URL $url", Wire(oneUrl = url).document())
        }
        for (hash in listOf("", "1".repeat(63), "A".repeat(64), "g".repeat(64))) {
            rejects("hash $hash", Wire(oneHash = hash).document())
        }
        rejects("same URL", Wire(twoUrl = "https://example.test/controlled-1x.png").document())
        rejects("same hash", Wire(twoHash = "1".repeat(64)).document())
        val wire = Wire(); val bytes = wire.document()
        rejects("string length", set32(bytes, wire.offsets.getValue("oneUrl"), 0x0200_0001L))
        rejects("malformed UTF8", setByte(bytes, wire.offsets.getValue("oneUrl") + 4, 255))
        val wrongOrder = bytes.copyOfRange(0, wire.offsets.getValue("oneUrl")) +
            bytes.copyOfRange(wire.offsets.getValue("stateCount"), wire.offsets.getValue("tailEnd")) +
            bytes.copyOfRange(wire.offsets.getValue("oneUrl"), wire.offsets.getValue("stateCount")) +
            bytes.copyOfRange(wire.offsets.getValue("tailEnd"), bytes.size)
        rejects("states before required identities", wrongOrder)
    }
}
