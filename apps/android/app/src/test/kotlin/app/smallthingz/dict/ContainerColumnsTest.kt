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
    @Test fun preferredColumnWidthUsesActualContentThresholdAndAuthoredCountCap() {
        val auto = NativeColumnPolicy(null, 10.5f, false, 100.25f, 1.5f)
        assertEquals(1, auto.resolve(java.lang.Math.nextDown(211f)).count)
        val exact = auto.resolve(211f)
        assertEquals(2, exact.count)
        assertEquals(100.25f, exact.width, 0f)
        assertEquals(0f, exact.left(0, 211f), 0f)
        assertEquals(110.75f, exact.left(1, 211f), 0f)
        val widened = auto.resolve(400.5f)
        assertEquals(3, widened.count)
        assertEquals(126.5f, widened.width, 0f)
        assertEquals(274f, widened.left(2, 400.5f), 0f)
        val rtl = auto.copy(rtl = true).resolve(400.5f)
        assertEquals(274f, rtl.left(0, 400.5f), 0f)
        assertEquals(137f, rtl.left(1, 400.5f), 0f)
        assertEquals(0f, rtl.left(2, 400.5f), 0f)
        val capped = auto.copy(count = 2).resolve(400.5f)
        assertEquals(2, capped.count)
        assertEquals(195f, capped.width, 0f)
        assertEquals(1, auto.copy(count = 2).resolve(60.5f).count)
        assertEquals(60.5f, auto.resolve(60.5f).width, 0f)
        assertEquals(1, auto.resolve(0f).count)
        assertEquals(0f, auto.resolve(0f).width, 0f)
        // Source width remains a preference. A fixed count has its independent equal-width policy.
        assertEquals(126.5f, NativeColumnPolicy(3, 10.5f, false).resolve(400.5f).width, 0f)
        assertEquals(100.25f, auto.preferredWidth!!, 0f)
    }

    @Test fun columnIntrinsicsRemainIndependentOfAllocationAndUsedZeroFloor() {
        val content = ContainerWidths(20.25f, 80.5f)
        val auto = NativeColumnPolicy(null, 7.5f, false, 50.25f, 2f)
        assertEquals(ContainerWidths(20.25f, 80.5f), auto.intrinsic(content))
        assertEquals(ContainerWidths(10.25f, 80.5f), auto.copy(preferredWidth = 10.25f).intrinsic(content))
        val capped = auto.copy(count = 3)
        assertEquals(ContainerWidths(20.25f, 256.5f), capped.intrinsic(content))
        assertEquals(ContainerWidths(20.25f, 316.5f), capped.copy(preferredWidth = 100.5f).intrinsic(content))
        assertEquals(ContainerWidths(75.75f, 256.5f), NativeColumnPolicy(3, 7.5f, false).intrinsic(content))
        for (width in listOf(0f, 40f, 500f, 2000f)) {
            auto.resolve(width)
            assertEquals(ContainerWidths(20.25f, 80.5f), auto.intrinsic(content))
        }
        val zero = NativeColumnPolicy(null, 0f, false, 0f, 2f)
        assertEquals(ContainerWidths(0f, 80.5f), zero.intrinsic(content))
        assertEquals(2, zero.resolve(5.75f).count)
        assertEquals(2.875f, zero.resolve(5.75f).width, 0f)
        assertEquals(0f, zero.preferredWidth!!, 0f)
        assertEquals(ContainerWidths(0f, 0f), zero.intrinsic(ContainerWidths(0f, 0f)))
        assertEquals(ContainerWidths(0f, 50.25f), auto.intrinsic(ContainerWidths(0f, 0f)))
        assertEquals(ContainerWidths(0f, 165.75f), capped.intrinsic(ContainerWidths(0f, 0f)))
    }

    @Test fun derivedColumnCountCanExceedWireCountWithoutAllocatingEmptyColumns() {
        val policy = NativeColumnPolicy(null, 0f, true, 0f, .25f)
        val actual = policy.resolve(32760f)
        assertEquals(131040, actual.count)
        assertEquals(.25f, actual.width, 0f)
        assertEquals(32759.75f, actual.left(0, 32760f), 0f)
        assertEquals(0f, actual.left(actual.count - 1, 32760f), 0f)
        val lines = List(3) { NativeColumnLine(it, 0, 1f) }
        val balanced = balanceNativeColumns(lines, actual.count)
        assertEquals(3, balanced.placements.size)
        assertEquals(listOf(0, 1, 2, 3), balanced.breaks)
        assertEquals(1f, balanced.height, 0f)
        assertEquals(NativeColumnBalance(emptyList(), 0f, emptyList()), balanceNativeColumns(emptyList(), actual.count))
        assertEquals(65535, policy.copy(count = 65535).resolve(32760f).count)
        assertThrows(UnsupportedFloatLayout::class.java) { policy.copy(minimumWidthPixels = 0.0000001f).resolve(32760f) }
        assertEquals(2, policy.copy(count = 2, minimumWidthPixels = 0.0000001f).resolve(32760f).count)
    }

    @Test fun sourceOwnerBreakAvoidRaisesBalanceHeightWithoutDroppingOrReorderingLines() {
        val ordinary = List(8) { NativeColumnLine(0, it, 10f) } +
            listOf(NativeColumnLine(1, 0, 10f), NativeColumnLine(2, 0, 10f))
        val split = balanceNativeColumns(ordinary, 2)
        assertEquals(50f, split.height, 0f)
        assertEquals(listOf(0, 5, 10), split.breaks)
        val avoid = ordinary.map { if (it.owner == 0) it.copy(keepTogether = true) else it }
        val whole = balanceNativeColumns(avoid, 2)
        assertEquals(80f, whole.height, 0f)
        assertEquals(listOf(0, 8, 10), whole.breaks)
        assertEquals(List(8) { 0 } + listOf(1, 1), whole.placements.map { it.column })
        assertEquals(List(8) { it * 10f } + listOf(0f, 10f), whole.placements.map { it.top })
        assertEquals(split, balanceNativeColumns(avoid.map { it.copy(keepTogether = false) }, 2))
        // Auto height has no arbitrary cap: even many available columns keep this source owner whole.
        assertEquals(80f, balanceNativeColumns(avoid.take(8), 65536).height, 0f)
        assertEquals(listOf(0, 8), balanceNativeColumns(avoid.take(8), 65536).breaks)
        assertEquals(0f, balanceNativeColumns(avoid.take(8).map { it.copy(height = 0f) }, 3).height, 0f)
        assertThrows(IllegalArgumentException::class.java) {
            balanceNativeColumns(avoid.toMutableList().apply { this[1] = this[1].copy(keepTogether = false) }, 2)
        }

        // Enumerate every partition independently. Owner avoidance and widow/orphan rules
        // constrain legal source cuts; the oracle does not reuse the balancing queue.
        fun exhaustive(lines: List<NativeColumnLine>, count: Int): Float {
            var best = Float.POSITIVE_INFINITY
            for (mask in 0 until (1 shl (lines.size - 1))) {
                val cuts = listOf(0) + (1 until lines.size).filter { mask and (1 shl (it - 1)) != 0 } + lines.size
                if (cuts.size - 1 > count) continue
                var legal = true
                for (cut in cuts.drop(1).dropLast(1)) {
                    if (lines[cut - 1].owner != lines[cut].owner) continue
                    val owner = lines[cut].owner
                    if (lines[cut].keepTogether || lines.take(cut).count { it.owner == owner } < 2 ||
                        lines.drop(cut).count { it.owner == owner } < 2) legal = false
                }
                if (!legal) continue
                var largest = 0f
                for ((a, b) in cuts.zipWithNext()) {
                    val first = lines[a].owner
                    val last = lines[b - 1].owner
                    if (a > 0 && lines[a - 1].owner == first && (a until b).takeWhile { lines[it].owner == first }.size < 2 ||
                        b < lines.size && lines[b].owner == last && (a until b).reversed().takeWhile { lines[it].owner == last }.size < 2)
                        legal = false
                    var height = 0f
                    for (i in a until b) height += lines[i].height + if (i == a) 0f else lines[i].gapBefore
                    largest = maxOf(largest, height)
                }
                if (legal) best = minOf(best, largest)
            }
            return best
        }
        for (policy in 0..3) for (sizePattern in 0..7) {
            val lines = List(8) { at ->
                val owner = if (at < 4) 0 else 1
                NativeColumnLine(owner, at % 4, if (sizePattern and (1 shl (at % 3)) == 0) .75f else 2.25f,
                    if (at == 4) 3.5f else 0f, keepTogether = policy and (1 shl owner) != 0)
            }
            for (count in 1..4) {
                val result = balanceNativeColumns(lines, count)
                assertEquals("policy=$policy sizes=$sizePattern count=$count", exhaustive(lines, count), result.height, .0001f)
                assertEquals(lines.size, result.placements.size)
                for (owner in 0..1) if (policy and (1 shl owner) != 0)
                    assertEquals(1, lines.indices.filter { lines[it].owner == owner }.map { result.placements[it].column }.distinct().size)
            }
        }
    }

}
