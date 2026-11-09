package app.smallthingz.dict

import java.io.ByteArrayOutputStream
import org.junit.Assert.*
import org.junit.Test

/** Literal J wire controls, independent of a producer or rendered geometry. */
class FigureCodecTest {
    private class Wire {
        val out = ByteArrayOutputStream()
        val offsets = linkedMapOf<String, Int>()
        fun mark(name: String) { check(offsets.put(name, out.size()) == null) }
        fun byte(value: Int) { out.write(value) }
        fun u32(value: Int) { repeat(4) { byte(value ushr (it * 8)) } }
        fun f32(value: Float) = u32(value.toRawBits())
        fun f64(value: Double) { val bits = value.toRawBits(); repeat(8) { byte((bits ushr (it * 8)).toInt()) } }
        fun string(value: String) { val raw = value.toByteArray(Charsets.UTF_8); u32(raw.size); out.write(raw) }
        fun optional(value: String?) { byte(if (value == null) 0 else 1); if (value != null) string(value) }
        fun length(value: Float = 0f, unit: Int = 0) { byte(unit); f32(value) }
        fun text(value: String) {
            byte(0); byte(0); byte(0); string(value); repeat(6) { string("") }; repeat(6) { byte(0) }
        }
        fun action(target: String, fragment: String?, label: String, kind: Int = 0) {
            byte(kind); string(target); optional(fragment); string(label)
        }
        fun image(width: Long?, height: Long?) {
            byte(1); byte(0); byte(0)
            string(""); string("File:Map.png"); repeat(5) { string("") }
            repeat(3) { byte(0) } // foreground, background, scale
            byte(1); string("Map.png"); mark("imageFlags"); byte(0x3c or (if (width != null) 1 else 0) or (if (height != null) 2 else 0))
            if (width != null) u32(width.toInt())
            if (height != null) u32(height.toInt())
            string(""); string("") // explicit empty alt and own tooltip
            mark("description"); byte(1); mark("regionCount"); u32(1)
            mark("shape"); byte(0); mark("coordinateCount"); u32(4)
            mark("coordinate"); f64(-0.25); f64(1.5); f64(99.125); f64(80.75)
            action("", "", "Local fragment")
            byte(1); action("https://example.org/exact", null, "External", 1)
            optional(""); optional("Inherited advice")
        }
        fun figure(rich: Boolean, duplicateFlat: Boolean, format: Int, sizing: Int, width: Long?, height: Long?, minimum: Float?) {
            mark("figurePresence"); byte(1); mark("format"); byte(format); byte(2); byte(0)
            repeat(4) { length(it + .25f) }
            repeat(4) { length(1f) }
            repeat(4) { length(if (it == 2) 3f else 0f) }
            f32(.884f); length(1.2376f, 1)
            mark("frameColor"); byte(0)
            byte(1); length(0f); byte(2); string("#123456")
            byte(1); byte(0); byte(2); string("#654321"); byte(1)
            image(width, height)
            u32(if (!rich || duplicateFlat) 1 else 0)
            if (!rich || duplicateFlat) text("Caption")
            byte(if (rich) 1 else 0); if (rich) u32(0)
            byte(1); byte(2)
            mark("sizing"); byte(sizing)
            mark("frameMinPresence"); byte(if (minimum == null) 0 else 1)
            if (minimum != null) { mark("frameMinUnit"); byte(0); mark("frameMinValue"); f32(minimum) }
        }
        fun document(rich: Boolean = true, duplicateFlat: Boolean = false,
            format: Int = 0, sizing: Int = 2, width: Long? = 120, height: Long? = null,
            minimum: Float? = null): ByteArray {
            out.write(byteArrayOf(68, 80, 82, 74)); u32(0); u32(1)
            byte(2); string("Body"); string(""); string(""); u32(1)
            byte(0); byte(0); byte(0); u32(0); byte(0); string(""); string(""); byte(0)
            string(""); string(""); byte(0); byte(0); byte(0); byte(1)
            u32(3); byte(0); u32(1); text("Before")
            byte(2); byte(0); byte(3); byte(1); optional(""); u32(1); byte(1)
            figure(rich, duplicateFlat, format, sizing, width, height, minimum)
            byte(0); u32(1); text("After")
            repeat(4) { u32(0) } // preamble, lexemes, other sections, references
            u32(1); string("Map.png"); byte(0); string("Catalog caption")
            return out.toByteArray()
        }
    }
    private fun decode(bytes: ByteArray) = BlobDecoder.decode(bytes, "Literal figure", "language", "English", "en")
    private fun figure(entry: Entry): Figure {
        val flow = entry.sections.single().blocks.single().flow!!
        val scope = (flow[1] as FlowPart.Scope).scope
        assertEquals(BidiDirectionInput.Auto, scope.authoredDirection)
        assertEquals(BidiResolvedDirection.Rtl, scope.resolvedDirection)
        assertEquals("", scope.language)
        assertEquals("Before", textOf((flow.first() as FlowPart.Inline).spans))
        assertEquals("After", textOf((flow.last() as FlowPart.Inline).spans))
        return (scope.parts.single() as FlowPart.ImageFigure).figure
    }

