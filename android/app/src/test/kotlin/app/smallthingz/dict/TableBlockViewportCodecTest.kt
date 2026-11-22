package app.smallthingz.dict

import java.io.ByteArrayOutputStream
import org.junit.Assert.*
import org.junit.Test

/** Literal documents exercise the decoder independently of core encoding. All controls are unrun. */
class TableBlockViewportCodecTest {
    private enum class Owner { Direct, NestedCell, OrderedCell, RichCaption, Container, Reference }
    private data class PolicyWire(val language: String, val threshold: Long = 639, val boxPresent: Boolean = true,
        val boxFlags: Int = 160, val boxExtension: Int = 24, val boxWidth: Float = 70f,
        val boxWidthUnit: Int = 2, val boxDirection: Int = 0, val leftTag: Int = 0, val rightTag: Int = 0,
        val sizing: Int = 0, val maxWidth: Float = 100f, val maxUnit: Int = 2,
        val gridPresent: Boolean = true, val gridFlags: Int = 4, val gridExtension: Int = 4,
        val collapse: Int = 1, val gridDirection: Int = 1, val geometryFlags: Int = 0,
        val widePresent: Boolean = true, val wideFlags: Int = 32, val wideExtension: Int = 0,
        val wideDisplay: Int = 0)
    private class Wire {
        val out = ByteArrayOutputStream()
        val marks = linkedMapOf<String, Int>()
        fun byte(value: Int) { out.write(value) }
        fun u16(value: Int) { repeat(2) { byte(value ushr (it * 8)) } }
        fun u32(value: Long) { repeat(4) { byte((value ushr (it * 8)).toInt()) } }
        fun f32(value: Float) = u32(value.toRawBits().toLong())
        fun string(value: String) { val bytes = value.encodeToByteArray(); u32(bytes.size.toLong()); out.write(bytes) }
        fun mark(name: String) { marks[name] = out.size() }
        fun length(value: Float = .2f, unit: Int = 1) { byte(unit); f32(value) }
        fun span(text: String, target: String) {
            byte(1); byte(0); byte(1) // link, normal role, bold
            string(text); string(target); string("s"); repeat(4) { string("") }
            byte(1); string("#123456"); byte(0); byte(0); byte(0)
            byte(1); string("part"); byte(1); string("full advice")
        }
        fun style(name: String, present: Boolean, flags: Int, extension: Int,
            width: Float = 70f, widthUnit: Int = 2, collapse: Int = 1,
            direction: Int = 0, leftTag: Int = 0, rightTag: Int = 0, display: Int = 0) {
            mark(name + "Presence"); byte(if (present) 1 else 0)
            if (!present) return
            mark(name + "Flags"); byte(flags); mark(name + "Extension"); byte(extension)
            if (flags and 1 != 0) string("#abcdef")
            if (flags and 2 != 0) byte(0) // explicit border:none remains a represented field
            if (flags and 4 != 0) { mark(name + "Collapse"); byte(collapse) }
            if (flags and 8 != 0) repeat(4) { length(0f, 0) }
            if (flags and 16 != 0) byte(0)
            if (flags and 32 != 0) { mark(name + "WidthUnit"); byte(widthUnit); mark(name + "Width"); f32(width) }
            if (flags and 64 != 0) repeat(4) { length(0f, 0) }
            if (flags and 128 != 0) byte(0)
            if (extension and 1 != 0) byte(display)
            if (extension and 2 != 0) byte(1)
            if (extension and 4 != 0) { f32(1.2f); byte(1) }
            if (extension and 8 != 0) {
                byte(1); length()
                byte(rightTag); if (rightTag == 1) length(3f, 0)
                byte(1); length()
                byte(leftTag); if (leftTag == 1) length(3f, 0)
            }
            if (extension and 16 != 0) { mark(name + "Direction"); byte(direction) }
        }
        fun policy(name: String, value: PolicyWire) {
            mark(name + "Policy"); u32(value.threshold)
            style(name + "Box", value.boxPresent, value.boxFlags, value.boxExtension,
                value.boxWidth, value.boxWidthUnit, direction = value.boxDirection,
                leftTag = value.leftTag, rightTag = value.rightTag)
            mark(name + "Sizing"); byte(value.sizing)
            mark(name + "MaxUnit"); byte(value.maxUnit); mark(name + "MaxWidth"); f32(value.maxWidth)
            style(name + "Grid", value.gridPresent, value.gridFlags, value.gridExtension, collapse = value.collapse)
            mark(name + "GridDirection"); byte(value.gridDirection)
            mark(name + "Language"); string(value.language)
            mark(name + "PolicyEnd")
        }
        fun blockHeader(kind: Int, text: String? = null) {
            byte(kind); byte(0); byte(0); u32(if (text == null) 0 else 1)
            if (text != null) span(text, "caption-block-target")
            byte(0); string(""); string("")
        }
        fun blockTail() { string(""); string(""); repeat(4) { byte(0) } }
        fun paragraph() { blockHeader(0, "Rich caption"); byte(0); blockTail() }
        fun tableBlock(name: String, value: PolicyWire?, wrapper: Owner = Owner.Direct,
            rich: Boolean = false, absent: Boolean = false, flatCaption: Boolean = true) {
            blockHeader(12)
            if (absent) byte(0) else table(name, value, wrapper, rich, flatCaption)
            blockTail()
        }
        fun table(name: String, value: PolicyWire?, wrapper: Owner, rich: Boolean, flatCaption: Boolean) {
            val leaf = wrapper == Owner.Direct
            val current = value.takeIf { leaf }
            mark(name + "Table"); byte(if (current == null) 1 else 3)
            val geometry = current?.geometryFlags ?: 0
            byte(geometry)
            if (geometry and 1 != 0) u16(0)
            if (geometry and 2 != 0) u16(0)
            if (geometry and 4 != 0) u16(5)
            if (geometry and 8 != 0) { byte(1); u32(70) }
            val hasFlat = flatCaption && !rich && wrapper != Owner.RichCaption
            u32(if (hasFlat) 1 else 0); if (hasFlat) span("Caption $name", "caption-target-$name")
            u32(1); u32(1); byte(0); u16(1); u16(1); byte(0)
            val cellHasText = wrapper != Owner.NestedCell && wrapper != Owner.OrderedCell
            u32(if (cellHasText) 1 else 0); if (cellHasText) span("Body $name", "body-target-$name")
            if (wrapper == Owner.NestedCell) table("leaf", value, Owner.Direct, rich, flatCaption) else byte(0)
            if (wrapper == Owner.OrderedCell) { byte(1); u32(1); tableBlock("leaf", value, rich = rich, flatCaption = flatCaption) }
            else byte(0)
            mark(name + "CellStyle"); byte(0) // cell style absent
            style(name + "Wide", current?.widePresent ?: true, current?.wideFlags ?: 32,
                current?.wideExtension ?: 0, display = current?.wideDisplay ?: 0)
            mark(name + "CaptionBlocks")
            when {
                wrapper == Owner.RichCaption -> { byte(1); u32(1); tableBlock("leaf", value, rich = rich, flatCaption = flatCaption) }
                rich -> { byte(1); u32(1); paragraph() }
                else -> byte(0)
            }
            mark(name + "BaseEnd")
            if (current != null) policy(name, current)
            mark(name + "End")
        }
        fun document(value: PolicyWire? = PolicyWire("ru"), version: Int = 77, owner: Owner = Owner.Direct,
            rich: Boolean = false, absent: Boolean = false, flatCaption: Boolean = true): ByteArray {
            out.write(byteArrayOf(68, 80, 82, version.toByte())); u32(0)
            u32(if (owner == Owner.Reference) 0 else 1)
            if (owner != Owner.Reference) {
                byte(2); string("Body"); string(""); string(""); u32(1)
                if (owner == Owner.Container) {
                    blockHeader(13); byte(0); blockTail(); u32(0); u32(1)
                    tableBlock("leaf", value, rich = rich, flatCaption = flatCaption)
                } else tableBlock(if (owner == Owner.Direct) "leaf" else "outer", value, owner, rich, absent, flatCaption)
            }
            u32(0); u32(0); u32(0) // preamble, lexemes, unassigned sections
            u32(if (owner == Owner.Reference) 1 else 0)
            if (owner == Owner.Reference) {
                byte(1); u32(1); string(""); u32(0); byte(1); u32(1)
                tableBlock("leaf", value, rich = rich, flatCaption = flatCaption)
            }
            u32(0) // media
            return out.toByteArray()
        }
    }
    private fun read(bytes: ByteArray) = BlobDecoder.decode(bytes, "viewport", "supplemental", null, "ru")
    private fun leaf(entry: Entry, owner: Owner = Owner.Direct): Table = when (owner) {
        Owner.Direct -> entry.sections.single().blocks.single().table!!
        Owner.NestedCell -> entry.sections.single().blocks.single().table!!.rows.single().single().nestedTable!!
        Owner.OrderedCell -> entry.sections.single().blocks.single().table!!.rows.single().single().blocks!!.single().table!!
        Owner.RichCaption -> entry.sections.single().blocks.single().table!!.captionBlocks!!.single().table!!
        Owner.Container -> entry.sections.single().blocks.single().container!!.blocks.single().table!!
        Owner.Reference -> entry.references.single().blocks!!.single().table!!
    }

