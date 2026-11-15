package app.smallthingz.dict

import java.io.ByteArrayOutputStream
import org.junit.Assert.*
import org.junit.Test

/** Literal DPRQ fixtures; private source controls, not execution or MG corpus evidence. */
class TableCornerRadiiCodecTest {
    private enum class Owner {
        Direct, NestedCell, OrderedCell, RichCaption, Container, Reference, FigureCaption, FlowFigure, FlowScope,
    }
    private data class StyleWire(
        val flags: Int = 7, val extension: Int = 0x38, val border: Int = 1, val collapse: Int = 0,
        val radii: List<Float> = listOf(8f, 8f, 8f, 0f), val unit: Int = 0, val display: Int = 0,
        val width: Float = 70f, val widthUnit: Int = 2, val direction: Int = 1,
    )
    private class Wire(
        private val corners: Boolean = true,
        private val wide: StyleWire = StyleWire(),
        private val box: StyleWire? = null,
        private val grid: StyleWire = StyleWire(flags = 4, extension = 0, collapse = 1),
        private val family: Boolean = false,
        private val wrap: Boolean = false,
        private val cellOwner: Boolean = false,
        private val geometry: TableGeometry? = null,
        private val emptyGrid: Boolean = false,
        private val wideCorners: Boolean = false,
        private val maximum: StyleWidth = StyleWidth(StyleWidthUnit.Percent, 100f),
        private val paired: Boolean = false,
        private val focusMode: Int = 0,
        private val focusColor: FigureColor? = null,
        private val writeCornerFocus: Boolean = true,
    ) {
        private val out = ByteArrayOutputStream()
        private var version = 81
        val marks = linkedMapOf<String, Int>()
        private fun byte(value: Int) { out.write(value) }
        private fun u16(value: Int) { repeat(2) { byte(value ushr (it * 8)) } }
        private fun u32(value: Long) { repeat(4) { byte((value ushr (it * 8)).toInt()) } }
        private fun f32(value: Float) = u32(value.toRawBits().toLong())
        private fun string(value: String) {
            val bytes = value.encodeToByteArray(); u32(bytes.size.toLong()); out.write(bytes)
        }
        private fun mark(name: String) { marks[name] = out.size() }
        private fun length(value: Float = 0f, unit: Int = 0) { byte(unit); f32(value) }
        private fun fontFamily() { byte(1); u32(1); string("Corner Serif"); byte(1) }
        private fun span(text: String, target: String, trail: String = "s", featurePayload: Boolean = false) {
            byte(1); byte(0); byte(1)
            string(text); string(target); string(trail); repeat(4) { string("") }
            byte(1); string("#123456"); byte(0)
            byte((if (family && featurePayload) 16 else 0) or (if (wrap && featurePayload) 8 else 0))
            if (wrap && featurePayload) { byte(32); byte(0) }
            if (family && featurePayload) fontFamily()
            byte(0); byte(1); string("part"); byte(1); string("full advice")
        }
        private fun style(name: String, value: StyleWire, hasCorners: Boolean) {
            byte(1); mark(name + "Flags"); byte(value.flags)
            val extension = if (hasCorners) value.extension else value.extension and 0x20.inv()
            mark(name + "Extension"); byte(extension)
            if (value.flags and 1 != 0) string("#f5f4aa")
            if (value.flags and 2 != 0) {
                mark(name + "Border"); byte(value.border)
                when (value.border) {
                    1 -> { length(1f); string("#bca674") }
                    2 -> repeat(4) { byte(0) }
                }
            }
            if (value.flags and 4 != 0) { mark(name + "Collapse"); byte(value.collapse) }
            if (value.flags and 8 != 0) {
                length(0f, 1); length(0f, 1); length(.5f, 1); length(0f, 1)
            }
            if (value.flags and 16 != 0) byte(1)
            if (value.flags and 32 != 0) { byte(value.widthUnit); f32(value.width) }
            if (value.flags and 64 != 0) repeat(4) { length(.1f, 1) }
            if (value.flags and 128 != 0) byte(0)
            if (extension and 1 != 0) byte(value.display)
            if (extension and 2 != 0) byte(0)
            if (extension and 4 != 0) { f32(1.2f); byte(1) }
            if (extension and 8 != 0) {
                byte(1); length(.25f)
                byte(0)
                byte(1); length(.5f)
                byte(0)
            }
            if (extension and 16 != 0) { mark(name + "Direction"); byte(value.direction) }
            mark(name + "CornerStart")
            if (extension and 32 != 0) value.radii.forEachIndexed { index, radius ->
                mark(name + "Unit" + index); byte(value.unit)
                mark(name + "Value" + index); f32(radius)
            }
            mark(name + "CornerEnd")
        }
        private fun blockHeader(kind: Int) {
            byte(kind); byte(0); byte(0); u32(0); byte(0); string(""); string("")
        }
        private fun blockTail() { string(""); string(""); repeat(4) { byte(0) } }
        private fun tableBlock(name: String = "leaf", owner: Owner = Owner.Direct) {
            blockHeader(12); table(name, owner); blockTail()
        }
        private fun table(name: String, owner: Owner) {
            val leaf = owner == Owner.Direct
            val policy = box.takeIf { leaf }
            byte(if (policy == null) 1 else if (paired) 7 else 3)
            val shape = geometry.takeIf { leaf }
            val geometryFlags = (if (shape?.border != null) 1 else 0) or
                (if (shape?.cellSpacing != null) 2 else 0) or (if (shape?.cellPadding != null) 4 else 0) or
                (if (shape?.width != null) 8 else 0)
            byte(geometryFlags)
            shape?.border?.let(::u16); shape?.cellSpacing?.let(::u16); shape?.cellPadding?.let(::u16)
            shape?.width?.let { byte(it.unit.ordinal); u32(it.value) }
            u32(if (owner == Owner.RichCaption) 0 else 1)
            if (owner != Owner.RichCaption) span("Caption $name", "caption-target-$name")
            u32(if (leaf && emptyGrid) 0 else 1)
            if (!leaf || !emptyGrid) {
            u32(1); byte(0); u16(1); u16(1); byte(0)
            val text = owner != Owner.NestedCell && owner != Owner.OrderedCell
            u32(if (text) 1 else 0)
            if (text) span("Body $name", "body-target-$name", featurePayload = leaf)
            if (owner == Owner.NestedCell) table("leaf", Owner.Direct) else byte(0)
            if (owner == Owner.OrderedCell) { byte(1); u32(1); tableBlock() } else byte(0)
            if (cellOwner && leaf) {
                byte(1); byte(8); byte(2); f32(12f); byte(2)
                byte(0); byte(24); string("mg"); string(""); byte(0); byte(0); fontFamily()
                byte(0)
            } else byte(0)
            }
            style(name + "Wide", if (leaf) wide else StyleWire(flags = 4, extension = 0),
                corners && leaf && (policy == null || wideCorners))
            if (owner == Owner.RichCaption) { byte(1); u32(1); tableBlock() } else byte(0)
            if (policy != null) {
                u32(639); style(name + "Box", policy, corners)
                byte(0); byte(maximum.unit.ordinal); f32(maximum.value)
                style(name + "Grid", grid, grid.extension and 32 != 0)
                byte(0); string("mg"); mark(name + "LanguageEnd")
                if (paired || cornerBlockShape(policy) && writeCornerFocus) focus(name)
                if (paired) {
                    u32(639); byte(0); byte(0); string("mg")
                }
            }
        }
        private fun cornerBlockShape(value: StyleWire): Boolean = version == 81 && corners &&
            value.flags and 42 == 42 && value.flags and 20 == 0 && value.extension == 48 &&
            value.border in 0..1 && value.unit == 0 && value.radii.size == 4 &&
            value.radii.all { it.isFinite() && it in 0f..16777216f } && value.direction in 0..1 &&
            value.widthUnit == 2 && value.width == 100f && maximum == StyleWidth(StyleWidthUnit.Percent, 100f) &&
            grid.flags == 4 && grid.extension == 0 && grid.collapse == 0
        private fun focus(name: String) {
            mark(name + "FocusStart"); mark(name + "FocusMode"); byte(focusMode)
            mark(name + "FocusPresence"); byte(if (focusColor == null) 0 else 1)
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
            u32(0); byte(1); u32(1); tableBlock()
            byte(0); byte(0)
        }
        private fun figureBlock(owner: Owner) {
            blockHeader(0); byte(0); string(""); string(""); byte(0); byte(0)
            if (owner == Owner.FigureCaption) { figure(); byte(0) }
            else {
                byte(0); byte(1); u32(1)
                if (owner == Owner.FlowScope) {
                    byte(2); byte(0); byte(2); byte(1); byte(1); string("mg"); u32(1)
                }
                byte(1); figure()
            }
        }
        fun document(owner: Owner = Owner.Direct, version: Int = 81, features: Int = 0): ByteArray {
            this.version = version
            out.write(byteArrayOf(68, 80, 82, version.toByte())); u32(0)
            u32(if (owner == Owner.Reference) 0 else 1)
            if (owner != Owner.Reference) {
                byte(2); string("Body"); string(""); string(""); u32(1)
                when (owner) {
                    Owner.Container -> { blockHeader(13); byte(0); blockTail(); u32(0); u32(1); tableBlock() }
                    Owner.FigureCaption, Owner.FlowFigure, Owner.FlowScope -> figureBlock(owner)
                    else -> tableBlock(if (owner == Owner.Direct) "leaf" else "outer", owner)
                }
            }
            u32(0); u32(0); u32(0)
            u32(if (owner == Owner.Reference) 1 else 0)
            if (owner == Owner.Reference) {
                byte(1); u32(1); string(""); u32(0); byte(1); u32(1); tableBlock()
            }
            u32(0)
            if (version >= 80) { mark("Features"); byte(features) }
            return out.toByteArray()
        }
    }
    private fun read(bytes: ByteArray) = BlobDecoder.decode(bytes, "corners", "supplemental", null, "mg")
    private fun leaf(entry: Entry, owner: Owner = Owner.Direct): Table {
        if (owner == Owner.Reference) return entry.references.single().blocks!!.single().table!!
        val block = entry.sections.single().blocks.single()
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
    private fun px(value: Float) = StyleLength(StyleLengthUnit.Px, value)
    private fun corners(values: List<Float>) = TableCornerRadii(px(values[0]), px(values[1]), px(values[2]), px(values[3]))
    private fun mutate(bytes: ByteArray, index: Int, value: Int) = bytes.copyOf().also { it[index] = value.toByte() }
    private fun bad(bytes: ByteArray) { assertThrows(RuntimeException::class.java) { read(bytes) } }

    @Test fun modelRequiresFourPhysicalPixelCornersAndTheirActualBorderOwner() {
        val values = listOf(0f, .125f, 8f, 16777216f)
        val radii = corners(values)
        val style = TableStyle(border = StyleBorder.None, collapse = TableCollapse.Separate, cornerRadii = radii)
        assertEquals(radii, Table(emptyList(), emptyList(), style = style).style!!.cornerRadii)
        assertEquals(0f, radii.topLeft.value, 0f); assertEquals(.125f, radii.topRight.value, 0f)
        assertEquals(8f, radii.bottomRight.value, 0f); assertEquals(16777216f, radii.bottomLeft.value, 0f)
        for (index in 0..3) {
            for (value in listOf(-1f, Float.NaN, Float.POSITIVE_INFINITY, Float.NEGATIVE_INFINITY, 16777218f)) {
                assertThrows(IllegalArgumentException::class.java) { corners(values.toMutableList().also { it[index] = value }) }
            }
            val lengths = values.map(::px).toMutableList().also { it[index] = StyleLength(StyleLengthUnit.Em, 0f) }
            assertThrows(IllegalArgumentException::class.java) { TableCornerRadii(lengths[0], lengths[1], lengths[2], lengths[3]) }
        }
        assertThrows(IllegalArgumentException::class.java) { style.copy(border = null) }
        assertThrows(IllegalArgumentException::class.java) { style.copy(collapse = TableCollapse.Collapse) }
        for (display in listOf(TableDisplay.InlineBlock, TableDisplay.InlineTable))
            assertThrows(IllegalArgumentException::class.java) { style.copy(display = display) }
        val none = StyleBorderEdge.None
        assertThrows(IllegalArgumentException::class.java) { style.copy(border = StyleBorder.Edges(none, none, none, none)) }
        assertThrows(IllegalArgumentException::class.java) { Table(emptyList(), emptyList(), style = style.copy(collapse = null)) }
    }

    @Test fun qAppendsClockwiseTailAfterContainingDirectionAndPreservesOldPBytes() {
        val oldWire = Wire(corners = false); val old = oldWire.document(version = 80, features = 1)
        val nextWire = Wire(); val next = nextWire.document(features = 1)
        val start = nextWire.marks.getValue("leafWideCornerStart")
        val end = nextWire.marks.getValue("leafWideCornerEnd")
        assertEquals(nextWire.marks.getValue("leafWideDirection") + 1, start)
        assertArrayEquals(byteArrayOf(0, 0, 0, 0, 65, 0, 0, 0, 0, 65, 0, 0, 0, 0, 65, 0, 0, 0, 0, 0),
            next.copyOfRange(start, end))
        val stripped = next.copyOfRange(0, start) + next.copyOfRange(end, next.size)
        stripped[3] = 80; stripped[nextWire.marks.getValue("leafWideExtension")] = 24
        assertArrayEquals(old, stripped)
        val decoded = leaf(read(next)); val prior = leaf(read(old))
        assertEquals(prior, decoded.copy(style = decoded.style!!.copy(cornerRadii = null)))
        assertNull(prior.style!!.cornerRadii)
        assertEquals(corners(listOf(8f, 8f, 8f, 0f)), decoded.style!!.cornerRadii)
        assertEquals(TableContainingDirection.Rtl, decoded.style!!.containingDirection)
        assertEquals(BodyAdjoiningPolicy.Ordinary, read(next).bodyAdjoining)
        val body = decoded.rows.single().single().spans.single()
        assertEquals("Body leaf", body.text); assertEquals("body-target-leaf", body.target)
        assertEquals("s", body.trail); assertEquals("part", body.targetFragment)
        assertEquals("full advice", body.tooltip); assertEquals("#123456", body.foreground); assertTrue(body.bold)
        assertEquals("caption-target-leaf", decoded.caption.single().target)
        val zero = read(Wire().document())
        assertNull(zero.bodyAdjoining)
        bad(Wire(corners = false).document())
        bad(Wire(corners = false).document(version = 80))
        val m = Wire(corners = false).document(version = 77)
        assertArrayEquals(m, old.copyOf(old.size - 1).also { it[3] = 77 })
        assertEquals(prior, leaf(read(m)))
    }

    @Test fun recursiveCensusFindsOnlyRealCornersAcrossAllAuthoritativeContentOwners() {
        for (owner in Owner.entries) {
            val entry = read(Wire().document(owner))
            val table = leaf(entry, owner)
            assertEquals("Owner $owner", corners(listOf(8f, 8f, 8f, 0f)), table.style!!.cornerRadii)
            assertEquals("body-target-leaf", table.rows.single().single().spans.single().target)
            assertEquals("caption-target-leaf", table.caption.single().target)
            bad(Wire(corners = false).document(owner))
        }
    }

    @Test fun malformedCornerPayloadsFlagsBordersAndOldHeadersRefuseWithoutDefaults() {
        val wire = Wire(); val valid = wire.document()
        for (version in 67..80) bad(mutate(valid, 3, version))
        for (extension in listOf(0x40, 0x80, 0x78, 0xb8, 0x28, 0x30))
            bad(mutate(valid, wire.marks.getValue("leafWideExtension"), extension))
        for (border in listOf(2, 3, 255)) bad(Wire(wide = StyleWire(border = border)).document())
        for (flags in listOf(1, 3, 5)) bad(Wire(wide = StyleWire(flags = flags)).document())
        bad(Wire(wide = StyleWire(collapse = 1)).document())
        for (display in 1..2) bad(Wire(wide = StyleWire(extension = 0x39, display = display)).document())
        for (index in 0..3) {
            for (unit in listOf(1, 2, 255)) bad(mutate(valid, wire.marks.getValue("leafWideUnit$index"), unit))
            for (value in listOf(-1f, Float.NaN, Float.POSITIVE_INFINITY, Float.NEGATIVE_INFINITY, 16777218f)) {
                val wrong = valid.copyOf(); val bits = value.toRawBits(); val offset = wire.marks.getValue("leafWideValue$index")
                repeat(4) { wrong[offset + it] = (bits ushr (it * 8)).toByte() }
                bad(wrong)
            }
            val offset = wire.marks.getValue("leafWideUnit$index")
            bad(valid.copyOfRange(0, offset) + valid.copyOfRange(offset + 5, valid.size))
        }
        for (size in valid.indices) bad(valid.copyOf(size))
        bad(valid + byteArrayOf(0))
        for (values in listOf(listOf(0f, 0f, 0f, 0f), listOf(.125f, 0f, 16777216f, 2.5f))) {
            val result = leaf(read(Wire(wide = StyleWire(radii = values, border = 0)).document()))
            assertEquals(corners(values), result.style!!.cornerRadii)
            assertEquals(StyleBorder.None, result.style!!.border)
        }
    }

    @Test fun qRetainsActualPFamilyWrapAndCellOwnerPayloadsAndExactFeatureCensus() {
        val features = 1 or 4 or 16 or 128
        val wire = Wire(family = true, wrap = true, cellOwner = true)
        val q = wire.document(features = features)
        val entry = read(q); val table = leaf(entry)
        val p = read(Wire(corners = false, family = true, wrap = true, cellOwner = true).document(version = 80, features = features))
        assertEquals(leaf(p), table.copy(style = table.style!!.copy(cornerRadii = null)))
        assertEquals(p.bodyAdjoining, entry.bodyAdjoining)
        val span = table.rows.single().single().spans.single()
        assertEquals(ContainerFontFamily.Stack(listOf("Corner Serif"), GenericFontFamily.Serif), span.fontFamily)
        assertEquals(TextWrap.Normal, span.inlineStyle!!.wrap)
        val strut = table.rows.single().single().style!!.lineHeight!!.strut!!
        assertEquals(12f, strut.fontScale, 0f); assertEquals(FontScaleBasis.CssPx, strut.fontScaleBasis)
        assertEquals("mg", strut.ownerFont!!.language)
        assertEquals(span.fontFamily, strut.ownerFont!!.fontFamily)
        assertEquals(CellLineHeightValue.Normal, table.rows.single().single().style!!.lineHeight!!.height)
        for (missing in listOf(4, 16, 128)) bad(mutate(q, wire.marks.getValue("Features"), features and missing.inv()))
        // Every P payload-only bit must remain coupled to its payload in Q.
        val bareWire = Wire(); val bare = bareWire.document()
        for (spurious in listOf(2, 4, 8, 16, 32, 64, 128))
            bad(mutate(bare, bareWire.marks.getValue("Features"), spurious))
        val ordinary = mutate(q, wire.marks.getValue("Features"), features and 1.inv())
        assertNull(read(ordinary).bodyAdjoining)
        assertEquals(table, leaf(read(ordinary)))
    }

    @Test fun responsiveBoxOwnsCornersWhileAnonymousGridAndWideTableStayIndependent() {
        val box = StyleWire(flags = 35)
        val entry = read(Wire(box = box).document())
        val table = leaf(entry); val policy = table.blockViewport!!
        assertNull(table.style!!.cornerRadii)
        assertNull(policy.boxStyle.collapse)
        assertEquals(corners(listOf(8f, 8f, 8f, 0f)), policy.boxStyle.cornerRadii)
        assertEquals(StyleBorder.Solid(px(1f), "#bca674"), policy.boxStyle.border)
        assertEquals(TableContainingDirection.Rtl, policy.boxStyle.containingDirection)
        assertEquals(TableContainingDirection.Ltr, policy.gridDirection)
        assertEquals(TableCollapse.Collapse, policy.gridStyle.collapse)
        assertNull(policy.gridStyle.cornerRadii); assertNull(policy.gridStyle.border); assertNull(policy.gridStyle.background)
        assertEquals("body-target-leaf", table.rows.single().single().spans.single().target)
        val old = leaf(read(Wire(corners = false, box = box).document(version = 80, features = 1)))
        assertEquals(old, table.copy(blockViewport = policy.copy(boxStyle = policy.boxStyle.copy(cornerRadii = null))))
        bad(Wire(box = box, grid = StyleWire(flags = 6, extension = 32)).document())
        bad(Wire(box = box.copy(flags = 39)).document())
        bad(Wire(box = box.copy(border = 2)).document())
        bad(Wire(corners = false, box = box).document())
    }

    @Test fun completeSeparateCornerViewportRetainsNumericMarginsDirectionAndExplicitGridGeometry() {
        val wide = StyleWire(flags = 239, extension = 48, width = 100f)
        val box = StyleWire(flags = 235, extension = 48, width = 100f)
        val grid = StyleWire(flags = 4, extension = 0)
        val dimensions = listOf(TableGeometry(cellSpacing = 2, cellPadding = 1),
            TableGeometry(cellSpacing = 0, cellPadding = 0))
        for (shape in dimensions) for (direction in 0..1) {
            val wideState = wide.copy(direction = 1 - direction)
            val wire = Wire(wide = wideState, box = box.copy(direction = direction), grid = grid,
                geometry = shape, wideCorners = true)
            val bytes = wire.document()
            val entry = read(bytes); val table = leaf(entry); val policy = table.blockViewport!!
            assertEquals(81, bytes[3].toInt())
            assertEquals(0, bytes[wire.marks.getValue("Features")].toInt())
            assertNull(entry.bodyAdjoining)
            assertTrue(policy.isSeparateCornerGrid)
            assertEquals(TableScrollFocusPaint(TableScrollFocusMode.AuthoredNone), policy.focusPaint)
            assertEquals(wire.marks.getValue("leafLanguageEnd"), wire.marks.getValue("leafFocusStart"))
            assertArrayEquals(byteArrayOf(0, 0), bytes.copyOfRange(wire.marks.getValue("leafFocusStart"),
                wire.marks.getValue("leafFocusEnd")))
            assertEquals(shape, table.geometry)
            assertEquals(TableCollapse.Separate, table.style!!.collapse)
            assertEquals(TableContainingDirection.entries[1 - direction], table.style!!.containingDirection)
            assertEquals(StyleWidth(StyleWidthUnit.Percent, 100f), table.style!!.width)
            assertNull(table.style!!.marginValues)
            assertNotNull(table.style!!.margins)
            assertEquals(corners(listOf(8f, 8f, 8f, 0f)), table.style!!.cornerRadii)
            assertEquals(table.style!!.cornerRadii, policy.boxStyle.cornerRadii)
            assertEquals(StyleWidth(StyleWidthUnit.Percent, 100f), policy.boxStyle.width)
            assertEquals(StyleWidth(StyleWidthUnit.Percent, 100f), policy.maxWidth)
            assertEquals(ContainerBoxSizing.ContentBox, policy.boxSizing)
            assertEquals(TableContainingDirection.entries[direction], policy.boxStyle.containingDirection)
            assertEquals(TableContainingDirection.Ltr, policy.gridDirection)
            assertNull(policy.boxStyle.marginValues)
            assertEquals(StyleEdges(StyleLength(StyleLengthUnit.Em, 0f), StyleLength(StyleLengthUnit.Em, 0f),
                StyleLength(StyleLengthUnit.Em, .5f), StyleLength(StyleLengthUnit.Em, 0f)), policy.boxStyle.margins)
            val padding = StyleLength(StyleLengthUnit.Em, .1f)
            assertEquals(StyleEdges(padding, padding, padding, padding), policy.boxStyle.padding)
            assertEquals(TableStyle(collapse = TableCollapse.Separate), policy.gridStyle)
            assertEquals("mg", policy.language); assertEquals(639L, policy.maxViewportWidthPx)
            assertEquals("Body leaf", table.rows.single().single().spans.single().text)
            assertEquals("body-target-leaf", table.rows.single().single().spans.single().target)
            assertEquals("part", table.rows.single().single().spans.single().targetFragment)
            assertEquals("caption-target-leaf", table.caption.single().target)
            assertEquals(wire.marks.getValue("leafBoxDirection") + 1, wire.marks.getValue("leafBoxCornerStart"))
            assertEquals(20, wire.marks.getValue("leafBoxCornerEnd") - wire.marks.getValue("leafBoxCornerStart"))
            bad(mutate(bytes, 3, 80))
            val empty = leaf(read(Wire(wide = wideState, box = box.copy(direction = direction), grid = grid,
                geometry = shape, wideCorners = true, emptyGrid = true).document()))
            assertTrue(empty.rows.isEmpty()); assertEquals(shape, empty.geometry)
            assertEquals(policy, empty.blockViewport)
            assertEquals(table.caption, empty.caption)
        }
        val focusPolicies = listOf(TableScrollFocusPaint(TableScrollFocusMode.AuthoredNone),
            TableScrollFocusPaint(TableScrollFocusMode.UaAuto),
            TableScrollFocusPaint(TableScrollFocusMode.UaAuto, FigureColor.NativeTheme),
            TableScrollFocusPaint(TableScrollFocusMode.UaAuto, FigureColor.Transparent),
            TableScrollFocusPaint(TableScrollFocusMode.UaAuto, FigureColor.Rgb("#3366cc")))
        for (focus in focusPolicies) {
            val wire = Wire(wide = wide, box = box, grid = grid, geometry = dimensions.first(), wideCorners = true,
                focusMode = focus.mode.ordinal, focusColor = focus.color)
            val bytes = wire.document()
            val table = leaf(read(bytes))
            assertEquals(focus, table.blockViewport!!.focusPaint)
            assertEquals(0, bytes[wire.marks.getValue("Features")].toInt()) // Q focus never claims P32.
            assertEquals("body-target-leaf", table.rows.single().single().spans.single().target)
            assertEquals("caption-target-leaf", table.caption.single().target)
            bad(mutate(bytes, wire.marks.getValue("Features"), 32))
        }
        val legacy = Wire(box = StyleWire(flags = 35), focusMode = 255)
        assertArrayEquals(Wire(box = StyleWire(flags = 35)).document(), legacy.document())
        assertFalse(legacy.marks.containsKey("leafFocusStart"))
        val ordinaryBase = leaf(read(Wire(wide = wide.copy(extension = 32)).document()))
        assertNull(ordinaryBase.style!!.containingDirection)
        for (direction in 0..1) {
            val directedStyle = wide.copy(extension = 48, direction = direction)
            val wire = Wire(wide = directedStyle, box = null, corners = true)
            val bytes = wire.document()
            val ordinary = leaf(read(bytes))
            assertNull(ordinary.blockViewport)
            assertFalse(wire.marks.containsKey("leafFocusStart"))
            assertEquals(TableContainingDirection.entries[direction], ordinary.style!!.containingDirection)
            assertEquals(ordinaryBase.style!!.margins, ordinary.style!!.margins)
            assertNull(ordinary.style!!.marginValues)
            assertEquals(ordinaryBase, ordinary.copy(style = ordinary.style!!.copy(containingDirection = null)))
            assertEquals("body-target-leaf", ordinary.rows.single().single().spans.single().target)
            assertEquals(wire.marks.getValue("leafWideDirection") + 1, wire.marks.getValue("leafWideCornerStart"))
            bad(Wire(wide = directedStyle, corners = false).document())
            bad(Wire(wide = directedStyle, corners = false).document(version = 80, features = 1))
            bad(mutate(bytes, 3, 80))
        }
    }

    @Test fun separateCornerViewportRejectsIncompleteGeometryWrongOwnersAndUnboundDirection() {
        val wide = StyleWire(flags = 239, extension = 48, width = 100f)
        val box = StyleWire(flags = 235, extension = 48, width = 100f)
        val grid = StyleWire(flags = 4, extension = 0)
        val shape = TableGeometry(cellSpacing = 2, cellPadding = 1)
        fun fixture(nextBox: StyleWire = box, nextGrid: StyleWire = grid, nextWide: StyleWire = wide,
            nextShape: TableGeometry? = shape, maximum: StyleWidth = StyleWidth(StyleWidthUnit.Percent, 100f),
            wideCorners: Boolean = true, paired: Boolean = false) = Wire(wide = nextWide, box = nextBox,
                grid = nextGrid, geometry = nextShape, wideCorners = wideCorners, maximum = maximum,
                paired = paired)
        for (invalid in listOf(null, TableGeometry(cellSpacing = 2), TableGeometry(cellPadding = 1),
            shape.copy(border = 0), shape.copy(width = TableWidth(TableWidthUnit.Px, 100))))
            bad(fixture(nextShape = invalid).document())
        for (invalid in listOf(box.copy(width = 99f), box.copy(widthUnit = 0),
            box.copy(flags = 227), // No numeric margins.
            box.copy(extension = 32), // Corners and numeric margins, but no containing direction.
            box.copy(extension = 56), // Numeric margins and automatic margins conflict.
            box.copy(extension = 16), // Numeric direction is not licensed without corners.
            box.copy(flags = 239), box.copy(flags = 251), box.copy(extension = 49),
            box.copy(extension = 50), box.copy(extension = 52)))
            bad(fixture(nextBox = invalid).document())
        for (invalid in listOf(StyleWidth(StyleWidthUnit.Percent, 99f), StyleWidth(StyleWidthUnit.Px, 100f)))
            bad(fixture(maximum = invalid).document())
        for (invalid in listOf(grid.copy(collapse = 1), grid.copy(flags = 5), grid.copy(flags = 6),
            grid.copy(flags = 12), grid.copy(flags = 20), grid.copy(flags = 36), grid.copy(flags = 68),
            grid.copy(flags = 132), grid.copy(extension = 1), grid.copy(extension = 2),
            grid.copy(extension = 4), grid.copy(flags = 6, extension = 32)))
            bad(fixture(nextGrid = invalid).document())
        bad(fixture(nextWide = wide.copy(flags = 255)).document()) // Wide float is forbidden.
        bad(fixture(nextWide = wide.copy(collapse = 1)).document())
        for (invalid in listOf(wide.copy(flags = 231), // Missing numeric margins.
            wide.copy(extension = 32), // Missing the wide containing direction.
            wide.copy(flags = 207), wide.copy(width = 99f), wide.copy(widthUnit = 0),
            wide.copy(flags = 231, extension = 56))) // Automatic margins cannot substitute.
            bad(fixture(nextWide = invalid).document())
        bad(fixture(wideCorners = false).document())
        bad(fixture(paired = true).document(features = 32))
        val wire = fixture(); val bytes = wire.document()
        bad(mutate(bytes, wire.marks.getValue("leafBoxDirection"), 2))
        val table = leaf(read(bytes)); val policy = table.blockViewport!!
        val focusStart = wire.marks.getValue("leafFocusStart")
        val focusEnd = wire.marks.getValue("leafFocusEnd")
        for (mode in listOf(2, 255)) bad(mutate(bytes, wire.marks.getValue("leafFocusMode"), mode))
        for (presence in listOf(2, 255)) bad(mutate(bytes, wire.marks.getValue("leafFocusPresence"), presence))
        for (size in focusStart until focusEnd) bad(bytes.copyOf(size))
        bad(bytes.copyOfRange(0, focusStart) + bytes.copyOfRange(focusEnd, bytes.size))
        bad(Wire(wide = wide, box = box, grid = grid, geometry = shape, wideCorners = true,
            writeCornerFocus = false).document())
        bad(Wire(wide = wide, box = box, grid = grid, geometry = shape, wideCorners = true,
            focusMode = 0, focusColor = FigureColor.Rgb("#3366cc")).document())
        val coloredWire = Wire(wide = wide, box = box, grid = grid, geometry = shape, wideCorners = true,
            focusMode = 1, focusColor = FigureColor.Rgb("#3366cc"))
        val colored = coloredWire.document()
        bad(mutate(colored, coloredWire.marks.getValue("leafFocusColor"), 3))
        bad(mutate(colored, coloredWire.marks.getValue("leafFocusColor") + 5, 'x'.code))
        for (size in coloredWire.marks.getValue("leafFocusColor") until coloredWire.marks.getValue("leafFocusEnd"))
            bad(colored.copyOf(size))
        assertThrows(IllegalArgumentException::class.java) { policy.copy(focusPaint = null) }
        assertThrows(IllegalArgumentException::class.java) {
            policy.copy(boxStyle = policy.boxStyle.copy(containingDirection = null))
        }
        assertThrows(IllegalArgumentException::class.java) {
            policy.boxStyle.copy(cornerRadii = null)
        }
        assertThrows(IllegalArgumentException::class.java) {
            table.copy(floatViewport = TableFloatViewport(639, TableContainingDirection.Ltr,
                TableContainingDirection.Ltr, "mg"))
        }
        for (invalid in listOf(-1, 65536)) for (invalidShape in listOf(shape.copy(cellSpacing = invalid),
            shape.copy(cellPadding = invalid)))
            assertThrows(IllegalArgumentException::class.java) { table.copy(geometry = invalidShape) }
    }
}
