package app.smallthingz.dict

import java.io.ByteArrayOutputStream
import org.junit.Assert.*
import org.junit.Test

/** Literal Rule-clear DPRR controls; no encoder, source reconstruction or runtime supplies the bytes. */
class RuleClearCodecTest {
    private enum class Owner { Section, Container, Cell, NestedTable, Reference, TableCaption, FigureCaption, FlowFigure, ScopeFigure }
    private class Wire(
        private val marker: Int = 2,
        private val clear: Int = 2,
        private val intrinsic: Boolean = false,
        private val corners: Boolean = false,
        private val ruleKind: Int = 11,
        private val alignment: Int? = null,
    ) {
        private val out = ByteArrayOutputStream()
        val at = linkedMapOf<String, Int>()
        private fun byte(value: Int) { out.write(value) }
        private fun u16(value: Int) { byte(value); byte(value ushr 8) }
        private fun u32(value: Int) { repeat(4) { byte(value ushr (it * 8)) } }
        private fun f32(value: Float) = u32(value.toRawBits())
        private fun string(value: String) { val bytes = value.encodeToByteArray(); u32(bytes.size); out.write(bytes) }
        private fun mark(name: String) { check(at.put(name, out.size()) == null) }
        private fun length(value: Float = 0f, unit: Int = 0) { byte(unit); f32(value) }
        private fun span(text: String, target: String, trail: String = "s") {
            byte(1); byte(0); byte(1); string(text); string(target); string(trail)
            string("th"); repeat(3) { string("") }
            byte(1); string("#123456"); byte(0); byte(0); byte(0)
            byte(1); string("part"); byte(1); string("advice")
        }
        private fun prefix(kind: Int, label: String? = null, name: String? = null) {
            if (name != null) mark(name + "Start")
            byte(kind); if (name != null) mark(name + "Depth")
            byte(0); if (name != null) mark(name + "Level")
            byte(0); u32(if (label == null) 0 else 1)
            if (label != null) span(label, label.lowercase() + "-target")
            byte(0); string(""); string("")
        }
        private fun tail(name: String? = null) {
            string(""); string(""); byte(if (name != null && alignment != null) 1 else 0)
            if (name != null && alignment != null) byte(alignment)
            byte(0); byte(0); byte(0)
        }
        private fun paragraph(label: String) { prefix(0, label); byte(0); tail() }
        private fun rule(name: String, selectedMarker: Int) {
            prefix(if (name == "main") ruleKind else 11, name = name); byte(0); tail(if (name == "main") name else null)
            mark(name + "Marker"); byte(selectedMarker)
            if (selectedMarker != 0) {
                mark(name + "HeightUnit"); byte(0); mark(name + "Height"); f32(1.25f)
                mark(name + "Fill"); byte(2); string("#123456"); string("#abcdef")
                for ((edge, value, unit) in listOf(Triple("Top", .2f, 1), Triple("Right", 2f, 0),
                    Triple("Bottom", .3f, 1), Triple("Left", 4f, 0))) {
                    mark(name + edge + "Unit"); byte(unit); mark(name + edge); f32(value)
                }
                mark(name + "LegacyEnd")
                if (selectedMarker == 2) { mark(name + "Clear"); byte(clear) }
            }
            mark(name + "End")
        }
        private fun body() {
            paragraph("Before"); rule("main", marker); rule("legacy", 1); rule("absent", 0); paragraph("After")
        }
        private fun bodyList() { u32(5); body() }
        private fun table(caption: Boolean = false, nested: Boolean = false) {
            byte(1); byte(0); u32(0); u32(if (caption) 0 else 1)
            if (!caption) {
                u32(1); byte(0); u16(1); u16(1); byte(0); u32(0)
                if (nested) { table(); byte(0) } else { byte(0); byte(1); bodyList() }
                byte(1); byte(4); byte(2)
            }
            byte(1); byte(1); byte(0); string("#445566")
            byte(if (caption) 1 else 0); if (caption) bodyList()
        }
        private fun figure() {
            byte(2); byte(0); byte(0); byte(0)
            repeat(12) { length() }; f32(1f); length(18f)
            byte(1); byte(0); byte(1); byte(0); byte(0); byte(1)
            span("Missing image", "File:Missing.svg", trail = "")
            length(40f); length(18f); byte(0)
            u32(0); byte(1); bodyList(); byte(0); byte(0)
        }
        private fun root(owner: Owner) {
            val count = if (owner == Owner.Section) 5 else if (owner == Owner.Reference) 0 else 1
            u32(count + (if (intrinsic) 1 else 0) + (if (corners) 1 else 0))
            when (owner) {
                Owner.Section -> body()
                Owner.Container -> { prefix(13); byte(0); tail(); u32(0); bodyList() }
                Owner.Cell, Owner.NestedTable, Owner.TableCaption -> {
                    prefix(12); table(owner == Owner.TableCaption, owner == Owner.NestedTable); tail()
                }
                Owner.FigureCaption -> { prefix(0); byte(0); string(""); string(""); byte(0); byte(0); figure(); byte(0) }
                Owner.FlowFigure, Owner.ScopeFigure -> {
                    prefix(0); byte(0); string(""); string(""); byte(0); byte(0); byte(0); byte(1); u32(1)
                    if (owner == Owner.ScopeFigure) { byte(2); byte(0); byte(2); byte(1); byte(1); string("th"); u32(1) }
                    byte(1); figure()
                }
                Owner.Reference -> Unit
            }
            if (intrinsic) intrinsicTable()
            if (corners) cornerTable()
        }
        private fun tableStyle(flags: Int) {
            byte(1); byte(flags); byte(0)
            if (flags and 2 != 0) { byte(1); length(1f); string("#aaaaaa") }
            if (flags and 4 != 0) byte(1)
            if (flags and 8 != 0) repeat(4) { length() }
        }
        private fun intrinsicTable() {
            prefix(12); mark("IntrinsicStart"); byte(19); byte(7); u16(1); u16(0); u16(4)
            u32(1); span("Table caption", "table-caption-target")
            u32(1); u32(1); byte(1); u16(1); u16(1); byte(0)
            u32(1); span("Table body", "table-body-target"); byte(0); byte(0); byte(0)
            tableStyle(14); byte(0)
            u32(639); tableStyle(10); byte(1); byte(2); f32(100f); tableStyle(4)
            byte(0); string("ku"); mark("IntrinsicDirection"); byte(1); byte(1); byte(0)
            mark("IntrinsicEnd"); tail()
        }
        private fun cornerTable() {
            prefix(12); byte(1); byte(0); u32(0); u32(0)
            byte(1); byte(6); byte(32); byte(0); byte(0)
            listOf(8f, 8f, 8f, 0f).forEach { length(it) }
            byte(0); tail()
        }
        fun document(owner: Owner = Owner.Section, version: Char = 'R', features: Int = 0): ByteArray {
            out.write(byteArrayOf(68, 80, 82, version.code.toByte())); u32(0); u32(1)
            byte(2); string("Body"); string(""); string(""); root(owner)
            u32(0); u32(0); u32(0)
            u32(if (owner == Owner.Reference) 1 else 0)
            if (owner == Owner.Reference) { byte(1); u32(1); string(""); u32(0); byte(1); bodyList() }
            u32(0)
            if (version >= 'P') { mark("Features"); byte(features) }
            return out.toByteArray()
        }
        fun blockBytes(bytes: ByteArray, name: String) = bytes.copyOfRange(at.getValue(name + "Start"), at.getValue(name + "End"))
        fun intrinsicBytes(bytes: ByteArray) = bytes.copyOfRange(at.getValue("IntrinsicStart"), at.getValue("IntrinsicEnd"))
    }
    private fun read(bytes: ByteArray) = BlobDecoder.decode(bytes, "Rule clear", "supplemental", null, "th")
    private fun ownedBlocks(entry: Entry, owner: Owner = Owner.Section): List<Block> {
        if (owner == Owner.Reference) return entry.references.single().blocks!!
        val roots = entry.sections.single().blocks
        if (owner == Owner.Section) return roots.take(5)
        val block = roots.first()
        return when (owner) {
            Owner.Container -> block.container!!.blocks
            Owner.Cell -> block.table!!.rows.single().single().blocks!!
            Owner.NestedTable -> block.table!!.rows.single().single().nestedTable!!.rows.single().single().blocks!!
            Owner.TableCaption -> block.table!!.captionBlocks!!
            Owner.FigureCaption -> block.figure!!.captionBlocks!!
            Owner.FlowFigure -> (block.flow!!.single() as FlowPart.ImageFigure).figure.captionBlocks!!
            Owner.ScopeFigure -> ((block.flow!!.single() as FlowPart.Scope).scope.parts.single() as FlowPart.ImageFigure).figure.captionBlocks!!
            else -> error("Handled above")
        }
    }
    private fun expected(clear: FigureClear?) = RuleStyle(StyleLength(StyleLengthUnit.Px, 1.25f),
        ContainerColor.LightDark("#123456", "#abcdef"),
        StyleEdges(StyleLength(StyleLengthUnit.Em, .2f), StyleLength(StyleLengthUnit.Px, 2f),
            StyleLength(StyleLengthUnit.Em, .3f), StyleLength(StyleLengthUnit.Px, 4f)), clear)
    private fun changed(bytes: ByteArray, offset: Int, value: Int) = bytes.copyOf().also { it[offset] = value.toByte() }
    private fun changed32(bytes: ByteArray, offset: Int, value: Int) = bytes.copyOf().also { copy ->
        repeat(4) { copy[offset + it] = (value ushr (it * 8)).toByte() }
    }
    private fun bad(bytes: ByteArray) { assertTrue("Malformed literal payload was accepted", runCatching { read(bytes) }.isFailure) }

