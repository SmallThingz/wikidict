package app.smallthingz.dict

import java.io.ByteArrayOutputStream
import org.junit.Assert.*
import org.junit.Test

/** Literal wire documents independent of a core encoder. Source-only, unrun controls. */
class TableFloatViewportCodecTest {
    private enum class Owner { Direct, NestedCell, OrderedCell, RichCaption, Container, Reference, FigureCaption, ScopeFigureCaption }
    private data class Policy(val threshold: Long = 639, val containing: Int = 0,
        val grid: Int = 1, val language: String = "de", val narrowClear: Int? = null)
    private data class Shape(val present: Boolean = true, val flags: Int = 159, val extension: Int = 0,
        val side: Int = 1, val geometry: Int = 0, val flatCaption: Boolean = false,
        val richCaption: Boolean = false, val rows: Int = 1, val cells: Int = 1, val emptyCell: Boolean = false,
        val widthUnit: Int = 0, val widthValue: Float = 0f, val clear: Int = 3)
    private class Wire {
        val out = ByteArrayOutputStream()
        val marks = linkedMapOf<String, Int>()
        fun mark(name: String) { check(marks.put(name, out.size()) == null) }
        fun byte(value: Int) { out.write(value) }
        fun u16(value: Int) { repeat(2) { byte(value ushr (it * 8)) } }
        fun u32(value: Long) { repeat(4) { byte((value ushr (it * 8)).toInt()) } }
        fun f32(value: Float) = u32(value.toRawBits().toLong())
        fun string(value: String) { val raw = value.encodeToByteArray(); u32(raw.size.toLong()); out.write(raw) }
        fun length(value: Float = 0f, unit: Int = 0) { byte(unit); f32(value) }
        fun edges() { length(.25f, 1); length(6f); length(.5f, 1); length(4f) }
        fun span(text: String, target: String, trail: String = "s", family: Boolean = false) {
            byte(1); byte(0); byte(1)
            string(text); string(target); string(trail); repeat(4) { string("") }
            byte(1); string("#123456"); byte(0); byte(if (family) 16 else 0)
            if (family) byte(0) // explicit Span Sans uses P feature4; Container Sans still does not.
            byte(0)
            byte(1); string("Deutsch"); byte(1); string("authored advice")
        }
        fun style(shape: Shape) {
            byte(if (shape.present) 1 else 0)
            if (!shape.present) return
            byte(shape.flags); byte(shape.extension)
            if (shape.flags and 1 != 0) string("#abcdef")
            if (shape.flags and 2 != 0) byte(0)
            if (shape.flags and 4 != 0) byte(1)
            if (shape.flags and 8 != 0) edges()
            if (shape.flags and 16 != 0) byte(shape.side)
            if (shape.flags and 32 != 0) { byte(shape.widthUnit); f32(shape.widthValue) }
            if (shape.flags and 64 != 0) repeat(4) { length() }
            if (shape.flags and 128 != 0) byte(shape.clear)
            if (shape.extension and 1 != 0) byte(0)
            if (shape.extension and 2 != 0) byte(1)
            if (shape.extension and 4 != 0) { f32(1f); byte(1) }
            if (shape.extension and 8 != 0) {
                byte(1); length(); byte(0); byte(1); length(); byte(0)
            }
            if (shape.extension and 16 != 0) byte(0)
        }
        fun floatPolicy(name: String, value: Policy) {
            mark(name + "Policy"); u32(value.threshold)
            mark(name + "Containing"); byte(value.containing)
            mark(name + "Grid"); byte(value.grid)
            mark(name + "Language"); string(value.language)
            if (value.narrowClear != null) { mark(name + "Clear"); byte(value.narrowClear) }
            mark(name + "PolicyEnd")
        }
        fun oldBlockPolicy() {
            u32(639)
            byte(1); byte(32); byte(24) // width, paired auto margins + containing direction
            byte(2); f32(70f)
            byte(1); length(); byte(0); byte(1); length(); byte(0); byte(0)
            byte(0); byte(2); f32(100f) // content-box, max-width:100%
            byte(1); byte(4); byte(0); byte(1) // anonymous grid collapse
            byte(1); string("ru")
        }
        fun blockHeader(kind: Int) {
            byte(kind); byte(0); byte(0); u32(0); byte(0); string(""); string("")
        }
        fun blockTail() { string(""); string(""); repeat(4) { byte(0) } }
        fun tableBlock(name: String, policy: Policy?, shape: Shape = Shape(), owner: Owner = Owner.Direct,
            absent: Boolean = false, blockPolicy: Boolean = false) {
            blockHeader(12)
            if (absent) { mark(name + "Table"); byte(0) }
            else table(name, policy, shape, owner, blockPolicy)
            blockTail()
        }
        fun table(name: String, policy: Policy?, shape: Shape, owner: Owner, blockPolicy: Boolean = false) {
            val leaf = owner == Owner.Direct
            val local = if (leaf) shape else Shape()
            val selected = policy.takeIf { leaf }
            mark(name + "Table"); byte(if (blockPolicy) 3 else if (selected?.narrowClear != null) 13 else if (selected != null) 5 else 1)
            byte(local.geometry)
            if (local.geometry and 1 != 0) u16(0)
            if (local.geometry and 2 != 0) u16(0)
            if (local.geometry and 4 != 0) u16(0)
            if (local.geometry and 8 != 0) { byte(1); u32(70) }
            u32(if (local.flatCaption) 1 else 0)
            if (local.flatCaption) span("Caption", "caption-target")
            u32(local.rows.toLong())
            repeat(local.rows) {
                u32(local.cells.toLong())
                repeat(local.cells) {
                    byte(0); u16(1); u16(1); byte(0)
                    val body = !local.emptyCell && owner != Owner.NestedCell && owner != Owner.OrderedCell
                    u32(if (body) 1 else 0)
                    if (body) span("Mai $name", "target-$name")
                    if (owner == Owner.NestedCell) table("leaf", policy, shape, Owner.Direct) else byte(0)
                    if (owner == Owner.OrderedCell) { byte(1); u32(1); tableBlock("leaf", policy, shape) }
                    else byte(0)
                    byte(0) // cell style absent
                }
            }
            if (blockPolicy) byte(0) else style(local)
            mark(name + "CaptionBlocks")
            if (owner == Owner.RichCaption) { byte(1); u32(1); tableBlock("leaf", policy, shape) }
            else if (local.richCaption) { byte(1); u32(0) } else byte(0)
            mark(name + "BaseEnd")
            if (blockPolicy) oldBlockPolicy() else if (selected != null) floatPolicy(name, selected)
            mark(name + "End")
        }
        fun figureBlock(policy: Policy?, shape: Shape) {
            blockHeader(0); byte(0); string(""); string(""); byte(0); byte(0)
            imageFigure(policy, shape)
            byte(0) // no flow
        }
        fun scopeFigureBlock(policy: Policy?, shape: Shape) {
            blockHeader(0); byte(0); string(""); string(""); byte(0); byte(0); byte(0)
            byte(1); u32(1); byte(2) // flow with one Scope
            byte(0); byte(1); byte(0); byte(0) // isolate, authored/resolved LTR, no scope language
            u32(1); byte(1); imageFigure(policy, shape)
        }
        fun imageFigure(policy: Policy?, shape: Shape) {
            byte(1); byte(0); byte(0); byte(0) // image Figure, thumbnail, normal, no clear
            repeat(12) { length() }; f32(1f); length(1.5f, 1)
            byte(1); byte(0); byte(1); byte(0); byte(0); byte(1)
            byte(1); byte(0); byte(0)
            string(""); string("File:Map.png"); repeat(5) { string("") }
            repeat(3) { byte(0) }; byte(1); string("Map.png"); byte(1); u32(120)
            byte(0); byte(0)
            u32(0); byte(1); u32(1); tableBlock("leaf", policy, shape)
            byte(0); byte(2); byte(0) // no caption align, requested-fit, no frame minimum
        }
        fun document(policy: Policy? = Policy(), shape: Shape = Shape(), owner: Owner = Owner.Direct,
            version: Int = 77, absent: Boolean = false, blockPolicy: Boolean = false, features: Int = 1): ByteArray {
            out.write(byteArrayOf(68, 80, 82, version.toByte())); u32(0)
            u32(if (owner == Owner.Reference) 0 else 1)
            if (owner != Owner.Reference) {
                byte(2); string("Body"); string(""); string(""); u32(1)
                when (owner) {
                    Owner.Container -> {
                        blockHeader(13); byte(0); blockTail(); u32(0); u32(1); tableBlock("leaf", policy, shape)
                    }
                    Owner.FigureCaption -> figureBlock(policy, shape)
                    Owner.ScopeFigureCaption -> scopeFigureBlock(policy, shape)
                    else -> tableBlock(if (owner == Owner.Direct) "leaf" else "outer", policy, shape, owner, absent, blockPolicy)
                }
            }
            u32(0); u32(0); u32(0)
            u32(if (owner == Owner.Reference) 1 else 0)
            if (owner == Owner.Reference) {
                byte(1); u32(1); string(""); u32(0); byte(1); u32(1); tableBlock("leaf", policy, shape)
            }
            val hasFigure = owner == Owner.FigureCaption || owner == Owner.ScopeFigureCaption
            u32(if (hasFigure) 1 else 0)
            if (hasFigure) { string("Map.png"); byte(0); string("catalogue") }
            if (version == 80) { mark("Features"); byte(features) }
            return out.toByteArray()
        }
        fun prefixDocument(features: Int, policy: Policy): ByteArray {
            out.write(byteArrayOf(68, 80, 82, 80))
            u32(if (features and 4 != 0) 1 else 0)
            if (features and 4 != 0) span("Display", "DisplayTarget", family = true)
            u32(2)
            byte(0); string(""); string(""); string(""); u32(1)
            tableBlock("outer", policy, Shape(flags = 191, widthUnit = 1, widthValue = 25f, clear = 2), Owner.NestedCell)
            byte(2); string("Heading"); string("heading"); string(""); u32(1)
            byte(9); byte(0); byte(2); u32(1); span("Heading", "HeadingTarget", trail = "")
            byte(0); string(""); string(""); byte(0); string("heading"); string(""); repeat(4) { byte(0) }
            repeat(5) { u32(0) } // preamble, lexemes, unowned sections, references, media
            mark("Features"); byte(features)
            if (features and 2 != 0) {
                u32(1); u32(1) // the real heading is index1; prefix remains index0
                u32(1L or 2L or 16L or 2048L or 4096L or 65536L or (1L shl 22))
                repeat(8) { length() }; byte(0); byte(0); byte(1); f32(1f); f32(1f); byte(0)
                byte(1); f32(1f); byte(1); byte(0); string("th"); string(""); byte(0); byte(0)
            }
            return out.toByteArray()
        }
    }
    private fun read(bytes: ByteArray) = BlobDecoder.decode(bytes, "Mai", "supplemental", null, "ja")
    private fun leaf(entry: Entry, owner: Owner = Owner.Direct): Table = when (owner) {
        Owner.Direct -> entry.sections.single().blocks.single().table!!
        Owner.NestedCell -> entry.sections.single().blocks.single().table!!.rows.single().single().nestedTable!!
        Owner.OrderedCell -> entry.sections.single().blocks.single().table!!.rows.single().single().blocks!!.single().table!!
        Owner.RichCaption -> entry.sections.single().blocks.single().table!!.captionBlocks!!.single().table!!
        Owner.Container -> entry.sections.single().blocks.single().container!!.blocks.single().table!!
        Owner.Reference -> entry.references.single().blocks!!.single().table!!
        Owner.FigureCaption -> entry.sections.single().blocks.single().figure!!.captionBlocks!!.single().table!!
        Owner.ScopeFigureCaption -> ((entry.sections.single().blocks.single().flow!!.single() as FlowPart.Scope)
            .scope.parts.single() as FlowPart.ImageFigure).figure.captionBlocks!!.single().table!!
    }

