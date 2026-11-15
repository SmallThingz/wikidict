package app.smallthingz.dict

import java.io.ByteArrayOutputStream
import org.junit.Assert.*
import org.junit.Test

/** Literal DPRR source controls; these fixtures are not KU corpus or execution evidence. */
class TableIntrinsicViewportCodecTest {
    private enum class Owner {
        Direct, NestedCell, OrderedCell, RichCaption, Container, Reference, FigureCaption, FlowFigure, FlowScope,
    }
    private enum class Mode { Intrinsic, Paired, LegacyBlock, Ordinary, Corners }
    private data class StyleWire(
        val flags: Int = 15, val extension: Int = 0, val collapse: Int = 1,
        val width: Float = 70f, val widthUnit: Int = 2, val display: Int = 0,
    )
    private class Wire(
        private val mode: Mode = Mode.Intrinsic,
        private val geometry: TableGeometry? = TableGeometry(border = 1, cellSpacing = 0, cellPadding = 4),
        private val wide: StyleWire? = StyleWire(),
        private val box: StyleWire = StyleWire(flags = 11),
        private val grid: StyleWire = StyleWire(flags = 4),
        private val threshold: Long = 639,
        private val maximum: StyleWidth = StyleWidth(StyleWidthUnit.Percent, 100f),
        private val boxSizing: Int = 1,
        private val containingDirection: Int = 1,
        private val gridDirection: Int = 0,
        private val language: String = "ku",
        private val focusMode: Int = 1,
        private val focusColor: FigureColor? = null,
        private val writeDirection: Boolean = true,
        private val writeFocus: Boolean = true,
        private val richBody: Boolean = false,
        private val cellOverride: Boolean = false,
        private val emptyGrid: Boolean = false,
        private val family: Boolean = false,
        private val image: Boolean = false,
        private val extras: List<Mode> = emptyList(),
    ) {
        private val out = ByteArrayOutputStream()
        val marks = linkedMapOf<String, Int>()
        private fun byte(value: Int) { out.write(value) }
        private fun u16(value: Int) { repeat(2) { byte(value ushr (it * 8)) } }
        private fun u32(value: Long) { repeat(4) { byte((value ushr (it * 8)).toInt()) } }
        private fun f32(value: Float) = u32(value.toRawBits().toLong())
        private fun string(value: String) { val bytes = value.encodeToByteArray(); u32(bytes.size.toLong()); out.write(bytes) }
        private fun mark(name: String) { marks[name] = out.size() }
        private fun length(value: Float = 0f, unit: Int = 0) { byte(unit); f32(value) }
        private fun span(text: String, target: String, feature: Boolean = false, trail: String = "s") {
            byte(1); byte(0); byte(1)
            string(text); string(target); string(trail); string("ku"); repeat(3) { string("") }
            byte(1); string("#123456"); byte(0)
            byte(if (family && feature) 16 else 0)
            if (family && feature) { byte(1); u32(1); string("Intrinsic Serif"); byte(1) }
            byte(0); byte(1); string("part"); byte(1); string("full advice")
        }
        private fun imageSpan() {
            byte(1); byte(0); byte(0)
            string(""); string("File:Intrinsic.svg"); string(""); repeat(4) { string("") }
            repeat(3) { byte(0) }
            byte(3); string("Intrinsic.svg"); byte(3); u32(30); u32(20); byte(1)
            byte(0); byte(0)
        }
        private fun style(name: String, value: StyleWire?) {
            if (value == null) { byte(0); return }
            byte(1); mark(name + "Flags"); byte(value.flags); mark(name + "Extension"); byte(value.extension)
            if (value.flags and 1 != 0) string("#f5f4aa")
            if (value.flags and 2 != 0) { byte(1); length(1f); string("#aaaaaa") }
            if (value.flags and 4 != 0) byte(value.collapse)
            if (value.flags and 8 != 0) { length(.25f); length(2f); length(.5f); length(3f) }
            if (value.flags and 16 != 0) byte(1)
            if (value.flags and 32 != 0) { byte(value.widthUnit); f32(value.width) }
            if (value.flags and 64 != 0) repeat(4) { length(.1f, 1) }
            if (value.flags and 128 != 0) byte(0)
            if (value.extension and 1 != 0) byte(value.display)
            if (value.extension and 2 != 0) byte(0)
            if (value.extension and 4 != 0) { f32(1.25f); byte(1) }
            if (value.extension and 8 != 0) {
                byte(1); length(); byte(0); byte(1); length(); byte(0)
            }
            if (value.extension and 16 != 0) byte(0)
            if (value.extension and 32 != 0) listOf(8f, 8f, 8f, 0f).forEach { length(it) }
        }
        private fun blockHeader(kind: Int, text: String? = null, target: String = "body-target-main", feature: Boolean = false) {
            byte(kind); byte(0); byte(0); u32(if (text == null) 0 else 1)
            if (text != null) span(text, target, feature)
            byte(0); string(""); string("")
        }
        private fun blockTail() { string(""); string(""); repeat(4) { byte(0) } }
        private fun paragraph(text: String, target: String, feature: Boolean = false) {
            blockHeader(0, text, target, feature); byte(0); blockTail()
        }
        private fun tableBlock(name: String = "main", kind: Mode = mode, owner: Owner = Owner.Direct) {
            blockHeader(12); table(name, kind, owner); blockTail()
        }
        private fun table(name: String, kind: Mode, owner: Owner = Owner.Direct) {
            val leaf = owner == Owner.Direct
            val selected = if (leaf) kind else Mode.Ordinary
            val contentName = if (leaf) "main" else name
            val intrinsic = selected == Mode.Intrinsic
            val paired = selected == Mode.Paired
            val legacy = selected == Mode.LegacyBlock
            mark(name + "Start"); byte(if (intrinsic) 19 else if (paired) 7 else if (legacy) 3 else 1)
            val shape = if (intrinsic || selected == Mode.Ordinary && leaf) geometry else null
            mark(name + "Geometry")
            byte((if (shape?.border != null) 1 else 0) or (if (shape?.cellSpacing != null) 2 else 0) or
                (if (shape?.cellPadding != null) 4 else 0) or (if (shape?.width != null) 8 else 0))
            shape?.border?.let(::u16); shape?.cellSpacing?.let(::u16); shape?.cellPadding?.let(::u16)
            shape?.width?.let { byte(it.unit.ordinal); u32(it.value) }
            val richCaption = owner == Owner.RichCaption || intrinsic && richBody
            val flatCaption = !paired && !richCaption
            u32(if (flatCaption) 1 else 0)
            if (flatCaption) span("Caption $contentName", "caption-target-$contentName")
            u32(if (intrinsic && emptyGrid) 0 else 1)
            if (!intrinsic || !emptyGrid) {
                u32(1); byte(1); u16(2); u16(1); byte(1); string("#add8e6")
                val ordered = owner == Owner.OrderedCell || intrinsic && richBody
                val nested = owner == Owner.NestedCell
                u32(if (ordered || nested) 0 else 1)
                if (!ordered && !nested) span("Body $contentName", "body-target-$contentName", feature = leaf)
                if (nested) table("main", mode) else byte(0)
                if (ordered) {
                    byte(1); u32(1)
                    if (owner == Owner.OrderedCell) tableBlock()
                    else paragraph("Body $contentName", "body-target-$contentName", feature = true)
                } else byte(0)
                if (cellOverride && intrinsic) { byte(1); byte(3); byte(0); repeat(4) { length() } }
                else byte(0)
            }
            val chosenStyle = when {
                !leaf -> StyleWire(flags = 4)
                intrinsic || selected == Mode.Ordinary -> wide
                paired -> StyleWire(flags = 31)
                selected == Mode.Corners -> StyleWire(flags = 6, extension = 32, collapse = 0)
                else -> StyleWire(flags = 4)
            }
            style(name + "Wide", chosenStyle)
            if (richCaption) {
                byte(1); u32(1)
                if (owner == Owner.RichCaption) tableBlock()
                else paragraph("Caption $contentName", "caption-target-$contentName")
            } else byte(0)
            if (intrinsic || paired || legacy) {
                u32(threshold)
                style(name + "Box", if (legacy) StyleWire(flags = 35, extension = 24) else box)
                byte(boxSizing); byte(maximum.unit.ordinal); f32(maximum.value)
                style(name + "Grid", grid)
                byte(gridDirection); string(language); mark(name + "LanguageEnd")
                if (intrinsic && writeDirection) { mark(name + "Direction"); byte(containingDirection) }
                if ((intrinsic || paired) && writeFocus) focus(name)
                if (paired) { u32(threshold); byte(0); byte(gridDirection); string(language) }
            }
            mark(name + "End")
        }
        private fun focus(name: String) {
            mark(name + "Focus"); byte(focusMode); mark(name + "FocusPresence"); byte(if (focusColor == null) 0 else 1)
            if (focusColor != null) {
                mark(name + "FocusColor")
                when (val color = requireNotNull(focusColor)) {
                    FigureColor.NativeTheme -> byte(0)
                    FigureColor.Transparent -> byte(1)
                    is FigureColor.Rgb -> { byte(2); string(color.value) }
                }
            }
            mark(name + "FocusEnd")
        }
        private fun figure() {
            byte(2); byte(0); byte(0); byte(0)
            repeat(12) { length() }; f32(1f); length(18f)
            byte(1); byte(0); byte(1); byte(0); byte(0); byte(1)
            span("Missing image", "File:Missing.svg", trail = "")
            length(40f); length(18f); byte(0)
            u32(0); byte(1); u32(1); tableBlock(); byte(0); byte(0)
        }
        private fun figureBlock(owner: Owner) {
            blockHeader(0); byte(0); string(""); string(""); byte(0); byte(0)
            if (owner == Owner.FigureCaption) { figure(); byte(0) }
            else {
                byte(0); byte(1); u32(1)
                if (owner == Owner.FlowScope) { byte(2); byte(0); byte(2); byte(1); byte(1); string("ku"); u32(1) }
                byte(1); figure()
            }
        }
        fun document(owner: Owner = Owner.Direct, version: Int = 82, features: Int = 0): ByteArray {
            out.write(byteArrayOf(68, 80, 82, version.toByte()))
            u32(if (image) 1 else 0); if (image) imageSpan()
            u32(if (owner == Owner.Reference) 0 else 1)
            if (owner != Owner.Reference) {
                byte(2); string("Body"); string(""); string(""); u32(1L + extras.size)
                when (owner) {
                    Owner.Container -> { blockHeader(13); byte(0); blockTail(); u32(0); u32(1); tableBlock() }
                    Owner.FigureCaption, Owner.FlowFigure, Owner.FlowScope -> figureBlock(owner)
                    else -> tableBlock(if (owner == Owner.Direct) "main" else "outer", mode, owner)
                }
                extras.forEachIndexed { index, next -> tableBlock("extra$index", next) }
            }
            u32(0); u32(0); u32(0)
            u32(if (owner == Owner.Reference) 1 else 0)
            if (owner == Owner.Reference) { byte(1); u32(1); string(""); u32(0); byte(1); u32(1); tableBlock() }
            u32(if (image) 1 else 0)
            if (image) { string("Intrinsic.svg"); byte(0); string("") }
            if (version >= 80) { mark("Features"); byte(features) }
            return out.toByteArray()
        }
        fun tableBytes(bytes: ByteArray, name: String = "main") =
            bytes.copyOfRange(marks.getValue(name + "Start"), marks.getValue(name + "End"))
    }
    private fun read(bytes: ByteArray) = BlobDecoder.decode(bytes, "intrinsic", "supplemental", null, "ku")
    private fun leaf(entry: Entry, owner: Owner = Owner.Direct): Table {
        if (owner == Owner.Reference) return entry.references.single().blocks!!.single().table!!
        val block = entry.sections.single().blocks.first()
        return when (owner) {
            Owner.Direct -> block.table!!
            Owner.NestedCell -> block.table!!.rows.single().single().nestedTable!!
            Owner.OrderedCell -> block.table!!.rows.single().single().blocks!!.single().table!!
            Owner.RichCaption -> block.table!!.captionBlocks!!.single().table!!
            Owner.Container -> block.container!!.blocks.single().table!!
            Owner.FigureCaption -> block.figure!!.captionBlocks!!.single().table!!
            Owner.FlowFigure -> (block.flow!!.single() as FlowPart.ImageFigure).figure.captionBlocks!!.single().table!!
            Owner.FlowScope -> ((block.flow!!.single() as FlowPart.Scope).scope.parts.single() as FlowPart.ImageFigure)
                .figure.captionBlocks!!.single().table!!
            Owner.Reference -> error("Handled above")
        }
    }
    private fun mutate(bytes: ByteArray, offset: Int, value: Int) = bytes.copyOf().also { it[offset] = value.toByte() }
    private fun bad(bytes: ByteArray) { assertTrue("Malformed literal payload was accepted", runCatching { read(bytes) }.isFailure) }