    @Test fun fourPhysicalClearValuesRetainRuleMetricsAndAdjacentActionsWithoutPFeatures() {
        for (clear in FigureClear.entries) {
            val wire = Wire(clear = clear.ordinal); val bytes = wire.document(); val entry = read(bytes)
            val body = ownedBlocks(entry)
            assertArrayEquals(byteArrayOf(68, 80, 82, 82), bytes.copyOf(4))
            assertEquals(0, bytes.last().toInt()); assertNull(entry.bodyAdjoining)
            assertEquals(2, bytes[wire.at.getValue("mainMarker")].toInt())
            assertEquals(wire.at.getValue("mainLegacyEnd"), wire.at.getValue("mainClear"))
            assertEquals(wire.at.getValue("mainClear") + 1, wire.at.getValue("mainEnd"))
            assertEquals(expected(clear), body[1].ruleStyle)
            assertEquals(expected(null), body[2].ruleStyle); assertNull(body[3].ruleStyle)
            assertEquals(listOf("paragraph", "rule", "rule", "rule", "paragraph"), body.map { it.kind })
            val before = body.first().spans.single(); val after = body.last().spans.single()
            assertEquals(listOf("Before", "After"), listOf(before.text, after.text))
            assertEquals(listOf("before-target", "after-target"), listOf(before.target, after.target))
            assertEquals("part", before.targetFragment); assertEquals("advice", after.tooltip)
            assertEquals("s", before.trail); assertTrue(after.bold)
        }
        assertNotEquals(expected(null), expected(FigureClear.None))
    }