    @Test fun completeTailPreservesOldTableBytesBodyActionsAndIndependentDirections() {
        val oldWire = Wire(); val old = oldWire.document(null)
        val nextWire = Wire(); val next = nextWire.document()
        val oldStart = oldWire.marks.getValue("leafTable"); val oldEnd = oldWire.marks.getValue("leafBaseEnd")
        val newStart = nextWire.marks.getValue("leafTable"); val newEnd = nextWire.marks.getValue("leafEnd")
        assertEquals(1, old[oldStart].toInt()); assertEquals(3, next[newStart].toInt())
        assertArrayEquals(old.copyOfRange(oldStart + 1, oldEnd), next.copyOfRange(newStart + 1, nextWire.marks.getValue("leafBaseEnd")))
        assertArrayEquals(old.copyOfRange(oldEnd, old.size), next.copyOfRange(newEnd, next.size))
        assertArrayEquals(byteArrayOf(127, 2, 0, 0), next.copyOfRange(oldEnd, oldEnd + 4))
        val table = leaf(read(next)); val policy = table.blockViewport!!
        assertEquals(639L, policy.maxViewportWidthPx)
        assertEquals(ContainerBoxSizing.ContentBox, policy.boxSizing)
        assertEquals(StyleWidth(StyleWidthUnit.Percent, 70f), policy.boxStyle.width)
        assertEquals(StyleWidth(StyleWidthUnit.Percent, 100f), policy.maxWidth)
        assertEquals(TableContainingDirection.Ltr, policy.boxStyle.containingDirection)
        assertEquals(TableContainingDirection.Rtl, policy.gridDirection)
        assertEquals("ru", policy.language)
        assertEquals(TableCollapse.Collapse, policy.gridStyle.collapse)
        assertEquals(ComputedLineHeight(1.2f, FontScaleBasis.NormalBody), policy.gridStyle.lineHeight)
        assertEquals(leaf(read(old)), table.copy(blockViewport = null))
        val body = table.rows.single().single().spans.single()
        assertEquals("Body leaf", body.text); assertEquals("body-target-leaf", body.target)
        assertEquals("s", body.trail); assertEquals("part", body.targetFragment)
        assertEquals("full advice", body.tooltip); assertEquals("#123456", body.foreground); assertTrue(body.bold)
        assertEquals("caption-target-leaf", table.caption.single().target)
    }

