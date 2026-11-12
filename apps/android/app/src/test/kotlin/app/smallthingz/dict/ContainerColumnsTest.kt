package app.smallthingz.dict

import java.io.ByteArrayOutputStream
import org.junit.Assert.*
import org.junit.Test

class ContainerColumnsTest {
    private class Wire {
        val out = ByteArrayOutputStream()
        fun byte(v: Int) { out.write(v) }
        fun short(v: Int) { byte(v); byte(v ushr 8) }
        fun int(v: Int) { repeat(4) { byte(v ushr (8 * it)) } }
        fun text(v: String) { val b = v.encodeToByteArray(); int(b.size); out.write(b) }
    }
    private fun frame(count: Int? = null, gap: Float = .9f, version: Int = 77,
        flags: Int = if (count == null) 0 else 0x40000, unit: Int = 1) = Wire().run {
        byte(68); byte(80); byte(82); byte(version); int(0)
        int(1); byte(2); text("Controlled"); text(""); text(""); int(1)
        byte(13); byte(0); byte(0); int(0)
        byte(0); text(""); text(""); byte(0); text(""); text(""); repeat(4) { byte(0) }
        if (version == 77) int(flags) else short(flags)
        if (flags and 0x10000 != 0) int(.9f.toRawBits())
        if (flags and 0x20000 != 0) { byte(0); int(0) }
        if (count != null) { short(count); byte(unit); int(gap.toRawBits()) }
        int(0); int(0); int(0); int(1); int(0); int(0); int(0)
        out.toByteArray()
    }
    private fun decode(bytes: ByteArray) = BlobDecoder.decode(bytes, "columns", "language", "English", "en")

    @Test fun mColumnsTailPreservesOldAbsenceAndStrictFraming() {
        fun style(bytes: ByteArray) = decode(bytes).sections.single().blocks.single().container!!.style
        assertNull(style(frame()).columns)
        assertEquals(decode(frame()).sections, decode(frame(version = 76)).sections)
        val value = style(frame(2, flags = 0x70000))
        assertEquals(.9f, value.ownerFontScale!!, 0f)
        assertEquals(StyleLength(StyleLengthUnit.Px, 0f), value.height)
        assertEquals(ContainerColumns(2, StyleLength(StyleLengthUnit.Em, .9f)), value.columns)
        assertEquals(ContainerColumns(1, StyleLength(StyleLengthUnit.Px, 0f)), style(frame(1, 0f, unit = 0)).columns)
        assertThrows(Exception::class.java) { decode(frame(2).also { it[3] = 76 }) }
        assertThrows(Exception::class.java) { decode(frame(flags = 0x400000)) }
        assertThrows(Exception::class.java) { decode(frame(0)) }
        for (gap in listOf(-1f, Float.NaN, Float.POSITIVE_INFINITY))
            assertThrows(Exception::class.java) { decode(frame(2, gap)) }
        assertThrows(Exception::class.java) { decode(frame(2, unit = 2)) }
        val complete = frame(2)
        for (length in complete.indices) assertThrows(Exception::class.java) { decode(complete.copyOf(length)) }
        assertThrows(Exception::class.java) { decode(complete + byteArrayOf(0)) }
    }

    @Test fun balanceSplitsOneParagraphByNativeLinesAndKeepsWidowsAndOrphans() {
        val eight = List(8) { NativeColumnLine(0, it, 10f) }
        val balanced = balanceNativeColumns(eight, 2)
        assertEquals(listOf(0, 4, 8), balanced.breaks)
        assertEquals(40f, balanced.height, 0f)
        assertEquals(listOf(0f, 10f, 20f, 30f, 0f, 10f, 20f, 30f), balanced.placements.map { it.top })
        assertEquals(30f, balanceNativeColumns(eight.take(3), 2).height, 0f)
        assertEquals(listOf(0, 2, 4, 6), balanceNativeColumns(eight.take(6), 3).breaks)
        val mixed = listOf(NativeColumnLine(0, 0, 6f)) + List(4) { NativeColumnLine(1, it, 10f) } +
            listOf(NativeColumnLine(2, 0, 6f))
        val result = balanceNativeColumns(mixed, 2)
        assertEquals(listOf(0, 3, 6), result.breaks)
        assertEquals(26f, result.height, 0f)
    }