    @Test fun clearCensusReachesContainersCellsReferencesRichCaptionsAndFigureFlows() {
        for (owner in Owner.entries) {
            val wire = Wire(clear = 0); val bytes = wire.document(owner); val entry = read(bytes)
            val blocks = ownedBlocks(entry, owner)
            assertEquals(owner.name, expected(FigureClear.None), blocks[1].ruleStyle)
            assertEquals("before-target", blocks.first().spans.single().target)
            assertEquals("after-target", blocks.last().spans.single().target)
            assertNull(blocks[2].ruleStyle!!.clear); assertNull(blocks[3].ruleStyle)
            for (header in listOf('N', 'O', 'P', 'Q')) {
                val oldFrame = Wire(clear = 0, corners = header == 'Q').document(owner, version = header,
                    features = if (header == 'P') 1 else 0)
                val failure = assertThrows(IllegalArgumentException::class.java) { read(oldFrame) }
                assertEquals("Invalid rule style marker", failure.message)
            }
            bad(changed(bytes, 3, 'M'.code))
            if (owner in listOf(Owner.Cell, Owner.NestedTable, Owner.TableCaption))
                assertEquals("#445566", entry.sections.single().blocks.single().table!!.style!!.background)
            if (owner == Owner.Cell)
                assertEquals(CellTextAlign.Right, entry.sections.single().blocks.single().table!!.rows.single().single().style!!.textAlign)
        }
    }

