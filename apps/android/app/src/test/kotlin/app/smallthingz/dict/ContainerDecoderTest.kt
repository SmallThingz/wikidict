package app.smallthingz.dict

import java.io.ByteArrayOutputStream
import org.junit.Assert.*
import org.junit.Test

class ContainerDecoderTest {
    private class Wire {
        val output = ByteArrayOutputStream()
        fun byte(value: Int) { output.write(value) }
        fun short(value: Int) { byte(value); byte(value ushr 8) }
        fun int(value: Int) { repeat(4) { byte(value ushr (it * 8)) } }
        fun float(value: Float) = int(value.toRawBits())
        fun text(value: String) { val bytes = value.encodeToByteArray(); int(bytes.size); output.write(bytes) }
        fun length(value: Float) { byte(0); float(value) }
        fun indices(vararg values: Int) { int(values.size); values.forEach(::int) }
        fun span(value: String) {
            byte(0); byte(0); byte(0); text(value); repeat(6) { text("") }; repeat(6) { byte(0) }
        }
        fun block(kind: Int, value: String? = null, children: (Wire.() -> Unit)? = null) {
            byte(kind); byte(0); byte(0)
            int(if (value == null) 0 else 1); value?.let(::span)
            byte(0); text(""); text(""); byte(0); text(""); text(""); repeat(4) { byte(0) }
            children?.invoke(this)
        }
    }
    private fun fixture(style: Wire.() -> Unit = { short(0) }, childKind: Int = 2,
        suffix: Int = 1, suffixCount: Int = 1, withContainer: Boolean = true,
        version: Int = 76): ByteArray = Wire().apply {
        byte(68); byte(80); byte(82); byte(version); int(0)
        int(1); byte(2); text("Controlled"); text(""); text(""); int(1)
        if (withContainer) block(13) {
            style(); int(2); block(0, "introduction"); block(childKind, "meaning")
        } else block(0, "legacy")
        int(0) // preamble
        if (withContainer) {
            int(1); text("English"); text("noun"); int(0); int(-1)
            int(1); int(0); int(-1); indices(0); indices(); indices(); byte(0)
            indices(suffix); int(suffixCount); repeat(suffixCount) { indices(0) }; int(0); int(0)
            indices(0); indices(); indices(); int(1); indices(0); int(0)
        } else int(0)
        int(0); int(0); int(0) // other sections, references, media
    }.output.toByteArray()
    private fun read(bytes: ByteArray) = BlobDecoder.decode(bytes, "word", "language", "English", "en")

    @Test fun realNestedAddressesRetainOneAuthoredTreeAndCompleteLexicalOwnership() {
        val entry = read(fixture())
        val root = entry.sections.single().blocks.single()
        val children = root.container!!.blocks
        assertEquals(listOf("paragraph", "definition"), children.map { it.kind })
        assertEquals(listOf("introduction", "meaning"), children.map { it.spans.single().text })
        val lexeme = entry.organization!!.lexemes.single()
        val sense = lexeme.definitions.single()
        assertEquals(listOf(1), sense.blockPath)
        assertEquals(listOf(listOf(0)), sense.examplePaths)
        assertSame(children[1], resolveBlockPath(entry.sections.single().blocks, sense.block, sense.blockPath))
        assertSame(children[0], resolveBlockPath(entry.sections.single().blocks, lexeme.introduction.single(), lexeme.introductionPaths.single()))
        val runs = mutableListOf<String>(); root.visitSpanRuns { spans, _ -> runs += spans.joinToString("") { it.text } }
        assertEquals(listOf("introduction", "meaning"), runs)
    }