    @Test fun existingRecursiveTableOwnersReadTheSamePolicyAndRichCaptionTail() {
        for (owner in Owner.entries) {
            val table = leaf(read(Wire().document(owner = owner, rich = true)), owner)
            assertNotNull(table.blockViewport)
            assertTrue(table.caption.isEmpty())
            val caption = table.captionBlocks!!.single().spans.single()
            assertEquals("Rich caption", caption.text); assertEquals("caption-block-target", caption.target)
            assertEquals("body-target-leaf", table.rows.single().single().spans.single().target)
        }
    }

    @Test fun nullPolicyKeepsKAndMBytesAndAbsenceFramingExact() {
        val m = Wire().document(null); val k = Wire().document(null, version = 75)
        assertArrayEquals(m.copyOf().also { it[3] = 75 }, k)
        assertEquals(leaf(read(k)), leaf(read(m)))
        assertNull(leaf(read(m)).blockViewport)
        assertNull(read(Wire().document(null, absent = true)).sections.single().blocks.single().table)
        val wire = Wire(); val valid = wire.document()
        for (version in listOf(74, 75, 76)) {
            val old = valid.copyOf().also { it[3] = version.toByte() }
            assertThrows(RuntimeException::class.java) { read(old) }
        }
    }

    @Test fun mandatoryOrderPresenceFlagsEnumsAndCompleteTruncationAreStrict() {
        val wire = Wire(); val valid = wire.document()
        fun mutate(mark: String, value: Int) = valid.copyOf().also { it[wire.marks.getValue(mark)] = value.toByte() }
        for (flag in listOf(2, 4, 129, 255)) assertThrows(RuntimeException::class.java) { read(mutate("leafTable", flag)) }
        for (mark in listOf("leafBoxPresence", "leafGridPresence"))
            assertThrows(RuntimeException::class.java) { read(mutate(mark, 3)) }
        for (mark in listOf("leafSizing", "leafBoxDirection", "leafGridDirection"))
            assertThrows(RuntimeException::class.java) { read(mutate(mark, 2)) }
        for (mark in listOf("leafBoxWidthUnit", "leafMaxUnit"))
            assertThrows(RuntimeException::class.java) { read(mutate(mark, 3)) }
        for (value in listOf(PolicyWire("ru", boxPresent = false), PolicyWire("ru", gridPresent = false)))
            assertThrows(RuntimeException::class.java) { read(Wire().document(value)) }
        val tail = wire.marks.getValue("leafPolicy"); val tailEnd = wire.marks.getValue("leafPolicyEnd")
        val caption = wire.marks.getValue("leafCaptionBlocks")
        val misplaced = valid.copyOfRange(0, caption) + valid.copyOfRange(tail, tailEnd) + valid.copyOfRange(caption, tail) + valid.copyOfRange(tailEnd, valid.size)
        assertThrows(RuntimeException::class.java) { read(misplaced) }
        val box = wire.marks.getValue("leafBoxPresence"); val sizing = wire.marks.getValue("leafSizing")
        val grid = wire.marks.getValue("leafGridPresence"); val direction = wire.marks.getValue("leafGridDirection")
        val swappedRoles = valid.copyOfRange(0, box) + valid.copyOfRange(grid, direction) +
            valid.copyOfRange(sizing, grid) + valid.copyOfRange(box, sizing) + valid.copyOfRange(direction, valid.size)
        assertThrows(RuntimeException::class.java) { read(swappedRoles) }
        for (size in valid.indices) assertThrows(RuntimeException::class.java) { read(valid.copyOf(size)) }
        assertThrows(RuntimeException::class.java) { read(valid + byteArrayOf(0)) }
    }

