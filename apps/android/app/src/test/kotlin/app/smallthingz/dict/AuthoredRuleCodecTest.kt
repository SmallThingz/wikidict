package app.smallthingz.dict

import java.io.ByteArrayOutputStream
import org.junit.Assert.*
import org.junit.Test

/** Literal DPRN framing; no encoder, source parser or renderer supplies these bytes. */
class AuthoredRuleCodecTest {
    private enum class Owner { Section, Reference, Container, Cell, NestedTable, TableCaption, FigureCaption, FlowFigure, ScopeFigure }
    private class Wire(val version: Char = 'N', val fillTag: Int = 2,
        val light: String = "#123456", val dark: String = "#abcdef", val advanced: Boolean = false,
        val ruleKind: Int = 11, val ruleAlignment: Int? = null) {
        val out = ByteArrayOutputStream()
        val at = linkedMapOf<String, Int>()
        private var ruleIndex = 0
        private var hasImage = false
        fun mark(name: String) { check(at.put(name, out.size()) == null) }
        fun byte(value: Int) { out.write(value) }
        fun u16(value: Int) { byte(value); byte(value ushr 8) }
        fun u32(value: Int) { repeat(4) { byte(value ushr (it * 8)) } }
        fun f32(value: Float) = u32(value.toRawBits())
        fun string(value: String) { val bytes = value.encodeToByteArray(); u32(bytes.size); out.write(bytes) }
        fun length(value: Float, unit: Int = 0) { byte(unit); f32(value) }
        fun span(text: String = "", target: String = "", image: Boolean = false, font: Boolean = false) {
            byte(if (target.isEmpty()) 0 else 1); byte(0); byte(0)
            string(text); string(target); repeat(5) { string("") }
            byte(0); byte(0); byte(if (font) 3 else 0)
            if (font) { f32(.75f); byte(2); byte(1) } // M CSS-pixel basis and SevenOn feature policy
            byte(if (image) 1 else 0)
            if (image) { hasImage = true; string("Controlled.svg"); byte(3); u32(44); u32(40) }
            byte(0); byte(0)
        }
        fun blockPrefix(kind: Int, spans: Int = 0, writeSpans: () -> Unit = {}, table: (() -> Unit)? = null,
            ruleName: String? = null) {
            if (ruleName != null) mark(ruleName + "Kind")
            byte(kind)
            if (ruleName != null) mark(ruleName + "Depth")
            byte(0)
            if (ruleName != null) mark(ruleName + "Level")
            byte(0); u32(spans); writeSpans(); byte(0); string(""); string("")
            if (table == null) byte(0) else table()
            string(""); string("")
            byte(if (ruleName != null && ruleAlignment != null) 1 else 0)
            if (ruleName != null && ruleAlignment != null) byte(ruleAlignment)
            byte(0) // BlockStyle
        }
        fun paragraph(label: String) {
            val extra = advanced && label == "Before"
            blockPrefix(0, if (extra) 2 else 1, {
                span(label, label.lowercase() + "-target", font = extra)
                if (extra) span(image = true)
            }); byte(0); byte(0)
        }
        fun rule(styled: Boolean) {
            val prefix = "rule${ruleIndex++}"
            blockPrefix(ruleKind, ruleName = prefix); byte(0); byte(0)
            mark(prefix + "Tail")
            if (version == 'N') {
                byte(if (styled) 1 else 0)
                if (styled) {
                    mark(prefix + "HeightUnit"); byte(0); mark(prefix + "HeightValue"); f32(1f)
                    mark(prefix + "FillTag"); byte(fillTag)
                    if (fillTag == 1 || fillTag == 2) { mark(prefix + "Light"); string(light) }
                    if (fillTag == 2) { mark(prefix + "Dark"); string(dark) }
                    for ((name, value, unit) in listOf(Triple("Top", .2f, 1), Triple("Right", 2f, 0),
                        Triple("Bottom", .3f, 1), Triple("Left", 4f, 0))) {
                        mark(prefix + name + "Unit"); byte(unit); mark(prefix + name + "Value"); f32(value)
                    }
                }
            }
            mark(prefix + "End")
        }
        fun body() { u32(4); paragraph("Before"); rule(true); rule(false); paragraph("After") }
        fun table(caption: Boolean = false, nested: Boolean = false) {
            byte(1); byte(0); u32(0); u32(if (caption) 0 else 1)
            if (!caption) {
                u32(1); byte(0); u16(1); u16(1); byte(0); u32(0)
                if (nested) { table(); byte(0) } else { byte(0); byte(1); body() }
                byte(1); byte(4); byte(2) // original CellStyle sentinel after cell blocks/nested table
            }
            byte(1); byte(1); byte(0); string("#445566") // M TableStyle: background, no extension fields
            byte(if (caption) 1 else 0); if (caption) body()
        }
        fun figure() {
            byte(1); byte(1); byte(0); byte(0) // old image Figure, Framed, no float/clear
            repeat(12) { length(0f) }; f32(.875f); length(1.25f, 1)
            byte(0); byte(0); byte(1); byte(0); byte(0); byte(1)
            span(image = true); u32(0); byte(1); body()
            byte(1); byte(2); byte(0); byte(1); length(3f) // align Right, Intrinsic, physical frame minimum
        }
        fun root(owner: Owner) {
            if (owner == Owner.Section) { body(); return }
            u32(if (owner == Owner.Reference) 0 else 1)
            when (owner) {
                Owner.Container -> {
                    blockPrefix(13); byte(0); byte(0); u32(0x10000); f32(1.25f); body()
                }
                Owner.Cell, Owner.NestedTable, Owner.TableCaption -> {
                    blockPrefix(12, table = { table(owner == Owner.TableCaption, owner == Owner.NestedTable) })
                    byte(0); byte(0)
                }
                Owner.FigureCaption -> { blockPrefix(0); figure(); byte(0) }
                Owner.FlowFigure, Owner.ScopeFigure -> {
                    blockPrefix(0); byte(0); byte(1); u32(1)
                    if (owner == Owner.ScopeFigure) { byte(2); byte(0); byte(3); byte(1); byte(1); string("sr"); u32(1) }
                    byte(1); figure()
                }
                Owner.Reference -> Unit
                Owner.Section -> error("handled above")
            }
        }
        fun document(owner: Owner = Owner.Section, minimalKind: Int? = null): ByteArray {
            out.write(byteArrayOf(68, 80, 82, version.code.toByte())); u32(0); u32(1)
            byte(2); string("S"); string(""); string("")
            if (minimalKind == null) root(owner)
            else {
                u32(1)
                if (minimalKind == 11) rule(false)
                else { blockPrefix(minimalKind); byte(0); byte(0) }
            }
            u32(0); u32(0); u32(0) // preamble, lexemes, other sections
            val reference = minimalKind == null && owner == Owner.Reference
            u32(if (reference) 1 else 0)
            if (reference) { byte(0); u32(1); u32(1); string("controlled"); string(""); u32(0); byte(1); body() }
            u32(if (hasImage) 1 else 0)
            if (hasImage) { string("Controlled.svg"); byte(0); string("original catalog caption") }
            return out.toByteArray()
        }
    }
    private fun decode(bytes: ByteArray) = BlobDecoder.decode(bytes, "Controlled rule", "language", "Serbian", "sr")
    private fun ownedBlocks(entry: Entry, owner: Owner): List<Block> {
        if (owner == Owner.Reference) return entry.references.single().blocks!!
        val roots = entry.sections.single().blocks
        if (owner == Owner.Section) return roots
        val block = roots.single()
        return when (owner) {
            Owner.Container -> block.container!!.blocks
            Owner.Cell -> block.table!!.rows.single().single().blocks!!
            Owner.NestedTable -> block.table!!.rows.single().single().nestedTable!!.rows.single().single().blocks!!
            Owner.TableCaption -> block.table!!.captionBlocks!!
            Owner.FigureCaption -> block.figure!!.captionBlocks!!
            Owner.FlowFigure -> (block.flow!!.single() as FlowPart.ImageFigure).figure.captionBlocks!!
            Owner.ScopeFigure -> (((block.flow!!.single() as FlowPart.Scope).scope.parts.single()) as FlowPart.ImageFigure).figure.captionBlocks!!
            else -> error("handled above")
        }
    }
    private fun expectedStyle(fill: ContainerColor = ContainerColor.LightDark("#123456", "#abcdef")) =
        RuleStyle(StyleLength(StyleLengthUnit.Px, 1f), fill, StyleEdges(StyleLength(StyleLengthUnit.Em, .2f),
            StyleLength(StyleLengthUnit.Px, 2f), StyleLength(StyleLengthUnit.Em, .3f), StyleLength(StyleLengthUnit.Px, 4f)))
    private fun rejects(label: String, bytes: ByteArray) { assertTrue(label, runCatching { decode(bytes) }.isFailure) }
    private fun changedByte(bytes: ByteArray, at: Int, value: Int) = bytes.copyOf().also { it[at] = value.toByte() }
    private fun changed32(bytes: ByteArray, at: Int, value: Int) = bytes.copyOf().also { copy ->
        repeat(4) { copy[at + it] = (value ushr (8 * it)).toByte() }
    }
    private fun hex(value: String) = value.chunked(2).map { it.toInt(16).toByte() }.toByteArray()

