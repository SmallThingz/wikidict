package app.smallthingz.dict

import java.io.ByteArrayOutputStream
import org.junit.Assert.*
import org.junit.Test

/** Literal complete documents pin the unpublished M tail; there is no runtime source parser. */
class FigureTableCaptionCodecTest {
    private class Wire(val imageKind: Int = 1, val imageTarget: String = "File:Image.svg", val imageMap: Boolean = false,
        val missingPaint: Boolean = false, val captionPaint: Boolean = false, val legacyMissingPaint: Boolean = false) {
        val out = ByteArrayOutputStream()
        val offsets = linkedMapOf<String, Int>()
        fun mark(name: String) { check(offsets.put(name, out.size()) == null) }
        fun byte(value: Int) { out.write(value) }
        fun u32(value: Int) { repeat(4) { byte(value ushr (it * 8)) } }
        fun float(value: Float) = u32(value.toRawBits())
        fun double(value: Double) { val bits = value.toRawBits(); repeat(8) { byte((bits ushr (it*8)).toInt()) } }
        fun string(value: String) { val bytes = value.encodeToByteArray(); u32(bytes.size); out.write(bytes) }
        fun length(value: Float, unit: Int = 0) { byte(unit); float(value) }
        fun span(text: String, image: Boolean = false) {
            byte(if (image) imageKind else 1); byte(0); byte(0); string(text); string(if (image) imageTarget else "caption-target")
            repeat(5) { string("") }; repeat(3) { byte(0) }
            byte(if (image) 1 else 0)
            if (image) {
                string("Image.svg"); byte(if (imageMap) 0x27 else 7); u32(100); u32(50); string("")
                if (imageMap) {
                    byte(0); u32(1); byte(0); u32(4); listOf(0.0,0.0,100.0,50.0).forEach(::double)
                    byte(0); string("Mapped target"); byte(0); string("Mapped region"); byte(0)
                }
            }
            byte(0); byte(0)
        }
        fun before() {
            mark("beforeFlags"); u32(0x2000d)
            repeat(4) { length(if (it == 3) 3f else 0f) }
            byte(1); byte(0); mark("beforeWidth"); float(15f)
            byte(1); length(11f)
        }
        fun media(prefix: String, missing: Boolean, paint: Boolean = true) {
            mark(prefix+"FontScale"); float(1.25f); mark(prefix+"FontFlags"); byte(3)
            string("fi"); mark(prefix+"Direction"); byte(0)
            mark(prefix+"Align"); byte(if (missing) 0 else 1)
            mark(prefix+"CapPresence"); byte(if (missing) 0 else 1)
            if (!missing) { mark(prefix+"CapPercent"); float(100f); length(4f) }
            byte(if (missing) 0 else 1); if (!missing) { mark(prefix+"Position"); byte(0) }
            byte(if (missing) 0 else 1)
            if (!missing) {
                length(15f); length(11f); mark(prefix+"AfterSide"); byte(1)
                length(6f); length(-11f); byte(if (paint) 1 else 0)
                if (paint) { mark(prefix+"Graphic"); byte(0); mark(prefix+"Invert"); byte(1) }
            }
            byte(if (missing) 0 else 1)
            if (!missing) { length(2f); byte(2); string("#3366cc"); length(2f); length(0f) }
        }
        fun linkPaint(prefix: String, red: Boolean) {
            listOf(if (red) "#bf3c2c" else "#3366cc", "#3056a9", "#233566", "#6a60b0", "#534fa3", "#353262")
                .forEachIndexed { index, color -> mark(prefix+"Color"+index); string(color) }
            mark(prefix+"Mask"); byte(if (red) 0 else 0x76)
            mark(prefix+"FocusPresence"); byte(1)
            mark(prefix+"FocusWidth"); length(2f)
            mark(prefix+"FocusColor"); byte(2); string("#123456")
            length(2f); mark(prefix+"FocusOffset"); length(-2f)
        }
        fun tail(missing: Boolean) {
            mark("collapse"); byte(1)
            mark("baseWrapper"); u32(0x200000)
            byte(1); length(0f); byte(0); byte(1); length(0f); byte(0)
            mark("baseWrapperEnd")
            mark("tableTop"); byte(2); length(1f); byte(2); string("#aabbcc")
            byte(0); byte(1); byte(0)
            byte(3); length(.1f, 1); byte(0); repeat(3) { byte(0) }
            media("base", missing)
            mark("beforePresence"); byte(1); before()
            mark("stateCount"); u32(2)
            mark("firstThreshold"); u32(639); u32(0x200000)
            byte(1); length(0f); byte(0); byte(1); length(0f); byte(0)
            media("first", missing, paint = false); byte(0)
            mark("secondThreshold"); u32(399); mark("secondWrapperFlags"); u32(0)
            media("second", missing); byte(0)
            mark("missingPaintPresence"); byte(if (missingPaint) 1 else 0)
            if (missingPaint) linkPaint("missing", red=true)
            mark("captionPaintPresence"); byte(if (captionPaint) 1 else 0)
            if (captionPaint) linkPaint("caption", red=false)
        }
        fun document(tag: Int = 5, version: Char = 'M'): ByteArray {
            val missing = tag == 2 || tag == 6
            out.write(byteArrayOf(68,80,82,version.code.toByte())); u32(0); u32(1)
            byte(2); string("Body"); string(""); string(""); u32(1)
            byte(0); byte(0); byte(0); u32(0); byte(0); string(""); string(""); byte(0)
            string(""); string(""); byte(0); byte(0)
            mark("figureTag"); byte(tag); byte(0); byte(0); byte(0)
            repeat(12) { length(0f) }; float(.9f); length(1.2f, 1)
            byte(0); byte(0); byte(1); byte(0); byte(0); byte(1)
            span(if (missing) "Missing image" else "", !missing)
            if (missing) { length(100f); length(1.2f, 1); byte(if (legacyMissingPaint) 1 else 0); if (legacyMissingPaint) byte(0) }
            u32(1); span("Caption action"); byte(0); byte(0)
            if (!missing) byte(2)
            byte(0)
            if (tag >= 5) tail(missing)
            byte(0); repeat(4) { u32(0) }
            u32(if (missing) 0 else 1)
            if (!missing) { string("Image.svg"); byte(0); string("") }
            return out.toByteArray()
        }
    }
    private fun read(bytes: ByteArray) = BlobDecoder.decode(bytes, "figure", "language", "English", "en")
        .sections.single().blocks.single().figure!!