    @Test fun literalTailRetainsEveryBaseByteAndCompleteBodyAction() {
        val oldWire = Wire(); val old = oldWire.document(null)
        val wire = Wire(); val bytes = wire.document()
        val oldStart = oldWire.marks.getValue("leafTable"); val start = wire.marks.getValue("leafTable")
        val oldEnd = oldWire.marks.getValue("leafBaseEnd"); val baseEnd = wire.marks.getValue("leafBaseEnd")
        val end = wire.marks.getValue("leafEnd")
        assertEquals(1, old[oldStart].toInt()); assertEquals(5, bytes[start].toInt())
        assertArrayEquals(old.copyOfRange(oldStart + 1, oldEnd), bytes.copyOfRange(start + 1, baseEnd))
        assertArrayEquals(old.copyOfRange(oldEnd, old.size), bytes.copyOfRange(end, bytes.size))
        assertArrayEquals(byteArrayOf(127, 2, 0, 0, 0, 1, 2, 0, 0, 0, 100, 101), bytes.copyOfRange(baseEnd, end))
        val table = leaf(read(bytes)); val policy = table.floatViewport!!
        assertEquals(TableFloatViewport(639, TableContainingDirection.Ltr, TableContainingDirection.Rtl, "de"), policy)
        assertEquals(leaf(read(old)), table.copy(floatViewport = null))
        assertEquals("ja", read(bytes).languageCode)
        val span = table.rows.single().single().spans.single()
        assertEquals("Mai leaf", span.text); assertEquals("target-leaf", span.target)
        assertEquals("Deutsch", span.targetFragment); assertEquals("authored advice", span.tooltip)
        assertEquals("s", span.trail); assertEquals("#123456", span.foreground); assertTrue(span.bold)
        assertEquals(FigureClear.Both, table.style!!.clear)
        assertEquals(TableCollapse.Collapse, table.style!!.collapse)
        assertNull(table.blockViewport)
    }

