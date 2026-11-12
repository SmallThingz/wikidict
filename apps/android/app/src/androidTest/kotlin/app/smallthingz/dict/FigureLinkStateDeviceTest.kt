package app.smallthingz.dict

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Rect
import android.os.SystemClock
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.accessibility.AccessibilityNodeInfo
import androidx.activity.compose.setContent
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.sp
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.viewinterop.AndroidView
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** Drives the actual native span owners. This is not a delegated Compose hit-ancestry oracle. */
@RunWith(AndroidJUnit4::class)
class FigureLinkStateDeviceTest {
    @get:Rule val compose=createPhysicalComposeRule()
    private fun px(value:Float)=StyleLength(StyleLengthUnit.Px,value)
    private val edges=FigureBorderEdges(FigureBorderEdge.None,FigureBorderEdge.None,FigureBorderEdge.None,FigureBorderEdge.None)
    private fun policy():FigureLinkPaint {
        val states=listOf("#3366cc","#3056a9","#233566","#6a60b0","#534fa3","#353262")
            .mapIndexed { index,value -> FigureLinkState(value,index%3!=0) }
        return FigureLinkPaint(states[0],states[1],states[2],states[3],states[4],states[5],true,
            FigureFocusOutline(px(2f),FigureColor.Rgb("#ff0000"),px(2f),SignedContainerMargin(StyleLengthUnit.Px,-2f)))
    }
    private fun figure(caption:List<Span>,mediaWidth:Float=80f):Figure {
        val zero=StyleEdges(px(0f),px(0f),px(0f),px(0f))
        return Figure(FigureContent.Missing(Span("text","media"),px(mediaWidth),px(20f)),
            FigureFormat.Framed,FigurePlacement.None,FigureClear.None,zero,zero,zero,
            1f,px(26f),FigureColor.Transparent,FigureBorder.None,FigureColor.Transparent,FigureBorder.None,
            FigureColor.NativeTheme,FigureColor.Transparent,caption=caption,
            tableCaptionLayout=TableCaptionLayout(TableCollapse.Collapse,ContainerStyle(),edges,edges,
                FigureMediaLayout(FigureMediaStrut(1f,direction=BidiResolvedDirection.Ltr),InlineBoxVerticalAlign.Baseline),
                captionLinkPaint=policy()))
    }
    private fun nativeView():NativeFloatTextView {
        val found=mutableListOf<NativeFloatTextView>()
        compose.activityRule.scenario.onActivity { activity ->
            fun visit(view:View) {
                if(view is NativeFloatTextView) found+=view
                if(view is android.view.ViewGroup) for(i in 0 until view.childCount) visit(view.getChildAt(i))
            }
            visit(activity.window.decorView)
        }
        return found.single()
    }
    private fun event(view:NativeFloatTextView,node:FloatInteractionNode,action:Int,down:Long=SystemClock.uptimeMillis()) {
        val b=node.bounds.first { !it.isEmpty }
        val e=MotionEvent.obtain(down,SystemClock.uptimeMillis(),action,b.centerX()+view.paddingLeft,b.centerY()+view.paddingTop,0)
        try { assertTrue(view.dispatchTouchEvent(e)) } finally { e.recycle() }
    }
    private fun hover(view:NativeFloatTextView,node:FloatInteractionNode,action:Int) {
        val b=node.bounds.first { !it.isEmpty }
        val now=SystemClock.uptimeMillis()
        val e=MotionEvent.obtain(now,now,action,b.centerX()+view.paddingLeft,b.centerY()+view.paddingTop,0)
        e.source = android.view.InputDevice.SOURCE_MOUSE
        try { view.dispatchGenericMotionEvent(e) } finally { e.recycle() }
    }
    private fun colorPixels(view:NativeFloatTextView,color:Int):Int {
        val bitmap=Bitmap.createBitmap(view.width,view.height,Bitmap.Config.ARGB_8888)
        try {
            bitmap.eraseColor(android.graphics.Color.WHITE);view.draw(Canvas(bitmap))
            val pixels=IntArray(bitmap.width*bitmap.height)
            bitmap.getPixels(pixels,0,bitmap.width,0,0,bitmap.width,bitmap.height)
            return pixels.count { it==color }
        } finally { bitmap.recycle() }
    }