    @Test fun nullRuleStylesKeepEveryLegacyBlockByteAcrossNOPQAndR() {
        val nWire = Wire(marker = 1); val n = nWire.document(version = 'N')
        val oWire = Wire(marker = 1); val o = oWire.document(version = 'O')
        val pWire = Wire(marker = 1); val p = pWire.document(version = 'P', features = 1)
        assertArrayEquals(n.copyOfRange(4, n.size), o.copyOfRange(4, o.size))
        assertArrayEquals(n.copyOfRange(4, n.size), p.copyOfRange(4, p.size - 1))
        assertEquals(ownedBlocks(read(n)), ownedBlocks(read(o)))
        assertEquals(ownedBlocks(read(n)), ownedBlocks(read(p)))
        val qWire = Wire(marker = 1, corners = true); val q = qWire.document(version = 'Q')
        val rWire = Wire(marker = 1, intrinsic = true); val r = rWire.document()
        assertNotNull(read(q).sections.single().blocks.last().table!!.style!!.cornerRadii)
        assertNotNull(read(r).sections.single().blocks.last().table!!.blockViewport!!.intrinsicContainingDirection)
        for (name in listOf("main", "legacy", "absent")) {
            assertArrayEquals(nWire.blockBytes(n, name), qWire.blockBytes(q, name))
            assertArrayEquals(nWire.blockBytes(n, name), rWire.blockBytes(r, name))
        }
        val newWire = Wire(clear = 2); val new = newWire.document()
        val oldRule = nWire.blockBytes(n, "main"); val newRule = newWire.blockBytes(new, "main")
        val markerOffset = nWire.at.getValue("mainMarker") - nWire.at.getValue("mainStart")
        assertEquals(oldRule.size + 1, newRule.size)
        assertArrayEquals(oldRule.copyOfRange(0, markerOffset), newRule.copyOfRange(0, markerOffset))
        assertArrayEquals(oldRule.copyOfRange(markerOffset + 1, oldRule.size), newRule.copyOfRange(markerOffset + 1, newRule.size - 1))
        assertEquals(2, newRule.last().toInt())
        bad(Wire(marker = 1).document(version = 'P'))
        bad(Wire(marker = 1).document(version = 'Q'))
    }