    @Test fun literalJFigureRetainsMapPrecisionTaggedPaintAndAuthoritativeEmptyCaption() {
        val entry = decode(Wire().document())
        val value = figure(entry)
        assertEquals(FigurePlacement.FloatLeft, value.placement)
        assertEquals(FigureSizingPolicy.RequestedFit, value.sizing)
        assertEquals(FigureColor.NativeTheme, value.frameBackground)
        assertEquals(FigureColor.Transparent, value.imageBackground)
        assertEquals(FigureBorder.Solid(StyleLength(StyleLengthUnit.Px, 0f), FigureColor.Rgb("#123456")), value.frameBorder)
        assertEquals(3f, value.captionPadding.bottom.value, 0f)
        assertEquals(emptyList<Block>(), value.captionBlocks)
        assertTrue(value.caption.isEmpty())
        assertEquals(CellTextAlign.Right, value.captionTextAlign)
        assertEquals("", value.imageSpan.targetFragment)
        assertEquals("Inherited advice", value.imageSpan.tooltip)
        val image = value.imageSpan.image!!
        assertEquals(120L, image.widthPx); assertNull(image.heightPx)
        assertEquals("", image.alt); assertEquals("", image.tooltip); assertTrue(image.border)
        val map = image.map!!
        assertEquals(ImageMapDescription.TopRight, map.description)
        assertEquals(listOf(-.25, 1.5, 99.125, 80.75), map.regions.single().coordinates)
        assertEquals(EntryLink("", ""), map.regions.single().action.entryLink())
        assertEquals(ImageMapActionKind.External, map.defaultAction!!.kind)
        assertNull(map.defaultAction!!.targetFragment)
        assertEquals(listOf(Media("Map.png", "image", "Catalog caption")), entry.media)
        assertEquals(1, entry.inlineImages.size)
        val runs = mutableListOf<String>()
        entry.sections.single().blocks.single().visitSpanRuns { spans, _ -> runs += spans.map { it.image?.file ?: it.text } }
        assertEquals(listOf("Before", "Map.png", "After"), runs)
        val flat = figure(decode(Wire().document(rich = false)))
        assertNull(flat.captionBlocks); assertEquals("Caption", textOf(flat.caption))
    }

    @Test fun malformedFigureTagsCountsCoordinatesAndDuplicateCaptionOwnershipAreRejected() {
        val wire = Wire(); val valid = wire.document()
        fun badByte(name: String, value: Int) {
            val bytes = valid.copyOf(); bytes[wire.offsets.getValue(name)] = value.toByte()
            assertThrows(name, RuntimeException::class.java) { decode(bytes) }
        }
        badByte("figurePresence", 0)
        badByte("format", 2)
        badByte("sizing", 4)
        badByte("sizing", 255)
        badByte("sizing", 0) // intrinsic cannot describe a thumbnail
        badByte("frameColor", 3)
        badByte("description", 5)
        badByte("shape", 3)
        badByte("imageFlags", 0x7d)
        badByte("coordinateCount", 3)
        val oversized = valid.copyOf()
        repeat(4) { oversized[wire.offsets.getValue("regionCount") + it] = 0xff.toByte() }
        assertThrows(IllegalArgumentException::class.java) { decode(oversized) }
        val nonfinite = valid.copyOf(); val bits = Double.NaN.toRawBits()
        repeat(8) { nonfinite[wire.offsets.getValue("coordinate") + it] = (bits ushr (8 * it)).toByte() }
        assertThrows(IllegalArgumentException::class.java) { decode(nonfinite) }
        assertThrows(IllegalArgumentException::class.java) { decode(Wire().document(duplicateFlat = true)) }
    }

