package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test

class FigureLinkStateTest {
    private fun policy(underline: Boolean = true): FigureLinkPaint {
        val colors = listOf("#3366cc", "#3056a9", "#233566", "#6a60b0", "#534fa3", "#353262")
        val states = colors.mapIndexed { index, value -> FigureLinkState(value, underline && index % 3 != 0) }
        return FigureLinkPaint(states[0], states[1], states[2], states[3], states[4], states[5], underline)
    }

    @Test fun fixedStatesKeepActivePriorityAndFocusOrChildDecorationWithoutThemeInference() {
        val policy = policy()
        val expected = listOf(0x3366cc,0x3056a9,0x233566,0x6a60b0,0x534fa3,0x353262)
        for (visited in listOf(false,true)) for (hover in listOf(false,true))
            for (active in listOf(false,true)) for (focus in listOf(false,true)) {
                val paint = NativeMissingLinkPaint(policy,visited).apply {
                    hovered=hover; this.active=active; focused=focus
                }
                val index = (if (visited) 3 else 0) + if (active) 2 else if (hover) 1 else 0
                assertEquals(0xff000000.toInt() or expected[index],paint.appearance().color)
                assertEquals(hover || active || focus,paint.appearance().underline)
                assertFalse(paint.dark)
            }
        val red = policy(false).copy(normal=FigureLinkState("#bf3c2c",false))
        assertEquals(0xffbf3c2c.toInt(),NativeMissingLinkPaint(red,false).appearance().color)
        val noDecoration=NativeMissingLinkPaint(red,false).apply { hovered=true; active=true; focused=true }
        assertFalse(noDecoration.appearance().underline)
        assertTrue(NativeMissingLinkPaint(red,false,childUnderline=true).appearance().underline)
        val legacy=NativeMissingLinkPaint(MissingLinkPaint.VectorNewLinkV1,true,false).apply { hovered=true }
        assertEquals(0xfffea898.toInt(),legacy.appearance().color)
        assertTrue(legacy.appearance().underline)
    }

    @Test fun sameTargetAnchorsShareSessionVisitsButNotPendingActionIdentity() {
        val owner=Any(); val paragraph=Any()
        val first=Span("link","One","Target",targetFragment="part")
        val target=missingLinkTarget(first,"fi")
        val firstIdentity=MissingLinkActionIdentity(owner,target,NativeLinkOccurrenceIdentity(paragraph,0,0,3,first))
        val secondIdentity=firstIdentity.copy(occurrence=NativeLinkOccurrenceIdentity(paragraph,1,3,6,first))
        val visits=MissingLinkVisits()
        assertFalse(visits.contains(target))
        visits.record(target)
        assertTrue(visits.contains(missingLinkTarget(first.copy(text="Two"),"fi")))
        assertFalse(visits.contains(missingLinkTarget(first,"en")))
        var calls=0
        val callback={ calls++; Unit }
        fun node(identity:MissingLinkActionIdentity)=FloatInteractionNode(0,FloatInteractionKind.LINK,
            0,3,emptyList(),"One",null,callback,missingLinkPaint=NativeMissingLinkPaint(policy(),false,
                actionIdentity=identity))
        val pending=NativeLinkKeyPress(0,66,firstIdentity,{ error("Replaced callback must not run") })
        assertTrue(pending.matches(node(firstIdentity)))
        assertFalse(pending.matches(node(secondIdentity)))
        assertFalse(pending.matches(node(firstIdentity.copy(owner=Any()))))
        assertFalse(pending.matches(node(firstIdentity.copy(occurrence=
            NativeLinkOccurrenceIdentity(paragraph,0,0,3,first.copy(text="Two"))))))
        node(firstIdentity).onClick!!.invoke()
        assertEquals(1,calls)
        visits.clear(); assertFalse(visits.contains(target))
    }