    @Test fun intrinsicDirectionPrecedesRequiredFocusAndPreservesCompleteTableData() {
        for (direction in 0..1) for (focus in listOf(TableScrollFocusPaint(TableScrollFocusMode.AuthoredNone),
            TableScrollFocusPaint(TableScrollFocusMode.UaAuto),
            TableScrollFocusPaint(TableScrollFocusMode.UaAuto, FigureColor.NativeTheme),
            TableScrollFocusPaint(TableScrollFocusMode.UaAuto, FigureColor.Transparent),
            TableScrollFocusPaint(TableScrollFocusMode.UaAuto, FigureColor.Rgb("#3366cc")))) {
            val wire = Wire(containingDirection = direction, gridDirection = 1 - direction,
                focusMode = focus.mode.ordinal, focusColor = focus.color)
            val bytes = wire.document(); val entry = read(bytes); val table = leaf(entry); val policy = table.blockViewport!!
            assertArrayEquals(byteArrayOf(68, 80, 82, 82), bytes.copyOf(4))
            assertEquals(19, bytes[wire.marks.getValue("mainStart")].toInt())
            assertEquals(0, bytes.last().toInt()); assertNull(entry.bodyAdjoining)
            assertEquals(wire.marks.getValue("mainLanguageEnd"), wire.marks.getValue("mainDirection"))
            assertEquals(wire.marks.getValue("mainDirection") + 1, wire.marks.getValue("mainFocus"))
            assertEquals(TableContainingDirection.entries[direction], policy.intrinsicContainingDirection)
            assertEquals(TableContainingDirection.entries[1 - direction], policy.gridDirection)
            assertNull(policy.boxStyle.containingDirection); assertNull(table.style!!.containingDirection)
            assertEquals(focus, policy.focusPaint); assertEquals("ku", policy.language)
            assertEquals(TableGeometry(1, 0, 4), table.geometry)
            assertEquals("Caption main", table.caption.single().text)
            val cell = table.rows.single().single(); val span = cell.spans.single()
            assertTrue(cell.header); assertEquals(2, cell.colspan); assertEquals(1, cell.rowspan)
            assertEquals("#add8e6", cell.background); assertTrue(span.bold)
            assertNull(cell.style)
            assertEquals("Body main", span.text); assertEquals("body-target-main", span.target)
            assertEquals("s", span.trail); assertEquals("part", span.targetFragment)
            assertEquals("full advice", span.tooltip); assertEquals("#123456", span.foreground)
        }
        val rich = leaf(read(Wire(richBody = true, cellOverride = true,
            wide = StyleWire(flags = 207), box = StyleWire(flags = 203)).document()))
        assertTrue(rich.caption.isEmpty()); assertEquals("Caption main", rich.captionBlocks!!.single().spans.single().text)
        assertEquals("body-target-main", rich.rows.single().single().blocks!!.single().spans.single().target)
        val explicitCell = rich.rows.single().single().style!!
        assertEquals(StyleBorder.None, explicitCell.border)
        val zero = StyleLength(StyleLengthUnit.Px, 0f)
        assertEquals(StyleEdges(zero, zero, zero, zero), explicitCell.padding)
        assertEquals(rich.captionBlocks, rich.copy(rows = emptyList()).captionBlocks)
        for (edge in listOf(0, 65535)) for (threshold in listOf(1L, 0xffff_ffffL)) {
            val table = leaf(read(Wire(geometry = TableGeometry(edge, edge, edge), threshold = threshold, emptyGrid = true).document()))
            assertEquals(TableGeometry(edge, edge, edge), table.geometry); assertTrue(table.rows.isEmpty())
            assertEquals(threshold, table.blockViewport!!.maxViewportWidthPx)
        }
    }