    @Test fun allSizingTagsAreRequiredAndPreserveBoundsInsideTheSameScopedFigure() {
        for (policy in FigureSizingPolicy.entries) {
            val framed = policy == FigureSizingPolicy.Intrinsic || policy == FigureSizingPolicy.OriginalWidthWithHeightBound
            val value = figure(decode(Wire().document(format = if (framed) 1 else 0,
                sizing = policy.ordinal, width = 1200, height = 600)))
            assertEquals(policy, value.sizing)
            assertEquals(1200L, value.imageSpan.image!!.widthPx)
            assertEquals(600L, value.imageSpan.image!!.heightPx)
            assertEquals("", value.imageSpan.targetFragment)
            assertEquals(listOf(-.25, 1.5, 99.125, 80.75), value.imageSpan.image!!.map!!.regions.single().coordinates)
            assertEquals(emptyList<Block>(), value.captionBlocks)
        }
        assertThrows(IllegalArgumentException::class.java) { decode(Wire().document(width = null)) }
        assertThrows(IllegalArgumentException::class.java) { decode(Wire().document(format = 1, sizing = 1)) }
        val wire = Wire(); val bytes = wire.document(); val at = wire.offsets.getValue("sizing")
        val missing = bytes.copyOfRange(0, at) + bytes.copyOfRange(at + 1, bytes.size)
        assertThrows(RuntimeException::class.java) { decode(missing) }
    }

    @Test fun everyTruncatedFigureDocumentAndMissingCatalogFailsClosed() {
        val valid = Wire().document()
        for (length in valid.indices) assertThrows("prefix $length", RuntimeException::class.java) {
            decode(valid.copyOf(length))
        }
        val catalogBytes = 4 + 4 + "Map.png".length + 1 + 4 + "Catalog caption".length
        val missing = valid.copyOf(valid.size - catalogBytes + 4)
        repeat(4) { missing[missing.lastIndex - it] = 0 }
        assertThrows(IllegalArgumentException::class.java) { decode(missing) }
    }

    @Test fun frameMinimumRequiresStrictPresencePxAndFiniteNonnegativeValue() {
        for (minimum in listOf(null, 0f, 100f)) {
            val value = figure(decode(Wire().document(rich = false, minimum = minimum)))
            assertEquals(minimum?.let { StyleLength(StyleLengthUnit.Px, it) }, value.frameMinWidth)
            assertEquals(120L, value.imageSpan.image!!.widthPx)
            assertEquals("Caption", textOf(value.caption))
            assertEquals(listOf(-.25, 1.5, 99.125, 80.75), value.imageSpan.image!!.map!!.regions.single().coordinates)
        }
        val wire = Wire(); val valid = wire.document(minimum = 100f)
        for ((field, byte) in listOf("frameMinPresence" to 2, "frameMinUnit" to 1, "frameMinUnit" to 2)) {
            val bad = valid.copyOf(); bad[wire.offsets.getValue(field)] = byte.toByte()
            assertThrows(field, RuntimeException::class.java) { decode(bad) }
        }
        for (value in listOf(-1f, Float.NaN, Float.POSITIVE_INFINITY, Float.NEGATIVE_INFINITY)) {
            assertThrows(RuntimeException::class.java) { decode(Wire().document(minimum = value)) }
        }
        for (end in wire.offsets.getValue("frameMinPresence")..wire.offsets.getValue("frameMinValue") + 3)
            assertThrows("minimum prefix $end", RuntimeException::class.java) { decode(valid.copyOf(end)) }
        val absent = Wire(); val old = absent.document(); val at = absent.offsets.getValue("frameMinPresence")
        assertThrows(RuntimeException::class.java) { decode(old.copyOfRange(0, at) + old.copyOfRange(at + 1, old.size)) }
    }
}