    @Test fun mImageAndMissingTagsDecodeExactEdgesCapAndCompleteResponsiveStates() {
        val image = read(Wire().document())
        val value = image.tableCaptionLayout!!
        assertEquals(TableCollapse.Collapse, value.collapse)
        assertEquals(ContainerMargin.Auto, value.wrapper.marginValues!!.left)
        assertEquals(ContainerMargin.Auto, value.wrapper.marginValues!!.right)
        assertNull(value.wrapper.floatSide)
        assertEquals(FigureBorderEdge.Hidden, value.tableBorder.bottom)
        assertEquals(FigureBorderEdge.Solid(StyleLength(StyleLengthUnit.Px,1f), FigureColor.Rgb("#aabbcc")), value.tableBorder.top)
        assertEquals(AvailableWidthLimit(100f, StyleLength(StyleLengthUnit.Px,4f)), value.media.maxWidth)
        assertEquals(FigureMediaStrut(1.25f, bold = true, italic = true, language = "fi", direction = BidiResolvedDirection.Ltr), value.media.strut)
        assertEquals(InlineBoxVerticalAlign.Middle, value.media.verticalAlign)
        assertEquals(ContainerPositioning.RelativeAuto, value.media.positioning)
        assertEquals(-11f, value.media.after!!.bottom.value, 0f)
        assertEquals(FigureGraphicPaint(FigureMediaGraphic.MagnifyClipLtrV1, true), value.media.after!!.paint)
        assertEquals(FigureColor.Rgb("#3366cc"), value.media.focusOutline!!.color)
        assertNotNull(value.stateAtViewport(639.0)!!.media.after)
        assertNull(value.stateAtViewport(639.0)!!.media.after!!.paint)
        assertEquals(15f, ((value.captionBefore!!.width as ContainerWidth.Length).value.value), 0f)
        assertEquals(TableFloatSide.Right, value.captionBefore!!.floatSide)
        assertEquals(listOf(639L,399L), value.viewportStates.map { it.maxWidthPx })
        assertNull(value.stateAtViewport(639.0)!!.captionBefore)
        assertEquals(ContainerMargin.Auto, value.stateAtViewport(639.0)!!.wrapper.marginValues!!.left)
        assertEquals(ContainerStyle(), value.stateAtViewport(399.0)!!.wrapper)
        assertEquals("caption-target", image.caption.single().target)
        assertEquals(50L, image.content.span.image!!.heightPx) // Source axes survive height:auto cap policy.
        val missing = read(Wire().document(tag=6))
        assertTrue(missing.content is FigureContent.Missing)
        assertNull(missing.tableCaptionLayout!!.media.maxWidth)
        assertEquals(InlineBoxVerticalAlign.Baseline, missing.tableCaptionLayout!!.media.verticalAlign)
        assertNull(missing.tableCaptionLayout!!.media.positioning)
        assertNull(missing.tableCaptionLayout!!.media.after)
        assertNull(missing.tableCaptionLayout!!.media.focusOutline)
        assertEquals("Missing image", missing.content.span.text)
        assertEquals("Caption action", missing.caption.single().text)
    }