    @Test fun nineRecursiveOwnersRetainStyledAndNullRulesOrderedBodyActionsAndParentTails() {
        for (owner in Owner.entries) {
            val entry = decode(Wire().document(owner)); val blocks = ownedBlocks(entry, owner)
            assertEquals(owner.name, listOf("paragraph", "rule", "rule", "paragraph"), blocks.map { it.kind })
            assertEquals(expectedStyle(), blocks[1].ruleStyle); assertNull(blocks[2].ruleStyle)
            assertEquals(listOf("Before", "After"), listOf(blocks.first(), blocks.last()).map { textOf(it.spans) })
            assertEquals(listOf("before-target", "after-target"), listOf(blocks.first(), blocks.last()).map { it.spans.single().target })
            when (owner) {
                Owner.Container -> assertEquals(1.25f, entry.sections.single().blocks.single().container!!.style.ownerFontScale!!, 0f)
                Owner.Cell, Owner.NestedTable, Owner.TableCaption -> {
                    val table = entry.sections.single().blocks.single().table!!
                    assertEquals("#445566", table.style!!.background)
                    if (owner != Owner.TableCaption) assertEquals(CellTextAlign.Right, table.rows.single().single().style!!.textAlign)
                    if (owner == Owner.NestedTable) {
                        val inner = table.rows.single().single().nestedTable!!
                        assertEquals("#445566", inner.style!!.background)
                        assertEquals(CellTextAlign.Right, inner.rows.single().single().style!!.textAlign)
                    }
                }
                Owner.FigureCaption, Owner.FlowFigure, Owner.ScopeFigure -> {
                    assertEquals(listOf(Media("Controlled.svg", "image", "original catalog caption")), entry.media)
                    assertEquals(1, entry.inlineImages.size)
                    val root = entry.sections.single().blocks.single()
                    val figure = when (owner) {
                        Owner.FigureCaption -> root.figure!!
                        Owner.FlowFigure -> (root.flow!!.single() as FlowPart.ImageFigure).figure
                        else -> {
                            val scope = (root.flow!!.single() as FlowPart.Scope).scope
                            assertEquals(BidiDirectionInput.Auto, scope.authoredDirection)
                            assertEquals(BidiResolvedDirection.Rtl, scope.resolvedDirection)
                            assertEquals("sr", scope.language)
                            (scope.parts.single() as FlowPart.ImageFigure).figure
                        }
                    }
                    assertEquals(CellTextAlign.Right, figure.captionTextAlign)
                    assertEquals(FigureSizingPolicy.Intrinsic, (figure.content as FigureContent.Image).sizing)
                    assertEquals(StyleLength(StyleLengthUnit.Px, 3f), figure.frameMinWidth)
                }
                Owner.Reference -> assertEquals(1L, entry.references.single().number)
                Owner.Section -> Unit
            }
        }
    }