    @Test fun responsiveFlexAndExplicitResetsUseReaderViewportAndPreserveComputedLengths() {
        val style = read(fixture(style = {
            short(4 or 32 or 64 or 128 or 256 or 512 or 1024 or 2048 or 4096 or 8192 or 16384)
            byte(1); byte(0); float(250f) // width
            byte(1); byte(2); float(90f) // max width
            byte(0); byte(1); byte(2); byte(0) // content-box, row, center, flex:none
            byte(2); text("#ffffff"); text("#101010")
            byte(1); length(1f); byte(1); text("#aabbcc")
            byte(2); byte(1); float(1.35f); byte(0) // resolved line-height, left alignment
            int(719); byte(15)
            byte(0); byte(0); byte(1); byte(1); float(1.5f) // auto, no max, border-box, multiplier
        })).sections.single().blocks.single().container!!.style
        assertEquals(ContainerLayout.FlexRow, style.layout)
        assertEquals(ContainerAlignItems.Center, style.alignItems)
        assertEquals(ContainerFlexItem.None, style.flexItem)
        assertEquals(ContainerLineHeight.Length(StyleLength(StyleLengthUnit.Em, 1.35f)), style.lineHeight)
        assertEquals(ContainerColor.LightDark("#ffffff", "#101010"), style.background)
        assertEquals(ContainerWidth.Length(StyleWidth(StyleWidthUnit.Px, 250f)), style.atViewport(720f).box.width)
        val narrow = style.atViewport(719f).box
        assertEquals(ContainerWidth.Auto, narrow.width); assertEquals(ContainerMaxWidth.None, narrow.maxWidth)
        assertEquals(ContainerBoxSizing.BorderBox, narrow.boxSizing)
        assertEquals(ContainerLineHeight.Multiplier(1.5f), narrow.lineHeight)
        assertEquals(style.background, narrow.background); assertEquals(style.border, narrow.border)
    }

    @Test fun responsiveFloatResetRetainsComputedOverflowAndRejectsInvalidPresentFields() {
        fun bytes(overflow: Int) = fixture(style = {
            short(8 or 16 or 16384 or 32768)
            byte(0); byte(3) // left float and clear both
            int(639); byte(16 or 32)
            byte(0) // explicit float none
            byte(1); length(0f); byte(0); byte(1); length(0f); byte(0) // 0 auto 0 auto
            byte(overflow)
        })
        fun style(bytes: ByteArray) = read(bytes).sections.single().blocks.single().container!!.style
        val auto = style(bytes(1))
        val wide = auto.atViewport(640f)
        assertEquals(TableFloatSide.Left, wide.box.floatSide)
        assertEquals(ContainerOverflow.Auto, wide.box.overflow)
        assertTrue(wide.ownsFormattingContext)
        val narrow = auto.atViewport(639f)
        assertNull(narrow.box.floatSide)
        assertEquals(FigureClear.Both, narrow.box.clear)
        assertEquals(ContainerOverflow.Auto, narrow.box.overflow)
        assertTrue(narrow.ownsFormattingContext)
        assertEquals(ContainerMargin.Auto, narrow.margins!!.left)
        assertEquals(ContainerMargin.Auto, narrow.margins.right)
        assertEquals(ContainerMargin.Length(StyleLength(StyleLengthUnit.Px, 0f)), narrow.margins.top)
        assertEquals(ContainerOverflow.Visible, style(bytes(0)).atViewport(639f).box.overflow)
        assertFalse(style(bytes(0)).atViewport(639f).ownsFormattingContext)
        assertNull(style(fixture()).overflow)
        assertThrows(Exception::class.java) { read(bytes(2)) }
        for (oldVersion in listOf(74, 75))
            assertThrows(Exception::class.java) { read(bytes(1).also { it[3] = oldVersion.toByte() }) }
        val complete = bytes(1)
        for (length in complete.indices)
            assertThrows(Exception::class.java) { read(complete.copyOf(length)) }
        assertThrows(Exception::class.java) { read(fixture(style = { short(16384); int(639); byte(16); byte(3) })) }
        assertThrows(Exception::class.java) { read(fixture(style = {
            short(16384); int(639); byte(32); byte(2)
        })) }
    }

    @Test fun oldBlockPrefixIsIdenticalAndInvalidContainerFramesAndAddressesRefuse() {
        val plain = fixture(withContainer = false)
        assertEquals(read(plain).sections, read(plain.copyOf().also { it[3] = 75 }).sections)
        val valid = fixture()
        assertThrows(Exception::class.java) { read(valid.copyOf().also { it[3] = 75 }) }
        assertThrows(Exception::class.java) { read(valid + byteArrayOf(0)) }
        assertThrows(Exception::class.java) { read(fixture(suffix = 2)) }
        assertThrows(Exception::class.java) { read(fixture(suffixCount = 2)) }
        assertThrows(Exception::class.java) { read(fixture(childKind = 9)) }
        assertThrows(Exception::class.java) { read(fixture(style = { short(0x8000) })) }
        assertThrows(Exception::class.java) { read(fixture(style = { short(256); byte(2) })) }
        assertThrows(Exception::class.java) { read(fixture(style = { short(16384); int(719); byte(0) })) }
        for (length in valid.indices) assertThrows(Exception::class.java) { read(valid.copyOf(length)) }
    }