    @Test fun absentTailKeepsOldPayloadAndOldVersionsRejectOnlyNewFigureTags() {
        val old = Wire().document(tag=1, version='J')
        for (version in listOf('J','K','L','M')) {
            val bytes = old.copyOf().also { it[3]=version.code.toByte() }
            assertEquals(old.drop(4), bytes.drop(4))
            assertEquals(read(old), read(bytes))
            assertNull(read(bytes).tableCaptionLayout)
            if (version!='M') for(tag in listOf(5,6))
                assertThrows(RuntimeException::class.java) { read(Wire().document(tag,version)) }
        }
        assertEquals(read(Wire().document(2,'K')), read(Wire().document(2,'M')))
    }

    @Test fun malformedTailPresenceEnumsLengthsOrderAndTruncationFailClosed() {
        val wire=Wire();val bytes=wire.document()
        for((name,value) in listOf("figureTag" to 3,"figureTag" to 4,"figureTag" to 7,"collapse" to 0,"collapse" to 2,"tableTop" to 4,
            "baseCapPresence" to 2,"baseFontFlags" to 8,"baseDirection" to 2,"baseAlign" to 0,
            "firstAlign" to 2,"basePosition" to 1,"baseAfterSide" to 2,"baseGraphic" to 2,"baseInvert" to 2,"beforePresence" to 2)) {
            val bad=bytes.copyOf();bad[wire.offsets.getValue(name)]=value.toByte()
            assertThrows(name,RuntimeException::class.java) { read(bad) }
        }
        fun invalidU32(name:String,value:Int) {
            val bad=bytes.copyOf();repeat(4) { bad[wire.offsets.getValue(name)+it]=(value ushr(it*8)).toByte() }
            assertThrows(name,RuntimeException::class.java) { read(bad) }
        }
        invalidU32("baseCapPercent",Float.NaN.toRawBits());invalidU32("baseCapPercent",99f.toRawBits())
        invalidU32("baseFontScale",Float.NaN.toRawBits());invalidU32("secondFontScale",(-1f).toRawBits())
        invalidU32("beforeWidth",(-1f).toRawBits());invalidU32("beforeFlags",0x400000)
        invalidU32("stateCount",17);invalidU32("secondThreshold",639);invalidU32("secondThreshold",640)
        invalidU32("secondWrapperFlags",0x20000)
        invalidU32("baseWrapper",0x400000)
        // The required base record cannot be guessed from legacy Figure placement.
        val omittedBase = bytes.take(wire.offsets.getValue("baseWrapper")).toByteArray() +
            bytes.drop(wire.offsets.getValue("baseWrapperEnd")).toByteArray()
        assertThrows(RuntimeException::class.java) { read(omittedBase) }
        for(end in bytes.indices) assertThrows("prefix $end",RuntimeException::class.java) { read(bytes.copyOf(end)) }
        assertThrows(RuntimeException::class.java) { read(bytes+byteArrayOf(0)) }
    }