    @Test fun nullRuleGoldenKeepsOldHeadersAndNAddsOnlyTheRulePresenceByte() {
        val earliest = hex("44505232" + "00000000" + "01000000" + "02" + "0100000053" + "01000000" +
            "0b0000" + "00000000" + "00" + "00000000" + "00000000" + "00" +
            "00000000" + "00000000" + "00000000" + "00000000" + "00000000")
        assertEquals(59, earliest.size)
        assertEquals(Block("rule", 0, emptyList()), decode(earliest).sections.single().blocks.single())
        val golden = hex("4450524d" + "00000000" + "01000000" + "02" + "0100000053" +
            "00000000" + "00000000" + "01000000" +
            "0b0000" + "00000000" + "00" + "00000000" + "00000000" + "00" +
            "00000000" + "00000000" + "00" + "00" + "00" + "00" +
            "00000000" + "00000000" + "00000000" + "00000000" + "00000000")
        assertEquals(79, golden.size)
        val old = Wire(version = 'M').document(minimalKind = 11)
        assertArrayEquals(golden, old)
        for (version in listOf('J', 'K', 'L', 'M')) {
            val bytes = Wire(version = version).document(minimalKind = 11)
            assertArrayEquals(golden.copyOfRange(4, golden.size), bytes.copyOfRange(4, bytes.size))
            assertEquals(Block("rule", 0, emptyList()), decode(bytes).sections.single().blocks.single())
        }
        val expectedN = (golden.copyOfRange(0, 59) + byteArrayOf(0) + golden.copyOfRange(59, golden.size)).also { it[3] = 'N'.code.toByte() }
        assertArrayEquals(expectedN, Wire().document(minimalKind = 11))
        assertNull(decode(expectedN).sections.single().blocks.single().ruleStyle)
        assertEquals(CellTextAlign.Center, decode(Wire(ruleAlignment = 1).document(minimalKind = 11))
            .sections.single().blocks.single().textAlign)
        val ordinaryM = Wire(version = 'M').document(minimalKind = 0)
        val ordinaryN = Wire().document(minimalKind = 0)
        assertArrayEquals(ordinaryM.copyOfRange(4, ordinaryM.size), ordinaryN.copyOfRange(4, ordinaryN.size))
        assertEquals(decode(ordinaryM).sections, decode(ordinaryN).sections)
        rejects("N null rule missing presence", golden.copyOf().also { it[3] = 'N'.code.toByte() })
    }