    @Test fun recursiveOwnersKeepOneCaptionlessLeafWithoutNarrowingTheirOwnDomains() {
        for (owner in Owner.entries) {
            val table = leaf(read(Wire().document(owner = owner)), owner)
            assertEquals("de", table.floatViewport!!.language)
            assertTrue(table.caption.isEmpty()); assertNull(table.captionBlocks)
            assertEquals("target-leaf", table.rows.single().single().spans.single().target)
        }
        val empty = leaf(read(Wire().document(shape = Shape(emptyCell = true))))
        assertTrue(empty.rows.single().single().spans.isEmpty())
        assertNotNull(empty.floatViewport)
    }

    @Test fun mPresenceDomainKeepsLegacyNullBytesAndExistingBlockPolicy() {
        val m = Wire().document(null); val k = Wire().document(null, version = 75)
        assertArrayEquals(m.copyOf().also { it[3] = 75 }, k)
        assertEquals(leaf(read(m)), leaf(read(k)))
        assertNull(read(Wire().document(null, absent = true)).sections.single().blocks.single().table)
        val block = leaf(read(Wire().document(null, blockPolicy = true)))
        assertNotNull(block.blockViewport); assertNull(block.floatViewport)
        val wire = Wire(); val bytes = wire.document()
        for (tag in listOf(2, 4, 6, 7, 8, 129, 255)) {
            val changed = bytes.copyOf().also { it[wire.marks.getValue("leafTable")] = tag.toByte() }
            assertThrows(RuntimeException::class.java) { read(changed) }
        }
        for (version in listOf(75, 76))
            assertThrows(RuntimeException::class.java) { read(bytes.copyOf().also { it[3] = version.toByte() }) }
    }