    @Test fun afterAndFocusRequireOneActualImageActionAndMapsRemainLegacyOnly() {
        assertThrows(RuntimeException::class.java) { read(Wire(imageKind=0, imageTarget="").document()) }
        assertThrows(RuntimeException::class.java) { read(Wire(imageTarget="").document()) }
        val legacy = read(Wire(imageMap=true).document(tag=1))
        assertEquals("Mapped target", legacy.content.span.image!!.map!!.regions.single().action.target)
        assertThrows(RuntimeException::class.java) { read(Wire(imageMap=true).document()) }
        val image = read(Wire().document())
        val content = image.content as FigureContent.Image
        val noAction = content.copy(span=content.span.copy(kind="text",target=""))
        val style = image.tableCaptionLayout!!
        // A harmless base does not permit an actionable after box in a later complete state.
        val baseOnly = style.copy(media=style.media.copy(after=null,focusOutline=null))
        assertThrows(IllegalArgumentException::class.java) { image.copy(content=noAction,tableCaptionLayout=baseOnly) }
        assertEquals(noAction, image.copy(content=noAction,tableCaptionLayout=baseOnly.copy(viewportStates=emptyList())).content)
    }

    @Test fun fixedPalettesDecodeIndependentlyWithExactStateFlagsAndSignedFocus() {
        val image = read(Wire(captionPaint=true).document())
        assertNull(image.tableCaptionLayout!!.missingLinkPaint)
        val caption = image.tableCaptionLayout!!.captionLinkPaint!!
        assertEquals(FigureLinkState("#3366cc",false),caption.normal)
        assertEquals(FigureLinkState("#3056a9",true),caption.hover)
        assertEquals(FigureLinkState("#233566",true),caption.active)
        assertEquals(FigureLinkState("#6a60b0",false),caption.visited)
        assertEquals(FigureLinkState("#534fa3",true),caption.visitedHover)
        assertEquals(FigureLinkState("#353262",true),caption.visitedActive)
        assertTrue(caption.underlineOnFocus)
        assertEquals(SignedContainerMargin(StyleLengthUnit.Px,-2f),caption.focusOutline!!.offset)
        assertEquals(FigureColor.Rgb("#123456"),caption.focusOutline!!.color)
        val missing = read(Wire(missingPaint=true,captionPaint=true).document(6))
        val red = missing.tableCaptionLayout!!.missingLinkPaint!!
        assertEquals("#bf3c2c",red.normal.foreground)
        assertFalse(red.hover.underline)
        assertFalse(red.underlineOnFocus)
        assertNull((missing.content as FigureContent.Missing).linkPaint)
        assertEquals(caption,missing.tableCaptionLayout!!.captionLinkPaint)
        assertEquals(MissingLinkPaint.VectorNewLinkV1,
            (read(Wire(legacyMissingPaint=true).document(2)).content as FigureContent.Missing).linkPaint)
        assertEquals(read(Wire().document(1)),read(Wire(captionPaint=true,missingPaint=true).document(1)))
    }