    @Test fun nInheritsActualMFontsImagesContainerAndTableFieldsAndAllFillVariants() {
        val container = decode(Wire(advanced = true).document(Owner.Container))
        val before = ownedBlocks(container, Owner.Container).first()
        assertEquals(.75f, before.spans.first().fontScale!!, 0f)
        assertEquals(FontScaleBasis.CssPx, before.spans.first().fontScaleBasis)
        assertEquals(FontFeaturePolicy.SevenOn, before.spans.first().fontFeatures)
        assertEquals(44L, before.spans[1].image!!.widthPx)
        assertEquals(40L, before.spans[1].image!!.heightPx)
        assertEquals(1, container.inlineImages.size)
        assertEquals(1.25f, container.sections.single().blocks.single().container!!.style.ownerFontScale!!, 0f)
        val tableEntry = decode(Wire(advanced = true).document(Owner.Cell))
        val table = tableEntry.sections.single().blocks.single().table!!
        assertEquals("#445566", table.style!!.background)
        assertEquals(CellTextAlign.Right, table.rows.single().single().style!!.textAlign)
        for ((tag, color) in listOf(0 to ContainerColor.Transparent, 1 to ContainerColor.Rgb("#123456"),
            2 to ContainerColor.LightDark("#123456", "#abcdef"))) {
            assertEquals(expectedStyle(color), ownedBlocks(decode(Wire(fillTag = tag).document()), Owner.Section)[1].ruleStyle)
        }
        val wire = Wire(fillTag = 0); val bytes = wire.document()
        val zero = changed32(bytes, wire.at.getValue("rule0HeightValue"), 0)
        assertEquals(0f, ownedBlocks(decode(zero), Owner.Section)[1].ruleStyle!!.height.value, 0f)
        val em = changed32(changedByte(bytes, wire.at.getValue("rule0HeightUnit"), 1),
            wire.at.getValue("rule0HeightValue"), .125f.toRawBits())
        assertEquals(StyleLength(StyleLengthUnit.Em, .125f), ownedBlocks(decode(em), Owner.Section)[1].ruleStyle!!.height)
    }