    @Test fun roleDomainsRejectDefaultsThatBelongToAnotherOwner() {
        val invalidBoxes = listOf(PolicyWire("ru", boxFlags = 128), PolicyWire("ru", boxWidth = 0f),
            PolicyWire("ru", boxExtension = 0), PolicyWire("ru", boxExtension = 8), PolicyWire("ru", boxExtension = 16),
            PolicyWire("ru", boxFlags = 168), PolicyWire("ru", boxFlags = 176), PolicyWire("ru", boxFlags = 164),
            PolicyWire("ru", boxExtension = 25), PolicyWire("ru", boxExtension = 26), PolicyWire("ru", boxExtension = 28),
            PolicyWire("ru", leftTag = 1, rightTag = 1))
        val invalidGrids = listOf(PolicyWire("ru", collapse = 0), PolicyWire("ru", gridFlags = 0),
            PolicyWire("ru", gridFlags = 5), PolicyWire("ru", gridFlags = 6), PolicyWire("ru", gridFlags = 68),
            PolicyWire("ru", gridFlags = 36), PolicyWire("ru", gridFlags = 12), PolicyWire("ru", gridFlags = 20),
            PolicyWire("ru", gridFlags = 132), PolicyWire("ru", gridExtension = 5), PolicyWire("ru", gridExtension = 6),
            PolicyWire("ru", gridExtension = 28))
        for (value in invalidBoxes + invalidGrids) assertThrows(RuntimeException::class.java) { read(Wire().document(value)) }
        for (value in listOf(-1f, Float.NaN, Float.POSITIVE_INFINITY, Float.NEGATIVE_INFINITY)) {
            assertThrows(RuntimeException::class.java) { read(Wire().document(PolicyWire("ru", boxWidth = value))) }
            assertThrows(RuntimeException::class.java) { read(Wire().document(PolicyWire("ru", maxWidth = value))) }
        }
        for (flags in listOf(1, 2, 4, 8))
            assertThrows(RuntimeException::class.java) { read(Wire().document(PolicyWire("ru", geometryFlags = flags))) }
        assertThrows(RuntimeException::class.java) { read(Wire().document(PolicyWire("ru", wideFlags = 16))) }
        assertThrows(RuntimeException::class.java) {
            read(Wire().document(PolicyWire("ru", wideFlags = 0, wideExtension = 1, wideDisplay = 2), flatCaption = false))
        }
    }

