package app.smallthingz.dict

import java.io.ByteArrayOutputStream
import org.junit.Assert.*
import org.junit.Test

/** Typed transport only; no retained TH/RU source issuance is implied. */
class TextFlowModelCodecTest {
    private fun px(value: Float) = StyleLength(StyleLengthUnit.Px, value)
    private fun decode(bytes: ByteArray) = BlobDecoder.decode(bytes, "Entry", "language", "Thai", "th")
    private fun refuses(block: () -> Any?) = assertTrue(runCatching(block).isFailure)
    private class Wire {
        val out = ByteArrayOutputStream()
        val wrapOffsets = mutableListOf<Int>()
        val headingMasks = mutableListOf<Int>()
        val headingWrapOffsets = mutableListOf<Int>()
        val fallbackPresence = mutableListOf<Int>()
        var featureOffset = -1
        fun byte(value: Int) { out.write(value) }
        fun u32(value: Int) { repeat(4) { byte(value ushr (8 * it)) } }
        fun f32(value: Float) = u32(value.toRawBits())
        fun string(value: String) { val bytes = value.encodeToByteArray(); u32(bytes.size); out.write(bytes) }
        fun length(value: Float, unit: Int = 0) { byte(unit); f32(value) }
        fun span(text: String, wrap: Int? = null, target: String = "", trail: String = "", direction: String = "") {
            byte(if (target.isEmpty()) 0 else 1); byte(0); byte(0)
            string(text); string(target); string(trail); string("th"); string(""); string(direction); string("")
            byte(0); byte(0); byte(if (wrap == null) 0 else 8)
            if (wrap != null) { byte(32); wrapOffsets += out.size(); byte(wrap) }
            byte(0); byte(if (target.isEmpty()) 0 else 1); if (target.isNotEmpty()) string("part"); byte(0)
        }
        fun paragraph(wrap: Int?) {
            byte(0); byte(0); byte(0); u32(1); span("LongToken", wrap, "Target", "!", "rtl")
            byte(0); string(""); string(""); byte(0); string(""); string("")
            byte(0); byte(0); byte(0); byte(0)
        }
        fun headingBlock(index: Int) {
            byte(9); byte(0); byte(2); u32(1); span("Title$index", target = "Target$index")
            byte(0); string(""); string(""); byte(0); string("primary$index"); string("fallback$index")
            byte(0); byte(0); byte(0); byte(0)
        }
        fun headingStyle(mask: Int?, wrap: Int = 0, fallback: Boolean = true) {
            u32(1 or 2 or 16 or 2048 or 4096 or 65536 or (1 shl 22))
            repeat(8) { length(0f) }
            byte(0); byte(0); byte(1); f32(1.5f); f32(1.25f); byte(0)
            byte(1); f32(1.25f); byte(1); byte(0); string("th"); string(""); byte(0)
            byte(0)
            if (mask != null) {
                headingMasks += out.size(); byte(mask)
                if (mask and 1 != 0) { headingWrapOffsets += out.size(); byte(wrap) }
                if (mask and 2 != 0) {
                    length(75f); fallbackPresence += out.size(); byte(if (fallback) 1 else 0)
                    if (fallback) length(0f)
                }
            }
        }
        fun document(features: Int? = null, wrap: Int? = null, headingMasks: List<Int> = emptyList(),
            headingWrap: Int = 0, fallback: Boolean = true): ByteArray {
            out.write((if (features == null) "DPRO" else "DPRP").encodeToByteArray())
            u32(1); span("Display")
            u32(2)
            repeat(2) { index ->
                byte(2); string("Title$index"); string("primary$index"); string("fallback$index")
                u32(2); headingBlock(index); paragraph(if (index == 0) wrap else null)
            }
            u32(1); span("Preamble"); u32(0); u32(0)
            u32(1); byte(1); u32(7); string("refs"); u32(1); span("Reference", target = "Reference"); byte(0)
            u32(1); string("Media.ogg"); byte(1); string("Media")
            if (features != null) {
                featureOffset = out.size(); byte(features)
                if (features and 2 != 0) {
                    u32(headingMasks.size)
                    headingMasks.forEachIndexed { index, mask ->
                        u32(index); headingStyle(if (features and 16 != 0) mask else null, headingWrap, fallback)
                    }
                }
            }
            return out.toByteArray()
        }
    }

    @Test fun wrapOwnsNonemptyTextWithoutChangingTrailDirectionOrAction() {
        for (wrap in listOf(TextWrap.Normal, TextWrap.BreakWord)) {
            val span = Span("link", "Token", "Target", trail = "!", direction = "rtl", targetFragment = "part",
                inlineStyle = InlineTextStyle(wrap = wrap))
            assertEquals("Token", span.text); assertEquals("!", span.trail); assertEquals("rtl", span.direction)
            assertEquals(EntryLink("Target", "part"), span.entryLink())
            assertEquals(wrap, span.inlineStyle!!.wrap)
        }
        refuses { Span("text", "", inlineStyle = InlineTextStyle(wrap = TextWrap.Normal)) }
        refuses { Span("text", "", inlineStyle = InlineTextStyle(wrap = TextWrap.BreakWord,
            lineHeight = InlineLineHeight.Computed(InlineComputedLength(1f, FontScaleBasis.NormalBody)))) }
        refuses { Span("line_break", "\n", inlineStyle = InlineTextStyle(wrap = TextWrap.Normal)) }
        assertNull(Span("text", "Old").inlineStyle)
    }