    @Test fun presenceUnitsNumbersColorsAndPresentContextAreStrict() {
        val wire = Wire(); val bytes = wire.document(); val at = wire.at
        for (value in listOf(2, 255)) rejects("presence $value", changedByte(bytes, at.getValue("rule0Tail"), value))
        for (field in listOf("Height", "Top", "Right", "Bottom", "Left")) {
            rejects("unit $field", changedByte(bytes, at.getValue("rule0${field}Unit"), 2))
            for (value in listOf(-1f, Float.NaN, Float.POSITIVE_INFINITY, Float.NEGATIVE_INFINITY)) {
                rejects("value $field $value", changed32(bytes, at.getValue("rule0${field}Value"), value.toRawBits()))
            }
        }
        for (tag in listOf(3, 255)) rejects("fill tag $tag", changedByte(bytes, at.getValue("rule0FillTag"), tag))
        for (color in listOf("", "red", "#ABCDEF", "#12345", "#1234567")) {
            rejects("RGB $color", Wire(fillTag = 1, light = color).document())
            rejects("dark RGB $color", Wire(dark = color).document())
        }
        rejects("malformed UTF8", changedByte(bytes, at.getValue("rule0Light") + 4, 255))
        rejects("oversized color string", changed32(bytes, at.getValue("rule0Light"), 0x0200_0001))
        rejects("depth", changedByte(bytes, at.getValue("rule0Depth"), 1))
        rejects("level", changedByte(bytes, at.getValue("rule0Level"), 1))
        rejects("present alignment", Wire(ruleAlignment = 1).document())
        rejects("illicit non-rule tail", Wire(ruleKind = 0).document())
    }

    @Test fun mandatoryTailsRejectTruncationForeignHeadersAndReorderedFields() {
        val wire = Wire(); val bytes = wire.document(); val at = wire.at
        for (end in bytes.indices) rejects("prefix $end", bytes.copyOf(end))
        rejects("trailing", bytes + byteArrayOf(0))
        // O inherits the complete N Rule tail when no inline effects are present.
        assertEquals(decode(bytes), decode(changedByte(bytes, 3, 'O'.code)))
        rejects("unknown Q", changedByte(bytes, 3, 'Q'.code))
        for (version in listOf('J', 'K', 'L', 'M')) rejects("styled tail under $version", changedByte(bytes, 3, version.code))
        val withoutHeight = bytes.copyOfRange(0, at.getValue("rule0HeightUnit")) + bytes.copyOfRange(at.getValue("rule0FillTag"), bytes.size)
        rejects("missing height", withoutHeight)
        val withoutFill = bytes.copyOfRange(0, at.getValue("rule0FillTag")) + bytes.copyOfRange(at.getValue("rule0TopUnit"), bytes.size)
        rejects("missing fill", withoutFill)
        val reversed = bytes.copyOfRange(0, at.getValue("rule0HeightUnit")) +
            bytes.copyOfRange(at.getValue("rule0FillTag"), at.getValue("rule0TopUnit")) +
            bytes.copyOfRange(at.getValue("rule0HeightUnit"), at.getValue("rule0FillTag")) +
            bytes.copyOfRange(at.getValue("rule0TopUnit"), bytes.size)
        rejects("fill before height", reversed)
    }
}