    @Test fun orderedViewportBandsMergeNullFieldsAndKeepFractionalRootThresholdsAndExplicitZero() {
        val entry = read(fixture(style = {
            short(4 or 8 or 16 or 16384)
            byte(1); byte(0); float(250f); byte(1); byte(2) // fixed width, right float/clear
            int(719); byte(1 or 8 or 128)
            byte(1); byte(2); float(100f); byte(1); float(1.5f)
            int(2)
            int(639); byte(16 or 64); byte(0); byte(3) // float:none, clear:both
            int(0); byte(8 or 64); byte(1); float(0f); byte(0) // explicit zero, clear:none
        }))
        val container = entry.sections.single().blocks.single().container!!
        val style = container.style
        assertEquals(ContainerWidth.Length(StyleWidth(StyleWidthUnit.Px, 250f)), style.atViewport(719.0000001).box.width)
        val middle = style.atViewport(639.0000001).box
        assertEquals(ContainerWidth.Length(StyleWidth(StyleWidthUnit.Percent, 100f)), middle.width)
        assertEquals(TableFloatSide.Right, middle.floatSide); assertEquals(FigureClear.Right, middle.clear)
        assertEquals(ContainerLineHeight.Multiplier(1.5f), middle.lineHeight)
        val narrow = style.atViewport(639.0).box
        assertNull(narrow.floatSide); assertEquals(FigureClear.Both, narrow.clear)
        assertEquals(middle.width, narrow.width); assertEquals(middle.lineHeight, narrow.lineHeight)
        val zero = style.atViewport(0.0).box
        assertNull(zero.floatSide); assertEquals(FigureClear.None, zero.clear)
        assertEquals(ContainerLineHeight.Multiplier(0f), zero.lineHeight)
        assertEquals(narrow.width, zero.width)
        assertEquals(listOf("introduction", "meaning"), container.blocks.map { it.spans.single().text })
        assertEquals(listOf(1), entry.organization!!.lexemes.single().definitions.single().blockPath)
        for (invalid in listOf(Double.NaN, Double.POSITIVE_INFINITY, -1.0))
            assertThrows(IllegalArgumentException::class.java) { style.atViewport(invalid) }
    }

    @Test fun orderedWireRefusesNestedDuplicateAscendingEmptyAndOversizedRulesWithoutChangingOldHeaders() {
        fun bytes(count: Int = 1, childBound: Int = 639, childFlags: Int = 64, clear: Int = 0) = fixture(style = {
            short(16384); int(719); byte(64 or 128); byte(0); int(count)
            repeat(count.coerceIn(0, 16)) { index ->
                int(childBound - index); byte(childFlags); byte(clear)
                if (childFlags and 128 != 0) int(0)
            }
        })
        val valid = bytes()
        assertEquals(FigureClear.None, read(valid).sections.single().blocks.single().container!!.style.atViewport(639.0).box.clear)
        for (malformed in listOf(bytes(0), bytes(16), bytes(childBound = 719), bytes(childBound = 720),
            bytes(childFlags = 64 or 128), bytes(childFlags = 0), bytes(clear = 4)))
            assertThrows(Exception::class.java) { read(malformed) }
        assertThrows(Exception::class.java) { read(fixture(style = {
            short(16384); int(719); byte(128); int(1); int(639); byte(64); byte(0)
        })) }
        for (length in valid.indices) assertThrows(Exception::class.java) { read(valid.copyOf(length)) }
        for (version in listOf(74, 75)) assertThrows(Exception::class.java) {
            read(valid.copyOf().also { it[3] = version.toByte() })
        }
        val legacy = fixture(withContainer = false)
        assertEquals(read(legacy).sections, read(legacy.copyOf().also { it[3] = 75 }).sections)
        assertEquals(15, read(bytes(15)).sections.single().blocks.single().container!!.style.screenMaxWidth!!.followingRules.size)
    }