    @Test fun ruleAndIntrinsicTableShareRWhileQAndPKeepTheirIndependentCensus() {
        val onlyRule = read(Wire().document())
        assertTrue(onlyRule.sections.single().blocks.none { it.table != null })
        val oldWire = Wire(marker = 1, intrinsic = true); val old = oldWire.document()
        val joinedWire = Wire(intrinsic = true, corners = true); val joined = joinedWire.document(features = 1)
        val entry = read(joined); val blocks = entry.sections.single().blocks
        assertEquals(BodyAdjoiningPolicy.Ordinary, entry.bodyAdjoining)
        assertEquals(FigureClear.Right, blocks[1].ruleStyle!!.clear)
        val intrinsic = blocks[5].table!!
        assertEquals(TableGeometry(1, 0, 4), intrinsic.geometry)
        assertEquals(TableContainingDirection.Rtl, intrinsic.blockViewport!!.intrinsicContainingDirection)
        assertEquals(TableContainingDirection.Ltr, intrinsic.blockViewport.gridDirection)
        assertEquals(TableScrollFocusMode.UaAuto, intrinsic.blockViewport.focusPaint!!.mode)
        assertEquals("table-body-target", intrinsic.rows.single().single().spans.single().target)
        assertEquals("table-caption-target", intrinsic.caption.single().target)
        assertNotNull(blocks[6].table!!.style!!.cornerRadii)
        assertArrayEquals(oldWire.intrinsicBytes(old), joinedWire.intrinsicBytes(joined))
        assertNull(ownedBlocks(read(old))[1].ruleStyle!!.clear)
        bad(Wire(marker = 1).document())
        val q = Wire(marker = 1, corners = true).document(version = 'Q')
        bad(changed(q, 3, 'R'.code))
        for (feature in listOf(4, 8, 16, 32, 64, 128))
            bad(changed(joined, joinedWire.at.getValue("Features"), feature or 1))
        bad(joined.copyOf(joined.size - 1))
    }

    @Test fun markerEnumsTruncationAndExistingRuleContextRestrictionsRemainStrict() {
        val wire = Wire(); val bytes = wire.document(); val at = wire.at
        for (marker in listOf(0, 1, 3, 255)) bad(changed(bytes, at.getValue("mainMarker"), marker))
        for (clear in listOf(4, 255)) bad(changed(bytes, at.getValue("mainClear"), clear))
        for (end in bytes.indices) bad(bytes.copyOf(end))
        bad(bytes + byteArrayOf(0))
        val clearAt = at.getValue("mainClear")
        bad(bytes.copyOfRange(0, clearAt) + bytes.copyOfRange(clearAt + 1, bytes.size))
        for (header in listOf('M', 'S')) bad(changed(bytes, 3, header.code))
        for (field in listOf("Height", "Top", "Right", "Bottom", "Left")) {
            bad(changed(bytes, at.getValue("main${field}Unit"), 2))
            for (value in listOf(-1f, Float.NaN, Float.POSITIVE_INFINITY))
                bad(changed32(bytes, at.getValue("main$field"), value.toRawBits()))
        }
        bad(changed(bytes, at.getValue("mainFill"), 3))
        bad(changed(bytes, at.getValue("mainDepth"), 1)); bad(changed(bytes, at.getValue("mainLevel"), 1))
        bad(Wire(ruleKind = 0).document()); bad(Wire(alignment = 1).document())
        val rule = ownedBlocks(read(bytes))[1]
        val before = ownedBlocks(read(bytes)).first().spans
        val invalid = listOf<() -> Block>(
            { rule.copy(kind = "paragraph") }, { rule.copy(depth = 1) }, { rule.copy(level = 1) },
            { rule.copy(spans = before) }, { rule.copy(listPath = "#") }, { rule.copy(number = "1") },
            { rule.copy(anchor = "a") }, { rule.copy(anchorFallback = "a") },
            { rule.copy(textAlign = CellTextAlign.Center) }, { rule.copy(style = BlockStyle(margins = expected(null).margins)) },
            { rule.copy(table = Table(emptyList(), emptyList())) }, { rule.copy(flow = emptyList()) },
        )
        invalid.forEach { make -> assertThrows(IllegalArgumentException::class.java) { make() } }
    }
}