    @Test fun zeroAndUnsignedThresholdsCapsAndSingleAutoRemainRepresentable() {
        for (threshold in listOf(0L, 639L, 0xffff_ffffL)) for (unit in 0..2) {
            val value = PolicyWire("ru", threshold = threshold, maxWidth = 0f, maxUnit = unit,
                boxFlags = 227, sizing = 1, leftTag = 1, widePresent = false)
            val policy = leaf(read(Wire().document(value))).blockViewport!!
            assertEquals(threshold, policy.maxViewportWidthPx)
            assertEquals(StyleWidth(StyleWidthUnit.entries[unit], 0f), policy.maxWidth)
            assertEquals(ContainerBoxSizing.BorderBox, policy.boxSizing)
            assertEquals(ContainerMargin.Length(StyleLength(StyleLengthUnit.Px, 3f)), policy.boxStyle.marginValues!!.left)
            assertEquals(ContainerMargin.Auto, policy.boxStyle.marginValues!!.right)
            assertEquals("#abcdef", policy.boxStyle.background)
            assertEquals(StyleBorder.None, policy.boxStyle.border)
            assertNotNull(policy.boxStyle.padding)
        }
    }

    @Test fun literalCellMiddlePreservesNullTopAndTheExistingMetricPayloadOrder() {
        val wire = Wire(); val absent = wire.document(null)
        val at = wire.marks.getValue("leafCellStyle")
        fun styled(payload: ByteArray) = absent.copyOfRange(0, at) + payload + absent.copyOfRange(at + 1, absent.size)
        val top = styled(byteArrayOf(1, 0x80.toByte(), 0))
        val middle = styled(byteArrayOf(1, 0x80.toByte(), 1))
        assertEquals(0, absent[at].toInt())
        assertNull(leaf(read(absent)).rows.single().single().style)
        assertEquals(CellVerticalAlign.Top, leaf(read(top)).rows.single().single().style!!.verticalAlign)
        assertEquals(CellVerticalAlign.Middle, leaf(read(middle)).rows.single().single().style!!.verticalAlign)
        assertArrayEquals(top.copyOf().also { it[at + 2] = 1 }, middle)
        assertArrayEquals(absent.copyOfRange(0, at), middle.copyOfRange(0, at))
        assertArrayEquals(absent.copyOfRange(at + 1, absent.size), middle.copyOfRange(at + 3, middle.size))

        val metrics = Wire().apply {
            byte(1); byte(0xe8) // width, minimum, vertical alignment, line height
            byte(2); f32(55f) // preferred width precedes the minimum and alignment
            length(11f, 0)
            byte(1) // explicit middle
            byte(0); byte(1); f32(1.25f) // absent strut, multiplier line height
        }.out.toByteArray()
        val decoded = leaf(read(styled(metrics))).rows.single().single().style!!
        assertEquals(StyleWidth(StyleWidthUnit.Percent, 55f), decoded.width)
        assertEquals(StyleLength(StyleLengthUnit.Px, 11f), decoded.minWidth)
        assertEquals(CellVerticalAlign.Middle, decoded.verticalAlign)
        assertEquals(CellLineHeight(CellLineHeightValue.Multiplier(1.25f)), decoded.lineHeight)
        assertEquals("body-target-leaf", leaf(read(styled(metrics))).rows.single().single().spans.single().target)
    }