    @Test fun orderedMarginAdmissionChecksEveryInheritedStateAndRequiresTheRealVerticalReset() {
        fun bytes(reset: Boolean, version: Int = 76) = fixture(version = version, style = {
            if (version == 77) int(1 or 8 or 16384) else short(1 or 8 or 16384)
            length(0f); length(0f); length(8f); length(4f); byte(1)
            int(719); byte(64 or 128); byte(2); int(1)
            int(639); byte(16 or 64 or (if (reset) 32 else 0)); byte(0)
            if (reset) repeat(4) { byte(1); length(0f) }
            byte(3)
        })
        assertThrows(IllegalArgumentException::class.java) { read(bytes(false)) }
        val style = read(bytes(true)).sections.single().blocks.single().container!!.style
        assertEquals(ContainerMargin.Length(StyleLength(StyleLengthUnit.Px, 8f)), style.atViewport(700.0).margins!!.bottom)
        assertEquals(TableFloatSide.Right, style.atViewport(700.0).box.floatSide)
        val narrow = style.atViewport(639.0)
        assertNull(narrow.box.floatSide); assertEquals(FigureClear.Both, narrow.box.clear)
        assertEquals(ContainerMargin.Length(StyleLength(StyleLengthUnit.Px, 0f)), narrow.margins!!.bottom)
        val none = ContainerScreenMaxWidth(639, floatSide = ContainerFloatOverride.None)
        val middle = ContainerScreenMaxWidth(719, clear = FigureClear.None, followingRules = listOf(none))
        // The model represents M adjoining margins; the old wire gate still
        // checks every inherited band before accepting a legacy Container.
        val inherited = Container(emptyList(), style.copy(screenMaxWidth = middle))
        assertFalse(legacyContainerMarginsSupported(inherited))
        assertTrue(legacyContainerMarginsSupported(Container(emptyList(), style)))
        val current = read(bytes(false, 77)).sections.single().blocks.single().container!!
        assertFalse(legacyContainerMarginsSupported(current))
        for (viewport in listOf(720.0, 700.0, 639.0)) {
            val resolved = current.style.atViewport(viewport)
            assertEquals(ContainerMargin.Length(StyleLength(StyleLengthUnit.Px, 8f)), resolved.margins!!.bottom)
            assertEquals(when (viewport) { 720.0 -> TableFloatSide.Right; 700.0 -> TableFloatSide.Right; else -> null }, resolved.box.floatSide)
        }
        assertEquals(FigureClear.Both, current.style.atViewport(639.0).box.clear)
        assertEquals(listOf("introduction", "meaning"), current.blocks.map { it.spans.single().text })
    }

    @Test fun ownerFontMRetainsExplicitZeroInheritanceAndOldContainerFraming() {
        fun styled(font: Float) = fixture(version = 77, style = {
            int(4096 or 32768 or 65536)
            byte(1); float(1.5f); byte(1); float(font)
        })
        val owner = read(styled(.9f)).sections.single().blocks.single().container!!
        val inherited = owner.style.textContext(ContainerTextContext())
        assertEquals(.9f, inherited.ownerFontScale, 0f)
        assertEquals(ContainerLineHeight.Multiplier(1.5f), inherited.lineHeight)
        assertEquals(ContainerOverflow.Auto, owner.style.overflow)
        assertEquals(inherited, ContainerStyle().textContext(inherited))
        assertEquals(1f, ContainerStyle(ownerFontScale = 1f).textContext(inherited).ownerFontScale, 0f)
        assertEquals(0f, read(styled(0f)).sections.single().blocks.single().container!!.style.ownerFontScale!!, 0f)
        assertEquals(listOf("introduction", "meaning"), owner.blocks.map { it.spans.single().text })
        assertEquals(read(fixture()), read(fixture(version = 77, style = { int(0) })))
        assertEquals(read(fixture(withContainer = false)), read(fixture(withContainer = false, version = 77)))
        assertEquals(ContainerLineHeight.Multiplier(1.5f), ContainerStyle(ownerFontScale = 0f).textContext(inherited).lineHeight)
        assertThrows(Exception::class.java) { read(styled(.9f).also { it[3] = 76 }) }
        // N adds tails only to Rules; O adds only present inline effects. This owner has neither.
        for (version in listOf(78, 79)) {
            assertEquals(read(styled(.9f)), read(styled(.9f).also { it[3] = version.toByte() }))
        }
        assertThrows(Exception::class.java) { read(styled(.9f).also { it[3] = 81 }) }
    }