    @Test fun revealPreservesExplicitZeroAndRequiresExactDistinctAnchorIdentities() {
        val old = decode(Wire().document(2, headingMasks = listOf(0))).sections.first()
        val style = old.headingStyle!!.copy(titleWrap = TextWrap.Normal,
            anchorReveal = HeadingAnchorReveal(px(75f), px(0f)))
        val section = old.copy(headingStyle = style)
        assertSame(old.blocks, section.blocks)
        assertEquals(75f, section.headingStyle!!.anchorReveal!!.primaryTop.value, 0f)
        assertEquals(0f, section.headingStyle!!.anchorReveal!!.fallbackTop!!.value, 0f)
        refuses { HeadingAnchorReveal(StyleLength(StyleLengthUnit.Em, 1f)) }
        refuses { HeadingAnchorReveal(px(75f), StyleLength(StyleLengthUnit.Em, 0f)) }
        refuses { old.copy(headingStyle = style.copy(anchorReveal = HeadingAnchorReveal(px(75f)))) }
        refuses { old.copy(anchor = "", headingStyle = style) }
        val sameId = old.blocks.first().copy(anchorFallback = old.anchor)
        refuses { old.copy(anchorFallback = old.anchor, blocks = listOf(sameId) + old.blocks.drop(1), headingStyle = style) }
    }

    @Test fun oldOAndPPathsKeepDataWhileMixedInlineHeadingCensusUsesEachRealUser() {
        val oldO = Wire().document()
        val old = decode(oldO)
        val oldP = Wire().document(1)
        assertArrayEquals(oldO.copyOf().also { it[3] = 'P'.code.toByte() } + byteArrayOf(1), oldP)
        assertEquals(old.copy(bodyAdjoining = BodyAdjoiningPolicy.Ordinary), decode(oldP))
        for (wrap in 0..1) {
            val bytes = Wire().document(18, wrap, listOf(3, 0))
            val frozen = bytes.copyOf(); val entry = decode(bytes)
            assertArrayEquals(frozen, bytes)
            assertEquals(TextWrap.entries[wrap], entry.sections[0].blocks[1].spans.single().inlineStyle!!.wrap)
            assertEquals(TextWrap.Normal, entry.sections[0].headingStyle!!.titleWrap)
            assertEquals(HeadingAnchorReveal(px(75f), px(0f)), entry.sections[0].headingStyle!!.anchorReveal)
            assertNull(entry.sections[1].headingStyle!!.titleWrap)
            assertNull(entry.sections[1].headingStyle!!.anchorReveal)
            assertEquals(old.displayTitle, entry.displayTitle); assertEquals(old.references, entry.references)
            assertEquals(old.preamble, entry.preamble); assertEquals(old.media, entry.media)
            assertEquals(old.sections[0].blocks[1].spans.single().copy(inlineStyle = InlineTextStyle(wrap = TextWrap.entries[wrap])),
                entry.sections[0].blocks[1].spans.single())
        }
    }

    @Test fun exactRequiredFeatureRejectsMissingSpuriousUnknownAndOldHeaderWrap() {
        refuses { decode(Wire().document(16)) }
        refuses { decode(Wire().document(1, wrap = 1)) }
        refuses { decode(Wire().document(null, wrap = 1)) }
        refuses { decode(Wire().document(32, wrap = 1)) }
        assertEquals(TextWrap.BreakWord, decode(Wire().document(16, wrap = 1)).sections[0].blocks[1].spans.single().inlineStyle!!.wrap)
        assertNotNull(decode(Wire().document(18, headingMasks = listOf(2))).sections[0].headingStyle!!.anchorReveal)
    }

    @Test fun everyEnumMaskPresenceAndTruncatedTailFailsWithoutPartialEntry() {
        val wire = Wire(); val good = wire.document(18, 1, listOf(3, 0))
        for (position in wire.wrapOffsets + wire.headingWrapOffsets)
            for (value in listOf(2, 255)) refuses { decode(good.copyOf().also { it[position] = value.toByte() }) }
        for (position in wire.headingMasks)
            refuses { decode(good.copyOf().also { it[position] = 4 }) }
        for (position in wire.fallbackPresence)
            refuses { decode(good.copyOf().also { it[position] = 2 }) }
        refuses { decode(Wire().document(18, headingMasks = listOf(2), fallback = false)) }
        for (end in 0 until good.size) refuses { decode(good.copyOf(end)) }
        assertEquals(2, decode(good).sections.size)
    }
}
