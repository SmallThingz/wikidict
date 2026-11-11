package app.smallthingz.dict

import java.io.ByteArrayOutputStream
import org.junit.Assert.*
import org.junit.Test

class ContainerHeightTest {
    private fun px(value: Float) = StyleLength(StyleLengthUnit.Px, value)
    private class Wire {
        val out = ByteArrayOutputStream()
        fun byte(v: Int) { out.write(v) }
        fun int(v: Int) { repeat(4) { byte(v ushr (8 * it)) } }
        fun text(v: String) { val b = v.encodeToByteArray(); int(b.size); out.write(b) }
    }
    private fun frame(height: Float? = null, version: Int = 77, flags: Int = if (height == null) 0 else 0x20000,
        unit: Int = 0) = Wire().run {
        byte(68); byte(80); byte(82); byte(version); int(0)
        int(1); byte(2); text("Controlled"); text(""); text(""); int(1)
        byte(13); byte(0); byte(0); int(0)
        byte(0); text(""); text(""); byte(0); text(""); text(""); repeat(4) { byte(0) }
        if (version == 77) int(flags) else { byte(flags); byte(flags ushr 8) }
        if (flags and 0x10000 != 0) int(.9f.toRawBits())
        if (height != null) { byte(unit); int(height.toRawBits()) }
        int(0); int(0); int(0); int(1); int(0); int(0); int(0)
        out.toByteArray()
    }
    private fun decode(bytes: ByteArray) = BlobDecoder.decode(bytes, "height", "language", "English", "en")

    @Test fun mHeightTailPreservesAbsentAndZeroAndRefusesUnknownOrMalformedFields() {
        fun style(bytes: ByteArray) = decode(bytes).sections.single().blocks.single().container!!.style
        assertNull(style(frame()).height)
        assertEquals(decode(frame()).sections, decode(frame(version = 76)).sections)
        assertEquals(px(0f), style(frame(0f)).height)
        val paired = style(frame(1.44f, flags = 0x30000, unit = 1))
        assertEquals(.9f, paired.ownerFontScale!!, 0f)
        assertEquals(StyleLength(StyleLengthUnit.Em, 1.44f), paired.height)
        assertThrows(Exception::class.java) { decode(frame(0f).also { it[3] = 76 }) }
        assertThrows(Exception::class.java) { decode(frame(flags = 0x40000)) }
        for (value in listOf(-1f, Float.NaN, Float.POSITIVE_INFINITY))
            assertThrows(Exception::class.java) { decode(frame(value)) }
        assertThrows(Exception::class.java) { decode(frame(1f, unit = 2)) }
        val complete = frame(0f)
        for (length in complete.indices) assertThrows(Exception::class.java) { decode(complete.copyOf(length)) }
    }

    @Test fun contentAndBorderHeightUseBodyEmOnceAndKeepEdgesOutsideExplicitZero() {
        assertNull(containerUsedHeight(ContainerStyle(), 6f, 2f, 20f))
        val style = ContainerStyle(ownerFontScale = .9f, height = StyleLength(StyleLengthUnit.Em, 1.44f))
        assertEquals(28.8f, containerUsedHeight(style, 6f, 2f, 20f)!!.content, .0001f)
        assertEquals(34.8f, containerUsedHeight(style, 6f, 2f, 20f)!!.border, .0001f)
        assertEquals(NativeContainerHeight(0f, 6f), containerUsedHeight(style.copy(height = px(0f)), 6f, 2f, 20f))
        assertEquals(NativeContainerHeight(0f, 6f), containerUsedHeight(style.copy(height = px(2f),
            boxSizing = ContainerBoxSizing.BorderBox), 6f, 2f, 20f))
        assertEquals(NativeContainerHeight(14f, 20f), containerUsedHeight(style.copy(height = px(10f),
            boxSizing = ContainerBoxSizing.BorderBox), 6f, 2f, 20f))
        assertThrows(UnsupportedFloatLayout::class.java) {
            containerUsedHeight(style.copy(height = px(Float.MAX_VALUE)), 6f, 2f, 20f)
        }
    }

    @Test fun definiteHeightKeepsTopAdjacencyButBlocksBottomEscapeAndOnlyZeroMayBeThrough() {
        fun group(id: Int, height: Float?, children: List<NativeFloatContextPart>, margins: FloatMargins) =
            NativeFloatContextPart.Container(id, 100, { _, _ -> error("No measurement in structural query") },
                margins = margins, preparedParts = children, fixedContentHeight = height)
        val child = group(1, null, emptyList(), FloatMargins(10f, 0f, 20f, 0f))
        fun profile(height: Float?) = checkNotNull(NativeFloatContextGeometry.adjoiningProfile(
            group(2, height, listOf(child), FloatMargins(3f, 0f, 7f, 0f))))
        assertEquals(NativeAdjoiningMargins(20f, 20f, true), profile(null))
        assertEquals(NativeAdjoiningMargins(20f, 7f, true), profile(0f))
        assertEquals(NativeAdjoiningMargins(20f, 7f, false), profile(1f))
        val nonempty = NativeFloatContextPart.Child(3, NativeBlockWidth.FixedPx(10f),
            { error("No measurement in structural query") })
        assertFalse(checkNotNull(NativeFloatContextGeometry.adjoiningProfile(
            group(4, 0f, listOf(nonempty), FloatMargins(0f, 0f, 0f, 0f)))).through)
    }

    @Test fun definiteFlexCrossSizeKeepsSignedAlignmentAndAutoStretchRespectsBorderFloor() {
        val none = NativeFlexCrossMargins()
        assertEquals(NativeFlexCrossPlacement(-10f, 30f), nativeFlexCrossPlacement(10f, 30f, 0f, 0f,
            none, ContainerAlignItems.Center, definiteHeight = true))
        assertEquals(NativeFlexCrossPlacement(-20f, 30f), nativeFlexCrossPlacement(10f, 30f, 0f, 0f,
            none, ContainerAlignItems.End, definiteHeight = true))
        assertEquals(NativeFlexCrossPlacement(0f, 30f), nativeFlexCrossPlacement(60f, 30f, 0f, 0f,
            none, ContainerAlignItems.Stretch, definiteHeight = true))
        assertEquals(NativeFlexCrossPlacement(0f, 6f), nativeFlexCrossPlacement(0f, 30f, 0f, 0f,
            none, ContainerAlignItems.Stretch, minimumBorderHeight = 6f))
        assertEquals(NativeFlexCrossPlacement(0f, 30f), nativeFlexCrossPlacement(10f, 30f, 0f, 0f,
            NativeFlexCrossMargins(true, true), ContainerAlignItems.Center, definiteHeight = true))
    }

    @Test fun documentAllocationIncludesSignedOverflowWithoutChangingAnyUsedBox() {
        assertEquals(NativeDocumentVerticalExtent(12, 912), nativeDocumentVerticalExtent(0, -12, 900))
        assertEquals(NativeDocumentVerticalExtent(0, 900), nativeDocumentVerticalExtent(30, 0, 900))
        assertEquals(NativeDocumentVerticalExtent(0, 50), nativeDocumentVerticalExtent(50, 5, 20))
        assertThrows(UnsupportedFloatLayout::class.java) { nativeDocumentVerticalExtent(0, Int.MIN_VALUE, 10) }
    }
}