    @Test fun recursiveIntrinsicOwnersRequireRIncludingRichCaptionsAndFigureFlows() {
        for (owner in Owner.entries) {
            val wire = Wire(); val bytes = wire.document(owner); val table = leaf(read(bytes), owner)
            assertEquals(TableContainingDirection.Rtl, table.blockViewport!!.intrinsicContainingDirection)
            assertEquals("body-target-main", table.rows.single().single().spans.single().target)
            assertEquals("caption-target-main", table.caption.single().target)
            for (header in listOf(77, 80, 81)) bad(mutate(bytes, 3, header))
            bad(bytes.copyOf(bytes.size - 1))
        }
        for (mode in listOf(Mode.Ordinary, Mode.Corners, Mode.Paired, Mode.LegacyBlock)) {
            val features = if (mode == Mode.Paired) 32 else 0
            bad(Wire(mode = mode).document(features = features))
        }
        bad(Wire(mode = Mode.Ordinary, image = true).document())
        val q = read(Wire(mode = Mode.Corners).document(version = 81))
        assertNotNull(leaf(q).style!!.cornerRadii); assertNull(leaf(q).blockViewport)
        bad(Wire(mode = Mode.Ordinary).document(version = 81))
    }

    @Test fun rCombinesOptionalQPayloadsAndRetainsExactPFeatureCensus() {
        for (corners in listOf(false, true)) for (image in listOf(false, true)) {
            val extras = if (corners) listOf(Mode.Corners) else emptyList()
            val bytes = Wire(image = image, extras = extras).document()
            val entry = read(bytes)
            assertNotNull(leaf(entry).blockViewport!!.intrinsicContainingDirection)
            assertEquals(if (corners) 2 else 1, entry.sections.single().blocks.size)
            if (corners) assertNotNull(entry.sections.single().blocks.last().table!!.style!!.cornerRadii)
            if (image) assertEquals(InlineImageVerticalAlign.Baseline, entry.displayTitle.single().image!!.verticalAlign)
            else assertTrue(entry.displayTitle.isEmpty())
            assertEquals(0, bytes.last().toInt())
        }
        val familyWire = Wire(family = true, image = true, extras = listOf(Mode.Corners, Mode.Paired))
        val familyBytes = familyWire.document(features = 37)
        val entry = read(familyBytes)
        assertEquals(BodyAdjoiningPolicy.Ordinary, entry.bodyAdjoining)
        assertNotNull(leaf(entry).rows.single().single().spans.single().fontFamily)
        assertNotNull(entry.sections.single().blocks.last().table!!.floatViewport)
        for (features in listOf(0, 1, 4, 32, 33, 36 or 8, 37 or 16, 37 or 64, 37 or 128))
            bad(mutate(familyBytes, familyWire.marks.getValue("Features"), features))
        val plainWire = Wire(); val plain = plainWire.document()
        for (spurious in listOf(4, 8, 16, 32, 64, 128)) bad(mutate(plain, plainWire.marks.getValue("Features"), spurious))
        assertEquals(BodyAdjoiningPolicy.Ordinary, read(Wire().document(features = 1)).bodyAdjoining)
    }