    @Test fun requiredLanguageTailIsIndependentFromEntryAndRejectsMissingOrMalformedBytes() {
        val wire = Wire(); val valid = wire.document()
        val direction = wire.marks.getValue("leafGridDirection")
        val language = wire.marks.getValue("leafLanguage")
        val end = wire.marks.getValue("leafPolicyEnd")
        assertEquals(direction + 1, language)
        assertArrayEquals(byteArrayOf(2, 0, 0, 0, 'r'.code.toByte(), 'u'.code.toByte()), valid.copyOfRange(language, end))
        val entry = BlobDecoder.decode(valid, "viewport", "language", "Japanese", "ja")
        assertEquals("ja", entry.languageCode)
        assertEquals("ru", leaf(entry).blockViewport!!.language)
        assertEquals("body-target-leaf", leaf(entry).rows.single().single().spans.single().target)
        for (source in listOf("ru", "RU", "sr-Latn-RS", "und", "x-source"))
            assertEquals(source, leaf(read(Wire().document(PolicyWire(source)))).blockViewport!!.language)
        assertThrows(RuntimeException::class.java) { read(Wire().document(PolicyWire(""))) }
        val missing = valid.copyOfRange(0, language) + valid.copyOfRange(end, valid.size)
        assertThrows(RuntimeException::class.java) { read(missing) }
        val beforeDirection = valid.copyOfRange(0, direction) + valid.copyOfRange(language, end) +
            valid.copyOfRange(direction, language) + valid.copyOfRange(end, valid.size)
        assertThrows(RuntimeException::class.java) { read(beforeDirection) }
        for (size in language until end)
            assertThrows(RuntimeException::class.java) { read(valid.copyOf(size)) }
        val oversized = valid.copyOf().also { bytes ->
            repeat(4) { bytes[language + it] = ((32 * 1024 * 1024 + 1) ushr (it * 8)).toByte() }
        }
        assertThrows(RuntimeException::class.java) { read(oversized) }
        val invalidUtf8 = valid.copyOf().also { it[language + 4] = 0xc0.toByte(); it[language + 5] = 0xaf.toByte() }
        assertThrows(java.nio.charset.CharacterCodingException::class.java) { read(invalidUtf8) }
    }

    @Test fun cellMiddleRejectsOlderHeadersUnknownValuesAndTruncatedPayloads() {
        val wire = Wire(); val absent = wire.document(null)
        val at = wire.marks.getValue("leafCellStyle")
        fun styled(alignment: Int) = absent.copyOfRange(0, at) + byteArrayOf(1, 0x80.toByte(), alignment.toByte()) +
            absent.copyOfRange(at + 1, absent.size)
        for (alignment in listOf(2, 127, 255))
            assertThrows(RuntimeException::class.java) { read(styled(alignment)) }
        for (version in listOf(74, 75, 76)) for (alignment in listOf(0, 1)) {
            val older = styled(alignment).also { it[3] = version.toByte() }
            assertThrows(RuntimeException::class.java) { read(older) }
        }
        val middle = styled(1)
        for (size in at..at + 2)
            assertThrows(RuntimeException::class.java) { read(middle.copyOf(size)) }
    }

    @Test fun unsupportedNativeLanguageDecodesCompleteTableAndActionsForEveryOwner() {
        for (owner in Owner.entries) {
            val baseline = leaf(read(Wire().document(PolicyWire("ru"), owner = owner, rich = true)), owner)
            for (source in listOf("ru--RU", "zh-cmn", "i-klingon", "\u65e5\u672c", "\uD83D\uDE00")) {
                val decoded = leaf(read(Wire().document(PolicyWire(source), owner = owner, rich = true)), owner)
                val policy = checkNotNull(decoded.blockViewport)
                assertEquals(source, policy.language)
                assertNull(nativeTableOwnerLanguageTag(policy.language))
                assertEquals(baseline, decoded.copy(blockViewport = policy.copy(language = "ru")))
                assertEquals("body-target-leaf", decoded.rows.single().single().spans.single().target)
                assertEquals("caption-block-target", decoded.captionBlocks!!.single().spans.single().target)
            }
        }
    }
}