    @Test fun wireClosureRejectsForbiddenBaseFieldsCaptionAndEmptyGrid() {
        for (shape in listOf(Shape(present = false), Shape(flags = 151), Shape(flags = 143), Shape(side = 0),
            Shape(flags = 191, widthUnit = 2, widthValue = 70f), Shape(flags = 223), Shape(extension = 1), Shape(extension = 2),
            Shape(extension = 4), Shape(flags = 151, extension = 24), Shape(geometry = 1),
            Shape(geometry = 4), Shape(geometry = 8), Shape(flatCaption = true), Shape(richCaption = true),
            Shape(rows = 0), Shape(cells = 0))) {
            assertThrows(RuntimeException::class.java) { read(Wire().document(shape = shape)) }
        }
    }

    @Test fun thresholdsDirectionBytesTailPositionAndTruncationAreStrict() {
        assertEquals(0xffff_ffffL, leaf(read(Wire().document(Policy(threshold = 0xffff_ffffL)))).floatViewport!!.maxViewportWidthPx)
        assertThrows(RuntimeException::class.java) { read(Wire().document(Policy(threshold = 0))) }
        for (containing in 0..1) for (grid in 0..1) {
            val policy = leaf(read(Wire().document(Policy(containing = containing, grid = grid)))).floatViewport!!
            assertEquals(TableContainingDirection.entries[containing], policy.containingDirection)
            assertEquals(TableContainingDirection.entries[grid], policy.gridDirection)
        }
        for (value in listOf(2, 127, 255)) {
            assertThrows(RuntimeException::class.java) { read(Wire().document(Policy(containing = value))) }
            assertThrows(RuntimeException::class.java) { read(Wire().document(Policy(grid = value))) }
        }
        val wire = Wire(); val bytes = wire.document()
        val caption = wire.marks.getValue("leafCaptionBlocks"); val tail = wire.marks.getValue("leafPolicy")
        val end = wire.marks.getValue("leafPolicyEnd")
        val misplaced = bytes.copyOfRange(0, caption) + bytes.copyOfRange(tail, end) +
            bytes.copyOfRange(caption, tail) + bytes.copyOfRange(end, bytes.size)
        assertThrows(RuntimeException::class.java) { read(misplaced) }
        for (size in bytes.indices) assertThrows(RuntimeException::class.java) { read(bytes.copyOf(size)) }
        assertThrows(RuntimeException::class.java) { read(bytes + byteArrayOf(0)) }
    }