    @Test fun oldNullAndPairedOwnersKeepLiteralBytesWithoutAcquiringIntrinsicDirection() {
        for (mode in listOf(Mode.Ordinary, Mode.LegacyBlock)) {
            val oldWire = Wire(mode = mode); val oldBytes = oldWire.document(version = 77)
            val pWire = Wire(mode = mode); val pBytes = pWire.document(version = 80, features = 1)
            assertArrayEquals(oldBytes.copyOfRange(4, oldBytes.size), pBytes.copyOfRange(4, pBytes.size - 1))
            assertEquals(leaf(read(oldBytes)), leaf(read(pBytes)))
            assertNull(leaf(read(pBytes)).blockViewport?.intrinsicContainingDirection)
            bad(Wire(mode = mode).document(version = 80))
            val combinedWire = Wire(extras = listOf(mode)); val combined = combinedWire.document()
            assertArrayEquals(oldWire.tableBytes(oldBytes), combinedWire.tableBytes(combined, "extra0"))
            assertNull(read(combined).sections.single().blocks.last().table!!.blockViewport?.intrinsicContainingDirection)
        }
        val pairedWire = Wire(mode = Mode.Paired, focusMode = 0)
        val paired = pairedWire.document(version = 80, features = 32)
        val table = leaf(read(paired)); assertNotNull(table.floatViewport)
        assertNull(table.blockViewport!!.intrinsicContainingDirection)
        assertEquals(pairedWire.marks.getValue("mainLanguageEnd"), pairedWire.marks.getValue("mainFocus"))
        assertEquals(TableScrollFocusMode.AuthoredNone, table.blockViewport.focusPaint!!.mode)
        val combinedWire = Wire(focusMode = 0, extras = listOf(Mode.Paired))
        val combined = combinedWire.document(features = 32)
        assertArrayEquals(pairedWire.tableBytes(paired), combinedWire.tableBytes(combined, "extra0"))
        bad(mutate(paired, pairedWire.marks.getValue("Features"), 0))
        bad(mutate(paired, 3, 82))
        bad(mutate(combined, combinedWire.marks.getValue("Features"), 0))
    }

