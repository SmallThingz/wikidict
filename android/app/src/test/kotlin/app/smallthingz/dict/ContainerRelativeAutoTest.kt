package app.smallthingz.dict

import java.io.ByteArrayOutputStream
import org.junit.Assert.*
import org.junit.Test

class ContainerRelativeAutoTest {
    private class Wire {
        val out = ByteArrayOutputStream()
        fun byte(v: Int) { out.write(v) }
        fun short(v: Int) { byte(v); byte(v ushr 8) }
        fun int(v: Int) { repeat(4) { byte(v ushr (8 * it)) } }
        fun text(v: String) { val bytes = v.encodeToByteArray(); int(bytes.size); out.write(bytes) }
    }
    private fun frame(flags: Int = 0, positioning: Int = 0, version: Int = 77) = Wire().run {
        byte(68); byte(80); byte(82); byte(version); int(0)
        int(1); byte(2); text("Controlled"); text(""); text(""); int(1)
        byte(13); byte(0); byte(0); int(0)
        byte(0); text(""); text(""); byte(0); text(""); text(""); repeat(4) { byte(0) }
        if (version == 77) int(flags) else short(flags)
        if (flags and 0x10000 != 0) int(.9f.toRawBits())
        if (flags and 0x20000 != 0) { byte(0); int(0) }
        if (flags and 0x40000 != 0) { short(2); byte(1); int(.9f.toRawBits()) }
        if (flags and 0x80000 != 0) byte(positioning)
        int(0); int(0); int(0); int(1); int(0); int(0); int(0)
        out.toByteArray()
    }
    private fun decode(bytes: ByteArray) = BlobDecoder.decode(bytes, "positioned", "language", "English", "en")

    @Test fun relativeAutoMFramingKeepsAbsenceAndEarlierTailsExact() {
        fun style(bytes: ByteArray) = decode(bytes).sections.single().blocks.single().container!!.style
        assertNull(style(frame()).positioning)
        assertEquals(decode(frame()).sections, decode(frame(version = 76)).sections)
        assertEquals(ContainerPositioning.RelativeAuto, style(frame(0x80000)).positioning)
        val all = style(frame(0xf0000))
        assertEquals(.9f, all.ownerFontScale!!, 0f)
        assertEquals(StyleLength(StyleLengthUnit.Px, 0f), all.height)
        assertEquals(ContainerColumns(2, StyleLength(StyleLengthUnit.Em, .9f)), all.columns)
        assertEquals(ContainerPositioning.RelativeAuto, all.positioning)
        assertThrows(Exception::class.java) { decode(frame(0x80000, 1)) }
        assertThrows(Exception::class.java) { decode(frame(0x400000)) }
        assertThrows(Exception::class.java) { decode(frame(0x80000).also { it[3] = 76 }) }
        val complete = frame(0x80000)
        for (length in complete.indices) assertThrows(Exception::class.java) { decode(complete.copyOf(length)) }
        assertThrows(Exception::class.java) { decode(complete + byteArrayOf(0)) }
    }

    @Test fun positionedGroupsJoinTheEntryPhaseAcrossOrdinaryAncestorsAndTables() {
        val source = listOf(
            NativePaintOrderNode(0, children = listOf(
                NativePaintOrderNode(1, true, listOf(NativePaintOrderNode(2))),
                NativePaintOrderNode(3))), // a real later table slot
            NativePaintOrderNode(4),
            NativePaintOrderNode(5, children = listOf(
                NativePaintOrderNode(6, true, listOf(NativePaintOrderNode(7), NativePaintOrderNode(8))))))
        assertEquals(listOf(0, 3, 4, 5, 1, 2, 6, 7, 8), nativeContextPaintSequence(source))
        assertEquals(listOf(8, 7, 6, 2, 1, 5, 4, 3, 0), nativeContextPaintSequence(source).reversed())
        assertEquals(listOf(3, 0, 1, 2), nativeContextPaintSequence(listOf(
            NativePaintOrderNode(3), NativePaintOrderNode(0, children = listOf(
                NativePaintOrderNode(1, true, listOf(NativePaintOrderNode(2))))))))
        assertEquals(listOf(0, 1, 2), nativeContextPaintSequence(listOf(
            NativePaintOrderNode(0, children = listOf(NativePaintOrderNode(1))), NativePaintOrderNode(2))))
    }

    @Test fun positionedPolicyKeepsUsedBoxesAndRefusesUnjoinedChildrenWithBodyRetained() {
        val plain = ContainerStyle(height = StyleLength(StyleLengthUnit.Px, 0f))
        val relative = plain.copy(positioning = ContainerPositioning.RelativeAuto)
        fun prepare(style: ContainerStyle, children: List<NativeFloatContextSpec> = emptyList(), flex: Boolean = false) =
            nativeContainerSpec(9, style.atViewport(300f), children, 1f, 20f, false, false, flex)
        val a = prepare(plain)
        val b = prepare(relative)
        assertFalse(a.relativeAuto)
        assertTrue(b.relativeAuto)
        assertEquals(a.fixedContentHeight, b.fixedContentHeight)
        assertEquals(0f, b.fixedContentHeight!!, 0f)
        assertEquals(a.contentWidth(200, ContainerWidths(40f, 100f)), b.contentWidth(200, ContainerWidths(40f, 100f)))
        assertEquals(a.horizontal!!(200, ContainerWidths(40f, 100f)), b.horizontal!!(200, ContainerWidths(40f, 100f)))
        val child = NativeFloatContextSpec.Child(17, { it }, 0f)
        val unavailable = prepare(relative, listOf(child))
        assertNotNull(unavailable.unavailableReason)
        assertSame(child, unavailable.preparedParts!!.single())
        for (unsupported in listOf(relative.copy(layout = ContainerLayout.FlexRow),
            relative.copy(floatSide = TableFloatSide.Left),
            relative.copy(columns = ContainerColumns(2, StyleLength(StyleLengthUnit.Px, 0f)))))
            assertNotNull(prepare(unsupported).unavailableReason)
        assertNotNull(prepare(relative, flex = true).unavailableReason)
    }

    @Test fun nestedPositionedGroupsCannotSilentlyUseTheOrdinaryPhase() {
        assertThrows(IllegalArgumentException::class.java) {
            nativeContextPaintSequence(listOf(NativePaintOrderNode(0, true,
                listOf(NativePaintOrderNode(1, true)))))
        }
    }
}
