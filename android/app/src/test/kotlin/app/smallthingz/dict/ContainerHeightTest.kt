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
    @Test fun documentHorizontalExtentKeepsContainingWidthAndActualOriginSide() {
        val signed = NativeFloatBounds(-25.25f, -900f, 160.5f, 900f)
        assertEquals(NativeDocumentHorizontalExtent(100, 60.5f, 61),
            nativeDocumentHorizontalExtent(100, signed, rtl = false))
        assertEquals(NativeDocumentHorizontalExtent(100, 25.25f, 26),
            nativeDocumentHorizontalExtent(100, signed, rtl = true))
        for (rtl in listOf(false, true)) {
            assertEquals(NativeDocumentHorizontalExtent(100, 0f, 0),
                nativeDocumentHorizontalExtent(100, null, rtl))
            assertEquals(NativeDocumentHorizontalExtent(100, 0f, 0),
                nativeDocumentHorizontalExtent(100, NativeFloatBounds(0f, -900f, 100f, 900f), rtl))
        }
        val leftOnly = NativeFloatBounds(-50f, 0f, 90f, 20f)
        val rightOnly = NativeFloatBounds(10f, 0f, 150f, 20f)
        assertEquals(NativeDocumentHorizontalExtent(100, 0f, 0),
            nativeDocumentHorizontalExtent(100, leftOnly, rtl = false))
        assertEquals(NativeDocumentHorizontalExtent(100, 50f, 50),
            nativeDocumentHorizontalExtent(100, leftOnly, rtl = true))
        assertEquals(NativeDocumentHorizontalExtent(100, 50f, 50),
            nativeDocumentHorizontalExtent(100, rightOnly, rtl = false))
        assertEquals(NativeDocumentHorizontalExtent(100, 0f, 0),
            nativeDocumentHorizontalExtent(100, rightOnly, rtl = true))
        // Late table publication changes the scroll allocation, never the width
        // supplied to original paragraph, percentage or containing-block layout.
        val before = nativeDocumentHorizontalExtent(100, NativeFloatBounds(-10f, 0f, 110f, 20f), false)
        val after = nativeDocumentHorizontalExtent(100, signed, false)
        assertEquals(10, before.range)
        assertEquals(61, after.range)
        assertEquals(before.viewportWidth, after.viewportWidth)
        assertEquals(100, after.viewportWidth)
        assertEquals(NativeDocumentHorizontalExtent(100, 60.5f, 61),
            nativeDocumentHorizontalExtent(100, NativeFloatBounds(-900f, -1200f, 160.5f, 1800f), false))
        assertEquals(NativeDocumentHorizontalExtent(100, 25.25f, 26),
            nativeDocumentHorizontalExtent(100, NativeFloatBounds(-25.25f, -1200f, 900f, 1800f), true))
    }

    @Test fun documentHorizontalRangeRoundsOnlyPublicationAndChecksWholeAllocation() {
        val next = java.lang.Math.nextUp(100f)
        assertEquals(NativeDocumentHorizontalExtent(100, next - 100f, 1),
            nativeDocumentHorizontalExtent(100, NativeFloatBounds(0f, 0f, next, 1f), false))
        assertEquals(NativeDocumentHorizontalExtent(100, 0f, 0),
            nativeDocumentHorizontalExtent(100, NativeFloatBounds(0f, 0f, java.lang.Math.nextDown(100f), 1f), false))
        assertEquals(NativeDocumentHorizontalExtent(100, Float.MIN_VALUE, 1),
            nativeDocumentHorizontalExtent(100, NativeFloatBounds(-Float.MIN_VALUE, 0f, 100f, 1f), true))
        val limit = TablePixelLimit.toFloat()
        assertEquals(NativeDocumentHorizontalExtent(TablePixelLimit, 0f, 0),
            nativeDocumentHorizontalExtent(TablePixelLimit, NativeFloatBounds(0f, 0f, limit, 1f), false))
        assertEquals(NativeDocumentHorizontalExtent(0, limit, TablePixelLimit),
            nativeDocumentHorizontalExtent(0, NativeFloatBounds(-limit, 0f, 0f, 1f), true))
        assertThrows(UnsupportedFloatLayout::class.java) {
            nativeDocumentHorizontalExtent(TablePixelLimit,
                NativeFloatBounds(0f, 0f, java.lang.Math.nextUp(limit), 1f), false)
        }
        assertThrows(UnsupportedFloatLayout::class.java) {
            nativeDocumentHorizontalExtent(1, NativeFloatBounds(-limit, 0f, 0f, 1f), true)
        }
        assertThrows(UnsupportedFloatLayout::class.java) {
            nativeDocumentHorizontalExtent(100, NativeFloatBounds(0f, 0f, Float.MAX_VALUE, 1f), false)
        }
        assertThrows(UnsupportedFloatLayout::class.java) {
            nativeDocumentHorizontalExtent(100, NativeFloatBounds(-Float.MAX_VALUE, 0f, 100f, 1f), true)
        }
        assertThrows(UnsupportedFloatLayout::class.java) { nativeDocumentHorizontalExtent(-1, null, false) }
        assertThrows(UnsupportedFloatLayout::class.java) { nativeDocumentHorizontalExtent(TablePixelLimit + 1, null, true) }
    }

    @Test fun documentScrollableVerticalExtentUsesLateBottomWithoutReanchoringSurfaceTop() {
        assertEquals(NativeDocumentVerticalExtent(0, 901),
            nativeDocumentScrollableVerticalExtent(0, NativeFloatBounds(-60f, -12f, 100f, 900.25f)))
        assertEquals(NativeDocumentVerticalExtent(0, 50),
            nativeDocumentScrollableVerticalExtent(50, NativeFloatBounds(-1000f, -1000f, 1000f, 20f)))
        assertEquals(NativeDocumentVerticalExtent(0, 0),
            nativeDocumentScrollableVerticalExtent(0, NativeFloatBounds(-50f, -100f, 100f, -20f)))
        assertEquals(NativeDocumentVerticalExtent(0, 51),
            nativeDocumentScrollableVerticalExtent(20, NativeFloatBounds(0f, 0f, 100f, java.lang.Math.nextUp(50f))))
        assertEquals(NativeDocumentVerticalExtent(0, TablePixelLimit),
            nativeDocumentScrollableVerticalExtent(0, NativeFloatBounds(0f, 0f, 100f, TablePixelLimit.toFloat())))
        assertThrows(UnsupportedFloatLayout::class.java) {
            nativeDocumentScrollableVerticalExtent(0,
                NativeFloatBounds(0f, 0f, 100f, java.lang.Math.nextUp(TablePixelLimit.toFloat())))
        }
        assertThrows(UnsupportedFloatLayout::class.java) {
            nativeDocumentScrollableVerticalExtent(TablePixelLimit + 1, NativeFloatBounds(0f, 0f, 0f, 0f))
        }
        // The pre-existing physical-surface allocator retains its old signed-top contract.
        assertEquals(NativeDocumentVerticalExtent(12, 913), nativeDocumentVerticalExtent(0, -12, 901))
    }

}