    @Test fun malformedIntrinsicTagsTailsAndClosedGeometryDomainAreRefused() {
        val wire = Wire(focusColor = FigureColor.Rgb("#3366cc")); val bytes = wire.document()
        for (header in listOf(77, 80, 81, 83, 255)) bad(mutate(bytes, 3, header))
        for (tag in listOf(0, 1, 3, 7, 17, 23, 27, 35, 255)) bad(mutate(bytes, wire.marks.getValue("mainStart"), tag))
        for (name in listOf("mainDirection", "mainFocus", "mainFocusPresence")) for (invalid in listOf(2, 255))
            bad(mutate(bytes, wire.marks.getValue(name), invalid))
        bad(mutate(bytes, wire.marks.getValue("mainFocusColor"), 3))
        for (size in 0 until bytes.size) bad(bytes.copyOf(size))
        bad(bytes + byteArrayOf(0))
        for (name in listOf("mainDirection", "mainFocus")) {
            val start = wire.marks.getValue(name)
            val end = if (name == "mainDirection") start + 1 else wire.marks.getValue("mainFocusEnd")
            bad(bytes.copyOfRange(0, start) + bytes.copyOfRange(end, bytes.size))
        }
        bad(Wire(writeDirection = false).document()); bad(Wire(writeFocus = false).document())
        bad(Wire(focusMode = 0, focusColor = FigureColor.Rgb("#3366cc")).document())
        bad(Wire(threshold = 0).document()); bad(Wire(language = "").document())
        bad(Wire(gridDirection = 2).document()); bad(Wire(boxSizing = 2).document())
        for (shape in listOf(null, TableGeometry(), TableGeometry(1, 0, null), TableGeometry(1, null, 4),
            TableGeometry(null, 0, 4), TableGeometry(1, 0, 4, TableWidth(TableWidthUnit.Px, 100))))
            bad(Wire(geometry = shape).document())
        for (maximum in listOf(StyleWidth(StyleWidthUnit.Percent, 99f), StyleWidth(StyleWidthUnit.Px, 100f),
            StyleWidth(StyleWidthUnit.Em, 100f))) bad(Wire(maximum = maximum).document())
        for (wide in listOf(null, StyleWire(flags = 7), StyleWire(flags = 11), StyleWire(collapse = 0),
            StyleWire(flags = 31), StyleWire(flags = 47), StyleWire(extension = 1), StyleWire(extension = 2),
            StyleWire(extension = 4), StyleWire(flags = 7, extension = 24), StyleWire(extension = 32)))
            bad(Wire(wide = wide).document())
        for (box in listOf(StyleWire(flags = 3), StyleWire(flags = 43), StyleWire(flags = 27),
            StyleWire(flags = 15), StyleWire(flags = 11, extension = 1), StyleWire(flags = 11, extension = 2),
            StyleWire(flags = 11, extension = 4), StyleWire(flags = 3, extension = 24), StyleWire(flags = 11, extension = 32)))
            bad(Wire(box = box).document())
        for (grid in listOf(StyleWire(flags = 0), StyleWire(flags = 4, collapse = 0), StyleWire(flags = 5),
            StyleWire(flags = 6), StyleWire(flags = 12), StyleWire(flags = 20), StyleWire(flags = 36),
            StyleWire(flags = 68), StyleWire(flags = 132), StyleWire(flags = 4, extension = 1),
            StyleWire(flags = 4, extension = 2), StyleWire(flags = 4, extension = 4)))
            bad(Wire(grid = grid).document())
        val table = leaf(read(bytes)); val policy = table.blockViewport!!
        assertThrows(IllegalArgumentException::class.java) { policy.copy(focusPaint = null) }
        assertThrows(IllegalArgumentException::class.java) { table.copy(blockViewport = policy.copy(intrinsicContainingDirection = null)) }
        assertThrows(IllegalArgumentException::class.java) {
            table.copy(floatViewport = TableFloatViewport(639, TableContainingDirection.Ltr, TableContainingDirection.Ltr, "ku"))
        }
        for (invalid in listOf(-1, 65536)) for (shape in listOf(TableGeometry(invalid, 0, 4),
            TableGeometry(1, invalid, 4), TableGeometry(1, 0, invalid)))
            assertThrows(IllegalArgumentException::class.java) { table.copy(geometry = shape) }
    }
}