    @Test fun captionRangesRetainUtf16IsolationTrailAndSeparateOrdinaryActionOwners() {
        val first=Span("link","ab","Target",trail="!",direction="rtl")
        val image=Span("link","","File:Image.svg",image=InlineImage("Image.svg"))
        val spans=listOf(first,Span("line_break",""),image,
            Span("external_link","cd","https://example.invalid",direction="auto"),
            Span("link","ef","Target"),Span("text","tail"))
        val ranges=nativeCaptionLinkRanges(spans)
        assertEquals(listOf(0,3,4),ranges.map { it.index })
        assertEquals(listOf(0 to 5,7 to 11,11 to 13),ranges.map { it.start to it.end })
        assertSame(first,ranges[0].span)
        assertEquals(listOf("ab","cd","ef"),ranges.map { it.span.text })
        assertTrue(nativeCaptionLinkRanges(listOf(Span("text","No action"))).isEmpty())
    }

    @Test fun policyRejectsNoncanonicalColorsAndThemeFocusButPreservesSignedOffsets() {
        for (color in listOf("#ABCDEF","#fff","red","#00000000"," #123456","#12345g"))
            assertThrows(IllegalArgumentException::class.java) { FigureLinkState(color,false) }
        val width=StyleLength(StyleLengthUnit.Px,2f)
        val focus=FigureFocusOutline(width,FigureColor.Rgb("#123456"),width,
            SignedContainerMargin(StyleLengthUnit.Em,-2f))
        assertEquals(focus,policy().copy(focusOutline=focus).focusOutline)
        for (color in listOf(FigureColor.NativeTheme,FigureColor.Transparent))
            assertThrows(IllegalArgumentException::class.java) { policy().copy(focusOutline=focus.copy(color=color)) }
    }

    @Test fun atomicMissingUsesItsRealLastBaselineFontBandAndChildBorderWithoutVerticalMargins() {
        val font=NativePrimaryFontMetrics(-10f,3f,13f,0f)
        val fragments=figureMissingLinkFragments(100f,50f,42f,1f,3f,5f,font)
        assertEquals(listOf(NativeFloatBounds(-4f,32f,106f,45f),NativeFloatBounds(-1f,-1f,101f,51f)),fragments)
        fun hit(x:Float,y:Float)=fragments.any { x>=it.left && x<it.right && y>=it.top && y<it.bottom }
        assertTrue(hit(-3f,40f));assertTrue(hit(100.5f,1f))
        assertFalse(hit(-3f,1f));assertFalse(hit(0f,52f))
        val shifted=figureMissingLinkFragments(100f,50f,42f,1f,3f,5f,font.copy(baselineShift=-4f))
        assertEquals(NativeFloatBounds(-4f,28f,106f,41f),shifted[0]);assertEquals(fragments[1],shifted[1])
        val zero=NativePrimaryFontMetrics(0f,0f,0f,0f)
        assertTrue(figureMissingLinkFragments(0f,0f,0f,0f,0f,0f,zero).isEmpty())
        assertThrows(UnsupportedFloatLayout::class.java) {
            figureMissingLinkFragments(100f,50f,Float.MAX_VALUE,1f,3f,5f,font)
        }
    }

    @Test fun actualRoundedMaiAxesKeepPreferred190WhileARealHeightBoundStillReducesWidth() {
        val png=InlineImage("Control.png",widthPx=190,heightPx=248)
        val jpeg=InlineImage("Control.jpg",widthPx=190,heightPx=296)
        assertEquals(FigureSourceSize(190uL,248uL),figureSourceSize(png,FigureSizingPolicy.RequestedFit,460,600))
        assertEquals(FigureSourceSize(190uL,296uL),figureSourceSize(jpeg,FigureSizingPolicy.RequestedFit,2420,3775))
        assertEquals(FigureSourceSize(189uL,295uL),figureSourceSize(jpeg.copy(heightPx=295),
            FigureSizingPolicy.RequestedFit,2420,3775))
        assertEquals(190L,png.widthPx)
        assertEquals(296L,jpeg.heightPx)
    }
}