    @Test fun ownerFontMUsesWideMasksInNestedOwnersAndRefusesInvalidScalarsBitsAndTruncation() {
        fun tree(font: Float, flags: Int = 65536): ByteArray = Wire().apply {
            byte(68); byte(80); byte(82); byte(77); int(0)
            int(1); byte(2); text("Controlled"); text(""); text(""); int(1)
            block(13) {
                int(flags); float(font); int(1)
                block(13) { int(0); int(1); block(0, "nested action body") }
            }
            repeat(5) { int(0) } // preamble, lexemes, other sections, references, media
        }.output.toByteArray()
        val bytes = tree(.9f)
        val outer = read(bytes).sections.single().blocks.single().container!!
        val nested = outer.blocks.single().container!!
        assertNull(nested.style.ownerFontScale)
        assertEquals(.9f, nested.style.textContext(outer.style.textContext(ContainerTextContext())).ownerFontScale, 0f)
        assertEquals("nested action body", nested.blocks.single().spans.single().text)
        for (bad in listOf(-1f, Float.NaN, Float.POSITIVE_INFINITY, Float.NEGATIVE_INFINITY)) {
            assertThrows(Exception::class.java) { read(tree(bad)) }
            assertThrows(IllegalArgumentException::class.java) { ContainerStyle(ownerFontScale = bad) }
        }
        assertThrows(Exception::class.java) { read(tree(.9f, 0x40000)) }
        assertThrows(Exception::class.java) { read(tree(.9f, Int.MIN_VALUE)) }
        for (length in bytes.indices) assertThrows(Exception::class.java) { read(bytes.copyOf(length)) }
        assertThrows(Exception::class.java) { read(bytes + byteArrayOf(0)) }
    }


    @Test fun flexColumnKeepsExistingLayoutPresenceAndEveryOldNullFlowRowByte() {
        fun oldLayout(bytes: ByteArray, wide: Boolean): ContainerLayout? {
            val width = if (wide) 4 else 2
            require(bytes.size == width || bytes.size == width + 1)
            val flags = bytes.take(width).mapIndexed { index, value -> (value.toInt() and 255) shl (8 * index) }.fold(0) { a, b -> a or b }
            if (flags == 0) { require(bytes.size == width); return null }
            require(flags == 0x80 && bytes.size == width + 1)
            return when (bytes.last().toInt() and 255) {
                0 -> ContainerLayout.Flow
                1 -> ContainerLayout.FlexRow
                else -> throw IllegalArgumentException("Old two-tag layout reader")
            }
        }
        for (layout in listOf(null, ContainerLayout.Flow, ContainerLayout.FlexRow, ContainerLayout.FlexColumn)) {
            val narrow = if (layout == null) byteArrayOf(0, 0) else byteArrayOf(0x80.toByte(), 0, layout.ordinal.toByte())
            val wide = if (layout == null) byteArrayOf(0, 0, 0, 0) else byteArrayOf(0x80.toByte(), 0, 0, 0, layout.ordinal.toByte())
            for ((version, literal) in listOf(76 to narrow, 77 to wide)) {
                var start = -1
                val encoded = fixture(version = version, style = { start = output.size(); output.write(literal) })
                assertArrayEquals(literal, encoded.copyOfRange(start, start + literal.size))
                val original = read(encoded)
                val container = original.sections.single().blocks.single().container!!
                assertEquals(layout, container.style.layout)
                assertEquals(listOf("introduction", "meaning"), container.blocks.map { it.spans.single().text })
                val sense = original.organization!!.lexemes.single().definitions.single()
                assertSame(container.blocks[1], resolveBlockPath(original.sections.single().blocks, sense.block, sense.blockPath))
                if (layout == ContainerLayout.FlexColumn) {
                    assertThrows(IllegalArgumentException::class.java) { oldLayout(literal, version == 77) }
                    for (tag in listOf(3, 255)) assertThrows(Exception::class.java) {
                        read(encoded.copyOf().also { it[start + literal.lastIndex] = tag.toByte() })
                    }
                    for (length in 0 until literal.size) assertThrows(Exception::class.java) { read(encoded.copyOf(start + length)) }
                    assertThrows(Exception::class.java) { read(encoded + byteArrayOf(0)) }
                } else assertEquals(layout, oldLayout(literal, version == 77))
            }
        }
        assertEquals(0, ContainerLayout.Flow.ordinal); assertEquals(1, ContainerLayout.FlexRow.ordinal)
        assertEquals(2, ContainerLayout.FlexColumn.ordinal)
        for (layout in listOf(ContainerLayout.FlexRow, ContainerLayout.FlexColumn)) for (align in ContainerAlignItems.entries) {
            val entry = read(fixture(style = { short(128 or 256); byte(layout.ordinal); byte(align.ordinal) }))
            assertEquals(align, entry.sections.single().blocks.single().container!!.style.alignItems)
        }
        assertThrows(Exception::class.java) { read(fixture(style = { short(128 or 256); byte(2); byte(4) })) }
    }
}