    @Test fun actualCaptionStatesKeepDistinctRtlFragmentsVisitsFocusAndSelectionAcrossResize() {
        val first=Span("link","Alpha beta gamma delta epsilon zeta","Same",direction="rtl",italic=true,trail="!",
            background="#eeeeee")
        val second=Span("link","Second","Same",underline=true)
        val captionSpans=listOf(first,Span("text"," / "),second)
        val width=mutableStateOf(190)
        val zeroMargin=ContainerMargin.Length(SignedContainerMargin(StyleLengthUnit.Px,0f))
        val base=figure(captionSpans,190f)
        val source=base.copy(tableCaptionLayout=base.tableCaptionLayout!!.copy(wrapper=ContainerStyle(
            marginValues=ContainerMargins(zeroMargin,ContainerMargin.Auto,zeroMargin,ContainerMargin.Auto))))
        val visits=MissingLinkVisits()
        var geometry:FloatTextGeometry?=null
        val clicks=mutableListOf<EntryLink>()
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                MaterialTheme { CompositionLocalProvider(LocalDensity provides Density(1f,1f),
                    LocalMissingLinkVisits provides visits,LocalMissingLinkDocument provides "Document") {
                    Layout(content={
                        AnonymousBlockView(Block("paragraph",0,emptyList(),figure=source),Modifier,{clicks+=it},emptyList(),
                            AppSettings(allowImages=false,allowAudio=false),"fi",onGeometry={geometry=it})
                    }) { children,_ ->
                        val child=children.single().measure(Constraints.fixedWidth(width.value))
                        layout(width.value,child.height) { child.place(0,0) }
                    }
                } }
            } }
            compose.waitForIdle()
            val view=nativeView()
            var ids=emptyList<Int>();var text="";var initialIdentity:MissingLinkActionIdentity?=null
            var firstBounds=emptyList<android.graphics.RectF>()
            compose.runOnIdle {
                val g=checkNotNull(geometry);val nodes=g.nodes.filter { it.missingLinkPaint?.fixedPolicy!=null }
                assertEquals(2,nodes.size);assertEquals(g.text.toString(),view.logicalText.toString())
                ids=nodes.map { it.id };text=g.text.toString()
                assertTrue(nodes[0].bounds.size>1)
                assertNotEquals(nodes[0].missingLinkPaint!!.actionIdentity,nodes[1].missingLinkPaint!!.actionIdentity)
                initialIdentity=nodes[0].missingLinkPaint!!.actionIdentity
                firstBounds=nodes[0].bounds.map { android.graphics.RectF(it) }
                assertEquals(nodes[0].missingLinkPaint!!.actionIdentity!!.target,nodes[1].missingLinkPaint!!.actionIdentity!!.target)
                assertEquals(0xff3366cc.toInt(),nodes[0].missingLinkPaint!!.appearance().color)
                assertFalse(nodes[0].missingLinkPaint!!.appearance().underline)
                assertTrue(nodes[1].missingLinkPaint!!.appearance().underline)
                assertTrue(colorPixels(view,0xff3366cc.toInt())>0)
                hover(view,nodes[0],MotionEvent.ACTION_HOVER_ENTER)
                assertEquals(0xff3056a9.toInt(),nodes[0].missingLinkPaint!!.appearance().color)
                assertTrue(colorPixels(view,0xff3056a9.toInt())>0)
                val now=SystemClock.uptimeMillis();event(view,nodes[0],MotionEvent.ACTION_DOWN,now)
                assertEquals(0xff233566.toInt(),nodes[0].missingLinkPaint!!.appearance().color)
                assertTrue(colorPixels(view,0xff233566.toInt())>0)
                assertFalse(nodes[0].missingLinkPaint!!.focused)
                assertEquals(0,colorPixels(view,android.graphics.Color.RED))
                event(view,nodes[0],MotionEvent.ACTION_CANCEL,now)
                hover(view,nodes[0],MotionEvent.ACTION_HOVER_EXIT)
                assertTrue(clicks.isEmpty())
                val provider=view.accessibilityNodeProvider
                assertEquals(2,provider.createAccessibilityNodeInfo(View.NO_ID)!!.childCount)
                assertTrue(provider.performAction(nodes[0].id,AccessibilityNodeInfo.ACTION_ACCESSIBILITY_FOCUS,null))
                assertFalse(nodes[0].missingLinkPaint!!.focused)
                assertEquals(0,colorPixels(view,android.graphics.Color.RED))
                assertTrue(provider.performAction(nodes[0].id,AccessibilityNodeInfo.ACTION_FOCUS,null))
                assertTrue(nodes[0].missingLinkPaint!!.focused)
                assertTrue(nodes[0].missingLinkPaint!!.appearance().underline)
                assertTrue(colorPixels(view,android.graphics.Color.RED)>0)
                val focus=nodes[0].focusPaint as NativeNodeFocusPaint.Fragments
                assertEquals(nodes[0].bounds,focus.outlines.map { it.bounds })
                view.dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN,KeyEvent.KEYCODE_ENTER))
                assertTrue(clicks.isEmpty())
                view.dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_UP,KeyEvent.KEYCODE_ENTER))
                assertEquals(listOf(EntryLink("Same")),clicks)
            }
            compose.waitForIdle()
            compose.runOnIdle {
                val nodes=checkNotNull(geometry).nodes.filter { it.missingLinkPaint?.fixedPolicy!=null }
                assertTrue(nodes.all { it.missingLinkPaint!!.visited })
                assertEquals(0xff6a60b0.toInt(),nodes[0].missingLinkPaint!!.appearance().color)
                assertEquals(initialIdentity,nodes[0].missingLinkPaint!!.actionIdentity)
                width.value=280
            }
            compose.waitForIdle();assertSame(view,nativeView())
            compose.runOnIdle {
                val g=checkNotNull(geometry);val nodes=g.nodes.filter { it.missingLinkPaint?.fixedPolicy!=null }
                assertEquals(text,g.text.toString());assertEquals(ids,nodes.map { it.id })
                assertEquals(initialIdentity,nodes[0].missingLinkPaint!!.actionIdentity)
                assertNotEquals(firstBounds,nodes[0].bounds)
                view.setSelection(nodes[0].start,nodes[1].end)
                assertEquals(nodes[0].start,view.selectionStart);assertEquals(nodes[1].end,view.selectionEnd)
                assertEquals(2,view.accessibilityNodeProvider.createAccessibilityNodeInfo(View.NO_ID)!!.childCount)
                val a=view.accessibilityNodeProvider.createAccessibilityNodeInfo(nodes[0].id)!!
                val bounds=Rect();a.getBoundsInParent(bounds);assertFalse(bounds.isEmpty)
                width.value=190
            }
            compose.waitForIdle();assertSame(view,nativeView())
            compose.runOnIdle {
                assertEquals(text,checkNotNull(geometry).text.toString())
                assertEquals(listOf(EntryLink("Same")),clicks)
                val nodes=checkNotNull(geometry).nodes.filter { it.missingLinkPaint?.fixedPolicy!=null }
                view.dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN,KeyEvent.KEYCODE_ESCAPE))
                assertTrue(view.accessibilityNodeProvider.performAction(nodes[0].id,
                    AccessibilityNodeInfo.ACTION_CLEAR_FOCUS,null))
                val down=SystemClock.uptimeMillis();event(view,nodes[1],MotionEvent.ACTION_DOWN,down)
                event(view,nodes[1],MotionEvent.ACTION_UP,down)
                assertEquals(listOf(EntryLink("Same"),EntryLink("Same")),clicks)
                assertFalse(nodes[1].missingLinkPaint!!.focused)
                assertEquals(0,colorPixels(view,android.graphics.Color.RED))
            }
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} };compose.waitForIdle() }
    }

    @Test fun heldCaptionPointerTimerAndKeyCannotActivateAReplacementSpanOwner() {
        val caption=mutableStateOf(Span("link","First label","First"))
        var geometry:FloatTextGeometry?=null
        val clicks=mutableListOf<EntryLink>()
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                MaterialTheme { CompositionLocalProvider(LocalDensity provides Density(1f,1f)) {
                    val value=figure(listOf(caption.value))
                    AnonymousBlockView(Block("paragraph",0,emptyList(),figure=value),Modifier,{clicks+=it},emptyList(),
                        AppSettings(allowImages=false,allowAudio=false),"fi",onGeometry={geometry=it})
                } }
            } }
            compose.waitForIdle()
            val view=nativeView()
            fun node()=checkNotNull(geometry).nodes.single { it.missingLinkPaint?.fixedPolicy!=null }
            var down=0L
            compose.runOnIdle {
                down=SystemClock.uptimeMillis();event(view,node(),MotionEvent.ACTION_DOWN,down)
                caption.value=Span("link","Other label","Other")
            }
            compose.waitForIdle()
            Thread.sleep(android.view.ViewConfiguration.getLongPressTimeout().toLong()+100L)
            compose.runOnIdle {
                assertFalse(view.selectionActive)
                assertTrue(clicks.isEmpty())
                event(view,node(),MotionEvent.ACTION_UP,down)
                assertTrue(clicks.isEmpty())
                assertTrue(view.accessibilityNodeProvider.performAction(node().id,AccessibilityNodeInfo.ACTION_FOCUS,null))
                view.dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN,KeyEvent.KEYCODE_ENTER))
                caption.value=Span("link","Third label","Third")
            }
            compose.waitForIdle()
            compose.runOnIdle {
                view.dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_UP,KeyEvent.KEYCODE_ENTER))
                assertTrue(clicks.isEmpty())
                down=SystemClock.uptimeMillis();event(view,node(),MotionEvent.ACTION_DOWN,down)
            }
            Thread.sleep(android.view.ViewConfiguration.getLongPressTimeout().toLong()+100L)
            compose.runOnIdle {
                assertTrue(view.selectionActive)
                assertTrue(view.selectionEnd>view.selectionStart)
                assertTrue(clicks.isEmpty())
                event(view,node(),MotionEvent.ACTION_CANCEL,down)
                view.dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN,KeyEvent.KEYCODE_ESCAPE))
                assertFalse(view.selectionActive)
                assertTrue(view.accessibilityNodeProvider.performAction(node().id,AccessibilityNodeInfo.ACTION_FOCUS,null))
                view.dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN,KeyEvent.KEYCODE_ENTER))
                view.dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_UP,KeyEvent.KEYCODE_ENTER))
                assertEquals(listOf(EntryLink("Third")),clicks)
            }
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} };compose.waitForIdle() }
    }

    @Test fun realCaptionContainerAndNestedTableShareOneGraphWhileNestedFigureOwnsItsPolicy() {
        val ownNestedPolicy=mutableStateOf(false)
        val green=policy().let { p -> p.copy(normal=p.normal.copy(foreground="#009900")) }
        var geometry:FloatTextGeometry?=null
        val clicks=mutableListOf<EntryLink>()
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                MaterialTheme { CompositionLocalProvider(LocalDensity provides Density(1f,1f)) {
                    val nestedBase=figure(emptyList())
                    val nested=nestedBase.copy(caption=listOf(Span("link","Nested Figure","nested",foreground="#009900")),
                        tableCaptionLayout=nestedBase.tableCaptionLayout!!.copy(
                        captionLinkPaint=if(ownNestedPolicy.value) green else null))
                    val paragraph=Block("paragraph",0,listOf(Span("link","Paragraph","paragraph")))
                    val container=Block("container",0,emptyList(),container=Container(listOf(
                        Block("paragraph",0,listOf(Span("link","Container","container"))))))
                    val cell=Cell(emptyList(),false,1,1,blocks=listOf(
                        Block("paragraph",0,listOf(Span("link","Table child","table"))),
                        Block("paragraph",0,emptyList(),figure=nested)),style=CellStyle(minWidth=px(120f)))
                    val table=Block("table",0,emptyList(),table=Table(emptyList(),listOf(listOf(cell))))
                    val value=figure(emptyList()).copy(captionBlocks=listOf(paragraph,container,table))
                    AnonymousBlockView(Block("paragraph",0,emptyList(),figure=value),Modifier,{clicks+=it},emptyList(),
                        AppSettings(allowImages=false,allowAudio=false),"fi",onGeometry={geometry=it})
                } }
            } }
            compose.waitForIdle()
            val view=nativeView()
            var text="";var ids=emptyList<Int>()
            compose.runOnIdle {
                val g=checkNotNull(geometry);text=g.text.toString();ids=g.nodes.map { it.id }
                assertEquals(4,g.nodes.size);assertEquals(text,view.logicalText.toString())
                assertEquals(3,g.nodes.count { it.missingLinkPaint?.fixedPolicy!=null })
                val nested=g.nodes.single { it.label.toString()=="Nested Figure" }
                assertNull(nested.missingLinkPaint)
                assertTrue(colorPixels(view,0xff009900.toInt())>0)
                assertEquals(4,view.accessibilityNodeProvider.createAccessibilityNodeInfo(View.NO_ID)!!.childCount)
                assertTrue(view.accessibilityNodeProvider.performAction(nested.id,AccessibilityNodeInfo.ACTION_CLICK,null))
                assertEquals(listOf(EntryLink("nested")),clicks)
                ownNestedPolicy.value=true
            }
            compose.waitForIdle();assertSame(view,nativeView())
            compose.runOnIdle {
                val g=checkNotNull(geometry)
                assertEquals(text,g.text.toString());assertEquals(ids,g.nodes.map { it.id })
                assertEquals(4,g.nodes.count { it.missingLinkPaint?.fixedPolicy!=null })
                val nested=g.nodes.single { it.label.toString()=="Nested Figure" }
                assertEquals(green,nested.missingLinkPaint!!.fixedPolicy)
                assertEquals(0xff009900.toInt(),nested.missingLinkPaint!!.appearance().color)
                g.nodes.filter { it.id!=nested.id }.forEach {
                    assertEquals(policy(),it.missingLinkPaint!!.fixedPolicy)
                }
                assertTrue(view.accessibilityNodeProvider.performAction(nested.id,AccessibilityNodeInfo.ACTION_CLICK,null))
                assertEquals(listOf(EntryLink("nested"),EntryLink("nested")),clicks)
                view.setSelection(0,g.text.length)
                assertEquals(g.text.length,view.selectionEnd)
            }
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} };compose.waitForIdle() }
    }

    @Test fun atomicMissingUsesPrincipalFontBandAndChildBorderWithoutVerticalMarginHits() {
        val label=Span("link","Missing label wraps across several lines","File:Missing")
        val labelWidth=mutableStateOf(90f)
        val noUnderline=FigureLinkPaint(
            FigureLinkState("#d73333",false),FigureLinkState("#b32424",false),FigureLinkState("#8e1717",false),
            FigureLinkState("#a55858",false),FigureLinkState("#854545",false),FigureLinkState("#623333",false),false,
            FigureFocusOutline(px(2f),FigureColor.Rgb("#00aa00"),px(2f),SignedContainerMargin(StyleLengthUnit.Px,0f)))
        val visits=MissingLinkVisits()
        val clicks=mutableListOf<EntryLink>()
        var geometry:FloatTextGeometry?=null
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                MaterialTheme { CompositionLocalProvider(LocalDensity provides Density(1f,1f),
                    LocalMissingLinkVisits provides visits) {
                    val base=figure(emptyList())
                    val value=base.copy(content=FigureContent.Missing(label,px(labelWidth.value),px(24f)),
                        imageInsets=StyleEdges(px(20f),px(11f),px(30f),px(7f)),
                        imageBorder=FigureBorder.Solid(px(1f),FigureColor.Rgb("#000000")),
                        tableCaptionLayout=base.tableCaptionLayout!!.copy(captionLinkPaint=null,missingLinkPaint=noUnderline))
                    AnonymousBlockView(Block("paragraph",0,emptyList(),figure=value),Modifier,{clicks+=it},emptyList(),
                        AppSettings(allowImages=false,allowAudio=false),"th",onGeometry={geometry=it})
                } }
            } }
            compose.waitForIdle()
            val view=nativeView()
            var identity:MissingLinkActionIdentity?=null;var id=0;var text="";var initialHeight=0f
            compose.runOnIdle {
                val g=checkNotNull(geometry);val node=g.nodes.single()
                id=node.id;text=g.text.toString();identity=node.missingLinkPaint!!.actionIdentity
                val parts=node.bounds.sortedByDescending { it.width() }
                assertEquals(2,parts.size)
                val font=parts[0];val border=parts[1];initialHeight=border.height()
                assertEquals(110f,font.width(),0.01f);assertEquals(92f,border.width(),0.01f)
                assertEquals(border.left-7f,font.left,0.01f);assertEquals(border.right+11f,font.right,0.01f)
                assertTrue(border.height()>font.height()*2)
                assertTrue(node.contains(font.left+1f,font.centerY()))
                assertFalse(node.contains(font.left+1f,border.top+1f))
                assertFalse(node.contains(border.centerX(),border.top-10f))
                assertFalse(node.contains(border.centerX(),maxOf(font.bottom,border.bottom)+10f))
                assertTrue(node.focusPaint is NativeNodeFocusPaint.Connected)
                assertEquals(1,view.accessibilityNodeProvider.createAccessibilityNodeInfo(View.NO_ID)!!.childCount)
                hover(view,node,MotionEvent.ACTION_HOVER_ENTER)
                assertEquals(0xffb32424.toInt(),node.missingLinkPaint!!.appearance().color)
                assertFalse(node.missingLinkPaint!!.appearance().underline)
                assertTrue(colorPixels(view,0xffb32424.toInt())>0)
                hover(view,node,MotionEvent.ACTION_HOVER_EXIT)
                assertTrue(view.accessibilityNodeProvider.performAction(id,AccessibilityNodeInfo.ACTION_FOCUS,null))
                assertFalse(node.missingLinkPaint!!.appearance().underline)
                assertTrue(colorPixels(view,0xff00aa00.toInt())>0)
                view.setSelection(node.start,node.end)
                assertEquals(text.substring(node.start,node.end),view.logicalText.subSequence(view.selectionStart,view.selectionEnd).toString())
                view.dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN,KeyEvent.KEYCODE_ESCAPE))
                view.dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN,KeyEvent.KEYCODE_ENTER))
                view.dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_UP,KeyEvent.KEYCODE_ENTER))
                assertEquals(listOf(EntryLink("File:Missing")),clicks)
                labelWidth.value=140f
            }
            compose.waitForIdle();assertSame(view,nativeView())
            compose.runOnIdle {
                val g=checkNotNull(geometry);val node=g.nodes.single()
                assertEquals(id,node.id);assertEquals(text,g.text.toString())
                assertEquals(identity,node.missingLinkPaint!!.actionIdentity)
                assertTrue(node.missingLinkPaint!!.visited)
                assertEquals(0xffa55858.toInt(),node.missingLinkPaint!!.appearance().color)
                assertTrue(node.bounds.minBy { it.width() }.height()<initialHeight)
                assertEquals(1,view.accessibilityNodeProvider.createAccessibilityNodeInfo(View.NO_ID)!!.childCount)
                assertEquals(listOf(EntryLink("File:Missing")),clicks)
            }
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} };compose.waitForIdle() }
    }

    @Test fun connectedFocusContourPaintsNoInternalEdgesAndKeepsInsetPartsConnected() {
        val bitmap=Bitmap.createBitmap(130,90,Bitmap.Config.ARGB_8888)
        val rectangles=listOf(android.graphics.RectF(10f,40f,110f,55f),android.graphics.RectF(20f,10f,100f,60f))
        fun draw(offset:Float) {
            bitmap.eraseColor(android.graphics.Color.WHITE)
            paintNativeFocus(Canvas(bitmap),NativeNodeFocusPaint.Connected(rectangles.map {
                NativeNodeFocusPaint.Outline(it,2f,android.graphics.Color.RED,0f,offset)
            }))
        }
        try {
            draw(0f)
            assertEquals(android.graphics.Color.RED,bitmap.getPixel(19,20))
            assertEquals(android.graphics.Color.RED,bitmap.getPixel(9,48))
            assertEquals(android.graphics.Color.WHITE,bitmap.getPixel(50,40))
            assertEquals(android.graphics.Color.WHITE,bitmap.getPixel(12,20))
            draw(-100f)
            val ink=mutableSetOf<Int>()
            for(y in 0 until bitmap.height) for(x in 0 until bitmap.width)
                if(bitmap.getPixel(x,y)!=android.graphics.Color.WHITE) ink+=y*bitmap.width+x
            assertTrue(ink.isNotEmpty())
            val reached=mutableSetOf(ink.first());val pending=java.util.ArrayDeque<Int>();pending.add(ink.first())
            while(pending.isNotEmpty()) {
                val current=pending.removeFirst();val x=current%bitmap.width;val y=current/bitmap.width
                for(dy in -1..1) for(dx in -1..1) {
                    val nx=x+dx;val ny=y+dy
                    if(nx !in 0 until bitmap.width || ny !in 0 until bitmap.height) continue
                    val next=ny*bitmap.width+nx
                    if(next in ink && reached.add(next)) pending.add(next)
                }
            }
            assertEquals(ink,reached)
            val translated=NativeNodeFocusPaint.Connected(rectangles.map {
                NativeNodeFocusPaint.Outline(it,2f,android.graphics.Color.RED,0f,0f)
            }).translated(5f,7f) as NativeNodeFocusPaint.Connected
            assertEquals(rectangles[0].left+5f,translated.outlines[0].bounds.left,0f)
            assertEquals(rectangles[1].top+7f,translated.outlines[1].bounds.top,0f)
        } finally { bitmap.recycle() }
    }

    @Test fun nativeCssPixelCaptionKeepsGlyphsSourceSelectionAndZeroAdvanceKeyboardFocusAcrossZoomAndReset() {
        val span=mutableStateOf(Span("link","MMMM","Font target",fontScale=12.375f,
            fontScaleBasis=FontScaleBasis.CssPx,bold=true,italic=true))
        val zoom=mutableStateOf(1f)
        val clicks=mutableListOf<EntryLink>()
        val visits=MissingLinkVisits()
        var geometry:FloatTextGeometry?=null
        var actualDensity:Density?=null
        val textStyle=androidx.compose.ui.text.TextStyle(fontSize=20.sp,fontFamily=FontFamily.Monospace)
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                MaterialTheme(typography=Typography(bodyLarge=textStyle)) {
                    actualDensity=LocalDensity.current
                    CompositionLocalProvider(LocalCssPixelTextZoom provides zoom.value,LocalMissingLinkVisits provides visits) {
                        val value=figure(listOf(Span("text","prefix "),span.value,Span("text"," suffix")),220f)
                        AnonymousBlockView(Block("paragraph",0,emptyList(),figure=value),Modifier,{clicks+=it},emptyList(),
                            AppSettings(allowImages=false,allowAudio=false),"fi",onGeometry={geometry=it})
                    }
                }
            } }
            compose.waitForIdle()
            val view=nativeView()
            var originalText=""
            fun node()=checkNotNull(geometry).nodes.single { it.missingLinkPaint?.fixedPolicy!=null }
            fun verifyPositive() {
                val g=checkNotNull(geometry);val n=node();val density=checkNotNull(actualDensity)
                assertEquals(originalText,g.text.toString());assertEquals(originalText,view.logicalText.toString())
                assertEquals("MMMM",g.text.subSequence(n.start,n.end).toString())
                assertEquals(1,view.accessibilityNodeProvider.createAccessibilityNodeInfo(View.NO_ID)!!.childCount)
                val pixels=if(span.value.fontScaleBasis==FontScaleBasis.CssPx)
                    with(density) { (span.value.fontScale!!*zoom.value).sp.toPx() }
                    else with(density) { 20.sp.toPx() }*span.value.fontScale!!
                val expected=android.text.TextPaint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply {
                    textSize=pixels
                    typeface=android.graphics.Typeface.create(android.graphics.Typeface.MONOSPACE,android.graphics.Typeface.BOLD_ITALIC)
                }.measureText("MMMM")
                assertEquals(expected,n.bounds.sumOf { it.width().toDouble() }.toFloat(),n.bounds.size+2f)
                val color=if(clicks.any { it==EntryLink(span.value.target) }) 0xff6a60b0.toInt() else 0xff3366cc.toInt()
                assertTrue(colorPixels(view,color)>0)
                view.setSelection(n.start,n.end)
                assertEquals("MMMM",view.selectedTextForCopy())
                view.dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN,KeyEvent.KEYCODE_ESCAPE))
                val count=clicks.size;val down=SystemClock.uptimeMillis()
                event(view,n,MotionEvent.ACTION_DOWN,down);event(view,n,MotionEvent.ACTION_UP,down)
                assertEquals(count+1,clicks.size);assertEquals(EntryLink(span.value.target),clicks.last())
                assertFalse(n.missingLinkPaint!!.focused)
            }
            compose.runOnIdle {
                originalText=checkNotNull(geometry).text.toString();verifyPositive()
                span.value=span.value.copy(fontScale=0f)
            }
            compose.waitForIdle();assertSame(view,nativeView())
            compose.runOnIdle {
                val g=checkNotNull(geometry);val n=node()
                assertEquals(originalText,g.text.toString());assertEquals("MMMM",n.label.toString())
                assertTrue(n.bounds.all { it.isEmpty });assertEquals(0,colorPixels(view,0xff3366cc.toInt()))
                assertEquals(0,colorPixels(view,0xff6a60b0.toInt()))
                val parts=(n.focusPaint as NativeNodeFocusPaint.Fragments).outlines
                assertTrue(parts.isNotEmpty());assertTrue(parts.all { it.bounds.width()==0f })
                parts.forEach { part ->
                    val bounds=part.bounds
                    assertFalse(n.contains(bounds.left,bounds.centerY()))
                    val ink=checkNotNull(nativeOutlineGeometry(NativeFloatBounds(bounds.left,bounds.top,bounds.right,bounds.bottom),
                        part.width,part.radius,part.offset)).ink
                    assertTrue(ink.width>=2*part.width);assertTrue(ink.height>=2*part.width)
                }
                assertEquals(1,view.accessibilityNodeProvider.createAccessibilityNodeInfo(View.NO_ID)!!.childCount)
                assertTrue(view.accessibilityNodeProvider.performAction(n.id,AccessibilityNodeInfo.ACTION_ACCESSIBILITY_FOCUS,null))
                assertFalse(n.missingLinkPaint!!.focused);assertEquals(0,colorPixels(view,android.graphics.Color.RED))
                view.requestFocus()
                assertTrue(view.dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN,KeyEvent.KEYCODE_TAB)))
                assertTrue(n.missingLinkPaint!!.focused);assertTrue(colorPixels(view,android.graphics.Color.RED)>0)
                val count=clicks.size
                view.dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN,KeyEvent.KEYCODE_ENTER));assertEquals(count,clicks.size)
                view.dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_UP,KeyEvent.KEYCODE_ENTER));assertEquals(count+1,clicks.size)
                assertEquals(EntryLink("Font target"),clicks.last())
                view.setSelection(n.start,n.end);assertEquals("MMMM",view.selectedTextForCopy())
                view.dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN,KeyEvent.KEYCODE_ESCAPE));view.clearFocus()
                span.value=span.value.copy(fontScale=12.375f);zoom.value=1.5f
            }
            compose.waitForIdle();assertSame(view,nativeView())
            compose.runOnIdle { verifyPositive();span.value=span.value.copy(fontScale=40f) }
            compose.waitForIdle();assertSame(view,nativeView())
            compose.runOnIdle {
                verifyPositive()
                span.value=span.value.copy(fontScale=1.25f,fontScaleBasis=FontScaleBasis.Context,target="Reset target")
            }
            compose.waitForIdle();assertSame(view,nativeView())
            compose.runOnIdle {
                verifyPositive()
                assertEquals(EntryLink("Reset target"),clicks.last())
                assertEquals(1,view.accessibilityNodeProvider.createAccessibilityNodeInfo(View.NO_ID)!!.childCount)
            }
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} };compose.waitForIdle() }
    }

    @Test fun pointerOwnerReconciliationRejectsIncomingOwnersButRetainsSameOwnerReflow() {
        data class Frame(val text:String,val fixed:Boolean,val owner:Any,val width:Int,val click:()->Unit,val longClick:()->Unit)
        var clicks=0;var replacementClicks=0;var longClicks=0
        val click:()->Unit={clicks++};val replacement:()->Unit={replacementClicks++};val longClick:()->Unit={longClicks++}
        val state=mutableStateOf(Frame("same label",false,Any(),220,click,longClick))
        var geometry:FloatTextGeometry?=null
        val paint=android.text.TextPaint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply { textSize=24f }
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                val current=state.value
                Layout(content={AndroidView(factory={NativeFloatTextView(it)},update={view ->
                    view.bind({ width -> NativeFloatGeometry.build(android.text.SpannableString(current.text),paint,width,emptyList(),nodeFactory={ g ->
                        val appearance=if(current.fixed) NativeMissingLinkPaint(policy(),false,actionIdentity=
                            MissingLinkActionIdentity(current.owner,MissingLinkTarget("fi","link","same target",null),current.text)) else null
                        listOf(FloatInteractionNode(0,FloatInteractionKind.LINK,0,current.text.length,
                            g.rectsForRange(0,current.text.length),current.text,null,
                            if(current.fixed) ({current.click()}) else current.click,onLongClick=current.longClick,missingLinkPaint=appearance))
                    }).also { geometry=it } },0x6633b5e5,0xff1686c7.toInt())
                })}) { children,_ ->
                    val child=children.single().measure(Constraints.fixedWidth(current.width))
                    layout(current.width,child.height) { child.place(0,0) }
                }
            } }
            compose.waitForIdle()
            val view=nativeView()
            fun node()=checkNotNull(geometry).nodes.single()
            var down=0L
            fun rejectTransition(next:Frame) {
                val beforeClicks=clicks;val beforeReplacement=replacementClicks;val beforeLong=longClicks
                compose.runOnIdle { down=SystemClock.uptimeMillis();event(view,node(),MotionEvent.ACTION_DOWN,down);state.value=next }
                compose.waitForIdle();assertSame(view,nativeView())
                Thread.sleep(android.view.ViewConfiguration.getLongPressTimeout().toLong()+100L)
                compose.runOnIdle {
                    assertEquals(beforeLong,longClicks);assertFalse(view.selectionActive)
                    event(view,node(),MotionEvent.ACTION_UP,down)
                    assertEquals(beforeClicks,clicks);assertEquals(beforeReplacement,replacementClicks)
                }
            }
            rejectTransition(state.value.copy(fixed=true)) // Incoming fixed policy, same href and text.
            compose.runOnIdle { state.value=state.value.copy(fixed=false,owner=Any()) };compose.waitForIdle()
            rejectTransition(state.value.copy(fixed=true,text="replacement label",owner=Any()))
            compose.runOnIdle { state.value=state.value.copy(fixed=false,owner=Any()) };compose.waitForIdle()
            rejectTransition(state.value.copy(click=replacement)) // Changed ordinary action is not exempt.
            compose.runOnIdle {
                down=SystemClock.uptimeMillis();event(view,node(),MotionEvent.ACTION_DOWN,down)
                state.value=state.value.copy(width=200) // Ordinary owner retains its exact callback.
            }
            compose.waitForIdle();assertSame(view,nativeView())
            compose.runOnIdle { event(view,node(),MotionEvent.ACTION_UP,down);assertEquals(1,replacementClicks) }
            compose.runOnIdle { state.value=state.value.copy(fixed=true,owner=Any(),click=click) };compose.waitForIdle()
            val before=clicks
            compose.runOnIdle {
                down=SystemClock.uptimeMillis();event(view,node(),MotionEvent.ACTION_DOWN,down)
                state.value=state.value.copy(width=160) // New factory and callback, same semantic owner.
            }
            compose.waitForIdle();assertSame(view,nativeView())
            compose.runOnIdle { event(view,node(),MotionEvent.ACTION_UP,down);assertEquals(before+1,clicks) }
            compose.runOnIdle { down=SystemClock.uptimeMillis();event(view,node(),MotionEvent.ACTION_DOWN,down) }
            Thread.sleep(android.view.ViewConfiguration.getLongPressTimeout().toLong()+100L)
            compose.runOnIdle {
                assertEquals(1,longClicks);event(view,node(),MotionEvent.ACTION_CANCEL,down)
                down=SystemClock.uptimeMillis();event(view,node(),MotionEvent.ACTION_DOWN,down)
            }
            val detachedNode=node()
            compose.activityRule.scenario.onActivity { it.setContent {} };compose.waitForIdle()
            Thread.sleep(android.view.ViewConfiguration.getLongPressTimeout().toLong()+100L)
            compose.runOnIdle {
                assertEquals(1,longClicks);event(view,detachedNode,MotionEvent.ACTION_UP,down)
                assertEquals(before+1,clicks);assertEquals(1,replacementClicks)
            }
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} };compose.waitForIdle() }
    }
}