    @Test fun malformedPolicyBytesAndContentOwnershipRefuseWithoutOldTailFallback() {
        val wire = Wire(missingPaint=true,captionPaint=true); val bytes=wire.document(6)
        fun badByte(name:String,relative:Int,value:Int) {
            val bad=bytes.copyOf();bad[wire.offsets.getValue(name)+relative]=value.toByte()
            assertThrows(name,RuntimeException::class.java) { read(bad) }
        }
        badByte("missingPaintPresence",0,2); badByte("captionPaintPresence",0,2)
        badByte("missingMask",0,0x80); badByte("captionMask",0,0xff)
        badByte("missingFocusPresence",0,2); badByte("captionFocusPresence",0,2)
        badByte("missingColor0",5,'B'.code); badByte("captionColor5",6,'g'.code)
        badByte("captionFocusColor",0,0)
        for(name in listOf("missingFocusWidth","captionFocusOffset")) {
            val bad=bytes.copyOf();repeat(4) { bad[wire.offsets.getValue(name)+1+it]=(Float.NaN.toRawBits() ushr(it*8)).toByte() }
            assertThrows(name,RuntimeException::class.java) { read(bad) }
        }
        for(end in wire.offsets.getValue("missingPaintPresence") until bytes.size)
            assertThrows("policy prefix $end",RuntimeException::class.java) { read(bytes.copyOf(end)) }
        val noPolicies=Wire();val plain=noPolicies.document()
        val oldTail=plain.take(noPolicies.offsets.getValue("missingPaintPresence")).toByteArray()+
            plain.drop(noPolicies.offsets.getValue("captionPaintPresence")+1).toByteArray()
        assertThrows(RuntimeException::class.java) { read(oldTail) }
        assertThrows(RuntimeException::class.java) { read(Wire(missingPaint=true).document(5)) }
        assertThrows(RuntimeException::class.java) { read(Wire(missingPaint=true,legacyMissingPaint=true).document(6)) }
        for(version in listOf('J','K','L')) for(tag in listOf(5,6))
            assertThrows(RuntimeException::class.java) { read(Wire(captionPaint=true).document(tag,version)) }
    }

    @Test fun captionPolicyVisitsTypedChildrenButStopsAtNestedFigureAndKeepsOriginalSpans() {
        val value=read(Wire(captionPaint=true).document())
        val link=value.caption.single().copy(foreground="#3366cc",bold=true,italic=true,underline=true,
            language="fi",direction="rtl",trail="!",targetFragment="part")
        assertEquals(link,value.copy(caption=listOf(link)).caption.single())
        val conflict=link.copy(foreground="#112233")
        assertThrows(IllegalArgumentException::class.java) { value.copy(caption=listOf(conflict)) }
        val nested=read(Wire().document()).copy(caption=listOf(conflict))
        val cell=Cell(emptyList(),false,1,1,blocks=listOf(Block("paragraph",0,listOf(link)),
            Block("paragraph",0,emptyList(),figure=nested)))
        val table=Table(emptyList(),listOf(listOf(cell)))
        val graph=listOf(Block("table",0,emptyList(),table=table))
        assertSame(graph,value.copy(caption=emptyList(),captionBlocks=graph).captionBlocks)
        val bad=table.copy(rows=listOf(listOf(cell.copy(blocks=listOf(Block("paragraph",0,listOf(conflict)))))))
        assertThrows(IllegalArgumentException::class.java) {
            value.copy(caption=emptyList(),captionBlocks=listOf(Block("table",0,emptyList(),table=bad)))
        }
        val missing=read(Wire(missingPaint=true).document(6))
        val content=missing.content as FigureContent.Missing
        assertThrows(IllegalArgumentException::class.java) {
            missing.copy(content=content.copy(span=content.span.copy(foreground="#3366cc")))
        }
        val noAction=content.copy(span=content.span.copy(kind="text",target=""))
        assertThrows(IllegalArgumentException::class.java) { missing.copy(content=noAction) }
        assertThrows(IllegalArgumentException::class.java) {
            missing.copy(content=content.copy(span=content.span.copy(target="")))
        }
        assertEquals(noAction,missing.copy(content=noAction,
            tableCaptionLayout=missing.tableCaptionLayout!!.copy(missingLinkPaint=null)).content)
    }
}