    @Test fun languageTailRetainsRawSchemaIdentityAndRejectsMalformedOrOversizedUtf8() {
        for (language in listOf("de", "DE", "de--DE", "not a locale", "\u65e5\u672c", "\uD83D\uDE00", "\u0000"))
            assertEquals(language, leaf(read(Wire().document(Policy(language = language)))).floatViewport!!.language)
        assertThrows(RuntimeException::class.java) { read(Wire().document(Policy(language = ""))) }
        val wire = Wire(); val bytes = wire.document()
        val at = wire.marks.getValue("leafLanguage"); val end = wire.marks.getValue("leafPolicyEnd")
        assertEquals(wire.marks.getValue("leafGrid") + 1, at)
        val missing = bytes.copyOfRange(0, at) + bytes.copyOfRange(end, bytes.size)
        assertThrows(RuntimeException::class.java) { read(missing) }
        val oversized = bytes.copyOf().also { changed -> repeat(4) {
            changed[at + it] = ((32 * 1024 * 1024 + 1) ushr (it * 8)).toByte()
        } }
        assertThrows(RuntimeException::class.java) { read(oversized) }
        val malformed = bytes.copyOf().also { it[at + 4] = 0xc0.toByte(); it[at + 5] = 0xaf.toByte() }
        assertThrows(java.nio.charset.CharacterCodingException::class.java) { read(malformed) }
    }

    @Test fun pClearTailIsExactlyAfterTheOldPolicyAndKeepsTagFiveBytes() {
        val shape = Shape(flags = 191, widthUnit = 1, widthValue = 25f, clear = 2)
        val oldWire = Wire(); val old = oldWire.document(shape = shape, version = 80)
        val wire = Wire(); val bytes = wire.document(Policy(narrowClear = 3), shape, version = 80, features = 9)
        val start = wire.marks.getValue("leafTable"); val clear = wire.marks.getValue("leafClear")
        assertEquals(5, old[start].toInt()); assertEquals(13, bytes[start].toInt())
        assertEquals(oldWire.marks.getValue("leafPolicyEnd"), clear)
        assertArrayEquals(old.copyOfRange(start + 1, clear), bytes.copyOfRange(start + 1, clear))
        assertEquals(3, bytes[clear].toInt())
        assertArrayEquals(old.copyOfRange(clear, oldWire.marks.getValue("Features")),
            bytes.copyOfRange(clear + 1, wire.marks.getValue("Features")))
        val oldTable = leaf(read(old)); val extended = leaf(read(bytes))
        assertNull(oldTable.floatViewport!!.narrowClear)
        assertEquals(oldTable, extended.copy(floatViewport = extended.floatViewport!!.copy(narrowClear = null)))
        assertEquals(StyleWidth(StyleWidthUnit.Em, 25f), extended.style!!.width)
        assertEquals(FigureClear.Right, extended.style!!.clear)
        assertEquals(FigureClear.Both, extended.effectiveFloatStyle(639.0)!!.clear)
        assertEquals(oldTable.style, extended.effectiveFloatStyle(639.5))
        assertEquals(oldTable.rows, extended.rows)
        for (version in listOf(77, 78, 79)) {
            val legacy = Wire().document(shape = shape, version = version)
            assertEquals(oldTable, leaf(read(legacy)))
            assertArrayEquals(legacy, old.copyOf(old.size - 1).also { it[3] = version.toByte() })
        }
    }

    @Test fun recursiveClearCensusIncludesFigureScopeCellsCaptionsContainersAndReferences() {
        for (owner in Owner.entries) for (clear in 0..3) {
            val wire = Wire(); val bytes = wire.document(Policy(narrowClear = clear), owner = owner, version = 80, features = 8)
            val actual = leaf(read(bytes), owner)
            assertEquals(FigureClear.entries[clear], actual.floatViewport!!.narrowClear)
            assertEquals("target-leaf", actual.rows.single().single().spans.single().target)
            assertThrows(RuntimeException::class.java) {
                read(bytes.copyOf().also { it[wire.marks.getValue("Features")] = 1 })
            }
            assertThrows(RuntimeException::class.java) { read(Wire().document(owner = owner, version = 80, features = 8)) }
        }
    }