    @Test fun fractionalAndZeroUsedLinesProgressBySourceIndexWithoutInventingHeight() {
        val result = balanceNativeColumns(List(6) { NativeColumnLine(0, it, .5f) }, 3)
        assertEquals(1f, result.height, 0f)
        assertEquals(listOf(0, 2, 4, 6), result.breaks)
        val zero = balanceNativeColumns(List(8) { NativeColumnLine(0, it, 0f) }, 2)
        assertEquals(0f, zero.height, 0f)
        assertEquals(8, zero.placements.size)
        assertEquals(listOf(0, 8), zero.breaks)
        assertEquals(NativeColumnBalance(emptyList(), 0f, emptyList()), balanceNativeColumns(emptyList(), 2))
        val gap = balanceNativeColumns(listOf(NativeColumnLine(0, 0, 10f),
            NativeColumnLine(1, 0, 10f, 40f)), 2)
        assertEquals(10f, gap.height, 0f)
        assertEquals(listOf(0f, 0f), gap.placements.map { it.top })
    }

    @Test fun columnInlineSizingKeepsFractionalOriginsZeroWidthsAndIntrinsicTableFloor() {
        val ltr = NativeColumnPolicy(2, 9f, false)
        assertEquals(45.75f, ltr.width(100.5f), 0f)
        assertEquals(54.75f, ltr.left(1, 100.5f), 0f)
        val rtl = ltr.copy(rtl = true)
        assertEquals(54.75f, rtl.left(0, 100.5f), 0f)
        assertEquals(0f, rtl.left(1, 100.5f), 0f)
        assertEquals(0f, ltr.width(0f), 0f)
        assertEquals(9f, ltr.left(1, 0f), 0f)
        assertEquals(-9f, rtl.left(1, 0f), 0f)
        assertEquals(69f, ltr.intrinsic(30f), 0f)
        assertEquals(189f, ltr.intrinsic(90f), 0f)
        assertTrue(ContainerStyle(columns = ContainerColumns(1, StyleLength(StyleLengthUnit.Px, 0f)))
            .atViewport(400f).ownsFormattingContext)
    }

    @Test fun balancingMatchesExhaustiveLegalBreaksForMixedLineSizes() {
        // Independent exhaustive partition oracle for a small mixed-paragraph domain.
        fun brute(lines: List<NativeColumnLine>, count: Int): Float {
            var best = Float.POSITIVE_INFINITY
            fun visit(start: Int, columns: Int, maximum: Float) {
                if (start == lines.size) { best = minOf(best, maximum); return }
                if (columns == count) return
                var height = 0f
                for (end in start + 1..lines.size) {
                    height += lines[end - 1].height + if (end - 1 == start) 0f else lines[end - 1].gapBefore
                    val firstOwner = lines[start].owner
                    val lastOwner = lines[end - 1].owner
                    val headCount = (start until end).takeWhile { lines[it].owner == firstOwner }.size
                    val tailCount = (start until end).reversed().takeWhile { lines[it].owner == lastOwner }.size
                    val startsInside = start > 0 && lines[start - 1].owner == firstOwner
                    val endsInside = end < lines.size && lines[end].owner == lastOwner
                    if (startsInside && headCount < 2 || endsInside && tailCount < 2) continue
                    if (endsInside && lines.drop(end).takeWhile { it.owner == lastOwner }.size < 2) continue
                    visit(end, columns + 1, maxOf(maximum, height))
                }
            }
            visit(0, 0, 0f)
            return best
        }
        for (mask in 0 until 64) {
            val lines = List(6) { NativeColumnLine(if (it < 4) 0 else 1, if (it < 4) it else it - 4,
                if (mask and (1 shl it) == 0) .5f else 2f, if (it == 4) 1.25f else 0f) }
            for (count in 1..3) assertEquals("mask=$mask columns=$count", brute(lines, count),
                balanceNativeColumns(lines, count).height, .0001f)
        }
    }

    @Test fun unsupportedAtomicChildrenAndOwnerCombinationsRetainTheOriginalFallbackBody() {
        val child = NativeFloatContextSpec.Child(42, { it }, 0f)
        val columns = ContainerColumns(2, StyleLength(StyleLengthUnit.Em, .9f))
        val style = ContainerStyle(columns = columns)
        val result = nativeContainerSpec(7, style.atViewport(500f), listOf(child), 1f, 20f,
            rtl = false, dark = false, flexItem = false)
        assertNotNull(result.unavailableReason)
        assertSame(child, result.preparedParts!!.single())
        for (unsupported in listOf(style.copy(height = StyleLength(StyleLengthUnit.Px, 0f)),
            style.copy(layout = ContainerLayout.FlexRow), style.copy(overflow = ContainerOverflow.Auto))) {
            assertNotNull(nativeContainerSpec(7, unsupported.atViewport(500f), listOf(child), 1f, 20f,
                rtl = false, dark = false, flexItem = false).unavailableReason)
        }
    }
}