    @Test fun allPFeatureCombinationsRetainTheRealPrefixAndIndependentHeadingFamily() {
        for (features in 1..15) {
            val wire = Wire()
            val bytes = wire.prefixDocument(features, Policy(language = "th", narrowClear = if (features and 8 != 0) 3 else null))
            val entry = read(bytes)
            assertEquals(2, entry.sections.size)
            val prefix = entry.sections[0]
            assertEquals(0, prefix.level); assertEquals("", prefix.title); assertEquals("", prefix.anchor)
            assertNull(prefix.headingStyle)
            val table = prefix.blocks.single().table!!.rows.single().single().nestedTable!!
            assertEquals(StyleWidth(StyleWidthUnit.Em, 25f), table.style!!.width)
            assertEquals("target-leaf", table.rows.single().single().spans.single().target)
            assertEquals(if (features and 8 != 0) FigureClear.Both else null, table.floatViewport!!.narrowClear)
            assertEquals(if (features and 1 != 0) BodyAdjoiningPolicy.Ordinary else null, entry.bodyAdjoining)
            assertEquals(features and 2 != 0, entry.sections[1].headingStyle != null)
            assertEquals("Heading", entry.sections[1].blocks.single().spans.single().text)
            if (features and 4 != 0) assertEquals(ContainerFontFamily.SansSerif, entry.displayTitle.single().fontFamily)
            else assertTrue(entry.displayTitle.isEmpty())
            for (wrong in listOf(0, features xor 4, features xor 8, features or 16, 255)) {
                assertThrows(RuntimeException::class.java) {
                    read(bytes.copyOf().also { it[wire.marks.getValue("Features")] = wrong.toByte() })
                }
            }
        }
    }

    @Test fun clearPresenceHeaderWidthAndPayloadDomainsStayClosed() {
        val wire = Wire(); val bytes = wire.document(Policy(narrowClear = 0), version = 80, features = 8)
        val at = wire.marks.getValue("leafClear"); val tag = wire.marks.getValue("leafTable")
        for (bad in listOf(4, 127, 255)) assertThrows(RuntimeException::class.java) {
            read(bytes.copyOf().also { it[at] = bad.toByte() })
        }
        for (bad in listOf(2, 4, 6, 7, 8, 9, 11, 12, 15, 21, 255)) assertThrows(RuntimeException::class.java) {
            read(bytes.copyOf().also { it[tag] = bad.toByte() })
        }
        for (version in listOf(77, 78, 79)) assertThrows(RuntimeException::class.java) {
            read(bytes.copyOf(bytes.size - 1).also { it[3] = version.toByte() })
        }
        assertThrows(RuntimeException::class.java) { read(bytes.copyOf().also { it[3] = 81 }) }
        assertThrows(RuntimeException::class.java) { read(bytes.copyOfRange(0, at) + bytes.copyOfRange(at + 1, bytes.size)) }
        assertThrows(RuntimeException::class.java) { read(bytes.copyOf().also { it[tag] = 5 }) }
        for (size in bytes.indices) assertThrows(RuntimeException::class.java) { read(bytes.copyOf(size)) }
        assertThrows(RuntimeException::class.java) { read(bytes + byteArrayOf(0)) }
        for (unit in 0..1) for (value in listOf(0f, 25f, 127.25f)) {
            val table = leaf(read(Wire().document(Policy(narrowClear = 3),
                Shape(flags = 191, widthUnit = unit, widthValue = value), version = 80, features = 8)))
            assertEquals(StyleWidth(StyleWidthUnit.entries[unit], value), table.style!!.width)
            assertEquals(table.style!!.width, table.effectiveFloatStyle(639.0)!!.width)
        }
        for ((unit, value) in listOf(2 to 0f, 2 to 70f, 3 to 25f, 0 to -1f, 1 to Float.NaN,
            0 to Float.POSITIVE_INFINITY, 1 to Float.NEGATIVE_INFINITY)) assertThrows(RuntimeException::class.java) {
            read(Wire().document(Policy(narrowClear = 3), Shape(flags = 191, widthUnit = unit, widthValue = value),
                version = 80, features = 8))
        }
    }
}
